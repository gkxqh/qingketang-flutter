import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class FilePlatformHelper {
  static const MethodChannel _channel = MethodChannel('site.jiclub/file_helper');

  /// 获取系统默认公共下载目录
  static Future<String> getPublicDownloadsDirectory() async {
    if (Platform.isAndroid) {
      try {
        final path = await _channel.invokeMethod<String>('getPublicDownloadsDirectory');
        if (path != null && path.trim().isNotEmpty) {
          return path.trim();
        }
      } catch (_) {}
      return '/storage/emulated/0/Download';
    }

    try {
      final dir = await getDownloadsDirectory();
      if (dir != null) return dir.path;
    } catch (_) {}

    final docs = await getApplicationDocumentsDirectory();
    return docs.path;
  }

  /// 获取默认课件导出目录
  static Future<String> getDefaultExportDirectory() async {
    final base = await getPublicDownloadsDirectory();
    return '$base/晴课堂_课件导出';
  }

  /// 根据文件扩展名推断 MIME 类型
  static String inferMimeType(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.html') || lower.endsWith('.htm')) return 'text/html';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    return '*/*';
  }

  /// 打开导出的文件或目录
  static Future<bool> openFile(String path, {String? mimeType}) async {
    final isDir = await FileSystemEntity.isDirectory(path);

    // 如果是目录（如图片导出包），尝试打开首张图片
    var targetPath = path;
    var targetMime = mimeType ?? inferMimeType(path);
    if (isDir) {
      final dir = Directory(path);
      if (await dir.exists()) {
        final entries = dir.listSync();
        final firstImage = entries.whereType<File>().where((f) {
          final l = f.path.toLowerCase();
          return l.endsWith('.png') || l.endsWith('.jpg') || l.endsWith('.jpeg');
        }).firstOrNull;
        if (firstImage != null) {
          targetPath = firstImage.path;
          targetMime = inferMimeType(targetPath);
        }
      }
    }

    if (Platform.isAndroid) {
      try {
        final result = await _channel.invokeMethod<bool>('openFile', {
          'path': targetPath,
          'mimeType': targetMime,
        });
        return result ?? false;
      } catch (_) {
        return false;
      }
    }

    try {
      if (Platform.isMacOS) {
        await Process.run('open', [targetPath]);
        return true;
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [targetPath]);
        return true;
      } else if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', targetPath]);
        return true;
      }
    } catch (_) {}

    return false;
  }

  /// 分享导出的文件
  static Future<bool> shareFile(
    String path, {
    String? mimeType,
    String? title,
  }) async {
    var targetPath = path;
    var targetMime = mimeType ?? inferMimeType(path);

    final isDir = await FileSystemEntity.isDirectory(path);
    if (isDir) {
      final dir = Directory(path);
      if (await dir.exists()) {
        final entries = dir.listSync();
        final firstImage = entries.whereType<File>().where((f) {
          final l = f.path.toLowerCase();
          return l.endsWith('.png') || l.endsWith('.jpg') || l.endsWith('.jpeg');
        }).firstOrNull;
        if (firstImage != null) {
          targetPath = firstImage.path;
          targetMime = inferMimeType(targetPath);
        }
      }
    }

    if (Platform.isAndroid) {
      try {
        final result = await _channel.invokeMethod<bool>('shareFile', {
          'path': targetPath,
          'mimeType': targetMime,
          'title': title ?? '分享课件',
        });
        return result ?? false;
      } catch (_) {
        return false;
      }
    }

    // 非移动端回退为打开所在目录
    return openFile(targetPath, mimeType: targetMime);
  }
}
