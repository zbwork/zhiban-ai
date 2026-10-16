import 'package:zhiban_client/network/api_image_auth.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/services/account_info_api.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 「聊天历史」右侧抽屉。
///
/// 数据源直接复用 chatProvider.messages（即当前选中会话已加载的消息),
/// 不再额外请求接口。原因:
/// - 这条入口本身就在「某个 agent 的某次对话」上下文里,看的是这条对话的历史;
/// - 主聊天列表已经走过分页 + around 加载,这里只读不再放大数据范围,
///   避免再实现一套分页+缓存。
///
/// 如果未来要做"跨会话查所有历史/全局搜索",再加 service 接口和 family provider,
/// 不要在这个面板里再下钻。
class ChatHistoryPanel extends ConsumerStatefulWidget {
  const ChatHistoryPanel({
    super.key,
    this.width = 300,
    this.showHeader = true,
    this.showLeftDivider = true,
  });

  /// 由宿主算好的实际宽度。宿主用 LayoutBuilder 在窗口被拖窄时把它收成 280~300
  /// 之间的某个值,避免聊天主体被挤没。
  final double width;
  final bool showHeader;
  final bool showLeftDivider;

  @override
  ConsumerState<ChatHistoryPanel> createState() => _ChatHistoryPanelState();
}

enum _HistoryTab { all, file, media }

/// 发送人筛选枚举:全部 / 仅我 / 仅 agent。
/// 单会话上下文里就这三种,直接枚举,不做"任意发送人多选"。
enum _SenderFilter { all, me, agent }

/// 文件类型筛选枚举(只用于「文件」tab):
/// pdf / word / excel / ppt / archive(压缩包) / other(其它) / all。
enum _FileTypeFilter { all, pdf, word, excel, ppt, archive, other }

/// 日期范围筛选枚举:全部 / 今天 / 昨天 / 近 7 天 / 近 30 天。
enum _DateFilter { all, today, yesterday, last7Days, last30Days }

class _ChatHistoryPanelState extends ConsumerState<ChatHistoryPanel> {
  _HistoryTab _tab = _HistoryTab.all;
  String _query = '';
  String _activeHistoryTargetId = '';
  final TextEditingController _searchCtrl = TextEditingController();

  // 筛选条状态——切 tab 时统一重置,避免「文件 tab 选的『类型=PDF』」误带到媒体 tab。
  _SenderFilter _senderFilter = _SenderFilter.all;
  _FileTypeFilter _fileTypeFilter = _FileTypeFilter.all;
  _DateFilter _dateFilter = _DateFilter.all;

  @override
  void initState() {
    super.initState();
    // 面板打开时强制重拉一次当前会话 history。
    // 必要性:SSE 流式推送链路里没有 outputFiles 字段,数字员工本轮产出的附件
    // 只能从 GetMessages REST 接口拿到。如果用户从打开 app 起就停在当前会话、
    // 没切走过,chatProvider.messages 一直是旧的 SSE 数据,
    // 「文件」/「图片与视频」tab 永远拿不到 assistant 产物。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(chatProvider.notifier).reloadActiveMessages();
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // SSE 流结束(isSending: true → false)后再拉一次 history,把刚产出的
    // assistant_output 文件(比如 Excel/HTML)同步进面板。SSE 推送链路不带
    // outputFiles 字段,只有 GetMessages REST 才会返回,所以必须主动重拉。
    ref.listen<AsyncValue<ChatState>>(chatProvider, (prev, next) {
      final wasSending = prev?.asData?.value.isSending ?? false;
      final isSending = next.asData?.value.isSending ?? false;
      if (wasSending && !isSending) {
        ref.read(chatProvider.notifier).reloadActiveMessages();
      }
    });
    final messages = ref.watch(chatProvider).asData?.value.messages ?? const [];
    final agent = ref.watch(selectedAgentOrFallbackProvider);
    final agentName = (agent?.name.isNotEmpty ?? false) ? agent!.name : '助理';
    final account = ref.watch(accountInfoProvider).asData?.value;
    // 昵称优先,其次真实姓名;两者都没有再兜底"我"。
    final myName = (() {
      final n = account?.nickname.trim() ?? '';
      if (n.isNotEmpty) return n;
      final r = account?.name.trim() ?? '';
      if (r.isNotEmpty) return r;
      return '我';
    })();
    final filteredMsgs = _filterMessages(messages);
    final searchHint = switch (_tab) {
      _HistoryTab.all => '搜索历史内容',
      _HistoryTab.file => '搜索文件名',
      _HistoryTab.media => '搜索图中文字',
    };

    return Container(
      width: widget.width,
      decoration: BoxDecoration(
        color: Colors.white,
        border: widget.showLeftDivider
            ? const Border(
                left: BorderSide(color: Color(0xFFE8EDF4), width: 0.8),
              )
            : null,
        // 左缘弱阴影模拟企业微信"外接面板"的悬浮感,与左侧主对话区做视觉分隔。
        boxShadow: widget.showLeftDivider
            ? const [
                BoxShadow(
                  color: Color(0x14000000),
                  offset: Offset(-2, 0),
                  blurRadius: 12,
                ),
              ]
            : null,
      ),
      child: _HistoryPanelContent(
        showHeader: widget.showHeader,
        tab: _tab,
        searchController: _searchCtrl,
        searchHint: searchHint,
        senderFilter: _senderFilter,
        fileTypeFilter: _fileTypeFilter,
        dateFilter: _dateFilter,
        agentName: agentName,
        myName: myName,
        onClose: () =>
            ref.read(chatHistoryPanelOpenProvider.notifier).state = false,
        onTabChanged: (t) {
          setState(() {
            _tab = t;
            _query = '';
            _searchCtrl.clear();
            _senderFilter = _SenderFilter.all;
            _fileTypeFilter = _FileTypeFilter.all;
            _dateFilter = _DateFilter.all;
          });
        },
        onQueryChanged: (v) => setState(() => _query = v.trim()),
        onSenderChanged: (v) => setState(() => _senderFilter = v),
        onFileTypeChanged: (v) => setState(() => _fileTypeFilter = v),
        onDateChanged: (v) => setState(() => _dateFilter = v),
        buildBody: () => _buildBody(
          messages: filteredMsgs,
          agentName: agentName,
          myName: myName,
        ),
      ),
    );
  }

  Widget _buildBody({
    required List<ChatMessage> messages,
    required String agentName,
    required String myName,
  }) {
    switch (_tab) {
      case _HistoryTab.all:
        final grouped = _groupByDay(messages);
        if (grouped.isEmpty) return const _Empty();
        return ListView.builder(
          padding: const EdgeInsets.only(top: 4, bottom: 24),
          itemCount: grouped.length,
          itemBuilder: (context, i) {
            final g = grouped[i];
            return _DayGroup(
              label: g.label,
              messages: g.items,
              agentName: agentName,
              myName: myName,
              activeTargetId: _activeHistoryTargetId,
              onTap: _onMessageTap,
            );
          },
        );
      case _HistoryTab.file:
        final rows = _flattenAttachments(
          messages,
          const {ChatFileType.file},
          myName,
          agentName,
        );
        if (rows.isEmpty) return const _Empty(text: '暂无文件');
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: rows.length,
          separatorBuilder: (_, __) => const SizedBox(height: 2),
          itemBuilder: (context, i) {
            final r = rows[i];
            return _FileRow(
              entry: r,
              selected: _messageTargetId(r.message) == _activeHistoryTargetId,
              onTap: () => _onAttachmentTap(r),
            );
          },
        );
      case _HistoryTab.media:
        final rows = _flattenAttachments(
          messages,
          const {ChatFileType.image, ChatFileType.video},
          myName,
          agentName,
        );
        if (rows.isEmpty) return const _Empty(text: '暂无图片');
        final grouped = _groupAttachmentsByDay(rows);
        return ListView.builder(
          padding: const EdgeInsets.only(top: 4, bottom: 24),
          itemCount: grouped.length,
          itemBuilder: (context, i) {
            final g = grouped[i];
            return _MediaGroup(
              label: g.label,
              entries: g.items,
              activeTargetId: _activeHistoryTargetId,
              onTap: _onAttachmentTap,
            );
          },
        );
    }
  }

  /// 文件/图片 tab 用——把消息打散成单个附件行,按发送时间倒序。
  /// [wantTypes] 是允许通过的附件类型集合,例如媒体 tab 同时收 image + video。
  List<_AttachmentEntry> _flattenAttachments(
    List<ChatMessage> messages,
    Set<ChatFileType> wantTypes,
    String myName,
    String agentName,
  ) {
    final list = <_AttachmentEntry>[];
    final dateRange = _dateRange();
    for (final m in messages) {
      if (m.isSystem || m.isSystemPrompt) continue;
      final t = m.createdAt ?? m.streamStartedAt;
      if (t == null) continue;
      // 发送人筛选
      if (_senderFilter == _SenderFilter.me && !m.isQuestion) continue;
      if (_senderFilter == _SenderFilter.agent && m.isQuestion) continue;
      // 日期筛选 [lo, hi) —— hi 为 null 表示不卡上界
      if (dateRange != null) {
        if (t.isBefore(dateRange.$1)) continue;
        if (dateRange.$2 != null && !t.isBefore(dateRange.$2!)) continue;
      }
      final sender = m.isQuestion ? myName : agentName;
      // 用户消息只看 files;assistant 消息把 outputFiles 也合进来——
      // 主气泡靠 markdown 渲染 outputFiles,「聊天历史」列表视图需要它们露面。
      final allFiles =
          m.isQuestion ? m.files : <ChatFileItem>[...m.files, ...m.outputFiles];
      for (final f in allFiles) {
        if (!wantTypes.contains(f.fileType)) continue;
        // 文件名搜索
        if (_query.isNotEmpty &&
            !f.fileName.toLowerCase().contains(_query.toLowerCase())) {
          continue;
        }
        // 文件类型筛选(只在文件 tab 生效——media tab 的 _fileTypeFilter 始终是 all)
        if (_fileTypeFilter != _FileTypeFilter.all &&
            _resolveFileTypeFilter(f.fileName) != _fileTypeFilter) {
          continue;
        }
        list.add(_AttachmentEntry(
          file: f,
          message: m,
          sender: sender,
          time: t),
        );
      }
    }
    list.sort((a, b) => b.time.compareTo(a.time));
    return list;
  }

  /// 把扩展名归到 [_FileTypeFilter] 枚举。
  /// 不在已知列表里的统一算 [other],跟「其它」选项对齐。
  static _FileTypeFilter _resolveFileTypeFilter(String fileName) {
    final ext =
        fileName.contains('.') ? fileName.split('.').last.toLowerCase() : '';
    switch (ext) {
      case 'pdf':
        return _FileTypeFilter.pdf;
      case 'doc':
      case 'docx':
        return _FileTypeFilter.word;
      case 'xls':
      case 'xlsx':
      case 'csv':
        return _FileTypeFilter.excel;
      case 'ppt':
      case 'pptx':
        return _FileTypeFilter.ppt;
      case 'zip':
      case 'rar':
      case '7z':
      case 'tar':
      case 'gz':
        return _FileTypeFilter.archive;
      default:
        return _FileTypeFilter.other;
    }
  }

  /// 日期筛选转区间 `[lo, hi)`。hi=null 表示不卡上界(走到现在)。
  /// 返回 null = 「全部」不做日期筛选。
  (DateTime, DateTime?)? _dateRange() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (_dateFilter) {
      case _DateFilter.all:
        return null;
      case _DateFilter.today:
        return (today, null);
      case _DateFilter.yesterday:
        return (today.subtract(const Duration(days: 1)), today);
      case _DateFilter.last7Days:
        return (today.subtract(const Duration(days: 6)), null);
      case _DateFilter.last30Days:
        return (today.subtract(const Duration(days: 29)), null);
    }
  }

  List<_AttachmentDayBucket> _groupAttachmentsByDay(
    List<_AttachmentEntry> entries,
  ) {
    final Map<String, _AttachmentDayBucket> map = {};
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yest = today.subtract(const Duration(days: 1));
    for (final e in entries) {
      final t = e.time;
      final day = DateTime(t.year, t.month, t.day);
      final label = day == today
          ? '今天'
          : day == yest
              ? '昨天'
              : (t.year == now.year
                  ? '${t.month}/${t.day}'
                  : '${t.year}/${t.month}/${t.day}');
      final key = day.toIso8601String();
      map.putIfAbsent(
        key,
        () => _AttachmentDayBucket(label: label, day: day, items: []),
      );
      map[key]!.items.add(e);
    }
    final list = map.values.toList()..sort((a, b) => b.day.compareTo(a.day));
    return list;
  }

  /// 「全部」tab 用——按 query 命中正文/文件名,按时间倒序。
  /// 文件 / 图片与视频 tab 不再走这条,改用 [_flattenAttachments]
  /// 把每个附件展开成单独一行。
  List<ChatMessage> _filterMessages(List<ChatMessage> all) {
    return all.where((m) {
      if (m.isSystem || m.isSystemPrompt) return false;
      if (_query.isEmpty) return true;
      final hay = '${m.content} '
              '${m.files.map((f) => f.fileName).join(" ")}'
          .toLowerCase();
      return hay.contains(_query.toLowerCase());
    }).toList()
      ..sort((a, b) {
        final ta = a.createdAt ?? a.streamStartedAt ?? DateTime(0);
        final tb = b.createdAt ?? b.streamStartedAt ?? DateTime(0);
        return tb.compareTo(ta);
      });
  }

  List<_DayBucket> _groupByDay(List<ChatMessage> messages) {
    final Map<String, _DayBucket> map = {};
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    for (final m in messages) {
      final t = m.createdAt ?? m.streamStartedAt;
      if (t == null) continue;
      final day = DateTime(t.year, t.month, t.day);
      String label;
      if (day == today) {
        label = '今天';
      } else if (day == yesterday) {
        label = '昨天';
      } else {
        label = '${day.year}-${_pad(day.month)}-${_pad(day.day)}';
      }
      final key = day.toIso8601String();
      map.putIfAbsent(key, () => _DayBucket(label: label, day: day, items: []));
      map[key]!.items.add(m);
    }
    final list = map.values.toList()..sort((a, b) => b.day.compareTo(a.day));
    return list;
  }

  static String _pad(int v) => v.toString().padLeft(2, '0');

  void _onMessageTap(ChatMessage m) {
    // 历史消息常见只有 messageId（后端返回值即 DB uuid 列），uuid 可能为空。
    // 这里要和 ChatMessageList 里的高亮 key 规则保持一致：uuid -> messageId 兜底。
    final targetId = (m.uuid?.isNotEmpty == true)
        ? m.uuid!
        : (m.messageId?.isNotEmpty == true ? m.messageId! : '');
    if (targetId.isEmpty) return;
    setState(() => _activeHistoryTargetId = targetId);
    ref.read(chatProvider.notifier).requestHighlightMessage(targetId);
    if (PlatformUtils.isMobile) {
      ref.read(chatHistoryPanelOpenProvider.notifier).state = false;
    }
  }

  void _onAttachmentTap(_AttachmentEntry entry) {
    // 文件/媒体历史项点击与普通消息保持一致:定位到所属消息,而不是打开附件。
    _onMessageTap(entry.message);
  }
}

/// 聊天历史主体区域组件：可按场景决定是否渲染顶部「聊天历史 + 关闭」栏。
class _HistoryPanelContent extends StatelessWidget {
  const _HistoryPanelContent({
    required this.showHeader,
    required this.tab,
    required this.searchController,
    required this.searchHint,
    required this.senderFilter,
    required this.fileTypeFilter,
    required this.dateFilter,
    required this.agentName,
    required this.myName,
    required this.onClose,
    required this.onTabChanged,
    required this.onQueryChanged,
    required this.onSenderChanged,
    required this.onFileTypeChanged,
    required this.onDateChanged,
    required this.buildBody,
  });

  final bool showHeader;
  final _HistoryTab tab;
  final TextEditingController searchController;
  final String searchHint;
  final _SenderFilter senderFilter;
  final _FileTypeFilter fileTypeFilter;
  final _DateFilter dateFilter;
  final String agentName;
  final String myName;
  final VoidCallback onClose;
  final ValueChanged<_HistoryTab> onTabChanged;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<_SenderFilter> onSenderChanged;
  final ValueChanged<_FileTypeFilter> onFileTypeChanged;
  final ValueChanged<_DateFilter> onDateChanged;
  final Widget Function() buildBody;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showHeader) _Header(onClose: onClose),
        UiUnderlineTabs<_HistoryTab>(
          current: tab,
          onChanged: onTabChanged,
          tabs: const [
            UiUnderlineTab(value: _HistoryTab.all, label: '全部'),
            UiUnderlineTab(value: _HistoryTab.file, label: '文件'),
            UiUnderlineTab(value: _HistoryTab.media, label: '图片与视频'),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: UiSearchField(
            controller: searchController,
            hintText: searchHint,
            showBorder: false,
            onChanged: onQueryChanged,
          ),
        ),
        // 过滤条:全部 tab 不画,文件 tab 多一个"类型",图片与视频 tab 只有"发送人 / 日期"。
        if (tab != _HistoryTab.all)
          _FilterChips(
            showType: tab == _HistoryTab.file,
            senderFilter: senderFilter,
            fileTypeFilter: fileTypeFilter,
            dateFilter: dateFilter,
            agentName: agentName,
            myName: myName,
            onSenderChanged: onSenderChanged,
            onFileTypeChanged: onFileTypeChanged,
            onDateChanged: onDateChanged,
          ),
        Expanded(child: buildBody()),
      ],
    );
  }
}

class _DayBucket {
  _DayBucket({required this.label, required this.day, required this.items});
  final String label;
  final DateTime day;
  final List<ChatMessage> items;
}

/// 文件/图片 tab 用的"展平后的附件行"。一条消息里有多个附件就会拆成多个 entry。
class _AttachmentEntry {
  _AttachmentEntry({
    required this.file,
    required this.message,
    required this.sender,
    required this.time,
  });
  final ChatFileItem file;
  final ChatMessage message;
  final String sender;
  final DateTime time;
}

class _AttachmentDayBucket {
  _AttachmentDayBucket({
    required this.label,
    required this.day,
    required this.items,
  });
  final String label;
  final DateTime day;
  final List<_AttachmentEntry> items;
}

class _Header extends StatelessWidget {
  const _Header({required this.onClose});
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

class _DayGroup extends StatelessWidget {
  const _DayGroup({
    required this.label,
    required this.messages,
    required this.agentName,
    required this.myName,
    required this.activeTargetId,
    required this.onTap,
  });

  final String label;
  final List<ChatMessage> messages;
  final String agentName;
  final String myName;
  final String activeTargetId;
  final ValueChanged<ChatMessage> onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: Color(0xFF9CA3AF),
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        ...messages.map(
          (m) => _MessageRow(
            message: m,
            agentName: agentName,
            myName: myName,
            selected: _messageTargetId(m) == activeTargetId,
            onTap: () => onTap(m),
          ),
        ),
      ],
    );
  }
}

String _messageTargetId(ChatMessage m) {
  if (m.uuid?.isNotEmpty == true) return m.uuid!;
  if (m.messageId?.isNotEmpty == true) return m.messageId!;
  return '';
}

class _MessageRow extends StatefulWidget {
  const _MessageRow({
    required this.message,
    required this.agentName,
    required this.myName,
    required this.selected,
    required this.onTap,
  });

  final ChatMessage message;
  final String agentName;
  final String myName;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_MessageRow> createState() => _MessageRowState();
}

class _MessageRowState extends State<_MessageRow> {
  bool _hover = false;
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  void _handleTap() {
    _setPressed(true);
    widget.onTap();
    Future<void>.delayed(const Duration(milliseconds: 180), () {
      _setPressed(false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final senderName = m.isQuestion ? widget.myName : widget.agentName;
    final time = m.createdAt ?? m.streamStartedAt;
    final timeText = _formatTime(time);
    final preview = _previewText(m);
    final highlighted = widget.selected || _pressed || _hover;
    final bgColor = widget.selected || _pressed
        ? const Color(0xFFEFF4FF)
        : (_hover ? const Color(0xFFF7F8FA) : Colors.transparent);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapDown: (_) => _setPressed(true),
        onTapCancel: () => _setPressed(false),
        onTap: _handleTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: highlighted ? BorderRadius.circular(10) : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 第一行: "{发送人}  {日期时间}" —— 整行小灰字,参考图2 微信样式。
              RichText(
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                text: TextSpan(
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF9CA3AF),
                    height: 1.2,
                  ),
                  children: [
                    TextSpan(text: senderName),
                    const TextSpan(text: '  '),
                    TextSpan(text: timeText),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                preview,
                style: const TextStyle(
                  fontSize: 15,
                  color: Color(0xFF1D2129),
                  height: 1.45,
                  fontWeight: FontWeight.w400,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime? t) {
    if (t == null) return '';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    final hm =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    if (day == today) return hm;
    final yest = today.subtract(const Duration(days: 1));
    if (day == yest) return '昨天 $hm';
    // 同年省略年份,与图 2 "5/11 17:12" 一致。
    if (t.year == now.year) return '${t.month}/${t.day} $hm';
    return '${t.year}/${t.month}/${t.day} $hm';
  }

  String _previewText(ChatMessage m) {
    final text = m.content.trim();
    if (text.isNotEmpty) return text.replaceAll(RegExp(r'\s+'), ' ');
    if (m.files.isNotEmpty) {
      final imgs = m.files.where((f) => f.fileType == ChatFileType.image);
      final docs = m.files.where((f) => f.fileType == ChatFileType.file);
      if (imgs.isNotEmpty && docs.isEmpty) {
        return '[图片] ${imgs.length} 张';
      }
      if (docs.isNotEmpty && imgs.isEmpty) {
        return '[文件] ${docs.first.fileName}'
            '${docs.length > 1 ? "等 ${docs.length} 个" : ""}';
      }
      return '[附件] ${m.files.length} 个';
    }
    return '(空消息)';
  }
}

class _Empty extends StatelessWidget {
  const _Empty({this.text = '暂无聊天记录'});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 13,
            color: Color(0xFF9CA3AF)
          ),
        ),
      ),
    );
  }
}

/// 文件 / 图片与视频 tab 顶部的"发送人 / 类型 / 日期"筛选条。
/// 三个 chip 都接通了实际筛选逻辑——选中非"全部"时 chip 文案 + 颜色高亮变蓝。
class _FilterChips extends StatelessWidget {
  const _FilterChips({
    required this.showType,
    required this.senderFilter,
    required this.fileTypeFilter,
    required this.dateFilter,
    required this.agentName,
    required this.myName,
    required this.onSenderChanged,
    required this.onFileTypeChanged,
    required this.onDateChanged,
  });

  final bool showType;
  final _SenderFilter senderFilter;
  final _FileTypeFilter fileTypeFilter;
  final _DateFilter dateFilter;
  final String agentName;
  final String myName;
  final ValueChanged<_SenderFilter> onSenderChanged;
  final ValueChanged<_FileTypeFilter> onFileTypeChanged;
  final ValueChanged<_DateFilter> onDateChanged;

  @override
  Widget build(BuildContext context) {
    final senderLabel = switch (senderFilter) {
      _SenderFilter.all => '发送人',
      _SenderFilter.me => myName,
      _SenderFilter.agent => agentName,
    };
    final fileTypeLabel = switch (fileTypeFilter) {
      _FileTypeFilter.all => '类型',
      _FileTypeFilter.pdf => 'PDF',
      _FileTypeFilter.word => 'Word',
      _FileTypeFilter.excel => 'Excel',
      _FileTypeFilter.ppt => 'PPT',
      _FileTypeFilter.archive => '压缩包',
      _FileTypeFilter.other => '其它',
    };
    final dateLabel = switch (dateFilter) {
      _DateFilter.all => '日期',
      _DateFilter.today => '今天',
      _DateFilter.yesterday => '昨天',
      _DateFilter.last7Days => '近 7 天',
      _DateFilter.last30Days => '近 30 天',
    };

    final children = <Widget>[
      _FilterChip<_SenderFilter>(
        label: senderLabel,
        active: senderFilter != _SenderFilter.all,
        value: senderFilter,
        options: [
          (_SenderFilter.all, '全部'),
          (_SenderFilter.me, myName),
          (_SenderFilter.agent, agentName),
        ],
        onSelected: onSenderChanged,
      ),
      if (showType) const _Sep(),
      if (showType)
        _FilterChip<_FileTypeFilter>(
          label: fileTypeLabel,
          active: fileTypeFilter != _FileTypeFilter.all,
          value: fileTypeFilter,
          options: const [
            (_FileTypeFilter.all, '全部'),
            (_FileTypeFilter.pdf, 'PDF'),
            (_FileTypeFilter.word, 'Word'),
            (_FileTypeFilter.excel, 'Excel'),
            (_FileTypeFilter.ppt, 'PPT'),
            (_FileTypeFilter.archive, '压缩包'),
            (_FileTypeFilter.other, '其它'),
          ],
          onSelected: onFileTypeChanged,
        ),
      const _Sep(),
      _FilterChip<_DateFilter>(
        label: dateLabel,
        active: dateFilter != _DateFilter.all,
        value: dateFilter,
        options: const [
          (_DateFilter.all, '全部'),
          (_DateFilter.today, '今天'),
          (_DateFilter.yesterday, '昨天'),
          (_DateFilter.last7Days, '近 7 天'),
          (_DateFilter.last30Days, '近 30 天'),
        ],
        onSelected: onDateChanged,
      ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      child: Row(children: children),
    );
  }
}

/// 单个可点击筛选 chip。点击弹下拉菜单，选中后回调 onSelected；
/// active=true（即 value 非「全部」）时文字与箭头染蓝、底色淡蓝。
class _FilterChip<T> extends StatefulWidget {
  const _FilterChip({
    required this.label,
    required this.active,
    required this.value,
    required this.options,
    required this.onSelected,
  });

  final String label;
  final bool active;
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onSelected;

  @override
  State<_FilterChip<T>> createState() => _FilterChipState<T>();
}

class _FilterChipState<T> extends State<_FilterChip<T>>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _turns;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      duration: const Duration(milliseconds: 160),
      vsync: this,
    );
    _turns = Tween<double>(begin: 0, end: 0.5).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut)
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fg =
        widget.active ? const Color(0xFF1E66F5) : const Color(0xFF86909C);

    return UiDropdownMenu<T>(
      menuWidth: 140,
      activeValue: widget.value,
      onExpandedChanged: (open) => open ? _ctrl.forward() : _ctrl.reverse(),
      items: [
        for (final opt in widget.options)
          UiDropdownMenuItem(value: opt.$1, label: opt.$2),
      ],
      onSelected: widget.onSelected,
      child: AbsorbPointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: widget.active ? const Color(0xFFE8F0FE) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 80),
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: fg,
                    fontWeight:
                        widget.active ? FontWeight.w500 : FontWeight.w400,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              RotationTransition(
                turns: _turns,
                child: Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 16,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Sep extends StatelessWidget {
  const _Sep();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 12,
      margin: const EdgeInsets.symmetric(horizontal: 10),
      color: const Color(0xFFE4E7EC),
    );
  }
}

/// 文件 tab 单行,样式参考图 1 微信版式:
/// 左 36 圆角浅蓝底文件类型 icon + 右两行(文件名加粗 + meta 小灰字)。
class _FileRow extends StatefulWidget {
  const _FileRow({
    required this.entry,
    required this.selected,
    required this.onTap,
  });
  final _AttachmentEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_FileRow> createState() => _FileRowState();
}

class _FileRowState extends State<_FileRow> {
  bool _hover = false;
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  void _handleTap() {
    _setPressed(false);
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final parts = <String>[e.sender];
    final size = _formatSize(e.file.sizeBytes);
    if (size.isNotEmpty) parts.add(size);
    parts.add(_formatDateShort(e.time));
    final meta = parts.join('  |  ');

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) {
        setState(() {
          _hover = false;
          _pressed = false;
        });
      },
      child: GestureDetector(
        onTapDown: (_) => _setPressed(true),
        onTapCancel: () => _setPressed(false),
        onTapUp: (_) => _setPressed(false),
        onTap: _handleTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: widget.selected || _pressed
                ? const Color(0xFFEFF4FF)
                : (_hover ? const Color(0xFFEFF4FE) : Colors.transparent),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              _FileTypeIcon(name: e.file.fileName),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      e.file.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF1D2129),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      meta,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF9CA3AF),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDateShort(DateTime t) {
    final now = DateTime.now();
    if (t.year == now.year) return '${t.month}/${t.day}';
    return '${t.year}/${t.month}/${t.day}';
  }

  String _formatSize(int n) {
    if (n <= 0) return '';
    const kb = 1 << 10;
    const mb = 1 << 20;
    const gb = 1 << 30;
    if (n >= gb) return '${(n / gb).toStringAsFixed(1)}GB';
    if (n >= mb) return '${(n / mb).toStringAsFixed(1)}MB';
    if (n >= kb) {
      final v = n / kb;
      return v >= 10
          ? '${v.toStringAsFixed(0)}KB'
          : '${v.toStringAsFixed(1)}KB';
    }
    return '${n}B';
  }
}

/// 36x36 圆角浅蓝底 + 白色文件类型字母 / Material 图标。
/// 不强求每种 mime 都对得上,只保证视觉上像"图1 那种蓝色 ZIP 图标"。
class _FileTypeIcon extends StatelessWidget {
  const _FileTypeIcon({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    final (icon, label, bg, fg) = _resolve(ext);
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: icon != null
          ? Icon(icon, size: 20, color: fg)
          : Text(
              label,
              style: TextStyle(
                color: fg,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
    );
  }

  // 返回 (IconData?, fallback文字, 背景, 前景)。
  (IconData?, String, Color, Color) _resolve(String ext) {
    const blueBg = Color(0xFFE6EEFE);
    const blue = Color(0xFF1E66F5);
    const greenBg = Color(0xFFE6F7EC);
    const green = Color(0xFF22C55E);
    const redBg = Color(0xFFFEE9EA);
    const red = Color(0xFFEF4444);
    const orangeBg = Color(0xFFFFF1E5);
    const orange = Color(0xFFF97316);
    const grayBg = Color(0xFFEFF1F5);
    const gray = Color(0xFF86909C);

    switch (ext) {
      case 'zip':
      case 'rar':
      case '7z':
      case 'tar':
      case 'gz':
        return (Icons.folder_zip_rounded, 'ZIP', blueBg, blue);
      case 'pdf':
        return (Icons.picture_as_pdf_rounded, 'PDF', redBg, red);
      case 'doc':
      case 'docx':
        return (null, 'W', blueBg, blue);
      case 'xls':
      case 'xlsx':
      case 'csv':
        return (null, 'X', greenBg, green);
      case 'ppt':
      case 'pptx':
        return (null, 'P', orangeBg, orange);
      case 'txt':
      case 'md':
      case 'log':
        return (Icons.description_outlined, 'TXT', grayBg, gray);
      case 'html':
      case 'htm':
        return (Icons.code_rounded, 'HTML', orangeBg, orange);
      case 'json':
      case 'xml':
      case 'yaml':
      case 'yml':
        return (Icons.data_object_rounded, 'JSON', blueBg, blue);
      case 'mp3':
      case 'wav':
      case 'm4a':
        return (Icons.audiotrack_rounded, 'AUDIO', orangeBg, orange);
      case 'mp4':
      case 'mov':
      case 'avi':
        return (Icons.movie_outlined, 'VIDEO', blueBg, blue);
      default:
        return (
          Icons.insert_drive_file_outlined,
          ext.toUpperCase(),
          grayBg,
          gray
        );
    }
  }
}

/// 图片与视频 tab 一个日期分组:中间是带横线的"5/11"小标题,下面 3 列瀑布缩略图。
class _MediaGroup extends StatelessWidget {
  const _MediaGroup({
    required this.label,
    required this.entries,
    required this.activeTargetId,
    required this.onTap,
  });

  final String label;
  final List<_AttachmentEntry> entries;
  final String activeTargetId;
  final ValueChanged<_AttachmentEntry> onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Divider(color: Color(0xFFEFF1F5), height: 1),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF86909C),
                  ),
                ),
              ),
              const Expanded(
                child: Divider(color: Color(0xFFEFF1F5), height: 1),
              ),
            ],
          ),
          const SizedBox(height: 10),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
            ),
            itemCount: entries.length,
            itemBuilder: (context, i) {
              final e = entries[i];
              return _MediaTile(
                entry: e,
                selected: _messageTargetId(e.message) == activeTargetId,
                onTap: () => onTap(e),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _MediaTile extends StatefulWidget {
  const _MediaTile({
    required this.entry,
    required this.selected,
    required this.onTap,
  });
  final _AttachmentEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_MediaTile> createState() => _MediaTileState();
}

class _MediaTileState extends State<_MediaTile> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  void _handleTap() {
    // 图片/视频历史项只负责定位消息;真正预览仍交给消息气泡里的附件组件。
    _setPressed(false);
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.entry.file.fileLink ?? '';
    final isVideo = widget.entry.file.fileType == ChatFileType.video;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: (_) => _setPressed(true),
        onTapCancel: () => _setPressed(false),
        onTapUp: (_) => _setPressed(false),
        onTap: _handleTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: widget.selected || _pressed
                ? const Color(0xFFEFF4FF)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: widget.selected
                ? Border.all(color: const Color(0xFF1E66F5), width: 2)
                : null,
          ),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    color: const Color(0xFFF4F5F7),
                    child: (url.isEmpty || isVideo)
                        // 视频暂时不渲染首帧——前端没接 video_thumbnailer,
                        // 显示一个深灰底 + 播放图标的预留,符合微信视频缩略图视觉。
                        ? Center(
                            child: Icon(
                              isVideo
                                  ? Icons.videocam_outlined
                                  : Icons.image_not_supported_outlined,
                              color: const Color(0xFFB5BAC1),
                              size: 26,
                            ),
                          )
                        : _AuthedThumb(url: url),
                  ),
                  if (isVideo)
                    const Positioned.fill(
                      child: ColoredBox(color: Color(0x33000000)),
                    ),
                  if (isVideo)
                    const Center(
                      child: Icon(
                        Icons.play_circle_fill_rounded,
                        color: Colors.white,
                        size: 32,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 带 Bearer auth 的缩略图加载器。
/// 「聊天历史·图片与视频」tab 里的图片可能是 assistant_output cmf 行——
/// `fileLink` 是 `/app/openclaw-drive/files/{uuid}/preview` 这种相对路径,
/// 直接 `Image.network` 没 baseUrl 也没 Authorization,必然 401/404。
class _AuthedThumb extends StatefulWidget {
  const _AuthedThumb({required this.url});
  final String url;

  @override
  State<_AuthedThumb> createState() => _AuthedThumbState();
}

class _AuthedThumbState extends State<_AuthedThumb> {
  late Future<Map<String, String>> _headersFuture;

  @override
  void initState() {
    super.initState();
    _headersFuture = apiImageLoadHeaders(widget.url);
  }

  @override
  Widget build(BuildContext context) {
    final absoluteUrl = apiImageResolveUrl(widget.url);
    return FutureBuilder<Map<String, String>>(
      future: _headersFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox.shrink();
        }
        return UiNetworkImage(
          imageUrl: absoluteUrl,
          httpHeaders: snap.data,
          cacheKey: absoluteUrl,
          fit: BoxFit.cover,
          clip: false,
          errorBuilder: (_, __, ___) => const Center(
            child: Icon(
              Icons.broken_image_outlined,
              color: Color(0xFFB5BAC1),
              size: 24,
            ),
          ),
        );
      },
    );
  }
}
