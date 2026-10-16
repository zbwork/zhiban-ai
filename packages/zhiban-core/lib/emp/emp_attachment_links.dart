/// Pure display normalization shared by split chat text and EMP block lists.
final RegExp _messageFileMarkdownLink = RegExp(
  r'!?\[([^\]\n]+)\]\(<?([^\s)>]*?/message-files/([0-9a-fA-F-]+)/(?:preview|download)(?:\?[^)>\s]*)?)>?\)',
);
final RegExp _sandboxFileMarkdownLink =
    RegExp(r'!?\[([^\]\n]+)\]\(<?sandbox:/mnt/data/([^\s)>/]+)>?\)');

/// A canonical EMP file/image block is the single attachment UI. Historical
/// Hermes messages may also contain a Markdown link to the same file; hide
/// only that duplicate link while leaving unrelated prose and links intact.
List<Map<String, dynamic>> suppressDuplicateAttachmentLinks(
  List<Map<String, dynamic>> blocks,
) {
  final attachmentIds = <String>{};
  final localNames = <String>{};
  for (final block in blocks) {
    final type = _asString(block['type']).toLowerCase();
    if (type != 'file' && type != 'image' && type != 'video') continue;
    if (block['local_artifact'] is Map) {
      final name = _firstNonEmpty([
        _asString(block['name']),
        _asString(block['filename']),
        _asString(block['file_name']),
      ]);
      if (name.isNotEmpty) localNames.add(name);
    }
    final id = _firstNonEmpty([
      _asString(block['file_id']),
      _asString(block['file_uuid']),
    ]);
    if (id.isNotEmpty) attachmentIds.add(id.toLowerCase());
  }
  if (attachmentIds.isEmpty && localNames.isEmpty) return blocks;

  return blocks.map((block) {
    final type = _asString(block['type']).toLowerCase();
    if (type != 'markdown' && type != 'plain' && type != 'text') {
      return block;
    }
    final key = block.containsKey('text') ? 'text' : 'markdown';
    final original = _asString(block[key]);
    if (original.isEmpty) return block;
    final lines = original.split('\n').map((line) {
      bool isLocalDuplicate(Match match) {
        return localNames.contains(_safeDecodeComponent(match.group(2)!));
      }

      final localMatches = _sandboxFileMarkdownLink.allMatches(line).toList();
      if (localMatches.length == 1 &&
          localMatches.single.group(0) == line.trim() &&
          isLocalDuplicate(localMatches.single)) {
        return '';
      }
      line = line.replaceAllMapped(
          _sandboxFileMarkdownLink,
          (match) =>
              isLocalDuplicate(match) ? match.group(1)! : match.group(0)!);
      final matches = _messageFileMarkdownLink.allMatches(line).toList();
      if (matches.length == 1 &&
          matches.single.group(0) == line.trim() &&
          attachmentIds.contains(matches.single.group(3)!.toLowerCase())) {
        return '';
      }
      return line.replaceAllMapped(_messageFileMarkdownLink, (match) {
        final id = match.group(3)?.toLowerCase() ?? '';
        return attachmentIds.contains(id)
            ? (match.group(1) ?? '')
            : match.group(0)!;
      });
    }).join('\n');
    final normalized =
        lines.replaceAll(RegExp(r'\n[ \t]*\n[ \t]*\n+'), '\n\n').trim();
    if (normalized == original) return block;
    return <String, dynamic>{...block, key: normalized};
  }).toList(growable: false);
}

String _asString(Object? value) => value is String ? value : '';
String _firstNonEmpty(List<String> values) =>
    values.firstWhere((value) => value.isNotEmpty, orElse: () => '');

String _safeDecodeComponent(String value) {
  try {
    return Uri.decodeComponent(value);
  } on FormatException catch (_) {
    // Model-generated sandbox links occasionally contain a literal `%` in a
    // filename. Preserve valid escapes and make only the malformed marker
    // decodable so duplicate suppression cannot break message rendering.
    final repaired =
        value.replaceAllMapped(RegExp(r'%(?![0-9A-Fa-f]{2})'), (_) => '%25');
    try {
      return Uri.decodeComponent(repaired);
    } on FormatException catch (_) {
      return value;
    }
  } on ArgumentError {
    final repaired =
        value.replaceAllMapped(RegExp(r'%(?![0-9A-Fa-f]{2})'), (_) => '%25');
    try {
      return Uri.decodeComponent(repaired);
    } on FormatException catch (_) {
      return value;
    } on ArgumentError {
      return value;
    }
  }
}
