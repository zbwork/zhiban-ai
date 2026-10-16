import 'package:zhiban_core/chat/chat_models.dart';

/// One stable platform order for the picker, filters and initial selection.
List<LlmModelOption> orderConversationModels(Iterable<LlmModelOption> models) {
  final groups = <String, List<LlmModelOption>>{};
  for (final model in models) {
    final key = model.providerId.isNotEmpty
        ? model.providerId
        : model.providerName.trim().toLowerCase();
    groups.putIfAbsent(key, () => []).add(model);
  }
  bool isBeeBridge(List<LlmModelOption> group) => group.any((model) {
        final name = model.providerName.trim().toLowerCase();
        return model.providerId.toLowerCase() == 'beebridge' ||
            name == 'beebridge' ||
            name == '蜂桥';
      });
  List<LlmModelOption> byName(List<LlmModelOption> group) {
    final entries = group.asMap().entries.toList()
      ..sort((a, b) {
        final nameOrder = a.value.label
            .trim()
            .toLowerCase()
            .compareTo(b.value.label.trim().toLowerCase());
        return nameOrder != 0 ? nameOrder : a.key.compareTo(b.key);
      });
    return entries.map((entry) => entry.value).toList();
  }

  return [
    for (final group in groups.values.where(isBeeBridge)) ...byName(group),
    for (final group in groups.values.where((group) => !isBeeBridge(group)))
      ...byName(group),
  ];
}
