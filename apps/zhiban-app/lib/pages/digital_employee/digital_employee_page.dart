import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

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
          const PageHeader(
            title: '数字员工',
            subtitle: '集中搜索、管理并打开数字员工会话。',
          ),
          Expanded(
            child: SizedBox(
              width: double.infinity,
              child: DigitalEmployeeGalleryHost(
                key: _galleryKey,
                mobile: false,
                // 设计稿：过滤 tab 与「搜索框 + 新建按钮」同一行,tab 左、操作右。
                filterTrailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 340,
                      child: DigitalEmployeeSearchField(),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      height: 40,
                      child: FilledButton.icon(
                        onPressed: () =>
                            _galleryKey.currentState?.createAgent(),
                        icon: const Icon(CupertinoIcons.add, size: 18),
                        label: const Text('新建数字员工'),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF1D63F2),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          textStyle: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
