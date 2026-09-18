// 输入框顶部的附件芯片条（所有者 2026-09-18 直接要求，对齐 Zed 的交互；设计稿里没有这一条，
// 规则 3 的「先改设计稿」这次由所有者当场裁定跳过，补稿记在 rounds/BACKLOG.md）：
// 待随下一条 prompt 发出的 ACP `image` 块一块一枚芯片，鼠标悬浮在芯片上浮出原图预览，芯片上的 × 去掉它。
// 芯片不另存一份状态：显示的就是 `pendingBlocks` 里那几个 `image` 块本身（规则 2）。

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../projection/wire.dart';
import '../../theme/tokens.dart' as t;
import '../transcript/card_chrome.dart';
import '../transcript/content_blocks.dart' show formatBytes;
import '../transcript/icons.dart';
import 'motion.dart';
import 'shell_common.dart';

/// 一行（放不下就折行）芯片。空列表由调用方判断，这里不做 0 高的占位。
class ComposerAttachments extends StatelessWidget {
  const ComposerAttachments({super.key, required this.blocks, this.onRemove, this.previewIndex});

  final List<ContentBlockWire> blocks;
  final ValueChanged<ContentBlockWire>? onRemove;

  /// gallery / 用例：强制把第 n 枚芯片的预览挂出来（真实交互里由悬浮驱动）。
  final int? previewIndex;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: t.Spacing.s4,
        runSpacing: t.Spacing.s4,
        children: <Widget>[
          for (var i = 0; i < blocks.length; i++)
            AttachmentChip(
              block: blocks[i],
              onRemove: onRemove == null ? null : () => onRemove!(blocks[i]),
              previewOpen: previewIndex == i,
            ),
        ],
      ),
    );
  }
}

/// 一枚附件芯片：图标 + 名字 + 大小，悬浮时浮出预览、亮出 ×。
class AttachmentChip extends StatefulWidget {
  const AttachmentChip({super.key, required this.block, this.onRemove, this.previewOpen = false});

  final ContentBlockWire block;
  final VoidCallback? onRemove;
  final bool previewOpen;

  @override
  State<AttachmentChip> createState() => _AttachmentChipState();
}

class _AttachmentChipState extends State<AttachmentChip> {
  final LayerLink _link = LayerLink();
  final OverlayPortalController _preview = OverlayPortalController();
  bool _hover = false;

  /// base64 只解一次：组合根每次 `_touch()` 都会重建这枚芯片，每帧解一张几百 KB 的图既费 CPU
  /// 又会让 `Image.memory` 换掉字节对象、预览闪一下。
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _decode();
    if (widget.previewOpen) _sync(true);
  }

  @override
  void didUpdateWidget(AttachmentChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.block.data != widget.block.data) _decode();
    if (oldWidget.previewOpen != widget.previewOpen) _sync(_hover || widget.previewOpen);
  }

  void _decode() {
    final data = widget.block.data;
    try {
      _bytes = data == null ? null : base64Decode(data);
    } on FormatException {
      _bytes = null;
    }
  }

  /// 没解出字节就不挂预览（芯片仍在，删得掉）。
  void _sync(bool show) {
    final want = show && _bytes != null;
    if (want == _preview.isShowing) return;
    if (want) {
      _preview.show();
    } else {
      _preview.hide();
    }
  }

  void _setHover(bool hover) {
    setState(() => _hover = hover);
    _sync(hover || widget.previewOpen);
  }

  /// 有 `uri`（从文件选的 / 从资源管理器复制的）就显示文件名，截图这类没有来源的显示 `Image`。
  String get _label {
    final uri = widget.block.uri;
    if (uri == null || uri.isEmpty) return 'Image';
    final segments = Uri.tryParse(uri)?.pathSegments ?? const <String>[];
    final name = segments.isEmpty ? '' : segments.last;
    return name.isEmpty ? uri : name;
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _preview,
        // 预览只是给眼睛看的：不吃指针事件，否则它会盖住芯片自己的 MouseRegion，鼠标一停就开始闪。
        // 外面那层 `Stack` 是必须的：overlay child 拿到的是**收紧到整屏**的约束，直接挂
        // `CompositedTransformFollower` 的话里面的 `Align` 收不动，预览会被撑成整屏、按整屏的角算落点
        // （popover_anchor.dart 记的同一条教训）。`Stack` 的非定位子节点才拿得到松约束。
        overlayChildBuilder: (context) => IgnorePointer(
          child: Stack(
            children: <Widget>[
              CompositedTransformFollower(
                link: _link,
                targetAnchor: Alignment.topLeft,
                followerAnchor: Alignment.bottomLeft,
                offset: t.Geometry.popoverAbove,
                showWhenUnlinked: false,
                // widthFactor / heightFactor 见 popover_anchor.dart 的注释：不收紧约束的话
                // `followerAnchor` 算的是整屏的角，预览会飞到窗口顶上。
                child: Align(
                  alignment: Alignment.topLeft,
                  widthFactor: 1,
                  heightFactor: 1,
                  child: MotionEnter(epoch: null, distance: t.Motion.pop, duration: t.Motion.base, child: _previewCard()),
                ),
              ),
            ],
          ),
        ),
        child: MouseRegion(onEnter: (_) => _setHover(true), onExit: (_) => _setHover(false), child: _chip()),
      ),
    );
  }

  Widget _chip() {
    final size = _bytes == null ? '' : formatBytes(_bytes!.length);
    return Container(
      height: t.Controls.compact,
      padding: t.Controls.padCompact,
      decoration: const BoxDecoration(color: t.Accent.soft, borderRadius: t.Radii.chip),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const AcpIcon(AcpIcons.image, size: t.IconSizes.toolbar, color: t.Accent.text),
          const SizedBox(width: t.Spacing.s4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: t.Geometry.composerModelMaxWidth),
            child: Text(
              _label,
              style: t.TextStyles.mono.copyWith(color: t.Accent.text),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (size.isNotEmpty) ...<Widget>[const SizedBox(width: t.Spacing.s4), Text(size, style: t.TextStyles.monoMeta)],
          if (widget.onRemove != null) ...<Widget>[
            const SizedBox(width: t.Spacing.s4),
            // × 一直占位、只在悬浮时上色：不然芯片宽度会随鼠标进出跳动。
            Hoverable(
              onTap: () {
                _sync(false);
                widget.onRemove!.call();
              },
              builder: (context, hovered) => AcpIcon(
                AcpIcons.x,
                size: t.IconSizes.toolbar,
                color: _hover || widget.previewOpen ? (hovered ? t.Neutral.text : t.Accent.text) : t.Accent.soft,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _previewCard() {
    final bytes = _bytes;
    return Popover(
      padding: const EdgeInsets.all(t.Spacing.s4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: t.Geometry.attachmentPreviewMaxWidth, maxHeight: t.Geometry.attachmentPreviewMaxHeight),
        child: ClipRRect(
          borderRadius: t.Radii.control,
          child: bytes == null
              ? const Text('image · 无法解码', style: t.TextStyles.monoMeta)
              : Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Text('image · 无法解码', style: t.TextStyles.monoMeta),
                ),
        ),
      ),
    );
  }
}
