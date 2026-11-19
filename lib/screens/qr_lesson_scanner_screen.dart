import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/lesson_qr.dart';

class QrLessonScannerScreen extends StatefulWidget {
  const QrLessonScannerScreen({super.key});

  @override
  State<QrLessonScannerScreen> createState() => _QrLessonScannerScreenState();
}

class _QrLessonScannerScreenState extends State<QrLessonScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
    torchEnabled: false,
  );
  bool _handled = false;
  String? _message;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleDetection(BarcodeCapture capture) async {
    if (_handled) return;
    final raw = capture.barcodes
        .map((barcode) => barcode.rawValue)
        .whereType<String>()
        .firstOrNull;
    if (raw == null || raw.isEmpty) return;
    final lessonId = parseLessonIdFromQr(raw);
    if (lessonId == null) {
      if (mounted) {
        setState(() => _message = '未识别到课堂 ID，请扫描老师展示的课堂二维码');
      }
      return;
    }
    _handled = true;
    await _controller.stop();
    if (mounted) Navigator.pop(context, lessonId);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('扫描课堂二维码'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: '切换手电筒',
            onPressed: _controller.toggleTorch,
            icon: const Icon(Icons.flashlight_on_rounded),
          ),
          IconButton(
            tooltip: '切换摄像头',
            onPressed: _controller.switchCamera,
            icon: const Icon(Icons.cameraswitch_rounded),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: (capture) => unawaited(_handleDetection(capture)),
            errorBuilder: (context, error) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.no_photography_outlined,
                        color: Colors.white70,
                        size: 48,
                      ),
                      const SizedBox(height: 14),
                      Text(
                        '无法启动相机：${error.errorDetails?.message ?? error}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(18),
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 42,
            child: Column(
              children: [
                const Text(
                  '将老师的课堂二维码放入取景框',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (_message != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _message!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xFFFFC58A)),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
