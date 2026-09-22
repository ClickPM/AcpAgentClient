// 界面上共用的数值格式化。此前 registry 面板 / 文件面板 / 内容块各写了一份 `formatBytes`，
// 三份口径还不一样（文件面板那份封顶 MB，1 GB 的文件会显示成「1024.0 MB」），收成这一份。

/// 字节数 → 「512 B」「13.1 KB」「4.1 MB」「1.2 GB」；null → 空串（内容块的 `size` 是可选字段）。
String formatBytes(num? bytes, {int digits = 1}) {
  if (bytes == null) return '';
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(digits)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(digits)} MB';
  return '${(mb / 1024).toStringAsFixed(digits)} GB';
}
