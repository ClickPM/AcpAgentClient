// 组合根：R0 只有一个开发用自检页（lib/app/smoke_screen.dart），R3 换成画板 01 的工作台壳。
// 数据源选择（fixtures / bridge）与路由在 R3 加进来。

import 'package:flutter/material.dart';

import '../theme/tokens.dart' as t;
import 'smoke_screen.dart';

class AcpApp extends StatelessWidget {
  const AcpApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AcpAgent Client',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: t.Fonts.sans,
        fontFamilyFallback: t.Fonts.cjkFallback,
        scaffoldBackgroundColor: t.Surface.canvas,
        colorScheme: ColorScheme.fromSeed(seedColor: t.Accent.base, surface: t.Surface.canvas),
        textTheme: const TextTheme(bodyMedium: t.TextStyles.body),
      ),
      home: const SmokeScreen(),
    );
  }
}
