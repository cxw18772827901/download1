// lib/download_manager/download_manager.dart
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:dio/dio.dart';
import 'package:download/download_manager/database_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

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
    id: json['id'],
    url: json['url'],
    title: json['title'],
    type: VideoType.values[json['type']],
    savePath: json['savePath'],
    status: DownloadStatus.values[json['status']],
    progress: json['progress'],
    downloadedBytes: json['downloadedBytes'],
    totalBytes: json['totalBytes'],
    error: json['error'],
    m3u8Key: json['m3u8Key'],
    m3u8IV: json['m3u8IV'],
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

  Future<void> initialize() async {
    _dbHelper = DatabaseHelper();
    await _dbHelper.initialize();
    await _loadTasksFromDB();
    _processQueue();
  }

  Future<void> _loadTasksFromDB() async {
    final tasks = await _dbHelper.getAllTasks();
    for (var task in tasks) {
      _tasks[task.id] = task;
      if (task.status == DownloadStatus.downloading) {
        task.status = DownloadStatus.paused;
      }
    }
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
    _processQueue();

    return id;
  }

  Future<void> _processQueue() async {
    while (_activeDownloads < _maxConcurrent && _downloadQueue.isNotEmpty) {
      final taskId = _downloadQueue.removeAt(0);
      final task = _tasks[taskId];

      if (task != null && task.status != DownloadStatus.downloading) {
        _activeDownloads++;
        _startDownload(task);
      }
    }
  }

  Future<void> _startDownload(DownloadTask task) async {
    task.status = DownloadStatus.downloading;
    task.cancelToken = CancelToken();
    _notifyTaskUpdate(task);

    try {
      if (task.type == VideoType.mp4) {
        await _downloadMP4(task);
      } else {
        await _downloadM3U8(task);
      }
    } catch (e) {
      if (e is DioException && e.response?.statusCode == 404) {
        // 404 错误，删除已下载内容
        await _handle404Error(task);
      } else {
        task.status = DownloadStatus.failed;
        task.error = e.toString();
        _notifyTaskUpdate(task);
      }
    } finally {
      _activeDownloads--;
      await _dbHelper.updateTask(task);
      _processQueue();
    }
  }

  Future<void> _handle404Error(DownloadTask task) async {
    debugPrint('Handle 404 for task: ${task.title}');

    // 删除已下载的文件
    if (task.savePath != null) {
      final file = File(task.savePath!);
      if (await file.exists()) {
        await file.delete();
      }

      // 如果是 m3u8，删除临时文件夹
      if (task.type == VideoType.m3u8) {
        final dir = Directory('${task.savePath!}_temp');
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      }
    }

    // 重置任务状态
    task.status = DownloadStatus.failed;
    task.progress = 0;
    task.downloadedBytes = 0;
    task.totalBytes = 0;
    task.error = '404 Not Found - Please update URL and retry';
    task.savePath = null;

    _notifyTaskUpdate(task);
    await _dbHelper.updateTask(task);
  }

  Future<void> _downloadMP4(DownloadTask task) async {
    final dir = await getApplicationDocumentsDirectory();
    final savePath = '${dir.path}/downloads/${task.id}.mp4';
    final file = File(savePath);

    await file.parent.create(recursive: true);
    task.savePath = savePath;

    // 检查断点续传
    int downloadedBytes = 0;
    if (await file.exists()) {
      downloadedBytes = await file.length();
      task.downloadedBytes = downloadedBytes;
    }

    await _dio.download(
      task.url,
      savePath,
      onReceiveProgress: (received, total) {
        if (total != -1) {
          task.downloadedBytes = received + downloadedBytes;
          task.totalBytes = total + downloadedBytes;
          task.progress = (received + downloadedBytes) / (total + downloadedBytes);
          _notifyTaskUpdate(task);
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
  }

  Future<void> _downloadM3U8(DownloadTask task) async {
    final dir = await getApplicationDocumentsDirectory();
    final tempDir = Directory('${dir.path}/downloads/${task.id}_temp');
    await tempDir.create(recursive: true);

    // 下载并解析 m3u8
    final response = await _dio.get(task.url);
    final m3u8Content = response.data as String;
    final segments = _parseM3U8(m3u8Content, task.url);

    task.totalBytes = segments.length;

    // 下载所有分片
    final segmentFiles = <File>[];
    for (int i = 0; i < segments.length; i++) {
      if (task.cancelToken?.isCancelled ?? false) {
        throw Exception('Download cancelled');
      }

      final segmentPath = '${tempDir.path}/segment_$i.ts';
      final segmentFile = File(segmentPath);

      // 检查是否已下载
      if (!await segmentFile.exists()) {
        try {
          await _dio.download(
            segments[i],
            segmentPath,
            cancelToken: task.cancelToken,
          );
        } catch (e) {
          if (e is DioException && e.response?.statusCode == 404) {
            rethrow; // 重新抛出 404 错误以便上层处理
          }
          throw e;
        }
      }

      // 解密（如果需要）
      if (task.m3u8Key != null) {
        await _decryptSegment(segmentFile, task.m3u8Key!, task.m3u8IV);
      }

      segmentFiles.add(segmentFile);
      task.downloadedBytes = i + 1;
      task.progress = (i + 1) / segments.length;
      _notifyTaskUpdate(task);
    }

    // 合并分片
    final outputPath = '${dir.path}/downloads/${task.id}.mp4';
    await _mergeSegments(segmentFiles, outputPath);

    // 清理临时文件
    await tempDir.delete(recursive: true);

    task.savePath = outputPath;
    task.status = DownloadStatus.completed;
    task.progress = 1.0;
    _notifyTaskUpdate(task);
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
    // 使用 isolate 在后台解密，避免卡顿
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
      final file = File(params['filePath']);
      final key = params['key'] as String;
      final iv = params['iv'] as String?;

      // 这里实现 AES 解密逻辑
      // 使用 encrypt 包进行解密
      final bytes = await file.readAsBytes();

      // TODO: 实现具体的 AES-128 解密
      // final decrypted = ...;

      // await file.writeAsBytes(decrypted);
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
      task.cancelToken?.cancel();
      task.status = DownloadStatus.paused;
      _notifyTaskUpdate(task);
      _dbHelper.updateTask(task);
    }
  }

  void resumeDownload(String taskId) {
    final task = _tasks[taskId];
    if (task != null && task.status == DownloadStatus.paused) {
      _downloadQueue.add(taskId);
      _processQueue();
    }
  }

  void cancelDownload(String taskId) async {
    final task = _tasks[taskId];
    if (task != null) {
      task.cancelToken?.cancel();
      task.status = DownloadStatus.cancelled;

      // 删除下载文件
      if (task.savePath != null) {
        final file = File(task.savePath!);
        if (await file.exists()) {
          await file.delete();
        }
      }

      _tasks.remove(taskId);
      _downloadQueue.remove(taskId);
      await _dbHelper.deleteTask(taskId);
      _notifyTaskUpdate(task);
    }
  }

  DownloadTask? getTask(String taskId) => _tasks[taskId];

  List<DownloadTask> getAllTasks() => _tasks.values.toList();

  void _notifyTaskUpdate(DownloadTask task) {
    _taskController.add(task);
  }

  void dispose() {
    _taskController.close();
  }
}