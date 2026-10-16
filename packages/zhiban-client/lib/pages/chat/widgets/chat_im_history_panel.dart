import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/im/human_direct_im_controller.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/network/api_image_auth.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_im_history.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_media_kind.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_message_time_divider.dart';
import 'package:zhiban_client/pages/chat/widgets/file_attachment_icon.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';
import 'chat_ai_generated.dart';

/// 聊天历史抽屉(P2,仅客户端,人↔人 + 群聊共用)。
///
/// 数据源 = `HumanDirectImController.messages`(既有物化视图),tab + 搜索纯客户端过滤,
/// `hasMore` 时滚动到顶部附近 / 点「加载更多」复用 `controller.loadMoreHistory()`。
/// **不**另起绕过 controller 的查询、**不**含 KB / 云盘内容。点击结果(`onSelectMessage`)可定位
/// 到主聊天区**当前已加载**的消息;跨页精准定位 / 后端全文搜索留后续。
class ChatImHistoryPanel extends StatefulWidget {
  const ChatImHistoryPanel({
    super.key,
    required this.messages,
    required this.selfUid,
    required this.resolveSenderName,
    required this.onClose,
    this.onSelectMessage,
    this.onPreviewImage,
    this.onOpenVideo,
    this.hasMore = false,
    this.loadingMore = false,
    this.onLoadMore,
    this.showHeader = true,
    this.now,
  });

  final List<ImMessage> messages;
  final String selfUid;

  /// 对端 / 群成员显示名(本人由组件内部统一显示「我」)。
  final String Function(ImMessage msg) resolveSenderName;
  final VoidCallback onClose;

  /// 点击一条历史结果(P2 定位):传入则回调目标消息(由 pane 关抽屉 + 定位 + 高亮);
  /// 不传则退回原行为(仅关抽屉)。
  final void Function(ImMessage msg)? onSelectMessage;

  /// P2 (2026-06): 「图片与视频」tab 点击**图片**结果 → 触发大图预览。
  /// 非空时优先于 `onSelectMessage` 处理该条 (避免又关又预览)。
  final void Function(ImMessage msg)? onPreviewImage;

  /// P2 (2026-06): 「图片与视频」tab 点击**视频**结果 → 下载 + 系统打开 (无内嵌播放器)。
  final void Function(ImMessage msg)? onOpenVideo;
  final bool hasMore;
  final bool loadingMore;
  final Future<void> Function()? onLoadMore;
  final bool showHeader;

  /// 测试可注入;生产用 `DateTime.now()`。
  final DateTime? now;

  @override
  State<ChatImHistoryPanel> createState() => _ChatImHistoryPanelState();
}

class _ChatImHistoryPanelState extends State<ChatImHistoryPanel> {
  ImHistoryTab _tab = ImHistoryTab.all;
  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();
  String _query = '';
  String _senderUid = '';
  ImHistoryFileType _fileType = ImHistoryFileType.all;
  ImHistoryDateFilter _dateFilter = ImHistoryDateFilter.all;
  String _lastAutoScrollKey = '';

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!widget.hasMore || widget.loadingMore || widget.onLoadMore == null) {
      return;
    }
    // 内容不足 80px 可滚动时，底部默认位置也会满足 `pixels <= 80`。
    // 这种短列表保留显式「加载更多」入口，避免初次布局/筛选切换自动重复拉取。
    if (_scroll.position.maxScrollExtent <= 80) return;
    if (_scroll.position.pixels <= 80) {
      widget.onLoadMore!.call();
    }
  }

  void _scrollToLatestOnce(String key) {
    if (_lastAutoScrollKey == key) return;
    _lastAutoScrollKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      if (max <= 0) return;
      _scroll.jumpTo(max);
    });
  }

  @override
  Widget build(BuildContext context) {
    final now = widget.now ?? DateTime.now();
    final results = filterHistoryMessages(
      widget.messages,
      _tab,
      _query,
      senderUid: _senderUid,
      fileType: _fileType,
      dateFilter: _dateFilter,
      now: now,
    );
    final latestResultKey =
        results.isEmpty ? 'empty' : imMessageIdentity(results.last);
    _scrollToLatestOnce(
      '${_tab.index}|$_query|$_senderUid|${_fileType.index}|'
      '${_dateFilter.index}|$latestResultKey',
    );
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          left: BorderSide(color: Color(0xFFE8EDF4), width: 0.8)
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showHeader) _PanelHeader(onClose: widget.onClose),
          UiUnderlineTabs<ImHistoryTab>(
            current: _tab,
            onChanged: (t) {
              setState(() {
                _tab = t;
                if (t != ImHistoryTab.file) {
                  _fileType = ImHistoryFileType.all;
                }
              });
            },
            tabs: const [
              UiUnderlineTab(value: ImHistoryTab.all, label: '全部'),
              UiUnderlineTab(value: ImHistoryTab.file, label: '文件'),
              UiUnderlineTab(value: ImHistoryTab.media, label: '图片与视频'),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: UiSearchField(
              controller: _search,
              hintText: _searchHint(_tab),
              showBorder: false,
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          _HistoryFilterBar(
            tab: _tab,
            senderUid: _senderUid,
            fileType: _fileType,
            dateFilter: _dateFilter,
            senderOptions: _senderOptions(),
            onSenderChanged: (value) => setState(() => _senderUid = value),
            onFileTypeChanged: (value) => setState(() => _fileType = value),
            onDateChanged: (value) => setState(() => _dateFilter = value),
          ),
          Expanded(
            child: results.isEmpty
                ? _EmptyResults(
                    hasMore: widget.hasMore,
                    loadingMore: widget.loadingMore,
                    onLoadMore: widget.onLoadMore,
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: results.length + (widget.hasMore ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (widget.hasMore && i == 0) {
                        return _LoadMoreRow(
                          loading: widget.loadingMore,
                          onTap: widget.onLoadMore,
                        );
                      }
                      final resultIndex = widget.hasMore ? i - 1 : i;
                      final m = results[resultIndex];
                      final isMine = m.fromUid == widget.selfUid;
                      final sender = isMine ? '我' : widget.resolveSenderName(m);
                      final time = formatMessageTime(m.timestamp, now: now);
                      VoidCallback resourceTap() {
                        // P2 (2026-06): media tab 点击图片 → 大图预览; 视频 → 下载+打开;
                        // 文件 tab 保持既有定位行为不变。
                        if (_tab == ImHistoryTab.media) {
                          if (isVideoMessage(m) && widget.onOpenVideo != null) {
                            return () => widget.onOpenVideo!(m);
                          }
                          if (isImageMessage(m) &&
                              widget.onPreviewImage != null) {
                            return () => widget.onPreviewImage!(m);
                          }
                        }
                        return widget.onSelectMessage != null
                            ? () => widget.onSelectMessage!(m)
                            : widget.onClose;
                      }

                      final row = _tab == ImHistoryTab.all
                          ? _HistoryAllRow(
                              message: m,
                              sender: sender,
                              time: time,
                              onTap: widget.onSelectMessage != null
                                  ? () => widget.onSelectMessage!(m)
                                  : widget.onClose,
                            )
                          : _HistoryResourceRow(
                              message: m,
                              tab: _tab,
                              sender: sender,
                              time: time,
                              onTap: resourceTap(),
                            );
                      return row;
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String _searchHint(ImHistoryTab tab) {
    switch (tab) {
      case ImHistoryTab.all:
        return '搜索聊天记录';
      case ImHistoryTab.file:
        return '搜索文件名称';
      case ImHistoryTab.media:
        return '搜索图片与视频';
    }
  }

  List<(String, String)> _senderOptions() {
    final labels = <String, String>{};
    for (final message in widget.messages) {
      final uid = message.fromUid.trim();
      if (uid.isEmpty || labels.containsKey(uid)) continue;
      final resolved = uid == widget.selfUid
          ? '我'
          : widget.resolveSenderName(message).trim();
      labels[uid] = resolved.isEmpty ? '未知发送人' : resolved;
    }
    final entries = labels.entries.toList()
      ..sort((a, b) {
        if (a.key == widget.selfUid) return -1;
        if (b.key == widget.selfUid) return 1;
        return a.value.compareTo(b.value);
      });
    return [
      const ('', '全部'),
      for (final entry in entries) (entry.key, entry.value),
    ];
  }
}

class _HistoryFilterBar extends StatelessWidget {
  const _HistoryFilterBar({
    required this.tab,
    required this.senderUid,
    required this.fileType,
    required this.dateFilter,
    required this.senderOptions,
    required this.onSenderChanged,
    required this.onFileTypeChanged,
    required this.onDateChanged,
  });

  final ImHistoryTab tab;
  final String senderUid;
  final ImHistoryFileType fileType;
  final ImHistoryDateFilter dateFilter;
  final List<(String, String)> senderOptions;
  final ValueChanged<String> onSenderChanged;
  final ValueChanged<ImHistoryFileType> onFileTypeChanged;
  final ValueChanged<ImHistoryDateFilter> onDateChanged;

  @override
  Widget build(BuildContext context) {
    var senderLabel = '发送人';
    if (senderUid.isNotEmpty) {
      for (final option in senderOptions) {
        if (option.$1 == senderUid) {
          senderLabel = option.$2;
          break;
        }
      }
    }
    final fileTypeLabel = switch (fileType) {
      ImHistoryFileType.all => '类型',
      ImHistoryFileType.pdf => 'PDF',
      ImHistoryFileType.word => 'Word',
      ImHistoryFileType.excel => 'Excel',
      ImHistoryFileType.ppt => 'PPT',
      ImHistoryFileType.archive => '压缩包',
      ImHistoryFileType.video => '视频',
      ImHistoryFileType.other => '其它',
    };
    final dateLabel = switch (dateFilter) {
      ImHistoryDateFilter.all => '日期',
      ImHistoryDateFilter.today => '今天',
      ImHistoryDateFilter.yesterday => '昨天',
      ImHistoryDateFilter.last7Days => '近 7 天',
      ImHistoryDateFilter.last30Days => '近 30 天',
    };
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          _HistoryFilterChip<String>(
            triggerKey: const ValueKey('chat-history-sender-filter'),
            label: senderLabel,
            value: senderUid,
            active: senderUid.isNotEmpty,
            options: senderOptions,
            onSelected: onSenderChanged,
          ),
          const _HistoryFilterDivider(),
          if (tab == ImHistoryTab.file) ...[
            _HistoryFilterChip<ImHistoryFileType>(
              triggerKey: const ValueKey('chat-history-type-filter'),
              label: fileTypeLabel,
              value: fileType,
              active: fileType != ImHistoryFileType.all,
              options: const [
                (ImHistoryFileType.all, '全部'),
                (ImHistoryFileType.pdf, 'PDF'),
                (ImHistoryFileType.word, 'Word'),
                (ImHistoryFileType.excel, 'Excel'),
                (ImHistoryFileType.ppt, 'PPT'),
                (ImHistoryFileType.archive, '压缩包'),
                (ImHistoryFileType.video, '视频'),
                (ImHistoryFileType.other, '其它'),
              ],
              onSelected: onFileTypeChanged,
            ),
            const _HistoryFilterDivider(),
          ],
          _HistoryFilterChip<ImHistoryDateFilter>(
            triggerKey: const ValueKey('chat-history-date-filter'),
            label: dateLabel,
            value: dateFilter,
            active: dateFilter != ImHistoryDateFilter.all,
            options: const [
              (ImHistoryDateFilter.all, '全部'),
              (ImHistoryDateFilter.today, '今天'),
              (ImHistoryDateFilter.yesterday, '昨天'),
              (ImHistoryDateFilter.last7Days, '近 7 天'),
              (ImHistoryDateFilter.last30Days, '近 30 天'),
            ],
            onSelected: onDateChanged,
          ),
        ],
      ),
    );
  }
}

class _HistoryFilterChip<T> extends StatelessWidget {
  const _HistoryFilterChip({
    required this.triggerKey,
    required this.label,
    required this.value,
    required this.active,
    required this.options,
    required this.onSelected,
  });

  final Key triggerKey;
  final String label;
  final T value;
  final bool active;
  final List<(T, String)> options;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final foreground =
        active ? const Color(0xFF1E66F5) : const Color(0xFF86909C);
    return UiDropdownMenu<T>(
      key: triggerKey,
      menuWidth: 140,
      activeValue: value,
      items: [
        for (final option in options)
          UiDropdownMenuItem(value: option.$1, label: option.$2),
      ],
      onSelected: onSelected,
      child: AbsorbPointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: active ? const Color(0xFFE8F0FE) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 80),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: foreground,
                    fontWeight: active ? FontWeight.w500 : FontWeight.w400,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 16,
                color: foreground,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryFilterDivider extends StatelessWidget {
  const _HistoryFilterDivider();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 18,
      child: VerticalDivider(
        width: 22,
        thickness: 1,
        color: Color(0xFFE5E6EB)
      ),
    );
  }
}

class _HistoryAllRow extends StatelessWidget {
  const _HistoryAllRow({
    required this.message,
    required this.sender,
    required this.time,
    this.onTap,
  });

  final ImMessage message;
  final String sender;
  final String time;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _HistorySenderLine(sender: sender, time: time),
            const SizedBox(height: 8),
            if (message.blocks.isNotEmpty) ...[
              _HistoryMixedBlocks(blocks: message.blocks),
            ] else if (message.mediaKind == ImMediaKind.image) ...[
              _HistoryImagePreview(url: message.mediaUrl),
              if (message.text.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                _HistoryBodyText(text: message.text.trim()),
              ],
            ] else if (message.mediaKind == ImMediaKind.file) ...[
              _HistoryInlineFileCard(message: message),
              if (message.text.trim().isNotEmpty &&
                  message.text.trim() != historyMessageSummary(message)) ...[
                const SizedBox(height: 8),
                _HistoryBodyText(text: message.text.trim()),
              ],
            ] else
              _HistoryBodyText(text: historyMessageSummary(message)),
            if (isAiGeneratedImContent(message)) const UiAiGeneratedLabel(),
          ],
        ),
      ),
    );
  }
}

class _HistorySenderLine extends StatelessWidget {
  const _HistorySenderLine({required this.sender, required this.time});
  final String sender;
  final String time;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Flexible(
          child: Text(
            sender,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              color: Color(0xFF86909C),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (time.isNotEmpty) ...[
          const SizedBox(width: 10),
          Text(
            time,
            style: const TextStyle(
              fontSize: 13,
              color: Color(0xFF86909C),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ],
    );
  }
}

class _HistoryBodyText extends StatelessWidget {
  const _HistoryBodyText({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 4,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 15,
        color: Color(0xFF1D2129),
        height: 1.45,
      ),
    );
  }
}

class _HistoryInlineFileCard extends StatelessWidget {
  const _HistoryInlineFileCard({required this.message}) : block = null;
  const _HistoryInlineFileCard.block({required this.block}) : message = null;
  final ImMessage? message;
  final ImMessageBlock? block;

  @override
  Widget build(BuildContext context) {
    final b = block;
    final m = message;
    final name = b != null
        ? (b.name.trim().isNotEmpty ? b.name : '文件')
        : (m!.mediaName.trim().isNotEmpty ? m.mediaName : '文件');
    final size = b?.size ?? m?.mediaSize ?? 0;
    return Container(
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE5E6EB)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFFEFF4FF),
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: FileAttachmentIcon(
              fileName: name,
              size: FileAttachmentIconSize.lg,
              fallbackIconColor: const Color(0xFF2563EB),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    color: Color(0xFF1D2129),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (size > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    _humanSize(size),
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF9AA0AA),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryMixedBlocks extends StatelessWidget {
  const _HistoryMixedBlocks({required this.blocks});
  final List<ImMessageBlock> blocks;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (final b in blocks) {
      Widget? w;
      if (b.isText && b.text.trim().isNotEmpty) {
        w = _HistoryBodyText(text: b.text.trim());
      } else if (b.isImage) {
        w = _HistoryImagePreview(url: b.url);
      } else if (b.isFile) {
        w = _HistoryInlineFileCard.block(block: b);
      } else if (b.isCallEvent) {
        w = _HistoryCallEventRow(
          label: b.text.trim().isNotEmpty ? b.text.trim() : '语音通话',
          endReason: b.callEndReason,
        );
      }
      if (w == null) continue;
      if (children.isNotEmpty) children.add(const SizedBox(height: 8));
      children.add(w);
    }
    if (children.isEmpty) return const _HistoryBodyText(text: '[非文本消息]');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}

/// F16 历史面板里的通话卡片行（电话图标 + 文案；未接/被拒红、其它蓝；克制不做大卡）。
class _HistoryCallEventRow extends StatelessWidget {
  const _HistoryCallEventRow({required this.label, required this.endReason});
  final String label;
  final String endReason;

  @override
  Widget build(BuildContext context) {
    final missed = endReason == 'timeout' || endReason == 'callee_reject';
    final color = missed ? const Color(0xFFFF3B30) : const Color(0xFF2563EB);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(CupertinoIcons.phone_fill, size: 15, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 15,
              color: Color(0xFF1D2129),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _HistoryResourceRow extends StatelessWidget {
  const _HistoryResourceRow({
    required this.message,
    required this.tab,
    required this.sender,
    required this.time,
    this.onTap,
  });

  final ImMessage message;
  final ImHistoryTab tab;
  final String sender;
  final String time;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final resource = _resourceFor(message, tab);
    final title = resource.title;
    final sizeText = resource.size > 0 ? _humanSize(resource.size) : '';
    final meta = [
      sender,
      if (sizeText.isNotEmpty) sizeText,
      if (time.isNotEmpty) time,
    ].join('  |  ');
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Container(
          constraints: const BoxConstraints(minHeight: 58),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: const BoxDecoration(color: Colors.transparent),
          child: Row(
            children: [
              if (resource.isImage)
                _HistoryImageThumb(url: resource.url)
              else
                _HistoryFileIcon(fileName: title),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        color: Color(0xFF1D2129),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF9AA0AA),
                      ),
                    ),
                    if (isAiGeneratedImContent(message))
                      const UiAiGeneratedLabel(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryResource {
  const _HistoryResource({
    required this.title,
    required this.url,
    required this.size,
    required this.isImage,
  });

  final String title;
  final String url;
  final int size;
  final bool isImage;
}

_HistoryResource _resourceFor(ImMessage message, ImHistoryTab tab) {
  if (message.blocks.isNotEmpty) {
    ImMessageBlock? block;
    for (final b in message.blocks) {
      if (tab == ImHistoryTab.media && b.isImage) {
        block = b;
        break;
      }
      if (tab == ImHistoryTab.file && b.isFile) {
        block = b;
        break;
      }
    }
    if (block != null) {
      return _HistoryResource(
        title: block.name.trim().isNotEmpty
            ? block.name.trim()
            : block.isImage
                ? '[图片]'
                : '[文件]',
        url: block.url,
        size: block.size,
        isImage: block.isImage,
      );
    }
  }
  return _HistoryResource(
    title: historyMessageSummary(message),
    url: message.mediaUrl,
    size: message.mediaSize,
    isImage: message.mediaKind == ImMediaKind.image,
  );
}

class _HistoryFileIcon extends StatelessWidget {
  const _HistoryFileIcon({required this.fileName});
  final String fileName;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: const Color(0xFFEAF2FF),
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: FileAttachmentIcon(
        fileName: fileName,
        size: FileAttachmentIconSize.md,
        fallbackIconColor: const Color(0xFF2563EB),
      ),
    );
  }
}

class _HistoryImageThumb extends StatelessWidget {
  const _HistoryImageThumb({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 42,
        height: 42,
        child: _HistoryAuthedImage(url: url, fit: BoxFit.cover),
      ),
    );
  }
}

class _HistoryImagePreview extends StatelessWidget {
  const _HistoryImagePreview({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: _HistoryAuthedImage(url: url, fit: BoxFit.cover),
      ),
    );
  }
}

class _HistoryAuthedImage extends StatelessWidget {
  const _HistoryAuthedImage({required this.url, required this.fit});
  final String url;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    if (url.trim().isEmpty) {
      return const ColoredBox(
        color: Color(0xFFF2F3F5),
        child: Center(
          child: Icon(Icons.broken_image_outlined,
              color: Color(0xFF98A2B3), size: 24),
        ),
      );
    }
    final absoluteUrl = apiImageResolveUrl(url);
    return UiNetworkImage(
      imageUrl: absoluteUrl,
      cacheKey: absoluteUrl,
      fit: fit,
      borderRadius: 0,
      placeholderBuilder: (_, __) => const ColoredBox(
        color: Color(0xFFF2F3F5),
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      errorBuilder: (_, __, ___) => const ColoredBox(
        color: Color(0xFFF2F3F5),
        child: Center(
          child: Icon(Icons.broken_image_outlined,
              color: Color(0xFF98A2B3), size: 24),
        ),
      ),
    );
  }
}

String _humanSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    final kb = bytes / 1024;
    return kb == kb.roundToDouble()
        ? '${kb.round()}K'
        : '${kb.toStringAsFixed(1)}K';
  }
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)}M';
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(0xFFE8EDF4), width: 0.8),
        ),
      ),
      child: Row(
        children: [
          const Text(
            '聊天历史',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1D2129),
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: '关闭',
            iconSize: 20,
            splashRadius: 18,
            color: const Color(0xFF4E5969),
            icon: const Icon(Icons.close_rounded),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _LoadMoreRow extends StatelessWidget {
  const _LoadMoreRow({required this.loading, this.onTap});
  final bool loading;
  final Future<void> Function()? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: loading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : TextButton(
                onPressed: onTap == null ? null : () => onTap!.call(),
                child: const Text('加载更多'),
              ),
      ),
    );
  }
}

/// 空结果态。当前 tab/搜索无命中时显示「暂无相关历史」;若仍有更早历史
/// (`hasMore`)→ **同时**给「加载更多」入口(Codex P2 修复:当前页无命中也能翻更早页找)。
class _EmptyResults extends StatelessWidget {
  const _EmptyResults({
    required this.hasMore,
    required this.loadingMore,
    this.onLoadMore,
  });
  final bool hasMore;
  final bool loadingMore;
  final Future<void> Function()? onLoadMore;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '暂无相关历史',
            style: TextStyle(fontSize: 13, color: Color(0xFF9AA0AA)),
          ),
          if (hasMore) _LoadMoreRow(loading: loadingMore, onTap: onLoadMore),
        ],
      ),
    );
  }
}

/// 历史定位高亮(P2):被定位那条消息短暂加一层半透明品牌底色,~1s 后由 pane 清除。
/// `active=false` 时**完全透明**(不改默认气泡颜色 / 圆角 / 布局)。
class ChatLocateHighlight extends StatelessWidget {
  const ChatLocateHighlight({
    super.key,
    required this.active,
    required this.child,
  });
  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      decoration: BoxDecoration(
        color: active ? const Color(0x1A2563EB) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: child,
    );
  }
}

/// 把 IM pane 的内容包一层:`chatHistoryPanelOpenProvider` 打开时,在桌面右侧挂定宽抽屉、
/// 移动端全屏覆盖抽屉(数据取 [controller],pane 自己持有 controller,不抬升状态)。
/// 关闭时透明返回 [child]。
class ChatImHistoryHost extends ConsumerWidget {
  const ChatImHistoryHost({
    super.key,
    required this.child,
    required this.controller,
    required this.resolveSenderName,
    this.onSelectMessage,
    this.onPreviewImage,
    this.onOpenVideo,
    this.now,
  });

  final Widget child;
  final HumanDirectImController controller;
  final String Function(ImMessage msg) resolveSenderName;

  /// 点击历史结果(P2 定位):pane 关抽屉 + 定位 + 高亮。
  final void Function(ImMessage msg)? onSelectMessage;

  /// P2 (2026-06): 点击「图片与视频」tab 的图片 → 触发大图预览。
  final void Function(ImMessage msg)? onPreviewImage;

  /// P2 (2026-06): 点击「图片与视频」tab 的视频 → 下载 + 系统打开。
  final void Function(ImMessage msg)? onOpenVideo;
  final DateTime? now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 移动端「聊天历史」已经改成 context.push 到独立页面（MobileHistoryPage），
    // 不再靠这个全局 flag 驱动行内覆盖层——那样会导致本页(仍挂在路由栈里)
    // 在 push/pop 过程中跟着 flag 闪一下面板。这里只在桌面响应 flag。
    final open =
        PlatformUtils.isDesktop && ref.watch(chatHistoryPanelOpenProvider);
    if (!open) return child;

    void close() =>
        ref.read(chatHistoryPanelOpenProvider.notifier).state = false;

    Widget panel({bool showHeader = true}) => AnimatedBuilder(
          animation: controller,
          builder: (context, _) => ChatImHistoryPanel(
            messages: controller.messages,
            selfUid: controller.myUid ?? '',
            resolveSenderName: resolveSenderName,
            hasMore: controller.hasMoreHistory,
            loadingMore: controller.loadingMore,
            onLoadMore: controller.loadMoreHistory,
            onClose: close,
            onSelectMessage: onSelectMessage,
            onPreviewImage: onPreviewImage,
            onOpenVideo: onOpenVideo,
            showHeader: showHeader,
            now: now,
          ),
        );

    if (PlatformUtils.isMobile) {
      return Stack(
        children: [
          child,
          Positioned.fill(child: Material(color: Colors.white, child: panel())),
        ],
      );
    }

    // 桌面:右侧定宽列;窗口太窄给不出(主区需留足)则本帧不挂,按钮仍是激活态。
    return LayoutBuilder(builder: (context, c) {
      const double desired = 300;
      const double minMain = 420;
      double panelW = 0;
      final avail = c.maxWidth;
      if (avail - desired >= minMain) {
        panelW = desired;
      } else if (avail - 300 >= minMain) {
        panelW = 300;
      }
      if (panelW <= 0) return child;
      return Row(
        children: [
          Expanded(child: child),
          SizedBox(width: panelW, child: panel()),
        ],
      );
    });
  }
}
