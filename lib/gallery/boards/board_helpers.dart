// gallery 各画板文件共用的小工具（iteration-04 收拢：原先 agent / panel / shell / transcript 五个 boards 文件里
// 各复制了 2–4 份）。只在 debug / test 编入。

import 'package:flutter/widgets.dart';

import '../../projection/session_store.dart';
import '../../theme/tokens.dart' as t;
import '../../ui/popovers/composer_popovers.dart';
import '../../ui/shell/composer.dart';
import '../board_page.dart';
import '../fixtures_source.dart';
import '../gallery.dart';

/// 输入控件的样张（gallery 里的输入框都是只读样张）。
TextEditingController boardText([String text = '']) => TextEditingController(text: text);

/// 整窗画板：`SelectableRegion` / `EditableText` / xterm 需要 Overlay 祖先（真实应用由 `MaterialApp` 提供）。
GalleryBoard windowBoard(String id, String title, WidgetBuilder build) => GalleryBoard(
      id: id,
      title: title,
      frame: const Size(1440, 900),
      build: (context) => Overlay(initialEntries: <OverlayEntry>[OverlayEntry(builder: build)]),
    );

/// 状态合集画板：BoardPage 版式，高度随内容。
GalleryBoard pageBoard(String id, String title, Widget Function() build) =>
    GalleryBoard(id: id, title: title, frame: const Size(BoardPage.width, 0), fitContent: true, build: (_) => build());

String fixtureAgentTitle(FixtureReplay r) {
  final a = r.sessions.agents[FixtureReplay.agentId];
  return a?.agentTitle ?? a?.agentName ?? 'Agent';
}

String fixtureSessionTitle(FixtureReplay r) => r.session.title ?? 'New ${fixtureAgentTitle(r)} Session';

/// 画板 01 / 03 / 60 / 61 输入框里的三个下拉：PNG 是按「模型 · 思考强度 · 模式」排的，画板未按固定档序重出之前，
/// 对照板保持 PNG 的顺序与条目（真输入框已改成按档序把每条 configOption 都平铺出来，见 design/DIVERGENCE.md）。
List<ComposerOption> boardComposerOptions(
  SessionStore s, {
  List<String> categories = const <String>['model', 'thought_level', 'mode'],
}) {
  final options = <ComposerOption>[];
  for (final category in categories) {
    final label = _currentName(s, category);
    if (label == null) continue;
    options.add(ComposerOption(
      label: label,
      maxWidth: category == 'model' ? t.Geometry.composerModelMaxWidth : null,
    ));
  }
  return options;
}

String? _currentName(SessionStore s, String category) {
  for (final o in s.configOptions) {
    if (o.category == category) return configCurrentName(o);
  }
  return null;
}
