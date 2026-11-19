import 'package:flutter/material.dart';

import 'main.dart';
import 'screens/home_screen.dart';
import 'services/app_state.dart';
import 'theme/app_theme.dart';

class GongXiaoHuApp extends StatelessWidget {
  const GongXiaoHuApp({required this.state, super.key});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AppLifecycleObserver(
      state: state,
      child: AnimatedBuilder(
        animation: state,
        builder: (context, _) => MaterialApp(
          title: '晴课堂',
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          darkTheme: buildAppDarkTheme(),
          themeMode: state.themeMode,
          home: HomeScreen(state: state),
        ),
      ),
    );
  }
}
