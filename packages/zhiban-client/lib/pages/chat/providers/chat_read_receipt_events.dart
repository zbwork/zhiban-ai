import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// WuKong no_persist 推来的轻量已读水位变更事件。
///
/// 事件不携带成员列表;具体某条自己 sent 消息的 read/unread 成员仍由
/// ChatReceiptsController 走 /read-receipts 权限校验后批量拉取。
class ChatReadReceiptChangedEvent {
  const ChatReadReceiptChangedEvent({
    required this.conversationUuid,
    required this.lastReadMessageSeq,
  });

  final String conversationUuid;
  final int lastReadMessageSeq;
}

class ChatReadReceiptEventBus {
  final StreamController<ChatReadReceiptChangedEvent> _controller =
      StreamController<ChatReadReceiptChangedEvent>.broadcast();

  Stream<ChatReadReceiptChangedEvent> get stream => _controller.stream;

  void emit(ChatReadReceiptChangedEvent event) {
    if (_controller.isClosed) return;
    _controller.add(event);
  }

  void dispose() {
    _controller.close();
  }
}

final chatReadReceiptEventBusProvider =
    Provider<ChatReadReceiptEventBus>((ref) {
  final bus = ChatReadReceiptEventBus();
  ref.onDispose(bus.dispose);
  return bus;
});
