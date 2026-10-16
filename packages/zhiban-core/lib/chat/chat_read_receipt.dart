/// F09 P1 「消息级已读回执 v1」 客户端 model.
///
/// 见 docs/contracts/agent-bus-client-contract.md §「消息级已读回执 v1」。
///
/// 设计:
///   - 底层水位 = WuKong message_seq + per-account last_read_message_seq.
///   - 服务端聚合, 客户端只读不算.
///   - 与 ImMessage / ImSendStatus 完全独立 (不污染消息字段).
library;

class ChatReceiptMember {
  const ChatReceiptMember({
    required this.accountUuid,
    required this.displayName,
    required this.avatar,
    this.subtitle = '',
  });

  final String accountUuid;
  final String displayName;
  final String avatar;
  final String subtitle; // department name / role label, optional

  factory ChatReceiptMember.fromJson(Map<String, dynamic> j) {
    return ChatReceiptMember(
      accountUuid: (j['account_uuid'] ?? '').toString(),
      displayName: (j['display_name'] ?? '').toString(),
      avatar: (j['avatar'] ?? '').toString(),
      subtitle: (j['subtitle'] ?? '').toString(),
    );
  }
}

/// 单条消息的回执快照。`messageSeq <= 0` 不会出现(底层 hide indicator)。
class ChatReceiptSnapshot {
  const ChatReceiptSnapshot({
    required this.messageSeq,
    required this.readCount,
    required this.unreadCount,
    required this.allRead,
    required this.readMembers,
    required this.unreadMembers,
  });

  final int messageSeq;
  final int readCount;
  final int unreadCount;
  final bool allRead;
  final List<ChatReceiptMember> readMembers;
  final List<ChatReceiptMember> unreadMembers;

  bool get isEmpty => readCount == 0 && unreadCount == 0;

  factory ChatReceiptSnapshot.fromJson(Map<String, dynamic> j) {
    final readList = (j['read_members'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => ChatReceiptMember.fromJson(m.cast<String, dynamic>()))
        .toList(growable: false);
    final unreadList = (j['unread_members'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => ChatReceiptMember.fromJson(m.cast<String, dynamic>()))
        .toList(growable: false);
    final seq = j['message_seq'];
    final read = j['read_count'];
    final unread = j['unread_count'];
    final allRead = j['all_read'];
    return ChatReceiptSnapshot(
      messageSeq: seq is num ? seq.toInt() : 0,
      readCount: read is num ? read.toInt() : readList.length,
      unreadCount: unread is num ? unread.toInt() : unreadList.length,
      allRead: allRead == true,
      readMembers: readList,
      unreadMembers: unreadList,
    );
  }
}
