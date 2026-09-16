// 组合根：默认接 Rust 核心（bridge），`--dart-define=DATA_SOURCE=fixtures` 时回放 test/fixtures（gallery 与开发用）。
// R0 的 SmokeScreen 已被会话工作台壳取代；无头自检仍走 `ACP_SMOKE_REPORT`（lib/main.dart → lib/app/smoke.dart）。

import 'package:flutter/material.dart';

import '../theme/tokens.dart' as t;
import 'core_bridge.dart';
import 'workbench_controller.dart';
import 'workbench_screen.dart';

class AcpApp extends StatefulWidget {
  const AcpApp({super.key, this.source, this.bridge});

  /// 缺省按 `--dart-define=DATA_SOURCE` 判定。
  final DataSource? source;
  final CoreCommands? bridge;

  @override
  State<AcpApp> createState() => _AcpAppState();
}

class _AcpAppState extends State<AcpApp> {
  late final WorkbenchController _controller = WorkbenchController(
    source: widget.source ?? DataSource.fromEnvironment(),
    bridge: widget.bridge,
  );

  @override
  void initState() {
    super.initState();
    _controller.start();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

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
      // 壳里一个 Material widget 都不用（画板全是自写的），而 `MaterialApp` 会把「没有 Material 祖先」的
      // 兜底样式装成环境 `DefaultTextStyle`——它带黄色双下划线，`Text` 只覆盖字号与颜色、下划线原样继承，
      // 于是 Release 里满屏文字挂着黄线。`builder` 在那层之内，用 token 基准字样把它换掉，弹层同样覆盖到。
      builder: (context, child) => DefaultTextStyle(style: t.TextStyles.body, child: child!),
      home: WorkbenchScreen(controller: _controller),
    );
  }
}
