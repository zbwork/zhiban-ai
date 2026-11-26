const _maxCaptionBytes = 2 * 1024 * 1024;
const maxCreatorSubtitleBytes = _maxCaptionBytes;

typedef CreatorSubtitle = ({int startMs, int endMs, String text});

final _timing = RegExp(
  r'^((?:\d{1,4}:)?\d{2}:\d{2}[.,]\d{3})[ \t]+-->[ \t]+'
  r'((?:\d{1,4}:)?\d{2}:\d{2}[.,]\d{3})(?:[ \t]+.*)?$',
);

List<CreatorSubtitle> parseCreatorSubtitles(String source) {
  final normalized = source
      .replaceFirst('\uFEFF', '')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .trim();
  final segments = <CreatorSubtitle>[];
  for (final block in normalized.split(RegExp(r'\n[ \t]*\n+'))) {
    final lines = block.split('\n');
    if (lines.first == 'WEBVTT' ||
        lines.first.startsWith('WEBVTT ') ||
        RegExp(r'^(NOTE(?:[ \t]|$)|STYLE$|REGION$)').hasMatch(lines.first)) {
      continue;
    }
    final index = lines.indexWhere((line) => _timing.hasMatch(line.trim()));
    if (index == -1 || index > 1) throw const FormatException('字幕时间码格式不正确。');
    final match = _timing.firstMatch(lines[index].trim())!;
    final start = _timestamp(match.group(1)!);
    final end = _timestamp(match.group(2)!);
    final content = lines.skip(index + 1).join('\n').trim();
    if (end <= start || content.isEmpty || content.length > 10000) {
      throw const FormatException('字幕片段缺少有效时间范围或文字。');
    }
    segments.add((startMs: start, endMs: end, text: content));
  }
  if (segments.isEmpty) throw const FormatException('字幕文件没有可用的片段。');
  return segments..sort((a, b) => a.startMs.compareTo(b.startMs));
}

int _timestamp(String value) {
  final fields = value.split(RegExp(r'[:.,]')).map(int.parse).toList();
  final seconds = fields[fields.length - 2];
  final minutes = fields[fields.length - 3];
  final hours = fields.length == 4 ? fields.first : 0;
  if (minutes > 59 || seconds > 59) throw const FormatException('字幕时间码超出范围。');
  return ((hours * 60 + minutes) * 60 + seconds) * 1000 + fields.last;
}

String creatorTimecode(int milliseconds) {
  final duration = Duration(milliseconds: milliseconds);
  String two(int value) => value.toString().padLeft(2, '0');
  final fraction =
      duration.inMilliseconds.remainder(1000).toString().padLeft(3, '0');
  return '${two(duration.inHours)}:${two(duration.inMinutes.remainder(60))}:'
      '${two(duration.inSeconds.remainder(60))}.$fraction';
}

String creatorEvidenceLocation(Map source) {
  if (source['image_number'] case final int image) return '第 $image 张图片';
  if (source['paragraph_number'] case final int paragraph) {
    return '正文第 $paragraph 段';
  }
  final start = source['start_ms'] as int?;
  final end = source['end_ms'] as int?;
  if (start == null || end == null) return '原作品';
  return '${creatorTimecode(start)} – ${creatorTimecode(end)}';
}

List<String> creatorArticleParagraphs(Map metadata) =>
    (metadata['article_body'] as String? ?? '')
        .split(RegExp(r'\r\n|\n|\r'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

List<({int index, String label, String text})> creatorArticleSignals(
    List<String> paragraphs) {
  final heading = RegExp(r'^([^：:。！？,，]{1,18})[：:]\s*(\S.*)$');
  return [
    for (final (index, paragraph) in paragraphs.indexed)
      if (heading.firstMatch(paragraph) case final match?)
        (index: index, label: match.group(1)!.trim(), text: match.group(2)!),
  ].take(3).toList();
}

Iterable<({int index, String text})> creatorImageTexts(Map metadata) sync* {
  final images = metadata['images'];
  final recognized = metadata['image_ocr'];
  if (images is! List || recognized is! Map) return;
  for (final (index, image) in images.indexed) {
    final entry = recognized['$index'];
    if (entry is Map && entry['image'] == image && entry['text'] is String) {
      final text = (entry['text'] as String).trim();
      if (text.isNotEmpty) yield (index: index, text: text);
    }
  }
}
