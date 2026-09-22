// 画板 27 · 表单模式交互卡：elicitation/create · mode "form"。requestedSchema 的受限 JSON Schema（string / enum(oneOf) /
// array(enum | anyOf) / number / integer / boolean），字段标题与描述一律取 schema 的 title / description，不自造文案；
// 未知 type 的属性忽略；required 未填 → 校验态（必填标记 + 红框 + 汇总条 + Submit 禁用）。回应 accept / decline / cancel。

import 'package:flutter/widgets.dart';

import '../../projection/entries.dart';
import '../../projection/wire.dart';
import '../../theme/tokens.dart' as t;
import 'card_chrome.dart';
import 'icons.dart';

/// 一个字段的 schema 视图。
class _ElicitationField {
  _ElicitationField(this.name, this.schema, {required this.required});

  final String name;
  final JsonMap schema;
  final bool required;

  // type / title / description 非字符串（例如 JSON Schema 常见的 type: ["string", "null"]）时不炸：
  // type 当未知（跳过字段），标题回落属性名（审查 P2）。
  String get type => schema['type'] is String ? schema['type'] as String : '';
  String get title => schema['title'] is String ? schema['title'] as String : name;
  String? get description => schema['description'] is String ? schema['description'] as String : null;
  Object? get defaultValue => schema['default'];

  /// 单选：string 的 oneOf（带标题）或 enum（无标题）。
  List<(String value, String title)>? get choices {
    if (type != 'string') return null;
    final oneOf = schema['oneOf'];
    if (oneOf is List) {
      return <(String, String)>[
        for (final o in oneOf)
          if (o is Map && o['const'] is String) (o['const'] as String, (o['title'] as String?) ?? o['const'] as String),
      ];
    }
    final en = schema['enum'];
    if (en is List) return <(String, String)>[for (final v in en) (v.toString(), v.toString())];
    return null;
  }

  /// 多选：array 的 items.enum（无标题）或 items.anyOf（带标题）。
  List<(String value, String title)>? get multiChoices {
    if (type != 'array') return null;
    final items = schema['items'];
    if (items is! Map) return null;
    final anyOf = items['anyOf'];
    if (anyOf is List) {
      return <(String, String)>[
        for (final o in anyOf)
          if (o is Map && o['const'] is String) (o['const'] as String, (o['title'] as String?) ?? o['const'] as String),
      ];
    }
    final en = items['enum'];
    if (en is List) return <(String, String)>[for (final v in en) (v.toString(), v.toString())];
    return null;
  }

  bool get isSupported => switch (type) {
        'string' || 'number' || 'integer' || 'boolean' => true,
        'array' => multiChoices != null,
        _ => false,
      };

  /// 字段元信息（mono 11）：「string · enum」「array · minItems 1」「integer · 1–16」「boolean」。
  String get meta {
    final parts = <String>[type];
    if (choices != null) parts.add('enum');
    if (type == 'array') {
      final min = schema['minItems'];
      final max = schema['maxItems'];
      if (min != null) parts.add('minItems $min');
      if (max != null) parts.add('maxItems $max');
    }
    if (type == 'integer' || type == 'number') {
      final min = schema['minimum'];
      final max = schema['maximum'];
      if (min != null && max != null) {
        parts.add('$min–$max');
      } else if (min != null) {
        parts.add('≥ $min');
      } else if (max != null) {
        parts.add('≤ $max');
      }
    }
    if (type == 'string' && choices == null) {
      final max = schema['maxLength'];
      if (max != null) parts.add('maxLength $max');
    }
    return parts.join(' · ');
  }

  static List<_ElicitationField> parse(JsonMap? requestedSchema) {
    if (requestedSchema == null) return const <_ElicitationField>[];
    final props = requestedSchema['properties'];
    final req = requestedSchema['required'];
    final required = req is List ? req.map((e) => e.toString()).toSet() : const <String>{};
    if (props is! Map) return const <_ElicitationField>[];
    return <_ElicitationField>[
      for (final entry in props.entries)
        if (entry.value is Map) _ElicitationField(entry.key.toString(), (entry.value as Map).cast<String, dynamic>(), required: required.contains(entry.key)),
    ];
  }
}

class ElicitationFormCard extends StatefulWidget {
  const ElicitationFormCard(
    this.entry, {
    super.key,
    this.agentName,
    this.initialValues,
    this.showValidationInitially = false,
    this.onAnswer,
  });

  final ElicitationEntry entry;
  final String? agentName;

  /// 覆盖 schema 的 default（gallery 的校验态用）。
  final JsonMap? initialValues;
  final bool showValidationInitially;

  /// action ∈ accept / decline / cancel；accept 带 content。
  final void Function(String action, JsonMap? content)? onAnswer;

  @override
  State<ElicitationFormCard> createState() => _ElicitationFormCardState();
}

class _ElicitationFormCardState extends State<ElicitationFormCard> {
  late final List<_ElicitationField> _fields = _ElicitationField.parse(widget.entry.wire.requestedSchema).where((f) => f.isSupported).toList();
  late final Map<String, Object?> _values = <String, Object?>{
    for (final f in _fields) f.name: f.defaultValue,
    ...?widget.initialValues,
  };
  final Map<String, TextEditingController> _controllers = <String, TextEditingController>{};
  final Map<String, FocusNode> _focus = <String, FocusNode>{};
  late bool _showValidation = widget.showValidationInitially;

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    for (final f in _focus.values) {
      f.dispose();
    }
    super.dispose();
  }

  bool _missing(_ElicitationField f) {
    if (!f.required) return false;
    final v = _values[f.name];
    if (v == null) return true;
    if (v is String) return v.isEmpty;
    if (v is List) return v.isEmpty;
    return false;
  }

  List<_ElicitationField> get _missingFields => _fields.where(_missing).toList();

  JsonMap _content() => <String, dynamic>{
        for (final f in _fields)
          if (_values[f.name] != null) f.name: _values[f.name],
      };

  void _submit() {
    if (_missingFields.isNotEmpty) {
      setState(() => _showValidation = true);
      return;
    }
    widget.onAnswer?.call('accept', _content());
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final who = widget.agentName ?? e.agentId ?? 'agent';
    final missing = _missingFields;
    final answered = e.status != PendingStatus.pending;
    final valid = missing.isEmpty;
    return TranscriptCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CardHeader(
            leading: AcpIcon(AcpIcons.info, color: t.Accent.base),
            title: 'Input Requested by $who',
            titleStyle: CardText.cardTitle,
            trailing: <Widget>[Text(answered ? _statusLabel(e) : 'Waiting for input', style: CardText.secondary)],
            height: t.Controls.input + t.Spacing.s8,
          ),
          CardBody(
            padding: const EdgeInsets.all(t.Spacing.s12),
            children: <Widget>[
              if (e.wire.message != null) Text(e.wire.message!, style: t.TextStyles.body),
              for (final f in _fields) _field(f, showRequired: _showValidation && _missing(f)),
              if (_showValidation && missing.isNotEmpty)
                Container(
                  decoration: BoxDecoration(color: t.Semantic.errorSoft, borderRadius: t.Radii.control),
                  padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12, vertical: t.Spacing.s8),
                  child: Text('有 ${missing.length} 个必填字段未填：${missing.map((f) => f.title).join('、')}', style: t.TextStyles.secondary.copyWith(color: t.Semantic.error)),
                ),
            ],
          ),
          Container(
            decoration: BoxDecoration(border: Border(top: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
            padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12, vertical: t.Spacing.s8),
            child: Row(
              children: <Widget>[
                AcpButton(label: 'Submit', kind: ButtonKind.primary, icon: AcpIcons.check, enabled: !answered && (valid || !_showValidation), onTap: _submit),
                const SizedBox(width: t.Spacing.s8),
                AcpButton(label: 'Decline', icon: AcpIcons.x, iconColor: t.Semantic.error, labelColor: t.Semantic.error, enabled: !answered, onTap: () => widget.onAnswer?.call('decline', null)),
                const SizedBox(width: t.Spacing.s4),
                AcpButton(label: 'Cancel', enabled: !answered, onTap: () => widget.onAnswer?.call('cancel', null)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _statusLabel(ElicitationEntry e) => switch (e.status) {
        PendingStatus.answered => '已${e.action == 'accept' ? '提交' : (e.action == 'decline' ? '拒绝' : '取消')}',
        PendingStatus.withdrawn => 'agent 已不再等待',
        PendingStatus.cancelled => '已取消',
        PendingStatus.completed => 'Completed',
        PendingStatus.pending => 'Waiting for input',
      };

  Widget _label(_ElicitationField f, {required bool showRequired}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        Text(f.title, style: CardText.strong),
        const SizedBox(width: t.Spacing.s8),
        Text(f.meta, style: t.TextStyles.monoMeta),
        if (showRequired) ...<Widget>[
          const SizedBox(width: t.Spacing.s8),
          Text('必填', style: t.TextStyles.meta.copyWith(color: t.Semantic.error)),
        ],
      ],
    );
  }

  Widget _field(_ElicitationField f, {required bool showRequired}) {
    final children = <Widget>[_label(f, showRequired: showRequired)];
    if (f.description != null) {
      children.add(Padding(padding: const EdgeInsets.only(top: t.Spacing.s4), child: Text(f.description!, style: t.TextStyles.secondary)));
    }
    children.add(const SizedBox(height: t.Spacing.s8));
    final choices = f.choices;
    final multi = f.multiChoices;
    if (choices != null) {
      final selected = _values[f.name];
      children.add(_optionList(<Widget>[
        for (final (value, title) in choices)
          _OptionRow(
            selected: selected == value,
            control: _Radio(selected: selected == value),
            title: title,
            recommended: f.defaultValue == value,
            onTap: () => setState(() => _values[f.name] = value),
          ),
      ]));
    } else if (multi != null) {
      final selected = (_values[f.name] as List?)?.map((e) => e.toString()).toSet() ?? <String>{};
      children.add(_optionList(<Widget>[
        for (final (value, title) in multi)
          // 画板 27：多选的 default 只预勾选（initialValues 已带），不打 Recommended 标签，单选才打。
          _OptionRow(
            selected: selected.contains(value),
            control: _Check(selected: selected.contains(value)),
            title: title,
            onTap: () => setState(() {
              final next = Set<String>.of(selected);
              if (!next.remove(value)) next.add(value);
              _values[f.name] = next.toList();
            }),
          ),
      ]));
    } else if (f.type == 'boolean') {
      final on = _values[f.name] == true;
      children.add(GestureDetector(
        onTap: () => setState(() => _values[f.name] = !on),
        child: Row(
          children: <Widget>[
            _Toggle(on: on),
            const SizedBox(width: t.Spacing.s8),
            Text(on ? '开启' : '关闭', style: t.TextStyles.body),
          ],
        ),
      ));
    } else {
      children.add(_textInput(f, error: showRequired));
    }
    return Padding(
      padding: const EdgeInsets.only(top: t.Spacing.s4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: children),
    );
  }

  Widget _optionList(List<Widget> rows) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (var i = 0; i < rows.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: t.Spacing.s4),
            rows[i],
          ],
        ],
      );

  Widget _textInput(_ElicitationField f, {required bool error}) {
    final v = _values[f.name];
    final controller = _controllers.putIfAbsent(f.name, () => TextEditingController(text: v == null ? '' : v.toString()));
    final focus = _focus.putIfAbsent(f.name, FocusNode.new);
    final numeric = f.type == 'integer' || f.type == 'number';
    return Container(
      height: t.Controls.input,
      decoration: BoxDecoration(
        color: t.Neutral.panel,
        borderRadius: t.Radii.control,
        border: error ? Border.all(color: t.Semantic.error, width: t.Borders.width) : null,
      ),
      padding: t.Controls.padInput,
      alignment: Alignment.centerLeft,
      child: Stack(
        alignment: Alignment.centerLeft,
        children: <Widget>[
          if (controller.text.isEmpty) Text(error ? '必填' : '', style: t.TextStyles.body.copyWith(color: error ? t.Semantic.error : t.Neutral.placeholder)),
          EditableText(
            controller: controller,
            focusNode: focus,
            style: t.TextStyles.body,
            cursorColor: t.Accent.base,
            backgroundCursorColor: t.Neutral.surface,
            onChanged: (text) => setState(() {
              if (text.isEmpty) {
                _values[f.name] = null;
              } else if (numeric) {
                _values[f.name] = f.type == 'integer' ? int.tryParse(text) : num.tryParse(text);
              } else {
                _values[f.name] = text;
              }
            }),
          ),
        ],
      ),
    );
  }
}

/// 选项行：panel 底（选中 surface）· radius 4 · 28 高。
class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.selected, required this.control, required this.title, required this.onTap, this.recommended = false});

  final bool selected;
  final Widget control;
  final String title;
  final VoidCallback onTap;
  final bool recommended;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: t.Controls.standard,
        padding: t.Controls.padStandard,
        decoration: BoxDecoration(color: selected ? t.Neutral.surface : null, borderRadius: t.Radii.control),
        child: Row(
          children: <Widget>[
            control,
            const SizedBox(width: t.Spacing.s8),
            Text(title, style: t.TextStyles.body),
            if (recommended) ...<Widget>[
              const SizedBox(width: t.Spacing.s8),
              ToneChip('Recommended', tone: ChipTone.accent),
            ],
          ],
        ),
      ),
    );
  }
}

class _Radio extends StatelessWidget {
  const _Radio({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: t.IconSizes.toolbar,
      height: t.IconSizes.toolbar,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? t.Accent.base : t.Surface.popover,
        border: Border.all(color: selected ? t.Accent.base : t.Borders.base, width: t.Borders.width),
      ),
      alignment: Alignment.center,
      child: selected
          ? Container(width: t.Spacing.s4, height: t.Spacing.s4, decoration: BoxDecoration(shape: BoxShape.circle, color: t.Accent.onAccent))
          : null,
    );
  }
}

class _Check extends StatelessWidget {
  const _Check({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: t.IconSizes.toolbar,
      height: t.IconSizes.toolbar,
      decoration: BoxDecoration(
        color: selected ? t.Accent.base : t.Surface.popover,
        border: Border.all(color: selected ? t.Accent.base : t.Borders.base, width: t.Borders.width),
        borderRadius: t.Radii.chip,
      ),
      alignment: Alignment.center,
      child: selected ? AcpIcon(AcpIcons.check, color: t.Accent.onAccent, size: t.IconSizes.toolbar, strokeWidth: t.IconSizes.stroke * 2) : null,
    );
  }
}

/// 布尔开关：轨道 28×16（radius.pill = 轨道高度一半），开 = accent。
class _Toggle extends StatelessWidget {
  const _Toggle({required this.on});

  final bool on;

  static const double _trackHeight = t.Geometry.toggleTrackHeight;
  static const double _trackWidth = t.Geometry.toggleTrackWidth;
  static const double _inset = t.Geometry.toggleKnobInset;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _trackWidth,
      height: _trackHeight,
      padding: const EdgeInsets.all(_inset),
      decoration: BoxDecoration(color: on ? t.Accent.base : t.Neutral.border, borderRadius: t.Radii.pill(_trackHeight)),
      alignment: on ? Alignment.centerRight : Alignment.centerLeft,
      child: AspectRatio(
        aspectRatio: 1,
        child: Container(decoration: BoxDecoration(shape: BoxShape.circle, color: t.Accent.onAccent)),
      ),
    );
  }
}
