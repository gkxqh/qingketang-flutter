import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class CaptchaCredentials {
  const CaptchaCredentials({required this.ticket, required this.rand});

  final String ticket;
  final String rand;
}

class CaptchaScreen extends StatefulWidget {
  const CaptchaScreen({this.appId = '2091064951', super.key});

  final String appId;

  @override
  State<CaptchaScreen> createState() => _CaptchaScreenState();
}

class _CaptchaScreenState extends State<CaptchaScreen> {
  late final WebViewController _controller;
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            if (request.url.startsWith('tcaptcha://result')) {
              _completeFromUrl(request.url);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadFlutterAsset('assets/captcha.html');
  }

  void _completeFromUrl(String url) {
    if (_completed) return;
    final data = Uri.tryParse(url)?.queryParameters['data'];
    if (data == null || data.isEmpty) return;
    try {
      final payload = jsonDecode(data);
      if (payload is! Map) return;
      final result = Map<String, dynamic>.from(payload);
      if (result['ret'] != 0) {
        _completed = true;
        if (mounted) Navigator.pop(context);
        return;
      }
      _completed = true;
      if (!mounted) return;
      Navigator.pop(
        context,
        CaptchaCredentials(
          ticket: '${result['ticket'] ?? ''}',
          rand: '${result['randstr'] ?? result['rand'] ?? ''}',
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('安全验证结果解析失败')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('腾讯安全验证'),
        leading: IconButton(
          tooltip: '取消',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close_rounded),
        ),
      ),
      body: WebViewWidget(controller: _controller),
    );
  }
}
