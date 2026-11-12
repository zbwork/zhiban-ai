import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/pages/server_connection/community_employee_gallery.dart';

import 'package:zhiban_client/config/color_config.dart';
import 'package:zhiban_client/pages/digital_employee/widgets/digital_employee_gallery_host.dart';
import 'package:zhiban_client/pages/digital_employee/widgets/digital_employee_search_field.dart';
import 'package:nexwork/widgets/page_header.dart';

/// 桌面端数字员工入口。
///
/// 移动端由 `MobileDigitalEmployeePage` 承载，平台选择统一在路由层完成。
class DigitalEmployeePage extends StatefulWidget {
  const DigitalEmployeePage({super.key});

  @override
  State<DigitalEmployeePage> createState() => _DigitalEmployeePageState();
}

class _DigitalEmployeePageState extends State<DigitalEmployeePage> {
  final _galleryKey = GlobalKey<DigitalEmployeeGalleryHostState>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ColorConfig.pageBackground,
      body: Column(
        children: [
          PageHeader(
            title: '数字员工',
            subtitle: '集中搜索、管理并打开数字员工会话。',
          ),
          Expanded(
            child: _buildGallery(context),
          ),
        ],
      ),
    );
  }

  Widget _buildGallery(BuildContext context) {
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(width: 340, child: DigitalEmployeeSearchField()),
        const SizedBox(width: 12),
        SizedBox(
          height: 40,
          child: FilledButton.icon(
            onPressed: () => _galleryKey.currentState?.createAgent(),
            icon: const Icon(CupertinoIcons.add, size: 18),
            label: const Text('新建数字员工'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Theme.of(context).colorScheme.onPrimary,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              textStyle:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
    if (AppConfig.communityEdition && AppConfig.serverWorkspace) {
      return CommunityEmployeeGallery(
        galleryKey: _galleryKey,
        filterTrailing: actions,
      );
    }
    return DigitalEmployeeGalleryHost(
      key: _galleryKey,
      mobile: false,
      filterTrailing: actions,
    );
  }
}
