// lib/utils/permission_manager.dart
import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/material.dart';
import 'dart:io';

class PermissionManager {
  static final PermissionManager _instance = PermissionManager._internal();
  factory PermissionManager() => _instance;
  PermissionManager._internal();

  /// 请求存储权限
  Future<bool> requestStoragePermission(BuildContext context) async {
    if (Platform.isIOS) {
      // iOS 不需要额外的存储权限
      return true;
    }

    // Android 13+ (API 33+) 不再需要 WRITE_EXTERNAL_STORAGE
    if (Platform.isAndroid) {
      final androidInfo = await _getAndroidVersion();

      if (androidInfo >= 33) {
        // Android 13+ 使用 Photo/Video/Audio 权限
        // 但下载到应用目录不需要权限
        return true;
      } else if (androidInfo >= 30) {
        // Android 11-12 (API 30-32)
        final status = await Permission.manageExternalStorage.status;
        if (status.isGranted) return true;

        final result = await Permission.manageExternalStorage.request();
        if (result.isGranted) return true;

        if (result.isPermanentlyDenied) {
          await _showPermissionDialog(
            context,
            'Storage Permission Required',
            'Please enable storage permission in settings to download videos.',
          );
        }
        return result.isGranted;
      } else {
        // Android 10 及以下
        final status = await Permission.storage.status;
        if (status.isGranted) return true;

        final result = await Permission.storage.request();
        if (result.isGranted) return true;

        if (result.isPermanentlyDenied) {
          await _showPermissionDialog(
            context,
            'Storage Permission Required',
            'Please enable storage permission in settings to download videos.',
          );
        }
        return result.isGranted;
      }
    }

    return false;
  }

  /// 请求通知权限
  Future<bool> requestNotificationPermission(BuildContext context) async {
    final status = await Permission.notification.status;
    if (status.isGranted) return true;

    final result = await Permission.notification.request();

    if (result.isPermanentlyDenied) {
      await _showPermissionDialog(
        context,
        'Notification Permission',
        'Enable notifications to get download progress updates.',
      );
    }

    return result.isGranted;
  }

  /// 一次性请求所有必要权限
  Future<bool> requestAllPermissions(BuildContext context) async {
    final storageGranted = await requestStoragePermission(context);
    final notificationGranted = await requestNotificationPermission(context);

    return storageGranted; // 通知权限是可选的
  }

  /// 检查权限状态
  Future<Map<String, bool>> checkPermissions() async {
    final permissions = <String, bool>{};

    if (Platform.isAndroid) {
      final androidVersion = await _getAndroidVersion();

      if (androidVersion >= 33) {
        permissions['storage'] = true; // 不需要权限
      } else if (androidVersion >= 30) {
        permissions['storage'] = await Permission.manageExternalStorage.isGranted;
      } else {
        permissions['storage'] = await Permission.storage.isGranted;
      }
    } else {
      permissions['storage'] = true; // iOS 不需要
    }

    permissions['notification'] = await Permission.notification.isGranted;

    return permissions;
  }

  /// 获取 Android 版本
  Future<int> _getAndroidVersion() async {
    if (!Platform.isAndroid) return 0;

    try {
      final deviceInfo = DeviceInfoPlugin();
      final androidInfo = await deviceInfo.androidInfo;
      return androidInfo.version.sdkInt; // 返回实际的 SDK 版本
    } catch (e) {
      debugPrint('Error getting Android version: $e');
      return 29; // 默认假设为 Android 10
    }
  }

  /// 显示权限说明对话框
  Future<void> _showPermissionDialog(
      BuildContext context,
      String title,
      String message,
      ) async {
    if (!context.mounted) return;

    return showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              // 这里是正确的使用方式
              await openAppSettings();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  /// 打开应用设置独立方法
  // Future<bool> openSettings() async {
  //   return await openAppSettings();
  // }
}