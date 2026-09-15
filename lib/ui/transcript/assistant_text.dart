// 画板 12 · 助手富文本正文：一条 agent 消息（MessageEntry）的全部内容块。连续 text 块拼成一段 Markdown（chunk 流是按
// 字符切的，不能逐块渲染），非文本块按画板 32 渲染。链接落右栏文件面板（R4 接 onLink），复选框只改本地呈现态。

import 'package:flutter/widgets.dart';

import '../../projection/entries.dart';
import '../../projection/wire.dart';
import '../../theme/tokens.dart' as t;
import 'content_blocks.dart';
import 'markdown_body.dart';

class AssistantText extends StatelessWidget {
  const AssistantText(this.entry, {super.key, this.onLink, this.mermaidFontFamily, this.audioPreview});

  final MessageEntry entry;
  final LinkCallback? onLink;
  final String? mermaidFontFamily;
  final AudioPreview? audioPreview;

  @override
  Widget build(BuildContext context) {
    // 把连续的 text 块合并成一段，其它块单独成项。
    final groups = <Object>[];
    final buf = StringBuffer();
    void flush() {
      if (buf.isNotEmpty) {
        groups.add(buf.toString());
        buf.clear();
      }
    }

    for (final b in entry.blocks) {
      if (b.type == ContentBlockType.text) {
        buf.write(b.text ?? '');
      } else {
        flush();
        groups.add(b);
      }
    }
    flush();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (var i = 0; i < groups.length; i++)
          Padding(
            padding: i == 0 ? EdgeInsets.zero : const EdgeInsets.only(top: t.Spacing.s8),
            child: groups[i] is String
                ? MarkdownBody(groups[i] as String, onLink: onLink, mermaidFontFamily: mermaidFontFamily)
                : ContentBlockView(groups[i] as ContentBlockWire, onOpen: onLink, audioPreview: audioPreview),
          ),
      ],
    );
  }
}
