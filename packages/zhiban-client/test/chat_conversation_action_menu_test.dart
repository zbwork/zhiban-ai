import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/widgets/sidebar/chat_conversation_action_menu.dart';
import 'package:zhiban_client/pages/chat/widgets/sidebar/components/conversation_list_panel.dart';
import 'package:zhiban_core/contacts/contact_models.dart';

// F09 P2 「会话列表操作菜单 v2」 · 全量动作 + 飞书风 overlay 菜单。
// 见 docs/contracts/agent-bus-client-contract.md §「会话列表操作菜单 v2」。

ConversationItem _conv({
  int unread = 0,
  String id = 'c1',
  bool pinned = false,
  bool muted = false,
  bool markedUnread = false,
  String kind = 'human_direct',
  bool canRenameGroup = false,
}) =>
    ConversationItem(
      conversationId: id,
      title: '张三',
      agentId: '',
      agentName: '',
      unreadCount: unread,
      kind: kind,
      wukongChannelId: 'ch1',
      wukongChannelType: 2,
      pinned: pinned,
      muted: muted,
      markedUnread: markedUnread,
      canRenameGroup: canRenameGroup,
    );

ContactPerson _person({String name = '王聪', String id = 'u1'}) => ContactPerson(
      kind: 'human',
      id: id,
      displayName: name,
      avatarUrl: '',
      subtitle: '',
      positionLabel: '主管',
      departmentId: '',
      departmentName: '产品部',
      source: 'tenant',
      skills: const [],
      apps: const [],
      lifecycleStatus: '',
      canChat: true,
    );

void main() {
  group('availableConversationActions v2', () {
    test('默认: 含「置顶 / 免打扰 / 标为未读 / 删除会话」 (有未读时改成 标为已读)', () {
      final acts = availableConversationActions(_conv());
      final kinds = acts.map((a) => a.kind).toList();
      expect(kinds, contains(ConversationMenuActionKind.togglePin));
      expect(kinds, contains(ConversationMenuActionKind.toggleMute));
      expect(kinds, contains(ConversationMenuActionKind.markUnread));
      expect(kinds, isNot(contains(ConversationMenuActionKind.markRead)));
      expect(kinds, contains(ConversationMenuActionKind.hide));
      // human_direct 不含「修改群名」
      expect(kinds, isNot(contains(ConversationMenuActionKind.renameGroup)));
    });

    test('unread>0 → 出现「标为已读」, 隐藏「标为未读」', () {
      final acts = availableConversationActions(_conv(unread: 3));
      final kinds = acts.map((a) => a.kind).toList();
      expect(kinds, contains(ConversationMenuActionKind.markRead));
      expect(kinds, isNot(contains(ConversationMenuActionKind.markUnread)));
    });

    test('markedUnread=true 也算「已是未读」 → 隐藏「标为未读」, 露出「标为已读」', () {
      final acts = availableConversationActions(_conv(markedUnread: true));
      final kinds = acts.map((a) => a.kind).toList();
      expect(kinds, contains(ConversationMenuActionKind.markRead));
      expect(kinds, isNot(contains(ConversationMenuActionKind.markUnread)));
    });

    test('pinned 状态切换 label', () {
      final unpinned = availableConversationActions(_conv())
          .firstWhere((a) => a.kind == ConversationMenuActionKind.togglePin);
      expect(unpinned.label, '置顶');
      final pinned = availableConversationActions(_conv(pinned: true))
          .firstWhere((a) => a.kind == ConversationMenuActionKind.togglePin);
      expect(pinned.label, '取消置顶');
    });

    test('muted 状态切换 label', () {
      final unm = availableConversationActions(_conv())
          .firstWhere((a) => a.kind == ConversationMenuActionKind.toggleMute);
      expect(unm.label, '消息免打扰');
      final m = availableConversationActions(_conv(muted: true))
          .firstWhere((a) => a.kind == ConversationMenuActionKind.toggleMute);
      expect(m.label, '取消免打扰');
    });

    test('仅有改名 capability 的 group 显示「修改群名」', () {
      final owner = availableConversationActions(
        _conv(kind: 'group', canRenameGroup: true),
      );
      expect(owner.any((a) => a.kind == ConversationMenuActionKind.renameGroup),
          isTrue);
      final member = availableConversationActions(_conv(kind: 'group'));
      expect(
          member.any((a) => a.kind == ConversationMenuActionKind.renameGroup),
          isFalse);
    });

    test('删除会话 = 危险项 (danger)', () {
      final hide = availableConversationActions(_conv())
          .firstWhere((a) => a.kind == ConversationMenuActionKind.hide);
      expect(hide.danger, isTrue);
    });
  });

  // CR5: resolveConversationMenuActions 按 callbacks 过滤。
  group('resolveConversationMenuActions (CR5 按 callbacks 过滤)', () {
    test('callbacks.isEmpty → 返回空 list', () {
      final out = resolveConversationMenuActions(
          _conv(), const ConversationMenuCallbacks());
      expect(out, isEmpty);
    });
    test('只注入 onTogglePin → 只剩置顶项', () {
      final out = resolveConversationMenuActions(
        _conv(),
        ConversationMenuCallbacks(onTogglePin: (_) {}),
      );
      expect(out.length, 1);
      expect(out.single.kind, ConversationMenuActionKind.togglePin);
    });
    test('注入 pin + mute + hide → 仅这三项 (顺序保留: pin / mute / hide)', () {
      final out = resolveConversationMenuActions(
        _conv(),
        ConversationMenuCallbacks(
          onTogglePin: (_) {},
          onToggleMute: (_) {},
          onHide: (_) {},
        ),
      );
      final kinds = out.map((a) => a.kind).toList();
      expect(kinds, [
        ConversationMenuActionKind.togglePin,
        ConversationMenuActionKind.toggleMute,
        ConversationMenuActionKind.hide,
      ]);
    });
    test('group 项 + onRenameGroup=null → 菜单不出现「修改群名」', () {
      final out = resolveConversationMenuActions(
        _conv(kind: 'group', canRenameGroup: true),
        ConversationMenuCallbacks(
          onTogglePin: (_) {},
          onHide: (_) {}
        ),
      );
      expect(out.any((a) => a.kind == ConversationMenuActionKind.renameGroup),
          isFalse);
    });
    test('group 项 + onRenameGroup 注入 → 「修改群名」出现', () {
      final out = resolveConversationMenuActions(
        _conv(kind: 'group', canRenameGroup: true),
        ConversationMenuCallbacks(
          onTogglePin: (_) {},
          onRenameGroup: (_) {},
          onHide: (_) {},
        ),
      );
      expect(out.any((a) => a.kind == ConversationMenuActionKind.renameGroup),
          isTrue);
    });
  });

  group('ConversationActionRegion widget (v2)', () {
    Widget host(
      ConversationItem item, {
      required ConversationMenuCallbacks callbacks,
      VoidCallback? onTap,
    }) =>
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ConversationActionRegion(
                item: item,
                callbacks: callbacks,
                child: GestureDetector(
                  onTap: onTap,
                  child: Container(
                      width: 200, height: 56, color: const Color(0xFFEFEFEF)),
                ),
              ),
            ),
          ),
        );

    testWidgets('右键 → 弹出至少含「置顶 / 消息免打扰 / 删除会话」', (tester) async {
      await tester.pumpWidget(host(
        _conv(),
        callbacks: ConversationMenuCallbacks(
          onTogglePin: (_) {},
          onToggleMute: (_) {},
          onMarkRead: (_) {},
          onMarkUnread: (_) {},
          onHide: (_) {},
        ),
      ));
      await tester.tap(find.byType(ConversationActionRegion),
          buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('置顶'), findsOneWidget);
      expect(find.text('消息免打扰'), findsOneWidget);
      expect(find.text('删除会话'), findsOneWidget);
    });

    testWidgets('点「置顶」→ onTogglePin 调用一次(带该会话)', (tester) async {
      ConversationItem? pinned;
      await tester.pumpWidget(host(
        _conv(id: 'cX'),
        callbacks: ConversationMenuCallbacks(
          onTogglePin: (c) => pinned = c),
        ),
      );
      await tester.tap(find.byType(ConversationActionRegion),
          buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('置顶'));
      await tester.pumpAndSettle();
      expect(pinned, isNotNull);
      expect(pinned!.conversationId, 'cX');
    });

    testWidgets('长按不再打开完整菜单', (tester) async {
      await tester.pumpWidget(host(
        _conv(),
        callbacks: ConversationMenuCallbacks(onTogglePin: (_) {}),
      ));

      await tester.longPress(find.byType(ConversationActionRegion));
      await tester.pumpAndSettle();

      expect(find.text('置顶'), findsNothing);
    });

    testWidgets('callbacks.isEmpty → 右键 / 长按都不弹菜单', (tester) async {
      await tester.pumpWidget(host(
        _conv(),
        callbacks: const ConversationMenuCallbacks()),
      );
      await tester.tap(find.byType(ConversationActionRegion),
          buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('置顶'), findsNothing);
      await tester.longPress(find.byType(ConversationActionRegion));
      await tester.pumpAndSettle();
      expect(find.text('置顶'), findsNothing);
    });

    testWidgets('左键正常点击不被吞 (primary tap 仍触发 child onTap)', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(host(
        _conv(),
        callbacks: ConversationMenuCallbacks(onTogglePin: (_) {}),
        onTap: () => tapped++,
      ));
      await tester.tap(find.byType(ConversationActionRegion));
      await tester.pumpAndSettle();
      expect(tapped, 1);
      expect(find.text('置顶'), findsNothing); // 左键不弹菜单
    });

    testWidgets('菜单已打开时右键另一个会话 → 关闭旧菜单并打开新菜单', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ConversationActionRegion(
                item: _conv(id: 'c1'),
                callbacks: ConversationMenuCallbacks(
                  onTogglePin: (_) {},
                  onToggleMute: (_) {},
                  onMarkUnread: (_) {},
                  onHide: (_) {},
                  onRenameGroup: (_) {},
                ),
                child: Container(
                  key: const ValueKey('region-c1'),
                  width: 220,
                  height: 56,
                  color: const Color(0xFFEFEFEF),
                ),
              ),
              ConversationActionRegion(
                item: _conv(
                  id: 'c2',
                  kind: 'group',
                  canRenameGroup: true
                ),
                callbacks: ConversationMenuCallbacks(
                  onTogglePin: (_) {},
                  onToggleMute: (_) {},
                  onMarkUnread: (_) {},
                  onHide: (_) {},
                  onRenameGroup: (_) {},
                ),
                child: Container(
                  key: const ValueKey('region-c2'),
                  width: 220,
                  height: 56,
                  color: const Color(0xFFEFEFEF),
                ),
              ),
            ],
          ),
        ),
      ));

      await tester.tap(find.byKey(const ValueKey('region-c1')),
          buttons: kSecondaryButton);
      await tester.pump();
      expect(find.text('置顶'), findsOneWidget);
      expect(find.text('修改群名'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('region-c2')),
          buttons: kSecondaryButton);
      await tester.pump();
      expect(find.text('置顶'), findsOneWidget);
      expect(find.text('修改群名'), findsOneWidget);
    });
  });

  group('mobile conversation swipe actions', () {
    Widget host(
      ConversationItem item, {
      required ConversationMenuCallbacks callbacks,
      ValueChanged<ConversationItem>? onSelected,
    }) {
      return ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                SizedBox(
                  width: 320,
                  height: 120,
                  child: ConversationListPanel(
                    selectedConversationId: null,
                    conversations: [item],
                    loadingConversations: false,
                    onConversationSelected: onSelected ?? (_) {},
                    menuCallbacks: callbacks,
                    mobileSwipeActions: true,
                  ),
                ),
                GestureDetector(
                  key: ValueKey('mobile-swipe-outside'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: const SizedBox(width: 320, height: 40),
                ),
              ],
            ),
          ),
        ),
      );
    }

    testWidgets('left swipe exposes mark-unread and delete actions',
        (tester) async {
      ConversationItem? markedUnread;
      await tester.pumpWidget(
        host(
          _conv(id: 'mobile-read'),
          callbacks: ConversationMenuCallbacks(
            onMarkUnread: (item) => markedUnread = item,
            onHide: (_) {},
          ),
        ),
      );

      await tester.drag(
        find.byKey(const ValueKey('conversation-tile-mobile-read')),
        const Offset(-180, 0),
      );
      await tester.pumpAndSettle();

      expect(tester.widget<AnimatedSlide>(find.byType(AnimatedSlide)).offset.dx,
          lessThan(0));
      expect(
        find.byKey(const ValueKey('conversation-swipe-unread-mobile-read')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('conversation-swipe-delete-mobile-read')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('conversation-swipe-unread-mobile-read')),
      );
      await tester.pumpAndSettle();

      expect(markedUnread?.conversationId, 'mobile-read');
      expect(tester.widget<AnimatedSlide>(find.byType(AnimatedSlide)).offset.dx,
          0);
    });

    testWidgets('mobile conversation row uses the Figma list geometry',
        (tester) async {
      await tester.pumpWidget(
        host(
          _conv(id: 'mobile-geometry'),
          callbacks: const ConversationMenuCallbacks(),
        ),
      );

      final tile = tester.widget<Container>(
        find.byKey(const ValueKey('conversation-tile-mobile-geometry')),
      );
      final title = tester.widget<Text>(find.text('张三'));
      final divider = tester.widget<Divider>(find.byType(Divider));
      final avatar = find.descendant(
        of: find.byKey(
          const ValueKey('conversation-tile-mobile-geometry')
        ),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is SizedBox && widget.width == 44 && widget.height == 44,
        ),
      );

      expect(
        tile.padding,
        const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
      );
      expect(
        tester
            .getSize(
              find.byKey(const ValueKey('conversation-tile-mobile-geometry')),
            )
            .height,
        72,
      );
      expect((tile.decoration! as BoxDecoration).border, isNull);
      expect(title.style?.fontSize, 16);
      expect(title.style?.fontWeight, FontWeight.w600);
      expect(title.style?.color, const Color(0xFF333333));
      expect(avatar, findsOneWidget);
      expect(divider.thickness, 0.5);
      expect(divider.indent, 69);
      expect(divider.endIndent, 15);
    });

    testWidgets('unread row exposes delete only', (tester) async {
      ConversationItem? deleted;
      await tester.pumpWidget(
        host(
          _conv(id: 'mobile-unread', unread: 2),
          callbacks: ConversationMenuCallbacks(
            onMarkUnread: (_) {},
            onHide: (item) => deleted = item,
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('conversation-swipe-unread-mobile-unread')),
        findsNothing,
      );

      await tester.drag(
        find.byKey(const ValueKey('conversation-tile-mobile-unread')),
        const Offset(-120, 0),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('conversation-swipe-delete-mobile-unread')),
      );

      expect(deleted?.conversationId, 'mobile-unread');
    });

    testWidgets('delete action uses the specified red color', (tester) async {
      await tester.pumpWidget(
        host(
          _conv(id: 'mobile-delete-color'),
          callbacks: ConversationMenuCallbacks(onHide: (_) {}),
        ),
      );

      final actionFinder = find.byKey(
        const ValueKey('conversation-swipe-delete-mobile-delete-color'),
      );
      final button = tester.widget<TextButton>(
        find.descendant(of: actionFinder, matching: find.byType(TextButton)),
      );

      expect(
        button.style?.backgroundColor?.resolve(<WidgetState>{}),
        const Color(0xFFE40014),
      );
    });

    testWidgets('tap outside closes an open swipe row', (tester) async {
      await tester.pumpWidget(
        host(
          _conv(id: 'mobile-close'),
          callbacks: ConversationMenuCallbacks(
            onMarkUnread: (_) {},
            onHide: (_) {},
          ),
        ),
      );

      await tester.drag(
        find.byKey(const ValueKey('conversation-tile-mobile-close')),
        const Offset(-180, 0),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<AnimatedSlide>(find.byType(AnimatedSlide)).offset.dx,
        lessThan(0),
      );

      await tester.tap(find.byKey(const ValueKey('mobile-swipe-outside')));
      await tester.pumpAndSettle();

      expect(
        tester.widget<AnimatedSlide>(find.byType(AnimatedSlide)).offset.dx,
        0,
      );
    });

    testWidgets('long press no longer opens full menu and tap still selects',
        (tester) async {
      ConversationItem? selected;
      await tester.pumpWidget(
        host(
          _conv(id: 'mobile-tap'),
          callbacks: ConversationMenuCallbacks(
            onTogglePin: (_) {},
            onToggleMute: (_) {},
            onMarkRead: (_) {},
            onMarkUnread: (_) {},
            onHide: (_) {},
            onRenameGroup: (_) {},
          ),
          onSelected: (item) => selected = item,
        ),
      );

      expect(find.byType(ConversationActionRegion), findsNothing);
      await tester.longPress(
        find.byKey(const ValueKey('conversation-tile-mobile-tap')),
      );
      await tester.pumpAndSettle();
      expect(find.text('置顶'), findsNothing);
      expect(find.text('消息免打扰'), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey('conversation-tile-mobile-tap')),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(selected?.conversationId, 'mobile-tap');
    });
  });

  group('ConversationListPanel context menu highlight', () {
    testWidgets('当前选中会话不显示未读数字', (tester) async {
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 220,
              child: ConversationListPanel(
                selectedConversationId: 'c1',
                conversations: [
                  _conv(id: 'c1', unread: 7),
                  _conv(id: 'c2', unread: 4),
                ],
                loadingConversations: false,
                onConversationSelected: (_) {},
                menuCallbacks: const ConversationMenuCallbacks(),
              ),
            ),
          ),
        ),
      ));

      expect(find.text('7'), findsNothing);
      expect(find.text('4'), findsOneWidget);
    });

    testWidgets('右键非当前会话 → 目标行蓝色描边, 不切换真实选中', (tester) async {
      ConversationItem? selected;
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 260,
              child: ConversationListPanel(
                selectedConversationId: 'c1',
                conversations: [
                  _conv(id: 'c1'),
                  _conv(id: 'c2', kind: 'group', canRenameGroup: true),
                ],
                loadingConversations: false,
                onConversationSelected: (item) => selected = item,
                menuCallbacks: ConversationMenuCallbacks(
                  onTogglePin: (_) {},
                  onToggleMute: (_) {},
                  onMarkUnread: (_) {},
                  onHide: (_) {},
                  onRenameGroup: (_) {},
                ),
              ),
            ),
          ),
        ),
      ));

      await tester.tap(find.byKey(const ValueKey('conversation-tile-c2')),
          buttons: kSecondaryButton);
      await tester.pump();

      final tile = tester.widget<Container>(
          find.byKey(const ValueKey('conversation-tile-c2')));
      final decoration = tile.decoration as BoxDecoration;
      expect(decoration.border, isNotNull);
      expect(selected, isNull);
      expect(find.text('修改群名'), findsOneWidget);
    });

    testWidgets('搜索结果分组展示联系人、数字员工和群聊结果', (tester) async {
      ContactPerson? selectedContact;
      ConversationItem? selectedConversation;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            height: 420,
            child: ConversationSearchResults(
              contacts: AsyncValue.data([_person()]),
              digitalEmployees: [
                _conv(id: 'a1', kind: 'agent_direct')
                    .copyForTest(title: '知办客服', lastMessage: '您好'),
              ],
              groups: [
                _conv(id: 'g1', kind: 'group')
                    .copyForTest(title: '王聪项目群', lastMessage: '日报同步'),
              ],
              onContactSelected: (person) => selectedContact = person,
              onConversationSelected: (item) => selectedConversation = item,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('联系人'), findsOneWidget);
      expect(find.text('王聪'), findsOneWidget);
      expect(find.text('产品部 / 主管'), findsOneWidget);
      expect(find.text('数字员工'), findsOneWidget);
      expect(find.text('知办客服'), findsOneWidget);
      expect(find.text('群聊'), findsOneWidget);
      expect(find.text('王聪项目群'), findsOneWidget);

      await tester.tap(find.text('王聪').first);
      await tester.pumpAndSettle();
      expect(selectedContact?.id, 'u1');

      await tester.tap(find.text('知办客服'));
      await tester.pumpAndSettle();
      expect(selectedConversation?.conversationId, 'a1');

      await tester.tap(find.text('王聪项目群'));
      await tester.pumpAndSettle();
      expect(selectedConversation?.conversationId, 'g1');
    });

    test('数字员工搜索只匹配会话名称', () {
      final byName = _conv(id: 'a1', kind: 'agent_direct')
          .copyForTest(title: '知办客服', lastMessage: '欢迎使用');
      final byMessage = _conv(id: 'a2', kind: 'agent_direct')
          .copyForTest(title: '行政助手', lastMessage: '知办客服');
      final legacy = _conv(id: 'a3', kind: 'single').copyForTest(title: '知办客服');
      final human = _conv(id: 'h1').copyForTest(title: '知办客服');

      expect(
        digitalEmployeeConversationMatchesKeyword(byName, '知办客服'),
        isTrue
      );
      expect(
        digitalEmployeeConversationMatchesKeyword(byMessage, '知办客服'),
        isFalse,
      );
      expect(
        digitalEmployeeConversationMatchesKeyword(legacy, '知办客服'),
        isTrue
      );
      expect(
        digitalEmployeeConversationMatchesKeyword(human, '知办客服'),
        isFalse
      );
    });
  });
}

extension on ConversationItem {
  ConversationItem copyForTest({
    String? title,
    String? lastMessage
  }) {
    return ConversationItem(
      conversationId: conversationId,
      title: title ?? this.title,
      agentId: agentId,
      agentName: agentName,
      agentAvatarUrl: agentAvatarUrl,
      lastMessage: lastMessage ?? this.lastMessage,
      unreadCount: unreadCount,
      kind: kind,
      wukongChannelId: wukongChannelId,
      wukongChannelType: wukongChannelType,
      participants: participants,
      pinned: pinned,
      muted: muted,
      markedUnread: markedUnread,
    );
  }
}
