// 画板 53 / 50（round-board-53 验收 3）：条目的升级四态 + 「需要认证且有新版本」，以及面板标题行的检查时间 / 检查中 /
// 从没拉成功过。建真的条目 widget 与标题行、查真的文字与按钮（只断言投影层的标志等于什么都没测）。

import 'package:acp_agent_client/projection/registry.dart';
import 'package:acp_agent_client/ui/registry/registry_entry.dart';
import 'package:acp_agent_client/ui/registry/registry_panel.dart';
import 'package:acp_agent_client/ui/transcript/card_chrome.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const RegistryEntryData _claude = RegistryEntryData(
  id: 'claude-acp',
  name: 'Claude Agent',
  version: '0.78.2',
  description: 'ACP wrapper for Claude.',
  installed: true,
  installedVersion: '0.76.0',
  authStatus: AuthStatus.authenticated,
  updateAvailable: '0.78.2',
);

InstallProgress _progress(String kind, String step, {String? detail, bool upgrade = true}) =>
    InstallProgress(kind: kind, step: step, at: DateTime(2026, 9, 23), detail: detail, upgrade: upgrade);

/// 标题行里的 [AcpTooltip] 要一个 Overlay 祖先（产品里右栏在 Overlay 之下）。Overlay 的 `initialEntries` 只在首次构建时用，
/// 同一个用例里换内容再 pump 要换一个 key，否则还是上一次的 child。
Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(1200, 900)),
          child: Overlay(
            key: UniqueKey(),
            initialEntries: <OverlayEntry>[
              OverlayEntry(builder: (_) => Align(alignment: Alignment.topLeft, child: SizedBox(width: 560, child: child))),
            ],
          ),
        ),
      ),
    );

Finder _rich(String text) => find.text(text, findRichText: true);

/// 标题行（名字 · 版本 · 芯片）里各段文字按树里的顺序；测试字体比真字体宽，芯片可能折行，所以不按横坐标比先后。
List<String> _titleTexts(WidgetTester tester) => <String>[
      for (final w in tester.widgetList<Text>(find.descendant(of: find.byType(Wrap).first, matching: find.byType(Text))))
        if (w.data != null) w.data!,
    ];

void main() {
  testWidgets('有新版本：旧 → 新、可升级芯片排在已安装 / 已登录之后，右侧 Update + Remove', (WidgetTester tester) async {
    final taps = <String>[];
    await _pump(tester, RegistryEntryCard(_claude, actions: RegistryEntryActions(onUpdate: () => taps.add('update'), onRemove: () => taps.add('remove'))));
    expect(_rich('v0.76.0 → v0.78.2'), findsOneWidget);
    for (final chip in <String>['已安装', '已登录', '可升级']) {
      expect(find.text(chip), findsOneWidget, reason: chip);
    }
    final title = _titleTexts(tester);
    expect(title.indexOf('可升级'), greaterThan(title.indexOf('已登录')), reason: '$title');
    await tester.tap(find.text('Update'));
    await tester.tap(find.text('Remove'));
    expect(taps, <String>['update', 'remove']);
  });

  testWidgets('升级中 · npx：只有 upgrading 芯片、两步、旧版仍可用的说明、取消', (WidgetTester tester) async {
    final taps = <String>[];
    final entry = _claude.copyWith(progress: _progress('npx', 'resolve', detail: '@agentclientprotocol/claude-agent-acp@0.78.2'));
    await _pump(tester, RegistryEntryCard(entry, actions: RegistryEntryActions(onCancel: () => taps.add('cancel'))));
    expect(find.text('upgrading'), findsOneWidget);
    expect(find.text('已安装'), findsNothing);
    expect(find.text('可升级'), findsNothing);
    expect(_rich('v0.76.0 → v0.78.2'), findsOneWidget);
    expect(find.text('解析 npx 包 @agentclientprotocol/claude-agent-acp@0.78.2'), findsOneWidget);
    expect(find.text('首次拉起并握手 initialize'), findsOneWidget);
    expect(find.text('写入 settings.json'), findsNothing);
    expect(find.text('v0.76.0 仍可正常使用；新版本握手通过后才切换。'), findsOneWidget);
    expect(find.text('Update'), findsNothing);
    await tester.tap(find.text('取消'));
    expect(taps, <String>['cancel']);
  });

  testWidgets('升级中 · binary：三步 + 进度条，说明写「解压完成」（binary 没有握手）', (WidgetTester tester) async {
    final entry = _claude.copyWith(progress: _progress('binary', 'download', detail: 'agent.zip'));
    await _pump(tester, RegistryEntryCard(entry));
    expect(find.text('sha256 校验'), findsOneWidget);
    expect(find.text('v0.76.0 仍可正常使用；新版本解压完成后才切换。'), findsOneWidget);
  });

  testWidgets('升级失败：只写装着的版本，failed 排在已安装之后，旧版不受影响的说明在日志收起时也在', (WidgetTester tester) async {
    final taps = <String>[];
    final entry = _claude.copyWith(failure: 'npm error code ETIMEDOUT');
    await _pump(
      tester,
      RegistryEntryCard(entry, showLog: false, actions: RegistryEntryActions(onRetry: () => taps.add('retry'), onViewLog: () => taps.add('log'))),
    );
    expect(find.text('v0.76.0'), findsOneWidget);
    expect(_rich('v0.76.0 → v0.78.2'), findsNothing);
    expect(find.text('可升级'), findsNothing);
    final title = _titleTexts(tester);
    expect(title.indexOf('failed'), greaterThan(title.indexOf('已安装')), reason: '$title');
    expect(find.text('npm error code ETIMEDOUT'), findsNothing, reason: '日志收起');
    expect(find.text('升级到 v0.78.2 失败，仍在使用 v0.76.0。'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.tap(find.text('查看日志'));
    expect(taps, <String>['retry', 'log']);
  });

  testWidgets('已升级 · 待重载：说明运行中的旧连接；认不出旧版本时写「旧版本」', (WidgetTester tester) async {
    const upgraded = RegistryEntryData(
      id: 'claude-acp',
      name: 'Claude Agent',
      version: '0.78.2',
      description: 'd',
      installed: true,
      installedVersion: '0.78.2',
      authStatus: AuthStatus.authenticated,
      reloadPending: '0.76.0',
    );
    await _pump(tester, const RegistryEntryCard(upgraded));
    expect(find.text('已升级到 v0.78.2。正在运行的 v0.76.0 连接不受影响，在会话头 Reload Agent 或重开应用后生效。'), findsOneWidget);
    expect(find.text('Remove'), findsOneWidget);
    expect(find.text('Update'), findsNothing);

    await _pump(
      tester,
      const RegistryEntryCard(RegistryEntryData(id: 'x', name: 'X', version: '2.0.0', description: '', installed: true, installedVersion: '2.0.0', reloadPending: '')),
    );
    expect(find.text('已升级到 v2.0.0。正在运行的旧版本连接不受影响，在会话头 Reload Agent 或重开应用后生效。'), findsOneWidget);
  });

  testWidgets('需要认证且有新版本：仍出旧 → 新与可升级，右侧是登录', (WidgetTester tester) async {
    const entry = RegistryEntryData(
      id: 'codex-acp',
      name: 'Codex',
      version: '1.12.0',
      description: '',
      installed: true,
      installedVersion: '1.11.0',
      authStatus: AuthStatus.needsAuth,
      updateAvailable: '1.12.0',
    );
    await _pump(tester, const RegistryEntryCard(entry));
    expect(_rich('v1.11.0 → v1.12.0'), findsOneWidget);
    expect(find.text('需要认证'), findsOneWidget);
    expect(find.text('可升级'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
    expect(find.text('Update'), findsNothing);
  });

  testWidgets('标题行：检查于 N 分钟前 + 检查更新；检查中换 spinner；从没拉成功过不显示时间', (WidgetTester tester) async {
    final now = DateTime(2026, 9, 23, 12);
    var refreshed = 0;
    await _pump(tester, RegistryPanelHeader(fetchedAt: now.subtract(const Duration(minutes: 12)), now: now, onRefresh: () => refreshed++));
    expect(find.text('检查于 12 分钟前'), findsOneWidget);
    await tester.tap(find.byType(IconButtonGhost));
    expect(refreshed, 1);

    await _pump(tester, RegistryPanelHeader(fetchedAt: now.subtract(const Duration(seconds: 20)), now: now));
    expect(find.text('刚刚检查过'), findsOneWidget);

    await _pump(tester, RegistryPanelHeader(fetching: true, fetchedAt: now, now: now));
    expect(find.text('检查中…'), findsOneWidget);
    expect(find.byType(IconButtonGhost), findsNothing);

    await _pump(tester, const RegistryPanelHeader());
    expect(find.textContaining('检查于'), findsNothing);
    expect(find.byType(IconButtonGhost), findsOneWidget);
  });
}
