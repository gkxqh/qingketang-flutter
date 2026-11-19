import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'services/app_state.dart';
import 'services/background_auto_submit_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await BackgroundAutoSubmitService.initialize();
  final state = AppState();
  await state.initialize();
  runApp(GongXiaoHuApp(state: state));
}

class AppLifecycleObserver extends StatefulWidget {
  const AppLifecycleObserver({
    required this.state,
    required this.child,
    super.key,
  });

  final AppState state;
  final Widget child;

  @override
  State<AppLifecycleObserver> createState() => _AppLifecycleObserverState();
}

class _AppLifecycleObserverState extends State<AppLifecycleObserver>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.state.refreshLessons());
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
