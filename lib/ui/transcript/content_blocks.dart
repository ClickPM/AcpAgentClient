// 画板 32 · 非文本内容块：image（内嵌 base64 预览）、audio（播放条，audioplayers 内存 BytesSource）、
// resource_link（文件卡）、embedded resource text（内嵌展示）、embedded resource blob（不可渲染的兜底文件卡）。
// 输出方向没有能力门，五种块在消息 / 思考 / 工具卡内容里都可能出现，都要能显示。

import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/widgets.dart';

import '../../projection/wire.dart';
import '../../theme/tokens.dart' as t;
import 'card_chrome.dart';
import 'code_block.dart';
import 'icons.dart';
import 'markdown_body.dart';

/// 字节数 → 「17.5 KB」「4.1 MB」。
String formatBytes(num? bytes) {
  if (bytes == null) return '';
  if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '$bytes B';
}

String _nameOf(String? uri, {String? fallback}) {
  if (uri == null || uri.isEmpty) return fallback ?? '';
  final u = Uri.tryParse(uri);
  final segs = u?.pathSegments ?? const <String>[];
  if (segs.isNotEmpty && segs.last.isNotEmpty) return segs.last;
  return fallback ?? uri;
}

int? _base64Length(String? data) {
  if (data == null) return null;
  final padding = data.endsWith('==') ? 2 : (data.endsWith('=') ? 1 : 0);
  return (data.length * 3 ~/ 4) - padding;
}

/// 按块类型分发。`onOpen` 是 R4 的文件面板定位 / 系统打开回调，本轮只占位。
class ContentBlockView extends StatelessWidget {
  const ContentBlockView(this.block, {super.key, this.onOpen, this.audioPreview});

  final ContentBlockWire block;
  final void Function(String uri)? onOpen;

  /// gallery 用：不起播放器就显示某个进度。
  final AudioPreview? audioPreview;

  @override
  Widget build(BuildContext context) {
    switch (block.type) {
      case ContentBlockType.text:
        return MarkdownBody(block.text ?? '');
      case ContentBlockType.image:
        return ImageBlock(block: block, onOpen: onOpen);
      case ContentBlockType.audio:
        return AudioBlock(block: block, preview: audioPreview);
      case ContentBlockType.resourceLink:
        return ResourceLinkBlock(block: block, onOpen: onOpen);
      case ContentBlockType.resource:
        final r = block.resource;
        if (r != null && r.isText) return EmbeddedTextBlock(block: block);
        return BlobBlock(block: block, onOpen: onOpen);
      case ContentBlockType.unknown:
        return BlobBlock(block: block, onOpen: onOpen);
    }
  }
}

/// image：surface 底的预览区 + 元信息行（mimeType · 大小 · uri）。
class ImageBlock extends StatelessWidget {
  const ImageBlock({super.key, required this.block, this.onOpen});

  final ContentBlockWire block;
  final void Function(String uri)? onOpen;

  @override
  Widget build(BuildContext context) {
    Uint8List? bytes;
    try {
      bytes = block.data == null ? null : base64Decode(block.data!);
    } on FormatException {
      bytes = null;
    }
    final mime = block.mimeType ?? 'image';
    final size = formatBytes(bytes?.length ?? _base64Length(block.data));
    final uri = block.uri;
    return TranscriptCard(
      child: Padding(
        padding: const EdgeInsets.all(t.Spacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            GestureDetector(
              onTap: uri == null ? null : () => onOpen?.call(uri),
              child: Container(
                height: t.Geometry.imagePreviewHeight,
                decoration: const BoxDecoration(color: t.Neutral.surface, borderRadius: t.Radii.control),
                clipBehavior: Clip.antiAlias,
                alignment: Alignment.center,
                child: bytes == null
                    ? Text('image · $mime · 无法解码', style: t.TextStyles.monoMeta)
                    : Image.memory(
                        bytes,
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) => Text('image · $mime · 无法解码', style: t.TextStyles.monoMeta),
                      ),
              ),
            ),
            const SizedBox(height: t.Spacing.s8),
            Text.rich(
              TextSpan(children: <InlineSpan>[
                TextSpan(text: '$mime · $size'),
                if (uri != null) TextSpan(text: '   uri: $uri'),
              ]),
              style: t.TextStyles.monoMeta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// gallery / 测试用的静态进度。
class AudioPreview {
  const AudioPreview({required this.position, required this.duration, this.playing = false});

  final Duration position;
  final Duration duration;
  final bool playing;
}

/// audio：播放 / 暂停 + 进度条 + 「0:14 / 0:37 · audio/wav · 592 KB」。播放器只在第一次点击时创建（内存 BytesSource）。
class AudioBlock extends StatefulWidget {
  const AudioBlock({super.key, required this.block, this.preview});

  final ContentBlockWire block;
  final AudioPreview? preview;

  @override
  State<AudioBlock> createState() => _AudioBlockState();
}

class _AudioBlockState extends State<AudioBlock> {
  AudioPlayer? _player;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration? _duration;

  /// 进度条厚度（几何，不是 token）。

  @override
  void initState() {
    super.initState();
    final p = widget.preview;
    if (p != null) {
      _position = p.position;
      _duration = p.duration;
      _playing = p.playing;
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (widget.preview != null && _player == null) {
      // 静态预览态：只切换图标，不起播放器。
      setState(() => _playing = !_playing);
      return;
    }
    final data = widget.block.data;
    if (data == null) return;
    if (_player == null) {
      final player = AudioPlayer();
      player.onDurationChanged.listen((d) => mounted ? setState(() => _duration = d) : null);
      player.onPositionChanged.listen((p) => mounted ? setState(() => _position = p) : null);
      player.onPlayerComplete.listen((_) => mounted ? setState(() => _playing = false) : null);
      _player = player;
      await player.play(BytesSource(base64Decode(data), mimeType: widget.block.mimeType));
      if (mounted) setState(() => _playing = true);
      return;
    }
    if (_playing) {
      await _player!.pause();
    } else {
      await _player!.resume();
    }
    if (mounted) setState(() => _playing = !_playing);
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final total = _duration;
    final fraction = total == null || total.inMilliseconds == 0 ? 0.0 : (_position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    final size = formatBytes(_base64Length(widget.block.data));
    final mime = widget.block.mimeType ?? 'audio';
    return TranscriptCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12, vertical: t.Spacing.s8),
        child: Row(
          children: <Widget>[
            _PlayButton(playing: _playing, onTap: _toggle),
            const SizedBox(width: t.Spacing.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  ClipRRect(
                    borderRadius: t.Radii.chip,
                    child: SizedBox(
                      height: t.Geometry.audioBarHeight,
                      child: Stack(
                        children: <Widget>[
                          const Positioned.fill(child: ColoredBox(color: t.Borders.subtle)),
                          FractionallySizedBox(widthFactor: fraction, child: const ColoredBox(color: t.Accent.base)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: t.Spacing.s4),
                  Text('${_fmt(_position)} / ${total == null ? '--:--' : _fmt(total)} · $mime · $size', style: t.TextStyles.monoMeta),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.playing, required this.onTap});

  final bool playing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: t.Controls.standard,
        height: t.Controls.standard,
        decoration: BoxDecoration(
          color: t.Surface.popover,
          border: Border.all(color: t.Borders.subtle, width: t.Borders.width),
          borderRadius: t.Radii.control,
        ),
        alignment: Alignment.center,
        child: playing
            ? Container(
                width: t.Spacing.s8,
                height: t.Spacing.s8,
                decoration: const BoxDecoration(color: t.Neutral.muted, borderRadius: t.Radii.chip),
              )
            : const AcpIcon(AcpIcons.play, color: t.Neutral.muted, size: t.IconSizes.toolbar),
      ),
    );
  }
}

/// 图标方块（28 · surface 底 · radius 4）。
class _IconBox extends StatelessWidget {
  const _IconBox(this.icon);

  final String icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: t.Controls.standard,
      height: t.Controls.standard,
      decoration: const BoxDecoration(color: t.Neutral.surface, borderRadius: t.Radii.control),
      alignment: Alignment.center,
      child: AcpIcon(icon, color: t.Neutral.muted, size: t.IconSizes.toolbar),
    );
  }
}

/// 文件卡的通用行：图标方块 + 名称 + 元信息 + 右侧动作。
class _FileRow extends StatelessWidget {
  const _FileRow({required this.icon, required this.name, required this.meta, required this.action, this.onAction});

  final String icon;
  final String name;
  final String meta;
  final String action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return TranscriptCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12, vertical: t.Spacing.s8),
        child: Row(
          children: <Widget>[
            _IconBox(icon),
            const SizedBox(width: t.Spacing.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(name, style: CardText.strong, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(meta, style: t.TextStyles.monoMeta, maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            const SizedBox(width: t.Spacing.s12),
            AcpButton(label: action, kind: ButtonKind.outline, height: t.Controls.compact, onTap: onAction),
          ],
        ),
      ),
    );
  }
}

/// resource_link：名称 + mimeType · 大小 · uri + 「在文件面板打开」。
class ResourceLinkBlock extends StatelessWidget {
  const ResourceLinkBlock({super.key, required this.block, this.onOpen});

  final ContentBlockWire block;
  final void Function(String uri)? onOpen;

  @override
  Widget build(BuildContext context) {
    final uri = block.uri ?? '';
    final name = block.name ?? block.title ?? _nameOf(uri);
    final parts = <String>[
      if (block.mimeType != null) block.mimeType!,
      if (block.size != null) formatBytes(block.size),
      if (uri.isNotEmpty) uri,
    ];
    return _FileRow(icon: AcpIcons.link, name: name, meta: parts.join(' · '), action: '在文件面板打开', onAction: uri.isEmpty ? null : () => onOpen?.call(uri));
  }
}

/// embedded resource · text：头行「resource · text · 文件名」+ 等宽块（按 mimeType 选 json 高亮）。
class EmbeddedTextBlock extends StatelessWidget {
  const EmbeddedTextBlock({super.key, required this.block});

  final ContentBlockWire block;

  @override
  Widget build(BuildContext context) {
    final r = block.resource!;
    final name = _nameOf(r.uri);
    final mime = r.mimeType ?? '';
    final lang = mime.contains('json')
        ? 'json'
        : mime.contains('javascript')
            ? 'javascript'
            : mime.contains('markdown')
                ? 'markdown'
                : null;
    return TranscriptCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            height: t.Controls.standard,
            child: Padding(
              padding: t.Controls.padStandard,
              child: Row(
                children: <Widget>[
                  const AcpIcon(AcpIcons.file, color: t.Neutral.muted, size: t.IconSizes.toolbar),
                  const SizedBox(width: t.Spacing.s8),
                  Expanded(child: Text('resource · text · $name', style: t.TextStyles.monoMeta, maxLines: 1, overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: t.Spacing.s8, right: t.Spacing.s8, bottom: t.Spacing.s8),
            child: MonoBlock(span: highlightCode(r.text ?? '', lang)),
          ),
        ],
      ),
    );
  }
}

/// embedded resource · blob（以及未知块）：不可渲染，兜底文件卡 + 「保存到本地」。
class BlobBlock extends StatelessWidget {
  const BlobBlock({super.key, required this.block, this.onOpen});

  final ContentBlockWire block;
  final void Function(String uri)? onOpen;

  @override
  Widget build(BuildContext context) {
    final r = block.resource;
    final uri = r?.uri ?? block.uri ?? '';
    final name = _nameOf(uri, fallback: block.rawType ?? 'resource');
    final size = formatBytes(_base64Length(r?.blob ?? block.data));
    final parts = <String>[
      'resource',
      r == null ? (block.rawType ?? 'unknown') : 'blob',
      if ((r?.mimeType ?? block.mimeType) != null) (r?.mimeType ?? block.mimeType)!,
      if (size.isNotEmpty) size,
      '不可渲染，仅给文件卡',
    ];
    return _FileRow(icon: AcpIcons.file, name: name, meta: parts.join(' · '), action: '保存到本地', onAction: uri.isEmpty ? null : () => onOpen?.call(uri));
  }
}
