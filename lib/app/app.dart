// 组合根：默认接 Rust 核心（bridge），`--dart-define=DATA_SOURCE=fixtures` 时回放 test/fixtures（gallery 与开发用）。
// R0 的 SmokeScreen 已被会话工作台壳取代；无头自检仍走 `ACP_SMOKE_REPORT`（lib/main.dart → lib/app/smoke.dart）。

import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import '../theme/tokens.dart' as t;
import 'core_bridge.dart';
import 'font_prefs.dart';
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

  /// 字体偏好（画板 70「外观」）：启动时扫可选字体并读设置，改动后 [ChangeNotifier] 触发整树重建。
  /// 放在最外层而不是设置页里：四个轴是全局样式，转录 / 终端 / 弹层都要跟着变。
  late final FontPrefsController _fonts = FontPrefsController(bridge: widget.bridge);

  /// 关窗前的收尾（R4 验收 4：应用退出时子进程全部回收）：Windows 引擎把 `WM_CLOSE` 转成 `System.requestAppExit`，
  /// 这里等核心 `core_shutdown`（释放终端、断开 agent）回来再放行。
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(onExitRequested: _onExitRequested);
  bool _shuttingDown = false;

  Future<AppExitResponse> _onExitRequested() async {
    if (!_shuttingDown) {
      _shuttingDown = true;
      await _controller.shutdown();
    }
    return AppExitResponse.exit;
  }

  @override
  void initState() {
    super.initState();
    _lifecycle;
    // 不 await：字体扫描是磁盘 IO，不该拖慢首帧。扫完若与默认不同会自己触发一次重建。
    _fonts.start();
    _controller.start();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _fonts.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 字体一变整棵树重建：`t.TextStyles` 各档是 getter，重建后自然取到新 family。
    return ListenableBuilder(listenable: _fonts, builder: (context, _) => _buildApp(context));
  }

  Widget _buildApp(BuildContext context) {
    return MaterialApp(
      title: 'AcpAgent Client',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: t.Fonts.sans,
        fontFamilyFallback: t.Fonts.cjkFallback,
        scaffoldBackgroundColor: t.Surface.canvas,
        colorScheme: ColorScheme.fromSeed(seedColor: t.Accent.base, surface: t.Surface.canvas),
        textTheme: TextTheme(bodyMedium: t.TextStyles.body),
      ),
      // 壳里一个 Material widget 都不用（画板全是自写的），而 `MaterialApp` 会把「没有 Material 祖先」的
      // 兜底样式装成环境 `DefaultTextStyle`——它带黄色双下划线，`Text` 只覆盖字号与颜色、下划线原样继承，
      // 于是 Release 里满屏文字挂着黄线。`builder` 在那层之内，用 token 基准字样把它换掉，弹层同样覆盖到。
      builder: (context, child) => DefaultTextStyle(style: t.TextStyles.body, child: child!),
      home: WorkbenchScreen(controller: _controller, fonts: _fonts),
    );
  }
}
