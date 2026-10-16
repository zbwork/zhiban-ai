/// Active human/group chat panes register their unsaved composer/send state.
/// Cache clearing checks the registry before resetting the session scope.
class HumanChatDraftGuard {
  HumanChatDraftGuard._();

  static final Set<bool Function()> _readers = {};

  static bool get hasUncommitted => _readers.any((read) => read());

  static void register(bool Function() read) => _readers.add(read);

  static void unregister(bool Function() read) => _readers.remove(read);
}

bool get hasUncommittedHumanChatDrafts => HumanChatDraftGuard.hasUncommitted;
