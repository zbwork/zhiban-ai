import 'dart:async';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/services/local_runtime_api.dart';
import 'package:zhiban_client/services/local_agent_service.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'local_approval_dialog.dart';
import 'local_approval_sheet.dart';

/// One foreground approval surface for the whole logged-in app, including other conversations.
class LocalApprovalHost extends ConsumerStatefulWidget {
  const LocalApprovalHost({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<LocalApprovalHost> createState() => _LocalApprovalHostState();
}

class _LocalApprovalHostState extends ConsumerState<LocalApprovalHost>
    with WidgetsBindingObserver {
  late final LocalRuntimeApi _api;
  Timer? _timer;
  ModalRoute<void>? _route;
  String? _approvalId;
  bool _loading = false, _foreground = true;
  int _epoch = 0;
  final Set<String> _announcedLocalApprovals = {};
  @override
  void initState() {
    super.initState();
    _api = ref.read(localRuntimeApiProvider);
    WidgetsBinding.instance.addObserver(this);
    if (PlatformUtils.isDesktop) {
      LocalAgentService.instance.addListener(_localApprovalChanged);
    }
    _foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed ||
        (PlatformUtils.isDesktop &&
            WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.inactive);
    _schedule(Duration.zero);
  }

  void _localApprovalChanged() {
    if (!mounted) return;
    final approvals = LocalAgentService.instance.approvals;
    _announcedLocalApprovals.removeWhere((id) => !approvals.containsKey(id));
    final now = DateTime.now().millisecondsSinceEpoch;
    final fresh = approvals.entries
        .where((entry) =>
            !_announcedLocalApprovals.contains(entry.key) &&
            (entry.value['expiresAt'] as num? ?? 0) > now)
        .toList();
    if (fresh.isEmpty) return;
    _announcedLocalApprovals.addAll(fresh.map((entry) => entry.key));
    unawaited(_presentLocalApproval());
  }

  Future<void> _presentLocalApproval() async {
    try {
      // External apps may fully obscure this window. focus alone does not unhide
      // it on macOS; show first, using the same path as notification activation.
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {
      // An unavailable native window must not grant or resolve an approval.
    }
    if (!mounted) return;
    _foreground = true;
    _schedule(Duration.zero);
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    if (mounted && _foreground) {
      _timer = Timer(delay, () => unawaited(_refresh()));
    }
  }

  void _close() {
    final route = _route;
    _route = null;
    _approvalId = null;
    if (route?.navigator != null) route!.navigator!.removeRoute(route);
  }

  Future<void> _refresh() async {
    if (!mounted || !_foreground || _loading) return;
    _loading = true;
    final epoch = _epoch;
    try {
      final requests = await _api.approvals('');
      if (!mounted || !_foreground || epoch != _epoch) return;
      if (_approvalId != null && !requests.any((r) => r['id'] == _approvalId)) {
        _close();
      }
      if (_route == null && requests.isNotEmpty) {
        final request = requests.first;
        _approvalId = '${request['id']}';
        final local = PlatformUtils.isDesktop
            ? LocalAgentService.instance.approvals[_approvalId]
            : null;
        final card = {
          ...request,
          'intent': local?['intent'] ??
              {
                'tool': request['display']?['tool'],
                'operation': request['display']?['operation'],
                'args': {'name': request['display']?['target']},
              },
        };
        Future<void> onAnswer(bool approved, String scope) async {
          await _api.decide(request, approved, scope);
          if (!mounted) return;
          _epoch++;
          if (_approvalId == request['id']) _close();
          _schedule(Duration.zero);
        }

        final ModalRoute<void> route;
        if (PlatformUtils.isMobile) {
          route = ModalBottomSheetRoute<void>(
              isScrollControlled: true,
              useSafeArea: true,
              isDismissible: false,
              enableDrag: false,
              backgroundColor: Theme.of(context).colorScheme.surface,
              shape: const RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.vertical(top: Radius.circular(24))),
              clipBehavior: Clip.antiAlias,
              builder: (_) => PopScope(
                  canPop: false,
                  child:
                      LocalApprovalSheet(request: card, onAnswer: onAnswer)));
        } else {
          route = DialogRoute<void>(
              context: context,
              barrierDismissible: false,
              builder: (_) => PopScope(
                  canPop: false,
                  child:
                      LocalApprovalDialog(request: card, onAnswer: onAnswer)));
        }
        _route = route;
        unawaited(Navigator.of(context, rootNavigator: true)
            .push(route)
            .whenComplete(() {
          if (identical(_route, route)) {
            _route = null;
            _approvalId = null;
          }
        }));
      }
    } catch (_) {
      if (mounted && epoch == _epoch) _close();
    } finally {
      _loading = false;
      _schedule(const Duration(seconds: 1));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _epoch++;
    // A visible desktop window becomes inactive when the user operates the phone
    // simulator or another app. It must still receive the same approval request.
    _foreground = state == AppLifecycleState.resumed ||
        (PlatformUtils.isDesktop && state == AppLifecycleState.inactive);
    if (_foreground) {
      _schedule(Duration.zero);
    } else {
      _timer?.cancel();
      _close();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (PlatformUtils.isDesktop) {
      LocalAgentService.instance.removeListener(_localApprovalChanged);
    }
    final route = _route;
    _route = null;
    // Never pop an unrelated route when logout or tenant switching tears down the host.
    if (route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.navigator != null) route.navigator!.removeRoute(route);
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
