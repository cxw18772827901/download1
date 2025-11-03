// lib/download_manager/download_manager.dart
import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:download/download_manager/database_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
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
  String url;
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
    Directory? saveRoot = await getApplicationDocumentsDirectory();
    if (Platform.isAndroid) {
      // var dir = await getExternalStorageDirectory();
      saveRoot = Directory('/storage/emulated/0/Download/');
      if (!await saveRoot.exists()) {
        await saveRoot.create(recursive: true);
      }
    }
    var savePath = '${saveRoot.path}/downloads/${task.id}.mp4';
    if(Platform.isAndroid){
      savePath = '${saveRoot.path}/${task.id}.mp4';
    }
    final file = File(savePath);

    await file.parent.create(recursive: true);
    task.savePath = savePath;

    int downloadedBytes = 0;
    if (await file.exists()) {
      downloadedBytes = await file.length();
      task.downloadedBytes = downloadedBytes;
      print('📥 Resuming from: ${_formatBytes(task.type, downloadedBytes)}');
    }

    print('⬇️ Starting download: ${task.url}');
    print('💾 Save to: $savePath');

    // 追踪上次通知的进度
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

          // 关键：每 0.5% 通知一次 UI 更新
          if ((task.progress - lastNotifiedProgress) >= 0.005 || task.progress == 1.0) {
            lastNotifiedProgress = task.progress;
            _notifyTaskUpdate(task);
          }

          // 每 5% 打印一次日志
          int currentPercent = (task.progress * 100).toInt();
          if (currentPercent % 5 == 0 && currentPercent != lastPrintedPercent) {
            lastPrintedPercent = currentPercent;
            print('📊 ${task.title}: $currentPercent% - ${_formatBytes(task.type, task.downloadedBytes)}/${_formatBytes(task.type, task.totalBytes)}');
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

    // 自动保存到相册
    await _saveVideoToGallery(task.savePath!);

    print('✅ Download completed: ${task.title}');
  }

  /// ✅ 完整增强版 M3U8 下载，带 Master 检测 + 清晰度选择 + 实时进度回调
  Future<void> _downloadM3U8(DownloadTask task) async {
    Directory? saveRoot = await getApplicationDocumentsDirectory();
    if (Platform.isAndroid) {
      // var dir = await getExternalStorageDirectory();
      saveRoot = Directory('/storage/emulated/0/Download/');
      if (!await saveRoot.exists()) {
        await saveRoot.create(recursive: true);
      }
    }
    var tempDir = Directory('${saveRoot.path}/downloads/${task.id}_temp');
    if(Platform.isAndroid){
      tempDir = Directory('${saveRoot.path}/${task.id}_temp');
    }

    await tempDir.create(recursive: true);

    try {
      print('📡 Fetching M3U8: ${task.url}');
      final response = await _dio.get(task.url, cancelToken: task.cancelToken);
      final content = response.data as String;

      // 🧭 Step 1: 判断 Master playlist
      if (content.contains('#EXT-X-STREAM-INF')) {
        print('🧩 Detected Master M3U8, selecting best variant ...');
        final bestUrl = _selectBestVariant(content, task.url);
        print('🎯 Using best variant: $bestUrl');
        // return _downloadM3U8(task.copyWith(url: bestUrl, cancelToken: task.cancelToken));
        task.url = bestUrl; // 直接修改原 task
        return _downloadM3U8(task);
      }

      // 🟩 Step 2: Media Playlist，解析所有分片
      final segments = _parseM3U8(content, task.url);
      if (segments.isEmpty) throw Exception('No segments found in $task.url');

      task.totalBytes = segments.length;
      print('📺 Found ${segments.length} segments');

      final segmentFiles = <File>[];

      // 🕒 下载分片循环
      for (int i = 0; i < segments.length; i++) {
        if (task.cancelToken?.isCancelled ?? false) {
          throw DioException(
            requestOptions: RequestOptions(path: task.url),
            type: DioExceptionType.cancel,
          );
        }

        final segUrl = segments[i];
        final segPath = '${tempDir.path}/segment_$i.ts';
        final segFile = File(segPath);

        // 已存在则跳过
        if (await segFile.exists() && await segFile.length() > 0) {
          segmentFiles.add(segFile);
          task.downloadedBytes = i + 1;
          task.progress = (i + 1) / segments.length;
          _notifyTaskUpdate(task);
          continue;
        }

        // 每个分片下载支持重试
        int retries = 0;
        const maxRetries = 3;

        while (true) {
          try {
            int lastPrintedPercent = 0;

            await _dio.download(
              segUrl,
              segFile.path,
              cancelToken: task.cancelToken,
              deleteOnError: false,
              onReceiveProgress: (received, total) {
                // print('⬇️ segment $i progress: $received/$total');
                if (total <= 0) return;
                final segProgress = received / total;
                final overallProgress = (i + segProgress) / segments.length;
                task.progress = overallProgress;

                // 整体下载进度推送
                _notifyTaskUpdate(task);

                final percent = (overallProgress * 100).toInt();
                if (percent % 5 == 0 && percent != lastPrintedPercent) {
                  lastPrintedPercent = percent;
                  print('📊 ${task.title}: $percent% ($i/${segments.length})');
                }
              },
            );

            break; // ✅ 下载成功，退出重试循环
          } catch (e) {
            retries++;
            if (retries >= maxRetries) {
              throw Exception('Segment $i failed after $retries retries: $e');
            }
            print('⚠️ Segment $i failed, retrying ($retries/$maxRetries)...');
            await Future.delayed(const Duration(seconds: 2));
          }
        }

        // 如果有加密 Key，进行解密
        if (task.m3u8Key != null) {
          await _decryptSegment(segFile, task.m3u8Key!, task.m3u8IV);
        }

        segmentFiles.add(segFile);
        task.downloadedBytes = i + 1;
        task.progress = (i + 1) / segments.length;
        _notifyTaskUpdate(task);
      }

      // 🟢 Step 3: 合并全部分片
      var outputPath = '${saveRoot.path}/downloads/${task.id}.mp4';
      if(Platform.isAndroid){
        outputPath = '${saveRoot.path}/${task.id}.mp4';
      }
      print('🔗 Merging ${segmentFiles.length} segments to $outputPath ...');
      await _mergeSegments(segmentFiles, outputPath);
      await tempDir.delete(recursive: true);

      // ✅ 更新状态
      task.savePath = outputPath;
      task.status = DownloadStatus.completed;
      task.progress = 1.0;
      _notifyTaskUpdate(task);
      await _dbHelper.updateTask(task);

      // 自动保存到相册
      await _saveVideoToGallery(task.savePath!);

      print('✅ M3U8 download completed: ${task.title}');
    } catch (e, st) {
      print('❌ Error downloading M3U8: $e\n$st');
      task.status = DownloadStatus.failed;
      task.error = e.toString();
      _notifyTaskUpdate(task);
      await _dbHelper.updateTask(task);
    }
  }

  Future<void> _saveVideoToGallery(String filePath) async {
    try {
      print('🖼️ Saving video to Gallery: $filePath');
      final result = await ImageGallerySaverPlus.saveFile(filePath);
      if (result == true) {
        print('✅ Video saved to Gallery');
      } else {
        print('⚠️ Failed to save to Gallery');
      }
    } catch (e) {
      print('❌ Gallery save error: $e');
    }
  }

  List<String> _parseM3U8(String content, String baseUrl) {
    final lines = content.split('\n');
    final segments = <String>[];
    final baseUri = Uri.parse(baseUrl);

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue; // 忽略注释
      final uri = line.startsWith('http')
          ? Uri.parse(line)
          : baseUri.resolve(line);
      segments.add(uri.toString());
    }

    return segments;
  }

  String _selectBestVariant(String content, String baseUrl) {
    final lines = content.split('\n');
    final baseUri = Uri.parse(baseUrl);
    final variants = <Map<String, dynamic>>[];

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.startsWith('#EXT-X-STREAM-INF')) {
        final match = RegExp(r'BANDWIDTH=(\d+)').firstMatch(line);
        final bw = match != null ? int.parse(match.group(1)!) : 0;
        if (i + 1 < lines.length) {
          final next = lines[i + 1].trim();
          if (next.isNotEmpty && !next.startsWith('#')) {
            final resolved = next.startsWith('http')
                ? next
                : baseUri.resolve(next).toString();
            variants.add({'url': resolved, 'bw': bw});
          }
        }
      }
    }

    if (variants.isEmpty) throw Exception('No variants found in master playlist');
    variants.sort((a, b) => b['bw'].compareTo(a['bw']));
    return variants.first['url'];
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

  String _formatBytes(VideoType type, int bytes) {
    if (bytes < 1024) return '$bytes ${type == VideoType.mp4?'B':''}';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} ${type == VideoType.mp4?'KB':''}';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} ${type == VideoType.mp4?'MB':''}';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} ${type == VideoType.mp4?'GB':''}';
  }

  void dispose() {
    _taskController.close();
  }
}