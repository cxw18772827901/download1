// lib/screens/download_screen.dart
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../download_manager/download_manager.dart';
import '../utils/permission_manager.dart';

class DownloadScreen extends StatefulWidget {
  const DownloadScreen({Key? key}) : super(key: key);

  @override
  State<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends State<DownloadScreen> {
  final _downloadManager = DownloadManager();
  final _permissionManager = PermissionManager();

  final _urlController = TextEditingController(
      // text: 'http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4'
      text: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'
  );
  final _titleController = TextEditingController(text: 'Big Buck Bunny - 480p');
  final _keyController = TextEditingController();

  // ⭐ 添加初始化标志
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _initializeManager();  // ⭐ 改为调用异步方法
    _checkPermissions();
  }

  // ⭐ 新增：异步初始化方法
  Future<void> _initializeManager() async {
    await _downloadManager.initialize();
    if (mounted) {
      setState(() {
        _isInitialized = true;
      });
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _titleController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _checkPermissions() async {
    final permissions = await _permissionManager.checkPermissions();
    if (!permissions['storage']!) {
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted) {
          _permissionManager.requestAllPermissions(context);
        }
      });
    }
  }

  Future<void> _addDownload() async {
    if (_urlController.text.isEmpty || _titleController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in URL and Title')),
      );
      return;
    }

    final taskId = await _downloadManager.addDownloadWithPermission(
      context: context,
      url: _urlController.text,
      title: _titleController.text,
      m3u8Key: _keyController.text.isEmpty ? null : _keyController.text,
    );

    if (taskId != null && mounted) {
      _urlController.clear();
      _titleController.clear();
      _keyController.clear();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Download added'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  void _showPermissionSettings() async {
    final permissions = await _permissionManager.checkPermissions();

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Permissions'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildPermissionRow(
              'Storage',
              permissions['storage']!,
              Icons.storage,
            ),
            const SizedBox(height: 12),
            _buildPermissionRow(
              'Notifications',
              permissions['notification']!,
              Icons.notifications,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          if (!permissions.values.every((v) => v))
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                await openAppSettings();
              },
              child: const Text('Open Settings'),
            ),
        ],
      ),
    );
  }

  Widget _buildPermissionRow(String name, bool granted, IconData icon) {
    return Row(
      children: [
        Icon(
          icon,
          color: granted ? Colors.green : Colors.red,
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(name)),
        Icon(
          granted ? Icons.check_circle : Icons.cancel,
          color: granted ? Colors.green : Colors.red,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Video Downloader'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showPermissionSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12,vertical: 10),
            child: Column(
              children: [
                TextField(
                  style: const TextStyle(fontSize: 16),
                  controller: _urlController,
                  decoration: const InputDecoration(
                    labelText: 'Video URL (mp4 or m3u8)',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    isDense: true,
                  ),
                  maxLines: 2,
                  minLines: 1,
                ),
                const SizedBox(height: 12),
                TextField(
                  style: const TextStyle(fontSize: 16),
                  controller: _titleController,
                  decoration: const InputDecoration(
                    labelText: 'Title',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  style: const TextStyle(fontSize: 16),
                  controller: _keyController,
                  decoration: const InputDecoration(
                    labelText: 'M3U8 Key (optional)',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _addDownload,
                  child: const Text('Add Download'),
                ),
              ],
            ),
          ),
          const Divider(),
          // ⭐ 修复：先显示加载动画，初始化完成后显示列表
          Expanded(
            child: !_isInitialized
                ? const Center(
              child: CircularProgressIndicator(),
            )
                : StreamBuilder<DownloadTask>(
              stream: _downloadManager.taskStream,
              builder: (context, snapshot) {
                // ⭐ 每次 stream 触发都重新获取所有任务
                final tasks = _downloadManager.getAllTasks();

                if (tasks.isEmpty) {
                  return const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.download_outlined,
                          size: 64,
                          color: Colors.grey,
                        ),
                        SizedBox(height: 16),
                        Text(
                          'No downloads',
                          style: TextStyle(
                            fontSize: 18,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  itemCount: tasks.length,
                  itemBuilder: (context, index) {
                    final task = tasks[index];
                    return DownloadTaskItem(
                      key: ValueKey(task.id),
                      task: task,
                      onPause: () {
                        print('UI: Pause ${task.title}');
                        _downloadManager.pauseDownload(task.id);
                      },
                      onResume: () {
                        print('UI: Resume ${task.title}');
                        _downloadManager.resumeDownload(task.id);
                      },
                      onCancel: () {
                        print('UI: Cancel ${task.title}');
                        _downloadManager.cancelDownload(task.id);
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class DownloadTaskItem extends StatelessWidget {
  final DownloadTask task;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onCancel;

  const DownloadTaskItem({
    Key? key,
    required this.task,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
  }) : super(key: key);

  String _formatBytes(VideoType type, int bytes) {
    if (bytes < 1024) return '$bytes ${type == VideoType.mp4?'B':''}';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} ${type == VideoType.mp4?'KB':''}';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} ${type == VideoType.mp4?'MB':''}';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} ${type == VideoType.mp4?'GB':''}';
  }

  Color _getStatusColor(DownloadStatus status) {
    switch (status) {
      case DownloadStatus.completed:
        return Colors.green;
      case DownloadStatus.downloading:
        return Colors.blue;
      case DownloadStatus.failed:
        return Colors.red;
      case DownloadStatus.paused:
        return Colors.orange;
      case DownloadStatus.cancelled:
        return Colors.grey;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题行
            Row(
              children: [
                Icon(
                  task.type == VideoType.m3u8 ? Icons.stream : Icons.video_file,
                  color: Colors.blue,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    task.title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 进度条
            LinearProgressIndicator(
              value: task.progress,
              backgroundColor: Colors.grey[200],
              valueColor: AlwaysStoppedAnimation<Color>(
                _getStatusColor(task.status),
              ),
              minHeight: 8,
            ),
            const SizedBox(height: 8),

            // 进度信息
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${(task.progress * 100).toStringAsFixed(1)}%',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                if (task.totalBytes > 0)
                  Text(
                    '${_formatBytes(task.type, task.downloadedBytes)} / ${_formatBytes(task.type, task.totalBytes)}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  )
                else if (task.downloadedBytes > 0)
                  Text(
                    _formatBytes(task.type, task.downloadedBytes),
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
              ],
            ),
            const SizedBox(height: 8),

            // 状态标签
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: _getStatusColor(task.status).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: _getStatusColor(task.status).withOpacity(0.3),
                    ),
                  ),
                  child: Text(
                    task.status.name.toUpperCase(),
                    style: TextStyle(
                      color: _getStatusColor(task.status),
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                    ),
                  ),
                ),
                if (task.status == DownloadStatus.completed) ...[
                  const SizedBox(width: 8),
                  const Icon(Icons.check_circle, color: Colors.green, size: 16),
                ],
              ],
            ),

            // 错误信息
            if (task.error != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red[50],
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.red[200]!),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.red, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        task.error!,
                        style: const TextStyle(
                          color: Colors.red,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // 操作按钮
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (task.status == DownloadStatus.downloading)
                  TextButton.icon(
                    onPressed: onPause,
                    icon: const Icon(Icons.pause, size: 18),
                    label: const Text('Pause'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.orange,
                    ),
                  ),
                if (task.status == DownloadStatus.paused ||
                    task.status == DownloadStatus.failed)
                  TextButton.icon(
                    onPressed: onResume,
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: Text(task.status == DownloadStatus.failed ? 'Retry' : 'Resume'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.green,
                    ),
                  ),
                TextButton.icon(
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Confirm Delete'),
                        content: Text('Delete "${task.title}"?'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () {
                              Navigator.pop(context);
                              onCancel();
                            },
                            child: const Text(
                              'Delete',
                              style: TextStyle(color: Colors.red),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                  icon: const Icon(Icons.delete, size: 18),
                  label: const Text('Delete'),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.red,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}