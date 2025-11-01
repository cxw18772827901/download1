// lib/screens/download_screen.dart
import 'package:flutter/material.dart';
import '../download_manager/download_manager.dart';

class DownloadScreen extends StatefulWidget {
  const DownloadScreen({Key? key}) : super(key: key);

  @override
  State<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends State<DownloadScreen> {
  final _downloadManager = DownloadManager();
  final _urlController = TextEditingController();
  final _titleController = TextEditingController();
  final _keyController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _downloadManager.initialize();
  }

  void _addDownload() {
    if (_urlController.text.isEmpty || _titleController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in URL and Title')),
      );
      return;
    }

    _downloadManager.addDownload(
      url: _urlController.text,
      title: _titleController.text,
      m3u8Key: _keyController.text.isEmpty ? null : _keyController.text,
    );

    _urlController.clear();
    _titleController.clear();
    _keyController.clear();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Download added to queue')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Video Downloader')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                TextField(
                  controller: _urlController,
                  decoration: const InputDecoration(
                    labelText: 'Video URL (mp4 or m3u8)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _titleController,
                  decoration: const InputDecoration(
                    labelText: 'Title',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _keyController,
                  decoration: const InputDecoration(
                    labelText: 'M3U8 Key (optional)',
                    border: OutlineInputBorder(),
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
          Expanded(
            child: StreamBuilder<DownloadTask>(
              stream: _downloadManager.taskStream,
              builder: (context, snapshot) {
                final tasks = _downloadManager.getAllTasks();

                if (tasks.isEmpty) {
                  return const Center(child: Text('No downloads'));
                }

                return ListView.builder(
                  itemCount: tasks.length,
                  itemBuilder: (context, index) {
                    final task = tasks[index];
                    return DownloadTaskItem(
                      task: task,
                      onPause: () => _downloadManager.pauseDownload(task.id),
                      onResume: () => _downloadManager.resumeDownload(task.id),
                      onCancel: () => _downloadManager.cancelDownload(task.id),
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

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              task.title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: task.progress),
            const SizedBox(height: 8),
            Text(
              '${(task.progress * 100).toStringAsFixed(1)}% - ${task.status.name}',
            ),
            if (task.error != null) ...[
              const SizedBox(height: 4),
              Text(
                'Error: ${task.error}',
                style: const TextStyle(color: Colors.red),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (task.status == DownloadStatus.downloading)
                  IconButton(
                    icon: const Icon(Icons.pause),
                    onPressed: onPause,
                  ),
                if (task.status == DownloadStatus.paused ||
                    task.status == DownloadStatus.failed)
                  IconButton(
                    icon: const Icon(Icons.play_arrow),
                    onPressed: onResume,
                  ),
                IconButton(
                  icon: const Icon(Icons.delete),
                  onPressed: onCancel,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}