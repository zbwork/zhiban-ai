import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 「新建数字员工」期间的全屏 loading 遮罩。
///
/// 由于后端 `POST /agents` 内部要做多步同步操作（DB 写入 → OpenClaw `agents add`
/// → workspace 准备 → 技能绑定 → 再读一次 agent），整体响应可能要好几秒，
/// 之前没有任何反馈，UI 上像"卡死"。这里通过定时器按时间段切换提示文案，
/// 让用户感知进度，并在请求结束时自动消失。
class AgentCreationProgressOverlay {
  AgentCreationProgressOverlay._();

  /// 在 [context] 所在 Overlay 上插入一个不可关闭的 loading，
  /// 调用方在 `await` 完成后必须调用返回对象的 [dismiss]。
  static AgentCreationProgressHandle show(BuildContext context) {
    final overlay = Overlay.of(context, rootOverlay: true);
    final phaseOverride = ValueNotifier<_PhaseOverride?>(null);
    final entry = OverlayEntry(
      builder: (_) => _AgentCreationProgressView(phaseOverride: phaseOverride),
    );
    overlay.insert(entry);
    return AgentCreationProgressHandle._(entry, phaseOverride);
  }
}

class AgentCreationProgressHandle {
  AgentCreationProgressHandle._(this._entry, this._override);

  final OverlayEntry _entry;
  final ValueNotifier<_PhaseOverride?> _override;
  bool _disposed = false;

  /// 用自定义文案覆盖默认的"按时间推进"阶段，常用于「等待技能安装」这种
  /// 需要额外耗时的串行步骤。
  ///
  /// [phaseIndex] 用于驱动底部的小段式进度指示器（哪一段亮）。
  /// [progress] 传非空时会在指示器下方再显示一条线性进度条。
  void setPhase({
    required String title,
    required String subtitle,
    required int phaseIndex,
    int? totalPhases,
    double? progress,
  }) {
    if (_disposed) return;
    _override.value = _PhaseOverride(
      title: title,
      subtitle: subtitle,
      phaseIndex: phaseIndex,
      totalPhases: totalPhases,
      progress: progress,
    );
  }

  void dismiss() {
    if (_disposed) return;
    _disposed = true;
    _entry.remove();
    _override.dispose();
  }
}

class _PhaseOverride {
  const _PhaseOverride({
    required this.title,
    required this.subtitle,
    required this.phaseIndex,
    this.totalPhases,
    this.progress,
  });

  final String title;
  final String subtitle;
  final int phaseIndex;
  final int? totalPhases;
  final double? progress;
}

class _AgentCreationProgressView extends StatefulWidget {
  const _AgentCreationProgressView({required this.phaseOverride});

  final ValueNotifier<_PhaseOverride?> phaseOverride;

  @override
  State<_AgentCreationProgressView> createState() =>
      _AgentCreationProgressViewState();
}

class _AgentCreationProgressViewState extends State<_AgentCreationProgressView>
    with SingleTickerProviderStateMixin {
  static const List<_Phase> _phases = [
    _Phase('正在生成数字员工档案...', '提交基本资料与岗位'),
    _Phase('正在初始化 Agent 环境...', '为您准备专属智能服务'),
    _Phase('正在绑定技能与默认配置...', '挂载技能广场所选技能'),
    _Phase('马上就好...', '即将创建完成'),
  ];

  late final Ticker _ticker;
  Duration _elapsed = Duration.zero;
  late int _phaseIndex;

  @override
  void initState() {
    super.initState();
    _phaseIndex = 0;
    _ticker = createTicker((d) {
      // 仅按时间推进阶段，无需 setState 触发每帧重绘。
      final next = _resolvePhaseIndex(d);
      if (next != _phaseIndex) {
        setState(() {
          _phaseIndex = next;
          _elapsed = d;
        });
      } else if ((d - _elapsed).inMilliseconds > 250) {
        setState(() => _elapsed = d);
      }
    })
      ..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  int _resolvePhaseIndex(Duration d) {
    // 默认阶段只在「档案 → 初始化 OpenClaw」之间推进，技能安装与收尾
    // 阶段必须由调用方通过 [AgentCreationProgressHandle.setPhase] 手动切换，
    // 避免 createAgent 还没返回 ticker 就跑到「马上就好」造成误导。
    final s = d.inMilliseconds / 1000.0;
    if (s < 1.6) return 0;
    return 1;
  }

  @override
  Widget build(BuildContext context) {
    // 固定走品牌蓝 #165DFF，不再跟随 Theme.primaryColor，避免主题切到紫色时
    // 进度条 / 脉冲圈也跟着变紫，与产品定的"知办AI 蓝"不一致。
    const primary = Color(0xFF165DFF);
    return ValueListenableBuilder<_PhaseOverride?>(
      valueListenable: widget.phaseOverride,
      builder: (_, value, __) => _buildContent(primary, value),
    );
  }

  Widget _buildContent(Color primary, _PhaseOverride? phaseOverride) {
    final title = phaseOverride?.title ?? _phases[_phaseIndex].title;
    final subtitle = phaseOverride?.subtitle ?? _phases[_phaseIndex].subtitle;
    final phaseKey = phaseOverride == null ? '$_phaseIndex' : 'override:$title';
    return Stack(
      children: [
        Positioned.fill(
          child: ColoredBox(color: const Color(0xCC0F172A))
        ),
        Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              // 固定宽度：避免不同阶段文案长短不同导致弹框横向抖动。
              width: 380,
              padding: const EdgeInsets.fromLTRB(28, 30, 28, 26),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF101828).withValues(alpha: 0.18),
                    blurRadius: 24,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _PulseCircle(color: primary),
                  const SizedBox(height: 22),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: Text(
                      title,
                      key: ValueKey(phaseKey),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF101828),
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(height: 8),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: Text(
                      subtitle,
                      key: ValueKey('${phaseKey}_sub'),
                      style: const TextStyle(
                        fontSize: 13.5,
                        height: 1.5,
                        color: Color(0xFF667085),
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (phaseOverride?.progress != null) ...[
                    const SizedBox(height: 20),
                    _LinearProgress(
                      value: phaseOverride!.progress!.clamp(0.0, 1.0),
                      primary: primary,
                    ),
                  ],
                  const SizedBox(height: 16),
                  Text(
                    '已用时 ${_formatElapsed(_elapsed)} · 请稍候',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF98A2B3),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _formatElapsed(Duration d) {
    final s = d.inMilliseconds / 1000.0;
    if (s < 10) return '${s.toStringAsFixed(1)}s';
    return '${d.inSeconds}s';
  }
}

class _Phase {
  const _Phase(this.title, this.subtitle);
  final String title;
  final String subtitle;
}

class _PulseCircle extends StatefulWidget {
  const _PulseCircle({required this.color});
  final Color color;

  @override
  State<_PulseCircle> createState() => _PulseCircleState();
}

class _PulseCircleState extends State<_PulseCircle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 76,
      height: 76,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, __) {
          final t = _ctrl.value;
          return Stack(
            alignment: Alignment.center,
            children: [
              Opacity(
                opacity: (1 - t).clamp(0.0, 1.0),
                child: Container(
                  width: 28 + 48 * t,
                  height: 28 + 48 * t,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.color.withValues(alpha: 0.18),
                  ),
                ),
              ),
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [
                      widget.color,
                      widget.color.withValues(alpha: 0.78),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: widget.color.withValues(alpha: 0.40),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: const Icon(
                  CupertinoIcons.sparkles,
                  color: Colors.white,
                  size: 26,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _LinearProgress extends StatelessWidget {
  const _LinearProgress({required this.value, required this.primary});

  final double value;
  final Color primary;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 260,
      height: 6,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: LinearProgressIndicator(
          value: value,
          backgroundColor: primary.withValues(alpha: 0.16),
          valueColor: AlwaysStoppedAnimation<Color>(primary),
        ),
      ),
    );
  }
}
