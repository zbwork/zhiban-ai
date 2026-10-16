import 'package:flutter/material.dart';
import 'package:zhiban_client/network/api_image_auth.dart';
import 'package:zhiban_client/pages/chat/widgets/messages/components/chat_avatar.dart';
import 'package:zhiban_client/utils/url_utils.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';

/// 群九宫格头像的一个成员单元。
class GroupAvatarMember {
  const GroupAvatarMember({this.avatarUrl, required this.name});
  final String? avatarUrl;
  final String name;
}

/// P2.3a 群头像:成员头像缩小拼接(微信式九宫格)。
///
/// 布局口径(与微信一致):cols = n==1?1 : n<=4?2 : 3;rows = ceil(n/cols);
/// 顶行为余数(较少的一行在上、居中),其余行填满 cols;整体在方形内垂直居中。
/// 成员超过 9 取前 9。无头像成员用姓氏渐变兜底。
class GroupGridAvatar extends StatelessWidget {
  const GroupGridAvatar({
    super.key,
    required this.members,
    this.size = 48,
    this.borderRadius = 8,
  });

  final List<GroupAvatarMember> members;
  final double size;
  final double borderRadius;

  static const double _gap = 2;
  static const Color _bg = Color(0xFFE9ECF2);

  @override
  Widget build(BuildContext context) {
    final list = members.length > 9 ? members.sublist(0, 9) : members;
    final n = list.length;
    if (n == 0) {
      return _frame(const SizedBox.shrink());
    }
    if (n == 1) {
      return _frame(_cell(list.first, size));
    }
    final cols = n <= 4 ? 2 : 3;
    final rows = (n / cols).ceil();
    final cell = (size - _gap * (cols + 1)) / cols;

    // 顶行余数(微信:较少的一行在上)。
    final topCount = n - (rows - 1) * cols;
    final rowCounts = <int>[topCount, for (var i = 1; i < rows; i++) cols];

    var idx = 0;
    final rowWidgets = <Widget>[];
    for (final count in rowCounts) {
      final cells = <Widget>[];
      for (var c = 0; c < count; c++) {
        cells.add(_cell(list[idx], cell));
        if (c != count - 1) cells.add(const SizedBox(width: _gap));
        idx++;
      }
      rowWidgets.add(Row(mainAxisSize: MainAxisSize.min, children: cells));
    }

    return _frame(
      Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < rowWidgets.length; i++) ...[
            rowWidgets[i],
            if (i != rowWidgets.length - 1) const SizedBox(height: _gap),
          ],
        ],
      ),
    );
  }

  Widget _frame(Widget child) {
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(_gap),
      decoration: BoxDecoration(
        color: _bg,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      alignment: Alignment.center,
      child: child,
    );
  }

  Widget _cell(GroupAvatarMember m, double s) {
    // `/message-files/...` 是受保护的 Bus 路径，必须保留 `/api/agent-bus/v1`
    // 前缀并由 UiNetworkImage 自动携带 Bearer；普通相对头像仍只补 origin。
    final raw = m.avatarUrl?.trim() ?? '';
    final url = apiImageNeedsAuth(raw)
        ? apiImageResolveUrl(raw)
        : resolveAgentAvatarUrl(raw);
    final lower = url.toLowerCase();
    final hasUrl = url.isNotEmpty &&
        !lower.contains('.svg') &&
        !lower.contains('/svg') &&
        !lower.contains('/portrait/default/');
    final initial = firstAvatarDisplayChar(m.name);
    if (!hasUrl) {
      return Container(
        width: s,
        height: s,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: avatarGradientColors(initial.isEmpty ? m.name : initial),
          ),
          borderRadius: BorderRadius.circular(3),
        ),
        alignment: Alignment.center,
        child: Text(
          initial,
          style: TextStyle(
            color: Colors.white,
            fontSize: s * 0.42,
            fontWeight: FontWeight.w700,
            height: 1,
          ),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: UiNetworkImage(
        imageUrl: url,
        cacheKey: stableAvatarCacheKey(url),
        width: s,
        height: s,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          width: s,
          height: s,
          color: const Color(0xFFD0D5DD)
        ),
      ),
    );
  }
}
