import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/ykt_presentation.dart';
import 'file_platform_helper.dart';

class PresentationExportProgress {
  const PresentationExportProgress({
    required this.current,
    required this.total,
    required this.statusText,
  });

  final int current;
  final int total;
  final String statusText;

  double get ratio => total <= 0 ? 0.0 : current / total;
}

enum ExportFormat { pdf, images, offlineHtml }

class ExportResult {
  const ExportResult({
    required this.success,
    required this.path,
    required this.format,
    required this.fileCount,
    this.errorMessage,
  });

  final bool success;
  final String path;
  final ExportFormat format;
  final int fileCount;
  final String? errorMessage;

  String get mimeType => switch (format) {
        ExportFormat.pdf => 'application/pdf',
        ExportFormat.offlineHtml => 'text/html',
        ExportFormat.images => 'image/*',
      };
}

class PresentationExporter {
  PresentationExporter({
    http.Client? client,
    this.outputDirectory,
    this.customDirectoryPath,
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final Directory? outputDirectory;
  final String? customDirectoryPath;

  Future<ExportResult> export({
    required YktPresentation presentation,
    required String lessonName,
    required ExportFormat format,
    void Function(PresentationExportProgress progress)? onProgress,
  }) async {
    final slides = presentation.slides
        .where((s) => s.coverUrl.trim().isNotEmpty)
        .toList();
    if (slides.isEmpty) {
      return const ExportResult(
        success: false,
        path: '',
        format: ExportFormat.pdf,
        fileCount: 0,
        errorMessage: '当前课件没有可导出的幻灯片图片',
      );
    }

    final total = slides.length;
    final downloadedBytes = <int, Uint8List>{};

    onProgress?.call(
      PresentationExportProgress(
        current: 0,
        total: total,
        statusText: '正在准备下载课件幻灯片…',
      ),
    );

    // 下载全部幻灯片图片
    for (var i = 0; i < slides.length; i++) {
      final slide = slides[i];
      onProgress?.call(
        PresentationExportProgress(
          current: i + 1,
          total: total,
          statusText: '正在下载幻灯片 (${i + 1}/$total)…',
        ),
      );

      try {
        final response = await _client.get(Uri.parse(slide.coverUrl));
        if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
          downloadedBytes[i] = response.bodyBytes;
        }
      } catch (e) {
        // 单页失败记录，继续下载其余页
      }
    }

    if (downloadedBytes.isEmpty) {
      return const ExportResult(
        success: false,
        path: '',
        format: ExportFormat.pdf,
        fileCount: 0,
        errorMessage: '所有幻灯片图片下载失败，请检查网络连接',
      );
    }

    final exportDir = await _getExportDirectory();
    final sanitizedLessonName = _sanitizeFilename(
      lessonName.isNotEmpty ? lessonName : presentation.title,
    );
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    if (format == ExportFormat.pdf) {
      onProgress?.call(
        PresentationExportProgress(
          current: total,
          total: total,
          statusText: '正在合并生成 PDF 课件文档…',
        ),
      );

      final pdfBytes = await _generatePdfFromImages(downloadedBytes);
      final pdfFile = File(
        '${exportDir.path}/${sanitizedLessonName}_$timestamp.pdf',
      );
      await pdfFile.writeAsBytes(pdfBytes, flush: true);

      return ExportResult(
        success: true,
        path: pdfFile.path,
        format: ExportFormat.pdf,
        fileCount: downloadedBytes.length,
      );
    } else if (format == ExportFormat.images) {
      onProgress?.call(
        PresentationExportProgress(
          current: total,
          total: total,
          statusText: '正在保存图片文件…',
        ),
      );

      final targetDir = Directory(
        '${exportDir.path}/${sanitizedLessonName}_图片_$timestamp',
      );
      await targetDir.create(recursive: true);

      var savedCount = 0;
      for (final entry in downloadedBytes.entries) {
        final pageNum = (entry.key + 1).toString().padLeft(2, '0');
        final ext = _detectImageExtension(entry.value);
        final file = File('${targetDir.path}/page_$pageNum.$ext');
        await file.writeAsBytes(entry.value, flush: true);
        savedCount++;
      }

      return ExportResult(
        success: true,
        path: targetDir.path,
        format: ExportFormat.images,
        fileCount: savedCount,
      );
    } else {
      // offlineHtml 离线网页课件
      onProgress?.call(
        PresentationExportProgress(
          current: total,
          total: total,
          statusText: '正在打包单文件离线网页课件…',
        ),
      );

      final htmlContent = _generateOfflineHtml(
        title: presentation.title.isNotEmpty ? presentation.title : lessonName,
        images: downloadedBytes,
      );
      final htmlFile = File(
        '${exportDir.path}/${sanitizedLessonName}_离线课件_$timestamp.html',
      );
      await htmlFile.writeAsString(htmlContent, flush: true);

      return ExportResult(
        success: true,
        path: htmlFile.path,
        format: ExportFormat.offlineHtml,
        fileCount: downloadedBytes.length,
      );
    }
  }

  Future<Directory> _getExportDirectory() async {
    final custom = outputDirectory;
    if (custom != null) return custom;

    String targetPath;
    if (customDirectoryPath != null && customDirectoryPath!.trim().isNotEmpty) {
      targetPath = customDirectoryPath!.trim();
    } else {
      targetPath = await FilePlatformHelper.getDefaultExportDirectory();
    }

    var exportDir = Directory(targetPath);
    try {
      if (!await exportDir.exists()) {
        await exportDir.create(recursive: true);
      }
      return exportDir;
    } catch (_) {
      try {
        final base = await getApplicationDocumentsDirectory();
        exportDir = Directory('${base.path}/晴课堂_课件导出');
        if (!await exportDir.exists()) {
          await exportDir.create(recursive: true);
        }
        return exportDir;
      } catch (_) {
        return Directory.systemTemp;
      }
    }
  }

  String _sanitizeFilename(String name) {
    return name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .trim();
  }

  String _detectImageExtension(Uint8List bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'png';
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
      return 'jpg';
    }
    return 'jpg';
  }

  // 基于 pdf 官方库合成符合 ISO 32000-1 标准的多页高保真课件 PDF
  Future<Uint8List> _generatePdfFromImages(Map<int, Uint8List> images) async {
    final doc = pw.Document(
      title: '雨课堂课件',
      author: '晴课堂',
      compress: true,
    );
    final sortedKeys = images.keys.toList()..sort();

    for (final key in sortedKeys) {
      final imgBytes = images[key]!;
      final image = pw.MemoryImage(imgBytes);

      // 自适应原始图片尺寸构建独立页面，全幅铺满
      final width = (image.width != null && image.width! > 0)
          ? image.width!.toDouble()
          : PdfPageFormat.a4.landscape.width;
      final height = (image.height != null && image.height! > 0)
          ? image.height!.toDouble()
          : PdfPageFormat.a4.landscape.height;

      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat(
            width,
            height,
            marginAll: 0,
          ),
          build: (pw.Context context) {
            return pw.FullPage(
              ignoreMargins: true,
              child: pw.Center(
                child: pw.Image(image, fit: pw.BoxFit.contain),
              ),
            );
          },
        ),
      );
    }

    return doc.save();
  }

  String _generateOfflineHtml({
    required String title,
    required Map<int, Uint8List> images,
  }) {
    final sortedKeys = images.keys.toList()..sort();
    final imagesJson = <Map<String, String>>[];

    for (var i = 0; i < sortedKeys.length; i++) {
      final index = sortedKeys[i];
      final bytes = images[index]!;
      final mime = _detectImageExtension(bytes) == 'png' ? 'image/png' : 'image/jpeg';
      final base64Url = 'data:$mime;base64,${base64Encode(bytes)}';
      imagesJson.add({
        'page': '${i + 1}',
        'src': base64Url,
      });
    }

    final rawJson = jsonEncode(imagesJson);

    return '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=3.0, user-scalable=yes">
  <title>$title - 离线课件</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: #181c1a;
      color: #e5e9e6;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      display: flex;
      flex-direction: column;
      height: 100vh;
      overflow: hidden;
    }
    header {
      background: #202623;
      padding: 12px 18px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      border-bottom: 1px solid #313834;
      flex-shrink: 0;
    }
    h1 { font-size: 16px; font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .counter { font-size: 14px; color: #8fa098; }
    main {
      flex: 1;
      display: flex;
      align-items: center;
      justify-content: center;
      position: relative;
      background: #111413;
      overflow: auto;
    }
    img {
      max-width: 100%;
      max-height: 100%;
      object-fit: contain;
      box-shadow: 0 4px 20px rgba(0,0,0,0.5);
      border-radius: 6px;
      user-select: none;
    }
    footer {
      background: #202623;
      padding: 10px 18px;
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 16px;
      border-top: 1px solid #313834;
      flex-shrink: 0;
    }
    button {
      background: #2d3632;
      color: #fff;
      border: 1px solid #434e48;
      padding: 8px 18px;
      border-radius: 8px;
      font-size: 14px;
      cursor: pointer;
      user-select: none;
      transition: background 0.15s;
    }
    button:hover { background: #3c4843; }
    button:active { background: #176B62; }
    @media print {
      body { height: auto; overflow: visible; background: #fff; }
      header, footer { display: none; }
      main { display: block; background: #fff; }
      img { page-break-after: always; max-width: 100%; height: auto; box-shadow: none; }
    }
  </style>
</head>
<body>
  <header>
    <h1>$title</h1>
    <div class="counter" id="pageIndicator">1 / ${imagesJson.length}</div>
  </header>
  <main onclick="nextPage()">
    <img id="slideImg" src="${imagesJson.isNotEmpty ? imagesJson.first['src'] : ''}" alt="Slide">
  </main>
  <footer>
    <button onclick="prevPage()">上一页</button>
    <button onclick="toggleFullscreen()">全屏</button>
    <button onclick="window.print()">打印 / 保存为 PDF</button>
    <button onclick="nextPage()">下一页</button>
  </footer>

  <script>
    const slides = $rawJson;
    let currentIndex = 0;
    const imgEl = document.getElementById('slideImg');
    const indicator = document.getElementById('pageIndicator');

    function update() {
      if (!slides.length) return;
      imgEl.src = slides[currentIndex].src;
      indicator.textContent = (currentIndex + 1) + ' / ' + slides.length;
    }

    function prevPage() {
      if (currentIndex > 0) { currentIndex--; update(); }
    }

    function nextPage() {
      if (currentIndex < slides.length - 1) { currentIndex++; update(); }
    }

    function toggleFullscreen() {
      if (!document.fullscreenElement) {
        document.documentElement.requestFullscreen().catch(()=>{});
      } else {
        document.exitFullscreen().catch(()=>{});
      }
    }

    document.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowLeft' || e.key === 'PageUp') prevPage();
      if (e.key === 'ArrowRight' || e.key === 'PageDown' || e.key === ' ') nextPage();
    });
  </script>
</body>
</html>
''';
  }
}
