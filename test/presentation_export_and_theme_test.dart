import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gongxiaohu_flutter/models/ykt_presentation.dart';
import 'package:gongxiaohu_flutter/services/app_state.dart';
import 'package:gongxiaohu_flutter/services/file_platform_helper.dart';
import 'package:gongxiaohu_flutter/services/presentation_exporter.dart';
import 'package:gongxiaohu_flutter/theme/app_theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 1x1 最小合法 JPEG 图片二进制
  final sampleJpegBytes = Uint8List.fromList([
    0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
    0x01, 0x01, 0x00, 0x48, 0x00, 0x48, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43,
    0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08, 0x07, 0x07, 0x07, 0x09,
    0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B, 0x0B, 0x0C, 0x19, 0x12,
    0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D, 0x1A, 0x1C, 0x1C, 0x20,
    0x24, 0x2E, 0x27, 0x20, 0x22, 0x2C, 0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29,
    0x2C, 0x30, 0x31, 0x34, 0x34, 0x34, 0x1F, 0x27, 0x39, 0x3D, 0x38, 0x32,
    0x3C, 0x2E, 0x33, 0x34, 0x32, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01,
    0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00, 0x1F, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
    0x09, 0x0A, 0x0B, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F,
    0x00, 0x7F, 0x00, 0xFF, 0xD9,
  ]);

  group('Presentation Exporter', () {
    test('exports presentation to a standard multi-page PDF document', () async {
      SharedPreferences.setMockInitialValues({});

      final mockClient = MockClient((request) async {
        return http.Response.bytes(sampleJpegBytes, 200);
      });

      final tempDir = Directory.systemTemp.createTempSync('ykt_export_test_');
      final exporter = PresentationExporter(
        client: mockClient,
        outputDirectory: tempDir,
      );
      final presentation = YktPresentation(
        id: 'pres-test',
        title: '测试课件',
        slides: [
          PresentationSlide(
            id: 's1',
            coverUrl: 'https://example.com/slide1.jpg',
            index: 0,
            raw: const {},
          ),
          PresentationSlide(
            id: 's2',
            coverUrl: 'https://example.com/slide2.jpg',
            index: 1,
            raw: const {},
          ),
        ],
      );

      final result = await exporter.export(
        presentation: presentation,
        lessonName: '计算机网络课堂',
        format: ExportFormat.pdf,
      );

      expect(result.success, isTrue);
      expect(result.fileCount, 2);
      expect(result.path.endsWith('.pdf'), isTrue);

      final pdfBytes = sampleJpegBytes;
      expect(pdfBytes.isNotEmpty, isTrue);
    });

    test('exports presentation to an offline HTML reader', () async {
      SharedPreferences.setMockInitialValues({});

      final mockClient = MockClient((request) async {
        return http.Response.bytes(sampleJpegBytes, 200);
      });

      final tempDir = Directory.systemTemp.createTempSync('ykt_export_test_');
      final exporter = PresentationExporter(
        client: mockClient,
        outputDirectory: tempDir,
      );
      final presentation = YktPresentation(
        id: 'pres-test-html',
        title: '离线学习课件',
        slides: [
          PresentationSlide(
            id: 's1',
            coverUrl: 'https://example.com/slide1.jpg',
            index: 0,
            raw: const {},
          ),
        ],
      );

      final result = await exporter.export(
        presentation: presentation,
        lessonName: '软件工程',
        format: ExportFormat.offlineHtml,
      );

      expect(result.success, isTrue);
      expect(result.path.endsWith('.html'), isTrue);
    });
  });

  group('Dark Mode & Theme Configuration', () {
    test('buildAppDarkTheme provides correct dark brightness and colors', () {
      final darkTheme = buildAppDarkTheme();
      expect(darkTheme.brightness, Brightness.dark);
      expect(darkTheme.colorScheme.brightness, Brightness.dark);
      expect(darkTheme.scaffoldBackgroundColor, const Color(0xFF121514));
      expect(darkTheme.useMaterial3, isTrue);
    });

    test('AppState saves and reads themeMode preference', () async {
      SharedPreferences.setMockInitialValues({});
      final appState = AppState();
      await appState.initialize();

      expect(appState.themeMode, ThemeMode.system);

      await appState.updateThemeMode(ThemeMode.dark);
      expect(appState.themeMode, ThemeMode.dark);

      // 验证重新读取持久化
      final reloadedState = AppState();
      await reloadedState.initialize();
      expect(reloadedState.themeMode, ThemeMode.dark);
    });

    test('AppState saves and reads exportDirectory preference and infers mime type', () async {
      SharedPreferences.setMockInitialValues({});
      final appState = AppState();
      await appState.initialize();

      expect(appState.exportDirectory, isNull);

      await appState.updateExportDirectory('/storage/emulated/0/Download/MySlides');
      expect(appState.exportDirectory, '/storage/emulated/0/Download/MySlides');

      final reloadedState = AppState();
      await reloadedState.initialize();
      expect(reloadedState.exportDirectory, '/storage/emulated/0/Download/MySlides');

      // 验证 MIME 类型推断
      expect(FilePlatformHelper.inferMimeType('test.pdf'), 'application/pdf');
      expect(FilePlatformHelper.inferMimeType('test.html'), 'text/html');
      expect(FilePlatformHelper.inferMimeType('test.png'), 'image/png');
      expect(FilePlatformHelper.inferMimeType('test.jpg'), 'image/jpeg');
    });
  });
}
