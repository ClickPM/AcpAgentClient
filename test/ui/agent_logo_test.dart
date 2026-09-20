// 会话的 agent logo（画板 01–04 的 agent 标记）：侧栏会话项、会话头与「新建会话 · 选 agent」弹层画的是
// **已装 agent 自己的 `icon.svg`**（registry 缓存的那一份，与画板 50 / 51 / 70 的图标框同源），
// registry 里没有才退回画板的单色占位菱形。守住：按 agentId 查出来（会话按所属 agent、弹层按每条自己的 id）、
// registry 后到时侧栏会重投影（不会一直停在占位上）、以及 [AgentMark] 真按有没有 svg 分两条路走。

import 'dart:io';

import 'package:acp_agent_client/app/workbench_controller.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/ui/registry/registry_entry.dart';
import 'package:acp_agent_client/ui/popovers/topbar_popovers.dart';
import 'package:acp_agent_client/ui/shell/shell_common.dart';
import 'package:acp_agent_client/ui/shell/transcript_empty.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

import '../app/fake_core.dart';

const String _svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><circle cx="8" cy="8" r="7"/></svg>';
const String _agent = 'codex-acp';

JsonMap _entry(String id, {String? icon}) => <String, dynamic>{
      'id': id,
      'name': id,
      'version': '1.0.0',
      'description': 'd',
      'distribution': 'npx',
      'supported': true,
      'iconSvg': ?icon,
      'installed': <String, dynamic>{'kind': 'npx', 'version': '1.0.0', 'authStatus': 'unknown', 'command': 'node', 'args': <String>['x']},
    };

JsonMap _registry(List<Object?> agents) => <String, dynamic>{'agents': agents, 'fetching': false, 'node': <String, dynamic>{}};

/// settings.json 里装着两个 agent：一个 registry 型、一个内置 sidecar（`zed`）。
class _TwoAgentsCore extends FakeCore {
  @override
  Future<JsonMap> agentSettingsGet() async => <String, dynamic>{
        'agent_servers': <String, dynamic>{
          _agent: <String, dynamic>{'command': 'node'},
          'zed': <String, dynamic>{'command': 'zed-agent-acp.exe', 'name': 'Zed Agent'},
        },
      };
}

Future<WorkbenchController> _start(FakeCore core) async {
  await core.sessionIndexUpsert(<String, dynamic>{
    'agentId': _agent,
    'sessionId': 's1',
    'title': '一条会话',
    'cwd': 'D:/repo',
    'messageCount': 1,
  });
  final c = WorkbenchController(source: DataSource.bridge, bridge: core, scheduler: WorkbenchController.scheduleOnMicrotask);
  await c.start();
  return c;
}

void main() {
  tearDown(t.Theming.reset);

  test('侧栏会话项与会话头拿的是所属 agent 的 icon.svg', () async {
    final core = FakeCore()..registry = _registry(<Object?>[_entry(_agent, icon: _svg)]);
    final c = await _start(core);
    expect(c.thread.sidebarSessions.single.iconSvg, _svg);
    expect(c.agents.iconSvgOf(_agent), _svg);
    // registry 里没有这条（custom 条目 / 没缓存到图标）→ null，widget 退回占位。
    expect(c.agents.iconSvgOf('not-in-registry'), isNull);
    expect(c.agents.iconSvgOf(null), isNull);
    c.dispose();
  });

  test('registry 后到（首启时图标是联网刷新才落盘的）：侧栏重投影，不停在占位上', () async {
    final core = FakeCore()..registry = _registry(<Object?>[_entry(_agent)]);
    final c = await _start(core);
    expect(c.thread.sidebarSessions.single.iconSvg, isNull, reason: '这轮 registry 还没有图标');

    core.registry = _registry(<Object?>[_entry(_agent, icon: _svg)]);
    await c.agents.refreshRegistry(network: true);
    expect(c.thread.sidebarSessions.single.iconSvg, _svg, reason: 'registry 一变就要重投影侧栏');
    c.dispose();
  });

  test('「新建会话 · 选 agent」弹层的每条也带 logo（内置 zed 用随包带的那份）', () async {
    final core = _TwoAgentsCore()
      ..registry = _registry(<Object?>[_entry(_agent, icon: _svg), _entry('zed', icon: '<svg viewBox="0 0 16 16"/>')]);
    final c = await _start(core);
    final byId = <String, AgentRef>{for (final a in c.agents.installed) a.id: a};
    expect(byId[_agent]!.iconSvg, _svg);
    expect(byId['zed']!.iconSvg, '<svg viewBox="0 0 16 16"/>', reason: '内置条目的 iconSvg 由 builtin.rs 放进 registry_list');
    c.dispose();
  });

  // 内置 sidecar（agent id `zed`）不在官方 registry 里、没有可缓存的图标，随包带一份 Zed 的标志，
  // 由 `rust/acp-core/src/builtin.rs` 放进条目的 `iconSvg`（走的还是同一条投影路）。这里只守「这份 SVG
  // 真能被 flutter_svg 解析」：文件头有一段来源声明的 XML 注释，解析不了的话前端会静默退回占位菱形。
  test('随包带的 Zed logo 能被 flutter_svg 解析', () async {
    final file = File('rust/acp-core/assets/zed-icon.svg');
    expect(file.existsSync(), isTrue, reason: 'include_str! 进 builtin.rs 的就是这个文件');
    final svg = file.readAsStringSync();
    expect(svg, contains('zed-industries/zed'), reason: '复用要标来源（CLAUDE.md 规则 5）');
    await SvgStringLoader(svg).loadBytes(null);
  });

  // 内置的第二条（agent id `dsh-acp-interactive`）同理：官方 registry 里没有它，图标随包带
  // （DeepSeek Harness 自己的标志，与桌面快捷方式那张图标同源）。
  test('随包带的 dsh logo 能被 flutter_svg 解析', () async {
    final file = File('rust/acp-core/assets/dsh-icon.svg');
    expect(file.existsSync(), isTrue, reason: 'include_str! 进 builtin.rs 的就是这个文件');
    final svg = file.readAsStringSync();
    expect(svg, contains('deepseek-ai/deepseek-harness'), reason: '复用要标来源（CLAUDE.md 规则 5）');
    // 匹配串带上 `fill=`：光找 `currentColor` 的话文件头那句来源注释就够让断言恒真，
    // 而根元素带着 `fill="none"`，path 上的取色一旦写错整张图一个像素都不画（审查 finding P2）。
    expect(svg, contains('fill="currentColor"'), reason: '取色方式与 registry 的 icon.svg 一致');
    await SvgStringLoader(svg).loadBytes(null);
  });

  testWidgets('转录区空态的大图标位同样吃 agent 的 icon.svg，没有才退占位菱形', (tester) async {
    Future<void> pump(String? svg) => tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(child: NewSessionEmpty(title: 'New Codex Session', svg: svg)),
          ),
        );

    await pump(null);
    expect(find.byType(SvgPicture), findsNothing, reason: '没有 icon.svg 就是占位菱形');

    await pump('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">'
        '<circle cx="8" cy="8" r="6" fill="currentColor"/></svg>');
    await tester.pumpAndSettle();
    expect(find.byType(SvgPicture), findsOneWidget, reason: '有 icon.svg 就画那张 logo');
  });

  testWidgets('AgentMark：有 icon.svg 画 logo，没有画占位菱形，两态同尺寸', (tester) async {
    Future<void> pump(Widget child) => tester.pumpWidget(Directionality(textDirection: TextDirection.ltr, child: Center(child: child)));

    await pump(const AgentMark(svg: _svg));
    expect(find.byType(SvgPicture), findsOneWidget);
    final withLogo = tester.getSize(find.byType(AgentMark));

    await pump(const AgentMark());
    expect(find.byType(SvgPicture), findsNothing);
    expect(tester.getSize(find.byType(AgentMark)), withLogo, reason: '有没有 logo 都占同样的 16 见方，行高不跳');
  });

  // 这些 logo 全是单色的 `fill="currentColor"`（registry 的约定；内置那两张同样如此），取什么色由宿主定。
  // 不给 SvgTheme 的话 flutter_svg 把 currentColor 当纯黑（`SvgTheme.currentColor` 缺省 opaqueBlack），
  // 深色主题下就是黑底上的黑标记（2026-09-20 所有者报障）。守住：三个画标记的地方都给取值，且随主题换。
  testWidgets('agent 的 icon.svg 取色随主题走，不落回 flutter_svg 的纯黑缺省', (WidgetTester tester) async {
    // 三个 widget 都不能写成 const：常量实例会被规范化，换主题后第二次 pump 时
    // `Element.updateChild` 见到 `identical(old, new)` 就跳过重建，量到的还是旧取色。
    // svg 过一道 final 局部量，构造就不再是常量表达式（也就不触发 prefer_const_constructors）。
    final String icon = _svg;
    Future<void> pump() => tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  AgentMark(svg: icon),
                  NewSessionEmpty(title: 'New Codex Session', svg: icon),
                  AgentIconBox(svg: icon),
                ],
              ),
            ),
          ),
        );

    List<Color?> tints() => tester
        .widgetList<SvgPicture>(find.byType(SvgPicture))
        .map((SvgPicture p) => (p.bytesLoader as SvgStringLoader).theme?.currentColor)
        .toList();

    await pump();
    expect(tints(), hasLength(3), reason: '侧栏 / 会话头的标记、空态大图标、registry 图标框');
    expect(tints(), everyElement(t.Theming.lightColors.strong));

    t.Theming.apply(t.AppTheme.dark);
    await pump();
    expect(tints(), everyElement(t.Theming.darkColors.strong));
    expect(tints(), isNot(contains(const Color(0xFF000000))), reason: 'flutter_svg 不给 theme 时的缺省就是这个黑');
  });
}
