// lib/download_manager/database_helper.dart
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'download_manager.dart';

class DatabaseHelper {
  Database? _database;

  Future<void> initialize() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'downloads.db');

    _database = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE downloads (
            id TEXT PRIMARY KEY,
            url TEXT NOT NULL,
            title TEXT NOT NULL,
            type INTEGER NOT NULL,
            savePath TEXT,
            status INTEGER NOT NULL,
            progress REAL NOT NULL,
            downloadedBytes INTEGER NOT NULL,
            totalBytes INTEGER NOT NULL,
            error TEXT,
            m3u8Key TEXT,
            m3u8IV TEXT
          )
        ''');
      },
    );
  }

  Future<void> insertTask(DownloadTask task) async {
    await _database?.insert(
      'downloads',
      task.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateTask(DownloadTask task) async {
    await _database?.update(
      'downloads',
      task.toJson(),
      where: 'id = ?',
      whereArgs: [task.id],
    );
  }

  Future<void> deleteTask(String id) async {
    await _database?.delete(
      'downloads',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<DownloadTask>> getAllTasks() async {
    final maps = await _database?.query('downloads') ?? [];
    return maps.map((map) => DownloadTask.fromJson(map)).toList();
  }
}