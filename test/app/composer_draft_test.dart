// 输入框草稿按会话归属（BACKLOG P0「切换 session 后，未发送的提示词会带入另一个会话的输入区」，所有者实机报障 2026-09-30）。
// 以前输入框是所有会话共用的一份：在 A 里打字不发、切到 B（或另一个 agent 的会话），文字还在。

import 'dart:async';

import 'package:acp_agent_client/app/workbench_controller.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:acp_agent_client/ui/popovers/topbar_popovers.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_core.dart';

/// 每条 `session/new` 一个不同的 id；连上就是 initialized，第二条会话不重连（同 concurrent_turns_test）。
/// `session/prompt` 挂住不回，用例只看发出去的内容。
class _Core extends FakeCore {
  int _seq = 0;

  @override
  Future<JsonMap> agentConnect(String agentId, {String? cwd}) async => <String, dynamic>{
        'agentId': agentId,
        'initialize': <String, dynamic>{
          'protocolVersion': 1,
          'agentInfo': <String, dynamic>{'name': agentId},
          'agentCapabilities': <String, dynamic>{'loadSession': true},
        },
      };

  @override
  Future<JsonMap> sessionNew(String agentId, String cwd) async => <String, dynamic>{'sessionId': '${agentId}_${++_seq}'};

  @override
  Future<JsonMap> sessionPrompt(String agentId, String sessionId, List<Object?> prompt) {
    prompts.add(prompt);
    return Completer<JsonMap>().future;
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

WorkbenchController _controller(_Core core) =>
    WorkbenchController(source: DataSource.bridge, bridge: core, scheduler: WorkbenchController.scheduleOnMicrotask)
      ..workspace.project = const ProjectRef(path: r'D:\repo', name: 'repo');

void main() {
  test('A 里未发送的正文与附件不带到 B（含跨 agent），切回 A 原样还原', () async {
    final core = _Core();
    final c = _controller(core);
    await c.session.newSession(const AgentRef(id: 'pi', name: 'pi'));
    final sidA = c.session.sessionId!;
    await c.session.newSession(const AgentRef(id: 'codex', name: 'codex'));
    final sidB = c.session.sessionId!;
    expect(sidA, isNot(sidB));

    await c.session.selectSession(sidA);
    c.composer.editor.text = '测试网络';
    c.composer.addImage('AAAA', 'image/png');

    await c.session.selectSession(sidB);
    expect(c.composer.editor.text, isEmpty);
    expect(c.composer.pendingBlocks, isEmpty);

    c.composer.editor.text = 'B 的草稿';
    await c.session.selectSession(sidA);
    expect(c.composer.editor.text, '测试网络');
    expect(c.composer.pendingImages, hasLength(1));

    await c.session.selectSession(sidB);
    expect(c.composer.editor.text, 'B 的草稿');
    expect(c.composer.pendingBlocks, isEmpty);
    c.dispose();
  });

  test('还没有会话时打的字发送：跟着现开的会话发出去，不留在「无会话」槽里', () async {
    final core = _Core();
    final c = _controller(core);
    c.session.agentId = 'pi';
    c.composer.editor.text = '第一条';

    unawaited(c.turn.send());
    await _settle();

    expect(c.session.sessionId, isNotNull);
    expect(core.prompts, hasLength(1));
    expect(core.prompts.single.toString(), contains('第一条'));
    expect(c.composer.editor.text, isEmpty);
    c.dispose();
  });

  test('换到别的项目：旧会话的正文与附件离开输入框，切回那条会话才还原', () async {
    final core = _Core();
    final c = _controller(core);
    await c.session.newSession(const AgentRef(id: 'pi', name: 'pi'));
    final sid = c.session.sessionId!;
    c.composer.editor.text = '留在旧项目';
    c.composer.addImage('AAAA', 'image/png');

    await c.workspace.openProject(const ProjectRef(path: r'D:\other', name: 'other'));
    expect(c.session.sessionId, isNull);
    expect(c.composer.editor.text, isEmpty);
    expect(c.composer.pendingBlocks, isEmpty);

    await c.workspace.openProject(const ProjectRef(path: r'D:\repo', name: 'repo'));
    await c.session.selectSession(sid);
    expect(c.composer.editor.text, '留在旧项目');
    expect(c.composer.pendingImages, hasLength(1));
    c.dispose();
  });

  test('删掉当前会话：它的草稿一并放下，不留到下一条', () async {
    final core = _Core();
    final c = _controller(core);
    await c.session.newSession(const AgentRef(id: 'pi', name: 'pi'));
    final sidA = c.session.sessionId!;
    c.composer.editor.text = '要被删的';

    await c.session.deleteSession(sidA);
    expect(c.session.sessionId, isNull);
    expect(c.composer.editor.text, isEmpty);
    c.dispose();
  });
}
