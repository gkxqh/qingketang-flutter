import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// 课件幻灯片预加载与本地磁盘缓存服务
class SlideCacheService {
  SlideCacheService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  final Set<String> _inFlight = {};
  Directory? _cacheRoot;

  Future<Directory> _getCacheRoot() async {
    if (_cacheRoot != null) return _cacheRoot!;
    final tempDir = await getTemporaryDirectory();
    final root = Directory('${tempDir.path}/slide_cache');
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    _cacheRoot = root;
    return root;
  }

  String _urlKey(String url) {
    // 使用 base64Url 摘要作为安全的文件名
    final encoded = base64Url.encode(utf8.encode(url)).replaceAll('=', '');
    if (encoded.length > 48) {
      return encoded.substring(encoded.length - 48);
    }
    return encoded;
  }

  /// 获取本地已缓存的幻灯片文件，如果未命中则返回 null
  Future<File?> getCachedFile(String presentationId, String url) async {
    if (url.trim().isEmpty) return null;
    try {
      final root = await _getCacheRoot();
      final dir = Directory('${root.path}/$presentationId');
      final file = File('${dir.path}/${_urlKey(url)}.img');
      if (await file.exists() && await file.length() > 0) {
        return file;
      }
    } catch (_) {}
    return null;
  }

  /// 内存预热当前页相邻的幻灯片（前1页、后2页）
  void precacheAdjacentImages(
    BuildContext context,
    List<String> urls,
    int currentIndex,
  ) {
    if (!context.mounted || urls.isEmpty) return;
    final indices = [
      currentIndex + 1,
      currentIndex + 2,
      currentIndex - 1,
    ];
    for (final idx in indices) {
      if (idx >= 0 && idx < urls.length) {
        final url = urls[idx].trim();
        if (url.isNotEmpty) {
          unawaited(
            precacheImage(NetworkImage(url), context).catchError((_) {}),
          );
        }
      }
    }
  }

  /// 低并发后台静默预加载全部幻灯片至本地磁盘，避免弱网切页白屏
  Future<void> prefetchSlides(
    String presentationId,
    List<String> urls,
  ) async {
    final validUrls = urls.where((u) => u.trim().isNotEmpty).toList();
    if (validUrls.isEmpty) return;

    try {
      final root = await _getCacheRoot();
      final dir = Directory('${root.path}/$presentationId');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      // 受控并发（最多同时 3 个下载任务），不抢占课堂核心信令带宽
      const concurrency = 3;
      for (var i = 0; i < validUrls.length; i += concurrency) {
        final batch = validUrls.skip(i).take(concurrency);
        await Future.wait(
          batch.map((url) => _downloadToCache(dir, url)),
        );
      }
    } catch (_) {}
  }

  Future<void> _downloadToCache(Directory dir, String url) async {
    final key = '${dir.path}/${_urlKey(url)}.img';
    if (_inFlight.contains(key)) return;
    final file = File(key);
    if (await file.exists() && await file.length() > 0) return;

    _inFlight.add(key);
    try {
      final response = await _client
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 12));
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        await file.writeAsBytes(response.bodyBytes, flush: true);
      }
    } catch (_) {
      // 预取失败静默忽略，不影响正常展示
    } finally {
      _inFlight.remove(key);
    }
  }

  void dispose() {
    _client.close();
  }
}
