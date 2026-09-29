// 画板 70 的 agent 列表行：内置 agent（dsh-acp-interactive）**可见、不可编辑、不可删**
// （docs/design.md § 6.6）。
// 2026-09-17 起两个按钮不是置灰而是**整个不画**（所有者裁定：置灰的按钮看着像坏了）。
//
// 这条用例建**真的 SettingsPage**、查真的按钮。核心侧的拒写有
// `rust/acp-core/src/builtin.rs` 的 `builtin_entry_is_not_written_to_settings_json` 兜着。

import 'package:acp_agent_client/projection/registry.dart';
import 'package:acp_agent_client/ui/registry/registry_entry.dart';
import 'package:acp_agent_client/ui/settings/settings_page.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const Map<String, String> _builtinNames = <String, String>{'dsh-acp-interactive': 'DeepSeek Harness'};

RegistryEntryData _custom(String id, {bool builtin = false}) => RegistryEntryData(
      id: id,
      name: builtin ? _builtinNames[id]! : id,
      version: '',
      description: '',
      kind: DistributionKind.custom,
      installed: true,
      builtin: builtin,
      custom: CustomCommand(command: 'x', args: const <String>[], env: const <String, String>{}),
    );

Future<void> _pump(WidgetTester tester, Widget page) => tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(data: const MediaQueryData(size: Size(1200, 900)), child: page),
      ),
    );

void main() {
  testWidgets('画板 70：内置条目不画「编辑」与 Remove，普通 custom 条目照常', (WidgetTester tester) async {
    final List<String> edited = <String>[];
    final List<String> removed = <String>[];
    await _pump(
      tester,
      SettingsPage(
        agents: <RegistryEntryData>[_custom('my-agent'), _custom('dsh-acp-interactive', builtin: true)],
        dataDir: 'D:/data',
        onEdit: edited.add,
        onRemove: removed.add,
      ),
    );

    // 两行里只有非内置那一行带按钮。
    expect(find.text('编辑'), findsOneWidget, reason: '内置条目不画「编辑」');
    expect(find.text('Remove'), findsOneWidget, reason: '内置条目不画 Remove');
    // 两行都在（内置条目可见，只是没有按钮）。
    expect(find.text('my-agent'), findsOneWidget);
    expect(find.text('dsh-acp-interactive'), findsOneWidget);

    // 剩下的那对按钮点得动，回调带的是非内置条目的 id。
    await tester.tap(find.text('编辑'));
    await tester.tap(find.text('Remove'));
    await tester.pump();
    expect(edited, <String>['my-agent']);
    expect(removed, <String>['my-agent']);
  });

  // 画板 50 的 Agents 面板同一条规矩：内置条目的行右侧什么都不画。
  testWidgets('画板 50：内置条目的行不画 Remove，普通 custom 条目照常', (WidgetTester tester) async {
    final List<String> removed = <String>[];
    await _pump(
      tester,
      Column(
        children: <Widget>[
          RegistryEntryRow(_custom('my-agent'), actions: RegistryEntryActions(onRemove: () => removed.add('my-agent'))),
          RegistryEntryRow(_custom('dsh-acp-interactive', builtin: true), actions: RegistryEntryActions(onRemove: () => removed.add('dsh'))),
        ],
      ),
    );

    expect(find.text('Remove'), findsOneWidget, reason: '两行里只有非内置那行带 Remove');
    await tester.tap(find.text('Remove'));
    await tester.pump();
    expect(removed, <String>['my-agent']);
  });
}
