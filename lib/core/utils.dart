import 'dart:math';

String formatBytes(dynamic bytes) {
  if (bytes == null) return "0 B";
  int b = (bytes is int) ? bytes : int.tryParse(bytes.toString()) ?? 0;
  if (b <= 0) return "0 B";
  const suffixes = ["B", "KB", "MB", "GB"];
  var i = (log(b) / log(1024)).floor();
  if (i >= suffixes.length) i = suffixes.length - 1;
  return ((b / pow(1024, i)).toStringAsFixed(2)) + suffixes[i];
}

String formatSpeed(dynamic bytes) {
  if (bytes == null) return "0 B/s";
  int b = (bytes is int) ? bytes : int.tryParse(bytes.toString()) ?? 0;
  if (b <= 0) return "0 B/s";
  const suffixes = ["B/s", "KB/s", "MB/s", "GB/s"];
  var i = (log(b) / log(1024)).floor();
  if (i >= suffixes.length) i = suffixes.length - 1;
  return "${(b / pow(1024, i)).toStringAsFixed(1)} ${suffixes[i]}";
}
