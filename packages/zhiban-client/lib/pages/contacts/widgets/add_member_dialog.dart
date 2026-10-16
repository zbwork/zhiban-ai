import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/pages/contacts/member_invite_api.dart';
import 'package:zhiban_client/pages/contacts/member_invite_poster.dart';
import 'package:zhiban_client/services/account_info_api.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:zhiban_client/widgets/ui/ui_page_bar.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// F28 添加企业成员：企业二维码 / 企业链接 / 手机号 三 tab。
/// 桌面端 [showAddMemberDialog]（Dialog），移动端 [AddMemberPage]（全屏页）。
/// 设计权威 docs/features/F28-member-invitation.md §1.2 / §6.2。

Future<void> showAddMemberDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const UiDialogShell(
      size: UiDialogSize.standard,
      maxHeight: 720,
      child: AddMemberContent(),
    ),
  );
}

/// 移动端全屏页（rule 10：移动端子流程用全屏页面）。
class AddMemberPage extends StatelessWidget {
  const AddMemberPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor:
          UiFormStyle.pageBackground(Theme.of(context).colorScheme),
      appBar: const UiPageBar(title: '添加企业成员'),
      body: const SafeArea(
        bottom: false,
        child: AddMemberContent(showHeader: false, compact: true),
      ),
    );
  }
}

enum _AddMemberTab { qrcode, link, phone }

enum _QrImageAction { save, copy }

class AddMemberContent extends ConsumerStatefulWidget {
  const AddMemberContent(
      {super.key, this.showHeader = true, this.compact = false});

  final bool showHeader;
  final bool compact;

  @override
  ConsumerState<AddMemberContent> createState() => _AddMemberContentState();
}

class _PhoneRow {
  _PhoneRow()
      : phone = TextEditingController(),
        name = TextEditingController(),
        phoneFocus = FocusNode(),
        nameFocus = FocusNode();

  final TextEditingController phone;
  final TextEditingController name;
  final FocusNode phoneFocus;
  final FocusNode nameFocus;
  String? resultError; // 发送后逐条回填的失败原因（null=未发/成功行已移除）

  void dispose() {
    phone.dispose();
    name.dispose();
    phoneFocus.dispose();
    nameFocus.dispose();
  }
}

class _AddMemberContentState extends ConsumerState<AddMemberContent> {
  _AddMemberTab _tab = _AddMemberTab.qrcode;
  final List<_PhoneRow> _rows = [_PhoneRow(), _PhoneRow()];
  bool _sending = false;
  bool _resetting = false;
  _QrImageAction? _qrImageAction;

  static final _phoneRe = RegExp(r'^1\d{10}$');

  /// 与后端 dom.MaxAddByPhoneItems 一致：超出整个请求会 400，UI 在达到上限时禁用继续添加。
  static const _maxRows = 20;

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: widget.compact ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.showHeader)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 0),
            child: UiSheetHeader(
              title: '添加企业成员',
              subtitle: '“企业成员”是你在企业、部门或组织内的同事',
              onClose: () => Navigator.of(context).pop(),
            ),
          ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
            child: UiUnderlineTabs<_AddMemberTab>(
              current: _tab,
              onChanged: (v) => setState(() => _tab = v),
              fontSize: 14.5,
              activeColor: Theme.of(context).colorScheme.primary,
              inactiveColor: Theme.of(context).colorScheme.onSurfaceVariant,
              tabs: const [
                UiUnderlineTab(value: _AddMemberTab.qrcode, label: '企业二维码'),
                UiUnderlineTab(value: _AddMemberTab.link, label: '企业链接'),
                UiUnderlineTab(value: _AddMemberTab.phone, label: '手机号'),
              ],
            ),
          ),
        ),
        Flexible(
          fit: widget.compact ? FlexFit.tight : FlexFit.loose,
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: widget.compact
                ? const EdgeInsets.all(16)
                : const EdgeInsets.fromLTRB(24, 20, 24, 24),
            child: switch (_tab) {
              _AddMemberTab.qrcode => _buildLinkTab(qr: true),
              _AddMemberTab.link => _buildLinkTab(qr: false),
              _AddMemberTab.phone => _buildPhoneTab(),
            },
          ),
        ),
        if (widget.compact && _tab == _AddMemberTab.phone)
          UiFormFooter(
              child: UiFormActions(
            primaryLabel: '发送',
            onPrimary: !_sending && _validRows().isNotEmpty ? _send : null,
            secondaryLabel: '取消',
            onSecondary: () => Navigator.of(context).maybePop(),
            busy: _sending,
          )),
      ],
    );
  }

  // ===== 企业二维码 / 企业链接（共用同一 token）=====

  Widget _buildLinkTab({required bool qr}) {
    final linkAsync = ref.watch(memberInviteLinkProvider);
    return linkAsync.when(
      data: (link) => _linkCard(link, qr: qr),
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 80),
        child: Center(child: CupertinoActivityIndicator()),
      ),
      error: (error, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 60),
        child: Center(
          child: Column(
            children: [
              Text('加载失败：$error',
                  style:
                      const TextStyle(fontSize: 13, color: Color(0xFF86909C))),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => ref.invalidate(memberInviteLinkProvider),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _linkCard(MemberInviteLink link, {required bool qr}) {
    final scheme = Theme.of(context).colorScheme;
    final expiresLabel = link.expiresAt == null
        ? ''
        : '${link.expiresAt!.toLocal().year}年${link.expiresAt!.toLocal().month}月${link.expiresAt!.toLocal().day}日';
    return Container(
      width: double.infinity,
      padding: widget.compact
          ? const EdgeInsets.all(16)
          : const EdgeInsets.fromLTRB(24, 28, 24, 20),
      decoration: BoxDecoration(
        color: widget.compact ? scheme.surface : null,
        gradient: widget.compact
            ? null
            : const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFF4F8FF), Color(0xFFFBFCFF)],
              ),
        border: Border.all(color: UiFieldStyle.enabledBorderColor(scheme)),
        borderRadius: BorderRadius.circular(widget.compact ? 16 : 12),
      ),
      child: Column(
        children: [
          Text(
            '仅支持区号为 +86 的手机号加入以下企业',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Text(
            link.tenantName,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 20),
          if (qr)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200),
              child: AspectRatio(
                aspectRatio: 1,
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(
                        color: UiFieldStyle.enabledBorderColor(scheme)),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: QrImageView(
                      data: link.url,
                      version: QrVersions.auto,
                      padding: EdgeInsets.zero),
                ),
              ),
            )
          else
            Container(
              key: const ValueKey('member-invite-link-message'),
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Color.alphaBlend(
                  scheme.onSurface.withValues(alpha: 0.055),
                  scheme.surface,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                '邀请你加入${link.tenantName}，区号为 +86 的手机号可通过此链接\n${link.url}',
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.7,
                  color: scheme.onSurface,
                ),
              ),
            ),
          const SizedBox(height: 18),
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              if (expiresLabel.isNotEmpty)
                Text(
                  '${qr ? '二维码' : '链接'}失效时间：$expiresLabel',
                  style:
                      const TextStyle(fontSize: 12.5, color: Color(0xFF86909C)),
                ),
              InkWell(
                onTap: _resetting ? null : _confirmReset,
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _resetting
                          ? const CupertinoActivityIndicator(radius: 7)
                          : Icon(CupertinoIcons.refresh,
                              size: 13, color: scheme.primary),
                      const SizedBox(width: 4),
                      Text('重置',
                          style:
                              TextStyle(fontSize: 12.5, color: scheme.primary)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (qr)
            _buildQrImageActions(link)
          else if (widget.compact)
            UiFormActions(
                primaryLabel: '复制链接', onPrimary: () => _copyLink(link))
          else
            Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                height: 38,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2F80ED),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  onPressed: () => _copyLink(link),
                  child: const Text('复制链接',
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildQrImageActions(MemberInviteLink link) {
    final busy = _qrImageAction != null;
    if (widget.compact) {
      return UiFormActions(
        primaryLabel: '复制二维码',
        onPrimary: () => _copyQrPoster(link),
        secondaryLabel: '保存二维码',
        onSecondary: () => _saveQrPoster(link),
        busy: busy,
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        SizedBox(
          height: 38,
          child: OutlinedButton(
            onPressed: busy ? null : () => _saveQrPoster(link),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF1D2129),
              side: const BorderSide(color: Color(0xFFD0D5DD)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            child: _qrImageAction == _QrImageAction.save
                ? const SizedBox(
                    width: 17,
                    height: 17,
                    child: CupertinoActivityIndicator(radius: 8),
                  )
                : const Text('保存二维码',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          height: 38,
          child: FilledButton(
            onPressed: busy ? null : () => _copyQrPoster(link),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF2F80ED),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            child: _qrImageAction == _QrImageAction.copy
                ? const SizedBox(
                    width: 17,
                    height: 17,
                    child: CupertinoActivityIndicator(
                      radius: 8,
                      color: Colors.white,
                    ),
                  )
                : const Text('复制二维码',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
        ),
      ],
    );
  }

  Future<void> _copyQrPoster(MemberInviteLink link) async {
    if (_qrImageAction != null) return;
    setState(() => _qrImageAction = _QrImageAction.copy);
    try {
      final bytes = await _renderQrPoster(link);
      await copyMemberInvitePoster(bytes);
      BotToast.showText(text: '二维码图片已复制');
    } catch (error) {
      debugPrint('[member-invite] copy poster failed: $error');
      BotToast.showText(text: '复制二维码失败，请稍后再试');
    } finally {
      if (mounted) setState(() => _qrImageAction = null);
    }
  }

  Future<void> _saveQrPoster(MemberInviteLink link) async {
    if (_qrImageAction != null) return;
    setState(() => _qrImageAction = _QrImageAction.save);
    try {
      final bytes = await _renderQrPoster(link);
      final path = await saveMemberInvitePoster(
        bytes,
        tenantName: link.tenantName,
      );
      if (path != null) BotToast.showText(text: '二维码图片已保存');
    } catch (error) {
      debugPrint('[member-invite] save poster failed: $error');
      BotToast.showText(text: '保存二维码失败，请稍后再试');
    } finally {
      if (mounted) setState(() => _qrImageAction = null);
    }
  }

  Future<Uint8List> _renderQrPoster(MemberInviteLink link) async {
    final account = await AccountInfoService().getCachedAccountInfo();
    final inviterName = [account?.nickname, account?.name, account?.accountNo]
        .whereType<String>()
        .map((value) => value.trim())
        .firstWhere((value) => value.isNotEmpty, orElse: () => '企业管理员');
    return renderMemberInvitePoster(MemberInvitePosterSpec(
      url: link.url,
      tenantName: link.tenantName,
      inviterName: inviterName,
      expiresAt: link.expiresAt,
    ));
  }

  Future<void> _copyLink(MemberInviteLink link) async {
    await Clipboard.setData(ClipboardData(
      text: '邀请你加入${link.tenantName}，区号为 +86 的手机号可通过此链接 ${link.url}',
    ));
    BotToast.showText(text: '已复制邀请链接');
  }

  Future<void> _confirmReset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重置邀请'),
        content: const Text('重置后，原企业二维码和企业链接将立即失效，确定重置吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('重置'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _resetting = true);
    try {
      await ref.read(memberInviteServiceProvider).resetLink();
      ref.invalidate(memberInviteLinkProvider);
      BotToast.showText(text: '已重置，原二维码/链接已失效');
    } catch (_) {
      BotToast.showText(text: '重置失败，请稍后再试');
    } finally {
      if (mounted) setState(() => _resetting = false);
    }
  }

  // ===== 手机号定向邀请 =====

  Widget _buildPhoneTab() {
    final scheme = Theme.of(context).colorScheme;
    final canSend = !_sending && _validRows().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '输入手机号发送企业邀请。对方接受后才会成为企业成员',
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 16),
        for (var i = 0; i < _rows.length; i++) ...[
          widget.compact ? _mobilePhoneCard(i) : _phoneRowField(i),
          if (_rows[i].resultError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: Text(
                _rows[i].resultError!,
                style: const TextStyle(fontSize: 12, color: Color(0xFFD4453C)),
              ),
            ),
          const SizedBox(height: 10),
        ],
        Builder(builder: (context) {
          final atCap = _rows.length >= _maxRows;
          final disabledColor = const Color(0xFF9AA1AE);
          return InkWell(
            onTap: _sending || atCap
                ? null
                : () => setState(() => _rows.add(_PhoneRow())),
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(CupertinoIcons.add,
                      size: 14, color: atCap ? disabledColor : scheme.primary),
                  const SizedBox(width: 5),
                  Text(atCap ? '一次最多添加 $_maxRows 人' : '继续添加',
                      style: TextStyle(
                          fontSize: 13.5,
                          color: atCap ? disabledColor : scheme.primary)),
                ],
              ),
            ),
          );
        }),
        if (!widget.compact) ...[
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              SizedBox(
                height: 38,
                child: OutlinedButton(
                  onPressed:
                      _sending ? null : () => Navigator.of(context).maybePop(),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: scheme.onSurface,
                    side: BorderSide(
                      color: UiFieldStyle.enabledBorderColor(scheme),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  child: const Text('取消',
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                height: 38,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2F80ED),
                    disabledBackgroundColor: const Color(0xFFE5E7EB),
                    foregroundColor: Colors.white,
                    disabledForegroundColor: const Color(0xFF9CA3AF),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  onPressed: canSend ? _send : null,
                  child: _sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child:
                              CupertinoActivityIndicator(color: Colors.white),
                        )
                      : const Text('发送',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _mobilePhoneCard(int index) {
    final row = _rows[index];
    final scheme = Theme.of(context).colorScheme;
    return UiFormSection(
      key: ValueKey('member-invite-mobile-row-$index'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
                child: Text('成员 ${index + 1}',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface))),
            UiIconButton(
                icon: CupertinoIcons.xmark,
                tooltip: '删除',
                enabled: !_sending && _rows.length > 1,
                onTap: () => setState(() => _rows.removeAt(index).dispose())),
          ]),
          const SizedBox(height: 12),
          UiInputField(
            label: '手机号',
            controller: row.phone,
            focusNode: row.phoneFocus,
            hintText: '输入手机号',
            prefixIcon: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('+86',
                  style:
                      TextStyle(fontSize: 14, color: scheme.onSurfaceVariant)),
            ),
            keyboardType: TextInputType.phone,
            maxLength: 11,
            onChanged: (_) => setState(() => row.resultError = null),
          ),
          const SizedBox(height: 16),
          UiInputField(
            label: '姓名',
            controller: row.name,
            focusNode: row.nameFocus,
            hintText: '请输入姓名',
            maxLength: 80,
            onChanged: (_) => setState(() => row.resultError = null),
          ),
        ],
      ),
    );
  }

  Widget _phoneRowField(int index) {
    final row = _rows[index];
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([row.phoneFocus, row.nameFocus]),
      builder: (context, _) {
        final focused = row.phoneFocus.hasFocus || row.nameFocus.hasFocus;
        final hasError = row.resultError != null;
        final borderColor = hasError
            ? UiFieldStyle.errorBorderColor(scheme)
            : focused
                ? UiFieldStyle.focusBorderColor(scheme)
                : UiFieldStyle.enabledBorderColor(scheme);
        return Row(
          children: [
            Expanded(
              child: Container(
                key: ValueKey('member-invite-phone-row-$index'),
                height: 44,
                decoration: BoxDecoration(
                  color: UiFieldStyle.defaultFillColor(scheme),
                  border: Border.all(
                    color: borderColor,
                    width: focused ? 1.5 : 1,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                clipBehavior: Clip.antiAlias,
                child: Row(
                  children: [
                    SizedBox(
                      width: 56,
                      child: Center(
                        child: Text(
                          '+86',
                          style: TextStyle(
                            fontSize: 13.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                    VerticalDivider(
                      width: 1,
                      thickness: 1,
                      color: UiFieldStyle.enabledBorderColor(scheme),
                    ),
                    Expanded(
                      flex: 3,
                      child: UiInputField(
                        controller: row.phone,
                        focusNode: row.phoneFocus,
                        hintText: '输入手机号',
                        keyboardType: TextInputType.phone,
                        maxLength: 11,
                        height: 42,
                        showBorder: false,
                        filled: false,
                        borderRadius: 0,
                        onChanged: (_) =>
                            setState(() => row.resultError = null),
                      ),
                    ),
                    VerticalDivider(
                      width: 1,
                      thickness: 1,
                      color: UiFieldStyle.enabledBorderColor(scheme),
                    ),
                    Expanded(
                      flex: 2,
                      child: UiInputField(
                        controller: row.name,
                        focusNode: row.nameFocus,
                        hintText: '请输入姓名',
                        maxLength: 80,
                        height: 42,
                        showBorder: false,
                        filled: false,
                        borderRadius: 0,
                        onChanged: (_) =>
                            setState(() => row.resultError = null),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 4),
            UiIconButton(
              icon: CupertinoIcons.xmark,
              tooltip: '删除',
              enabled: !_sending && _rows.length > 1,
              onTap: () => setState(() => _rows.removeAt(index).dispose()),
            ),
          ],
        );
      },
    );
  }

  /// 手机号+姓名都填了才算一条待发送记录（半填行忽略，与飞书一致）。
  List<({int index, String phone, String name})> _validRows() {
    final out = <({int index, String phone, String name})>[];
    for (var i = 0; i < _rows.length; i++) {
      final phone = _rows[i].phone.text.trim();
      final name = _rows[i].name.text.trim();
      if (phone.isEmpty && name.isEmpty) continue;
      out.add((index: i, phone: phone, name: name));
    }
    return out;
  }

  Future<void> _send() async {
    final rows = _validRows();
    // 行内前置校验：格式错/重复的行标红，不发请求。
    // 重复手机号必须在客户端拦截——响应按 phone 映射，同批重复号会导致结果错配
    //（codex 第 4 轮 P2）。
    var hasError = false;
    final seenPhones = <String>{};
    for (final r in rows) {
      if (!_phoneRe.hasMatch(r.phone)) {
        _rows[r.index].resultError = '手机号格式不正确';
        hasError = true;
      } else if (r.name.isEmpty) {
        _rows[r.index].resultError = '姓名不能为空';
        hasError = true;
      } else if (!seenPhones.add(r.phone)) {
        _rows[r.index].resultError = '与上方手机号重复';
        hasError = true;
      }
    }
    if (hasError) {
      setState(() {});
      return;
    }
    setState(() => _sending = true);
    try {
      final results = await ref.read(memberInviteServiceProvider).addByPhone([
        for (final r in rows) (phone: r.phone, name: r.name),
      ]);
      if (!mounted) return;
      var okCount = 0;
      var smsFailedCount = 0;
      // 逐条回填：成功行移除，失败行保留 + 标注原因。
      final failedByPhone = <String, String>{};
      for (final res in results) {
        if (res.ok) {
          okCount += 1;
          if (!res.smsSent) smsFailedCount += 1;
        } else {
          failedByPhone[res.phone] = res.errorLabel;
        }
      }
      setState(() {
        for (final r in rows.reversed) {
          final err = failedByPhone[r.phone];
          if (err == null) {
            _rows.removeAt(r.index).dispose();
          } else {
            _rows[r.index].resultError = err;
          }
        }
        if (_rows.isEmpty) _rows.add(_PhoneRow());
      });
      if (okCount > 0) {
        await _showSentDialog(
          okCount,
          failed: failedByPhone.length,
          smsFailed: smsFailedCount,
        );
      }
    } catch (_) {
      BotToast.showText(text: '发送失败，请稍后再试');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _showSentDialog(
    int okCount, {
    required int failed,
    required int smsFailed,
  }) {
    final suffix =
        smsFailed > 0 ? '其中 $smsFailed 条短信暂未发送，请联系对方或稍后重新邀请。' : '对方接受后才会加入企业。';
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(
          failed > 0
              ? '已创建 $okCount 个邀请，$failed 个邀请创建失败（原因见列表）。$suffix'
              : '已创建 $okCount 个邀请。$suffix',
          style: const TextStyle(fontSize: 14.5, height: 1.6),
        ),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF2F80ED),
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('确认'),
          ),
        ],
      ),
    );
  }
}
