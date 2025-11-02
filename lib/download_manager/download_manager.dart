// lib/download_manager/download_manager.dart
import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:download/download_manager/database_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../utils/permission_manager.dart';

enum DownloadStatus {
  pending,
  downloading,
  paused,
  completed,
  failed,
  cancelled
}

enum VideoType { mp4, m3u8 }

class DownloadTask {
  final String id;
  final String url;
  final String title;
  final VideoType type;
  String? savePath;
  DownloadStatus status;
  double progress;
  int downloadedBytes;
  int totalBytes;
  String? error;
  String? m3u8Key;
  String? m3u8IV;
  CancelToken? cancelToken;

  DownloadTask({
    required this.id,
    required this.url,
    required this.title,
    required this.type,
    this.savePath,
    this.status = DownloadStatus.pending,
    this.progress = 0.0,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.error,
    this.m3u8Key,
    this.m3u8IV,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    'title': title,
    'type': type.index,
    'savePath': savePath,
    'status': status.index,
    'progress': progress,
    'downloadedBytes': downloadedBytes,
    'totalBytes': totalBytes,
    'error': error,
    'm3u8Key': m3u8Key,
    'm3u8IV': m3u8IV,
  };

  factory DownloadTask.fromJson(Map<String, dynamic> json) => DownloadTask(
    id: json['id'].toString(),
    url: json['url'] as String,
    title: json['title'] as String,
    type: VideoType.values[json['type'] as int],
    savePath: json['savePath'] as String?,
    status: DownloadStatus.values[json['status'] as int],
    progress: (json['progress'] as num).toDouble(),
    downloadedBytes: json['downloadedBytes'] as int,
    totalBytes: json['totalBytes'] as int,
    error: json['error'] as String?,
    m3u8Key: json['m3u8Key'] as String?,
    m3u8IV: json['m3u8IV'] as String?,
  );
}

class DownloadManager {
  static final DownloadManager _instance = DownloadManager._internal();
  factory DownloadManager() => _instance;
  DownloadManager._internal();

  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(minutes: 5),
  ));

  final Map<String, DownloadTask> _tasks = {};
  final List<String> _downloadQueue = [];
  final int _maxConcurrent = 3;
  int _activeDownloads = 0;

  final _taskController = StreamController<DownloadTask>.broadcast();
  Stream<DownloadTask> get taskStream => _taskController.stream;

  late DatabaseHelper _dbHelper;
  final _permissionManager = PermissionManager();

  Future<void> initialize() async {
    _dbHelper = DatabaseHelper();
    await _dbHelper.initialize();
    await _loadTasksFromDB();
    _processQueue();
  }

  Future<void> _loadTasksFromDB() async {
    final tasks = await _dbHelper.getAllTasks();
    print('📦 Loaded ${tasks.length} tasks from database');

    for (var task in tasks) {
      _tasks[task.id] = task;
      if (task.status == DownloadStatus.downloading) {
        task.status = DownloadStatus.paused;
        await _dbHelper.updateTask(task);
      }
      print('  - ${task.title}: ${task.status.name}');
    }
  }

  Future<String?> addDownloadWithPermission({
    required BuildContext context,
    required String url,
    required String title,
    String? m3u8Key,
    String? m3u8IV,
  }) async {
    final hasPermission = await _permissionManager.requestStoragePermission(context);

    if (!hasPermission) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Storage permission is required'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return null;
    }

    final id = addDownload(
      url: url,
      title: title,
      m3u8Key: m3u8Key,
      m3u8IV: m3u8IV,
    );

    return id;
  }

  String addDownload({
    required String url,
    required String title,
    String? m3u8Key,
    String? m3u8IV,
  }) {
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final type = url.toLowerCase().contains('.m3u8')
        ? VideoType.m3u8
        : VideoType.mp4;

    final task = DownloadTask(
      id: id,
      url: url,
      title: title,
      type: type,
      m3u8Key: m3u8Key,
      m3u8IV: m3u8IV,
    );

    _tasks[id] = task;
    _downloadQueue.add(id);
    _dbHelper.insertTask(task);

    print('➕ Added task: $title');
    _notifyTaskUpdate(task);

    _processQueue();

    return id;
  }

  Future<void> _processQueue() async {
    print('🔄 Processing queue: ${_downloadQueue.length} tasks, $_activeDownloads active');

    while (_activeDownloads < _maxConcurrent && _downloadQueue.isNotEmpty) {
      final taskId = _downloadQueue.removeAt(0);
      final task = _tasks[taskId];

      if (task != null && task.status == DownloadStatus.pending) {
        print('🚀 Starting download: ${task.title}');
        _activeDownloads++;
        _startDownload(task);
      }
    }
  }

  Future<void> _startDownload(DownloadTask task) async {
    task.status = DownloadStatus.downloading;
    task.cancelToken = CancelToken();
    task.error = null;
    _notifyTaskUpdate(task);
    await _dbHelper.updateTask(task);

    try {
      if (task.type == VideoType.mp4) {
        await _downloadMP4(task);
      } else {
        await _downloadM3U8(task);
      }
    } catch (e) {
      print('❌ Download error: $e');

      if (e is DioException && e.type == DioExceptionType.cancel) {
        print('⏸️ Download cancelled by user');
        return;
      }

      task.status = DownloadStatus.failed;
      task.error = e.toString();
      _notifyTaskUpdate(task);
      await _dbHelper.updateTask(task);
    } finally {
      _activeDownloads--;
      print('✅ Download finished: ${task.title}, active: $_activeDownloads');
      _processQueue();
    }
  }

  Future<void> _downloadMP4(DownloadTask task) async {
    final dir = await getApplicationDocumentsDirectory();
    final savePath = '${dir.path}/downloads/${task.id}.mp4';
    final file = File(savePath);

    await file.parent.create(recursive: true);
    task.savePath = savePath;

    int downloadedBytes = 0;
    if (await file.exists()) {
      downloadedBytes = await file.length();
      task.downloadedBytes = downloadedBytes;
      print('📥 Resuming from: ${_formatBytes(downloadedBytes)}');
    }

    print('⬇️ Starting download: ${task.url}');
    print('💾 Save to: $savePath');

    // ⭐ 追踪上次通知的进度
    double lastNotifiedProgress = 0;
    int lastPrintedPercent = 0;

    await _dio.download(
      task.url,
      savePath,
      onReceiveProgress: (received, total) {
        if (total != -1) {
          task.downloadedBytes = received + downloadedBytes;
          task.totalBytes = total + downloadedBytes;
          task.progress = (received + downloadedBytes) / (total + downloadedBytes);

          // ⭐ 关键：每 0.5% 通知一次 UI 更新
          if ((task.progress - lastNotifiedProgress) >= 0.005 || task.progress == 1.0) {
            lastNotifiedProgress = task.progress;
            _notifyTaskUpdate(task);
          }

          // 每 5% 打印一次日志
          int currentPercent = (task.progress * 100).toInt();
          if (currentPercent % 5 == 0 && currentPercent != lastPrintedPercent) {
            lastPrintedPercent = currentPercent;
            print('📊 ${task.title}: $currentPercent% - ${_formatBytes(task.downloadedBytes)}/${_formatBytes(task.totalBytes)}');
          }
        }
      },
      cancelToken: task.cancelToken,
      options: Options(
        headers: downloadedBytes > 0
            ? {'Range': 'bytes=$downloadedBytes-'}
            : {},
      ),
      deleteOnError: false,
    );

    task.status = DownloadStatus.completed;
    task.progress = 1.0;
    _notifyTaskUpdate(task);
    await _dbHelper.updateTask(task);

    print('✅ Download completed: ${task.title}');
  }

  Future<void> _downloadM3U8(DownloadTask task) async {
    final dir = await getApplicationDocumentsDirectory();
    final tempDir = Directory('${dir.path}/downloads/${task.id}_temp');
    await tempDir.create(recursive: true);

    final response = await _dio.get(task.url);
    final m3u8Content = response.data as String;
    final segments = _parseM3U8(m3u8Content, task.url);

    task.totalBytes = segments.length;
    print('📺 M3U8 has ${segments.length} segments');

    final segmentFiles = <File>[];
    for (int i = 0; i < segments.length; i++) {
      if (task.cancelToken?.isCancelled ?? false) {
        throw DioException(
          requestOptions: RequestOptions(path: task.url),
          type: DioExceptionType.cancel,
        );
      }

      final segmentPath = '${tempDir.path}/segment_$i.ts';
      final segmentFile = File(segmentPath);

      if (!await segmentFile.exists()) {
        try {
          await _dio.download(
            segments[i],
            segmentPath,
            cancelToken: task.cancelToken,
          );
        } catch (e) {
          if (e is DioException && e.response?.statusCode == 404) {
            rethrow;
          }
          throw e;
        }
      }

      if (task.m3u8Key != null) {
        await _decryptSegment(segmentFile, task.m3u8Key!, task.m3u8IV);
      }

      segmentFiles.add(segmentFile);
      task.downloadedBytes = i + 1;
      task.progress = (i + 1) / segments.length;

      // ⭐ 每个分片下载完就通知
      _notifyTaskUpdate(task);

      if ((i + 1) % 10 == 0 || i == segments.length - 1) {
        print('📊 M3U8: ${i + 1}/${segments.length} segments (${(task.progress * 100).toStringAsFixed(1)}%)');
      }
    }

    print('🔗 Merging segments...');
    final outputPath = '${dir.path}/downloads/${task.id}.mp4';
    await _mergeSegments(segmentFiles, outputPath);

    await tempDir.delete(recursive: true);

    task.savePath = outputPath;
    task.status = DownloadStatus.completed;
    task.progress = 1.0;
    _notifyTaskUpdate(task);
    await _dbHelper.updateTask(task);
  }

  List<String> _parseM3U8(String content, String baseUrl) {
    final lines = content.split('\n');
    final segments = <String>[];
    final baseUri = Uri.parse(baseUrl);

    for (var line in lines) {
      line = line.trim();
      if (line.isNotEmpty && !line.startsWith('#')) {
        final segmentUrl = line.startsWith('http')
            ? line
            : baseUri.resolve(line).toString();
        segments.add(segmentUrl);
      }
    }

    return segments;
  }

  Future<void> _decryptSegment(File file, String key, String? iv) async {
    final result = await compute(_decryptInIsolate, {
      'filePath': file.path,
      'key': key,
      'iv': iv,
    });

    if (!result) {
      throw Exception('Decryption failed');
    }
  }

  static Future<bool> _decryptInIsolate(Map<String, dynamic> params) async {
    try {
      // TODO: 实现 AES-128 解密
      return true;
    } catch (e) {
      debugPrint('Decrypt error: $e');
      return false;
    }
  }

  Future<void> _mergeSegments(List<File> segments, String outputPath) async {
    final output = File(outputPath);
    final sink = output.openWrite();

    for (var segment in segments) {
      await sink.addStream(segment.openRead());
    }

    await sink.close();
  }

  void pauseDownload(String taskId) {
    final task = _tasks[taskId];
    if (task != null && task.status == DownloadStatus.downloading) {
      print('⏸️ Pausing: ${task.title}');

      task.cancelToken?.cancel('User paused');
      task.status = DownloadStatus.paused;

      _notifyTaskUpdate(task);
      _dbHelper.updateTask(task);
    }
  }

  void resumeDownload(String taskId) {
    final task = _tasks[taskId];
    if (task != null &&
        (task.status == DownloadStatus.paused ||
            task.status == DownloadStatus.failed)) {

      print('▶️ Resuming: ${task.title}');

      task.status = DownloadStatus.pending;
      task.error = null;

      if (!_downloadQueue.contains(taskId)) {
        _downloadQueue.add(taskId);
      }

      _notifyTaskUpdate(task);
      _dbHelper.updateTask(task);

      _processQueue();
    }
  }

  Future<void> cancelDownload(String taskId) async {
    final task = _tasks[taskId];
    if (task != null) {
      print('❌ Cancelling: ${task.title}');

      task.cancelToken?.cancel('User cancelled');
      task.status = DownloadStatus.cancelled;

      if (task.savePath != null) {
        final file = File(task.savePath!);
        if (await file.exists()) {
          await file.delete();
        }

        if (task.type == VideoType.m3u8) {
          final tempDir = Directory('${task.savePath!}_temp');
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        }
      }

      _tasks.remove(taskId);
      _downloadQueue.remove(taskId);
      await _dbHelper.deleteTask(taskId);

      _notifyTaskUpdate(task);
    }
  }

  DownloadTask? getTask(String taskId) => _tasks[taskId];

  List<DownloadTask> getAllTasks() {
    final tasks = _tasks.values.toList();
    tasks.sort((a, b) => b.id.compareTo(a.id));
    return tasks;
  }

  void _notifyTaskUpdate(DownloadTask task) {
    if (!_taskController.isClosed) {
      _taskController.add(task);
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  void dispose() {
    _taskController.close();
  }
}