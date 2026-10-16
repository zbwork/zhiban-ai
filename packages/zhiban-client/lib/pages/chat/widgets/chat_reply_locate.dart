import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/im/human_direct_im_controller.dart';
import 'package:zhiban_core/chat/chat_reply_reference.dart';

/// F09 引用回复 v1 (2026-06 best-effort 跨页定位增量):
///
/// 见 docs/contracts/agent-bus-client-contract.md §「消息操作菜单 v2」.
///
/// 共用纯函数 + helper, 给 human_direct + group pane 都用同一套定位逻辑。
/// **不**引入新的后端接口, **不**做 aroundSeq 精准定位; 只 best-effort 利用现有 loadMoreHistory。

/// 一次 reply 点击允许的最大上拉补加载页数。超过仍未找到 → toast 「原消息不在当前会话窗口」。
const int kReplyLocateMaxPages = 5;

/// 在 [messages] 里按 [ref] 的稳定锚点找下标。clientMsgNo > messageId > messageSeq。
/// 未命中 → -1。
int findMessageIndexByReplyRef(
    List<ImMessage> messages, ChatReplyReference ref) {
  if (ref.clientMsgNo.isNotEmpty) {
    for (int i = 0; i < messages.length; i++) {
      if (messages[i].clientMsgNo == ref.clientMsgNo) return i;
    }
  }
  if (ref.messageId.isNotEmpty) {
    for (int i = 0; i < messages.length; i++) {
      if (messages[i].messageId == ref.messageId) return i;
    }
  }
  if (ref.messageSeq > 0) {
    for (int i = 0; i < messages.length; i++) {
      if (messages[i].messageSeq == ref.messageSeq) return i;
    }
  }
  return -1;
}

/// 给定当前 [controller] 状态 + reply [ref], 判断**是否应该**触发上拉补加载一页历史。
///
/// 真当且仅当:
///   1. `ref.messageSeq > 0` (否则我们没办法判定它是不是在更早页);
///   2. `controller.hasMoreHistory == true` (还有更早页可拉);
///   3. `controller.earliestMessageSeq > 0` (当前窗口有 ack 消息可对比);
///   4. `controller.earliestMessageSeq > ref.messageSeq` (ref 真的在更早页)。
bool shouldLoadOlderForReplyRef({
  required int earliestMessageSeq,
  required bool hasMoreHistory,
  required int refMessageSeq,
}) {
  if (refMessageSeq <= 0) return false;
  if (!hasMoreHistory) return false;
  if (earliestMessageSeq <= 0) return false;
  return earliestMessageSeq > refMessageSeq;
}

/// 适配器: 仅暴露 reply 跨页定位需要的 controller 字段, 便于测试 mock。
class ReplyLocateController {
  ReplyLocateController({
    required this.earliestMessageSeq,
    required this.hasMoreHistory,
    required this.loadMoreHistory,
  });

  /// 当前已加载窗口最早 seq (0 = 无 ack 消息)。
  final int Function() earliestMessageSeq;

  /// 是否还有更早页。
  final bool Function() hasMoreHistory;

  /// 异步拉一页历史 (会修改 earliestMessageSeq / hasMoreHistory)。
  final Future<void> Function() loadMoreHistory;

  factory ReplyLocateController.fromController(HumanDirectImController c) {
    return ReplyLocateController(
      earliestMessageSeq: () => c.earliestMessageSeq,
      hasMoreHistory: () => c.hasMoreHistory,
      loadMoreHistory: c.loadMoreHistory,
    );
  }
}

/// 异步逐页拉历史 (最多 [kReplyLocateMaxPages] 页), 每页拉完后用 [findIndex] 查找;
/// 找到 → 返回该下标; 不在更早页 / 拉满上限 / hasMore 消失 → 返回 -1。
///
/// 实现说明: 控制循环退出条件以避免无限拉。即使 controller 因为去重判定 hasMoreHistory=false,
/// 也会在循环里被 [shouldLoadOlderForReplyRef] 抓到, 不会继续拉。
Future<int> loadOlderUntilFoundForReplyRef({
  required dynamic controller,
  required ChatReplyReference ref,
  required int Function() findIndex,
  int maxPages = kReplyLocateMaxPages,
}) async {
  final adapter = controller is ReplyLocateController
      ? controller
      : controller is HumanDirectImController
          ? ReplyLocateController.fromController(controller)
          : throw ArgumentError(
              'controller must be HumanDirectImController or ReplyLocateController');
  for (int page = 0; page < maxPages; page++) {
    // 先看是否还有必要继续拉。
    if (!shouldLoadOlderForReplyRef(
      earliestMessageSeq: adapter.earliestMessageSeq(),
      hasMoreHistory: adapter.hasMoreHistory(),
      refMessageSeq: ref.messageSeq,
    )) {
      break;
    }
    // 记录 earliest 以便检测「拉了但没进展」(去重后 controller 内部已置 hasMore=false, 下轮 should=false 自动退出)。
    final beforeEarliest = adapter.earliestMessageSeq();
    await adapter.loadMoreHistory();
    final found = findIndex();
    if (found >= 0) return found;
    // 防止 loadMoreHistory 因为网络异常没有改 hasMore 也没拉到新页 → 死循环.
    if (adapter.earliestMessageSeq() == beforeEarliest) break;
  }
  return findIndex();
}
