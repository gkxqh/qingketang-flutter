import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/ykt_session.dart';
import '../services/app_state.dart';
import '../services/ykt_api_client.dart';
import 'captcha_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({required this.state, super.key});

  final AppState state;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  int _tab = 0;
  bool _qrLoading = false;
  bool _polling = false;
  int _qrGeneration = 0;
  QrLoginInfo? _qrInfo;
  String? _qrMessage;
  CaptchaCredentials? _captcha;

  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _sendingCode = false;
  bool _loggingIn = false;

  YktServer get _server => widget.state.selectedServer;

  @override
  void initState() {
    super.initState();
    if (widget.state.privacyAgreed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _startQr());
    }
  }

  @override
  void dispose() {
    _qrGeneration++;
    _phoneController.dispose();
    _codeController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _setPrivacy(bool value) async {
    await widget.state.setPrivacyAgreed(value);
    if (!value) {
      _qrGeneration++;
      setState(() {
        _qrInfo = null;
        _polling = false;
        _qrLoading = false;
        _qrMessage = null;
      });
      return;
    }
    await _startQr();
  }

  Future<void> _startQr() async {
    if (!widget.state.privacyAgreed || !mounted) return;
    final generation = ++_qrGeneration;
    setState(() {
      _qrLoading = true;
      _qrMessage = null;
      _qrInfo = null;
      _polling = false;
    });
    try {
      final info = await widget.state.api.createQrLogin(_server);
      if (!mounted || generation != _qrGeneration) return;
      setState(() {
        _qrInfo = info;
        _qrLoading = false;
      });
      _poll(info.token, generation);
    } catch (error) {
      if (!mounted || generation != _qrGeneration) return;
      setState(() {
        _qrLoading = false;
        _qrMessage = '$error';
      });
    }
  }

  Future<void> _poll(String token, int generation) async {
    setState(() => _polling = true);
    while (mounted &&
        generation == _qrGeneration &&
        widget.state.privacyAgreed) {
      try {
        final result = await widget.state.api.pollQrLogin(token, _server);
        if (!mounted || generation != _qrGeneration) return;
        if (result.state == QrPollState.success && result.session != null) {
          await widget.state.setSession(result.session!);
          if (mounted) Navigator.pop(context);
          return;
        }
        if (result.state == QrPollState.expired) {
          setState(() {
            _polling = false;
            _qrMessage = '二维码已失效，请刷新';
          });
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 1600));
      } catch (error) {
        if (!mounted || generation != _qrGeneration) return;
        await Future<void>.delayed(const Duration(milliseconds: 1600));
      }
    }
    if (mounted) setState(() => _polling = false);
  }

  Future<void> _changeServer(YktServer? server) async {
    if (server == null || server == _server) return;
    await widget.state.updateServer(server);
    if (widget.state.privacyAgreed) _startQr();
  }

  Future<CaptchaCredentials?> _verifyCaptcha() {
    return Navigator.of(context).push<CaptchaCredentials>(
      MaterialPageRoute(builder: (_) => const CaptchaScreen()),
    );
  }

  Future<void> _sendCode() async {
    final phone = _phoneController.text.trim();
    if (!RegExp(r'^1[3-9]\d{9}$').hasMatch(phone)) {
      _showMessage('请输入有效的 11 位手机号');
      return;
    }
    setState(() => _sendingCode = true);
    try {
      final captcha = _captcha ?? await _verifyCaptcha();
      if (captcha == null) return;
      _captcha = captcha;
      await widget.state.api.sendSmsCode(
        phone: phone,
        server: _server,
        ticket: captcha.ticket,
        rand: captcha.rand,
      );
      if (mounted) _showMessage('验证码已发送');
    } catch (error) {
      _captcha = null;
      if (mounted) _showMessage('$error');
    } finally {
      if (mounted) setState(() => _sendingCode = false);
    }
  }

  Future<void> _loginWithSms() async {
    final phone = _phoneController.text.trim();
    final code = _codeController.text.trim();
    if (!RegExp(r'^1[3-9]\d{9}$').hasMatch(phone) || code.isEmpty) {
      _showMessage('请输入手机号和验证码');
      return;
    }
    setState(() => _loggingIn = true);
    try {
      final session = await widget.state.api.loginWithSms(
        phone: phone,
        code: code,
        server: _server,
        ticket: _captcha?.ticket ?? '',
        rand: _captcha?.rand ?? '',
      );
      await widget.state.setSession(session);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      _captcha = null;
      if (mounted) _showMessage('$error');
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  Future<void> _loginWithPassword() async {
    final phone = _phoneController.text.trim();
    final password = _passwordController.text;
    if (!RegExp(r'^1[3-9]\d{9}$').hasMatch(phone) || password.isEmpty) {
      _showMessage('请输入手机号和密码');
      return;
    }
    setState(() => _loggingIn = true);
    try {
      final captcha = _captcha ?? await _verifyCaptcha();
      if (captcha == null) return;
      _captcha = captcha;
      final session = await widget.state.api.loginWithPassword(
        phone: phone,
        password: password,
        server: _server,
        ticket: captcha.ticket,
        rand: captcha.rand,
      );
      await widget.state.setSession(session);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      _captcha = null;
      if (mounted) _showMessage('$error');
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('连接雨课堂')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<YktServer>(
                    initialValue: _server,
                    decoration: const InputDecoration(
                      labelText: '登录节点',
                      prefixIcon: Icon(Icons.dns_outlined),
                    ),
                    items: [
                      for (final server in YktServer.values)
                        DropdownMenuItem(
                          value: server,
                          child: Text(server.label),
                        ),
                    ],
                    onChanged: _changeServer,
                  ),
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: widget.state.privacyAgreed,
                    onChanged: (value) => _setPrivacy(value ?? false),
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('同意使用雨课堂凭据并遵守数据安全规范'),
                    subtitle: const Text(
                      'Cookie、Bearer token 和课堂 token 保存在系统安全存储中。',
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(
                value: 0,
                icon: Icon(Icons.qr_code_2_rounded),
                label: Text('扫码'),
              ),
              ButtonSegment(
                value: 1,
                icon: Icon(Icons.sms_outlined),
                label: Text('短信'),
              ),
              ButtonSegment(
                value: 2,
                icon: Icon(Icons.password_rounded),
                label: Text('密码'),
              ),
            ],
            selected: {_tab},
            onSelectionChanged: (value) {
              setState(() => _tab = value.first);
            },
          ),
          const SizedBox(height: 16),
          if (!widget.state.privacyAgreed)
            const _PrivacyRequired()
          else
            switch (_tab) {
              0 => _buildQrTab(context),
              1 => _buildSmsTab(context),
              _ => _buildPasswordTab(context),
            },
        ],
      ),
    );
  }

  Widget _buildQrTab(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const Text(
              '微信扫码登录',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            const Text(
              '用微信扫描二维码并根据提示完成雨课堂授权。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF69716D)),
            ),
            const SizedBox(height: 20),
            Container(
              constraints: const BoxConstraints(minHeight: 230),
              alignment: Alignment.center,
              child: _qrLoading
                  ? const CircularProgressIndicator()
                  : _qrInfo == null
                  ? Text(_qrMessage ?? '二维码尚未生成')
                  : _QrCodeView(info: _qrInfo!),
            ),
            const SizedBox(height: 12),
            Text(
              _qrMessage ?? (_polling ? '等待微信扫码确认…' : '二维码已就绪'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _qrMessage == null
                    ? const Color(0xFF216B42)
                    : const Color(0xFFB85C1E),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _qrLoading ? null : _startQr,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('刷新二维码'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSmsTab(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '短信验证码登录',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(11),
              ],
              decoration: const InputDecoration(
                labelText: '雨课堂绑定手机号',
                prefixIcon: Icon(Icons.phone_android_rounded),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _codeController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(8),
                    ],
                    decoration: const InputDecoration(
                      labelText: '短信验证码',
                      prefixIcon: Icon(Icons.sms_outlined),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton(
                  onPressed: _sendingCode ? null : _sendCode,
                  child: Text(_sendingCode ? '发送中' : '获取验证码'),
                ),
              ],
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _loggingIn ? null : _loginWithSms,
              icon: _loggingIn
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.login_rounded),
              label: Text(_loggingIn ? '正在登录…' : '登录雨课堂'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPasswordTab(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '账号密码登录',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(11),
              ],
              decoration: const InputDecoration(
                labelText: '手机号',
                prefixIcon: Icon(Icons.phone_android_rounded),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '雨课堂密码',
                prefixIcon: Icon(Icons.lock_outline_rounded),
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _loggingIn ? null : _loginWithPassword,
              icon: _loggingIn
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.login_rounded),
              label: Text(_loggingIn ? '正在登录…' : '验证并登录'),
            ),
          ],
        ),
      ),
    );
  }
}

class _QrCodeView extends StatelessWidget {
  const _QrCodeView({required this.info});

  final QrLoginInfo info;

  @override
  Widget build(BuildContext context) {
    if (info.qrContent.isNotEmpty) {
      return QrImageView(
        data: info.qrContent,
        size: 210,
        backgroundColor: Colors.white,
      );
    }
    if (info.qrImage.startsWith('data:image')) {
      final comma = info.qrImage.indexOf(',');
      if (comma >= 0) {
        final bytes = base64Decode(info.qrImage.substring(comma + 1));
        return Image.memory(
          Uint8List.fromList(bytes),
          width: 210,
          height: 210,
          fit: BoxFit.contain,
        );
      }
    }
    if (info.qrImage.startsWith('http')) {
      return Image.network(
        info.qrImage,
        width: 210,
        height: 210,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => const Text('二维码图片加载失败'),
      );
    }
    return const Text('服务器未返回可显示的二维码');
  }
}

class _PrivacyRequired extends StatelessWidget {
  const _PrivacyRequired();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(
              Icons.shield_outlined,
              size: 40,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 12),
            const Text(
              '请先同意数据安全说明',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
            ),
          ],
        ),
      ),
    );
  }
}
