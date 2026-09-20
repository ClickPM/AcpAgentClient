// R0 开发用自检页（不是画板，R3 由工作台壳取代）：core_init 状态、ping 往返、事件日志、
// 一个 TextField 给中文 IME 组合窗实测（docs/research.md § 8）。样式全部走 tokens。

import 'dart:async';

import 'package:flutter/material.dart';

import '../projection/wire.dart';
import '../theme/tokens.dart' as t;
import 'core_bridge.dart';
import 'paths.dart';

class SmokeScreen extends StatefulWidget {
  const SmokeScreen({super.key});

  @override
  State<SmokeScreen> createState() => _SmokeScreenState();
}

class _SmokeScreenState extends State<SmokeScreen> {
  CoreBridge? _bridge;
  StreamSubscription<CoreEventRecord>? _sub;
  String _status = 'loading cdylib…';
  String _lastPing = '—';
  final List<String> _log = <String>[];
  final TextEditingController _ime = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  Future<void> _boot() async {
    try {
      final bridge = await CoreBridge.load();
      if (!mounted) return;
      _sub = bridge.events.listen(_onEvent);
      final info = await bridge.init(defaultDataDir());
      if (!mounted) return;
      setState(() {
        _bridge = bridge;
        _status = 'core ${info['coreVersion']} · ${info['dataDir']}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'init failed: $e');
    }
  }

  void _onEvent(CoreEventRecord e) {
    final json = e.json;
    final summary = json == null
        ? e.raw
        : e.channel == CoreEvent.agentState
            ? 'state=${AgentStateWire(json).state}'
            : e.raw;
    setState(() {
      _log.insert(0, '${e.channel.name}  $summary');
      if (_log.length > 50) _log.removeLast();
    });
  }

  Future<void> _ping() async {
    final bridge = _bridge;
    if (bridge == null) return;
    try {
      final r = await bridge.ping('ui');
      if (!mounted) return;
      setState(() => _lastPing = 'pong=${r['pong']} seq=${r['sequence']} core=${r['coreVersion']}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _lastPing = 'ping failed: $e');
    }
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    _ime.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: t.Surface.canvas,
      body: Padding(
        padding: const EdgeInsets.all(t.Spacing.s24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('R0 smoke', style: t.TextStyles.title),
            const SizedBox(height: t.Spacing.s8),
            Text(_status, style: t.TextStyles.secondary),
            const SizedBox(height: t.Spacing.s16),
            Row(
              children: <Widget>[
                _PrimaryButton(label: 'ping', onPressed: _bridge == null ? null : _ping),
                const SizedBox(width: t.Spacing.s12),
                Expanded(child: Text(_lastPing, style: t.TextStyles.mono)),
              ],
            ),
            const SizedBox(height: t.Spacing.s16),
            Text('IME TEST · 在下面输入中文，观察组合窗与候选', style: t.TextStyles.label),
            const SizedBox(height: t.Spacing.s8),
            TextField(
              controller: _ime,
              style: t.TextStyles.body,
              decoration: InputDecoration(
                isDense: true,
                hintText: '在此输入中文…',
                hintStyle: t.TextStyles.secondary,
                contentPadding: t.Controls.padInput,
                enabledBorder: OutlineInputBorder(borderRadius: t.Radii.control, borderSide: BorderSide(color: t.Borders.base, width: t.Borders.width)),
                focusedBorder: OutlineInputBorder(borderRadius: t.Radii.control, borderSide: BorderSide(color: t.FocusRing.color, width: t.FocusRing.width)),
              ),
            ),
            const SizedBox(height: t.Spacing.s16),
            Text('EVENTS', style: t.TextStyles.label),
            const SizedBox(height: t.Spacing.s8),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: t.Surface.panel,
                  borderRadius: t.Radii.card,
                  border: Border.fromBorderSide(BorderSide(color: t.Borders.subtle, width: t.Borders.width)),
                ),
                child: ListView.builder(
                  padding: const EdgeInsets.all(t.Spacing.s12),
                  itemCount: _log.length,
                  itemBuilder: (_, i) => Text(_log[i], style: t.TextStyles.monoMeta),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        height: t.Controls.standard,
        padding: t.Controls.padInput,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled ? t.Accent.base : t.Neutral.surface,
          borderRadius: t.Radii.control,
        ),
        child: Text(
          label,
          style: t.TextStyles.body.copyWith(color: enabled ? t.Accent.onAccent : t.Neutral.placeholder, height: t.LineHeights.control),
        ),
      ),
    );
  }
}
