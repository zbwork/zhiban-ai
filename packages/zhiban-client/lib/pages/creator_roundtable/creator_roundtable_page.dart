import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/attachment_preview_panel.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/attachment_preview_target.dart';
import 'package:zhiban_client/pages/local_workspace/local_model_picker.dart';
import 'package:zhiban_client/pages/local_workspace/local_workspace_controller.dart';
import 'package:zhiban_client/config/client_assets.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_workspace_store.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_model_client.dart';
import 'package:zhiban_client/pages/model_service/models/ai_endpoint_type.dart';
import 'package:zhiban_client/pages/model_service/models/ai_provider_config.dart';
import 'package:zhiban_client/pages/model_service/providers/model_service_providers.dart';
import 'package:zhiban_client/pages/model_service/services/model_modality_classifier.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';
import 'package:zhiban_ui/zhiban_ui.dart';

import 'services/douyin_creator_service.dart';
import 'services/creator_subtitles.dart';
import 'services/creator_expert_workflow.dart';
import 'services/creator_graph_topics.dart';
import 'services/creator_graph_precedence.dart';
import 'creator_skill_preview.dart';
import 'creator_roundtable_chat.dart';
import 'creator_roundtable_controls.dart';
import 'creator_roundtable_graph.dart';
import 'creator_roundtable_seat_layer.dart';
import 'creator_asset_dialog.dart';
import 'creator_import_feedback.dart';
import 'services/creator_asset_workflow.dart';
import 'services/creator_media_transcriber.dart';
import 'services/creator_image_ocr.dart';
import 'services/creator_remote_media.dart';
import 'services/creator_seat_portrait.dart';

final _legacyTranscriberInstallHint = RegExp(
  r'没有找到 (?:whisper-cli|ffmpeg)(?:\.exe)?。请安装本机组件并将它加入 PATH。',
);

String? _visibleMediaSummary(String? summary) {
  final text = summary?.replaceAll(_legacyTranscriberInstallHint, '').trim();
  return text == null || text.isEmpty ? null : text;
}

const _modelPreference = 'creator_roundtable.model.v1';
const _guidePreference = 'creator_roundtable.guide_dismissed.v1';
const _seatsPreference = 'creator_roundtable.display_seats.v1';

final creatorRoundtableModelClientProvider =
    Provider<LocalModelClient>((ref) => LocalModelClient());
final creatorSeatPortraitServiceProvider =
    Provider<CreatorSeatPortraitService>((ref) => CreatorSeatPortraitService());

final creatorDouyinAdapterProvider = Provider<DouyinCreatorService Function()>(
    (ref) => DouyinCreatorService.new);

final creatorDouyinSessionProvider =
    Provider<Future<String> Function()>((ref) => _douyinLoginCookie);

Future<String> _douyinLoginCookie() async {
  if (InAppWebViewPlatform.instance == null) {
    throw MissingPluginException('当前环境不支持内置抖音登录');
  }
  final cookies = await CookieManager.instance()
      .getCookies(url: WebUri('https://www.douyin.com/'));
  final target = cookies.where((cookie) {
    final domain = (cookie.domain ?? '').replaceFirst(RegExp(r'^\.'), '');
    return domain == 'douyin.com' || domain.endsWith('.douyin.com');
  });
  final signedIn = target.any((cookie) =>
      {'sessionid', 'sessionid_ss'}.contains(cookie.name) &&
      '${cookie.value}'.isNotEmpty);
  return signedIn
      ? target.map((cookie) => '${cookie.name}=${cookie.value}').join('; ')
      : '';
}

const _seatPositions = [
  Alignment(-.62, .46),
  Alignment(-.48, -.46),
  Alignment(.44, -.46),
  Alignment(.60, .48),
  Alignment(-.02, -.68),
  Alignment(-.70, -.22),
  Alignment(.72, -.20),
  Alignment(-.02, .34),
];

class CreatorRoundtablePage extends ConsumerStatefulWidget {
  const CreatorRoundtablePage({super.key});

  @visibleForTesting
  static ValueChanged<InAppWebViewController>? debugOnLoginPageLoaded;

  @override
  ConsumerState<CreatorRoundtablePage> createState() =>
      _CreatorRoundtablePageState();
}

class _CreatorRoundtablePageState extends ConsumerState<CreatorRoundtablePage> {
  int _tab = 0;
  int _revision = 0;
  ({
    LocalWorkspaceStore store,
    int revision,
    Future<List<LocalRow>> rows
  })? _profileRead;
  ({
    LocalWorkspaceStore store,
    int revision,
    String id,
    Future<List<LocalRow>> rows
  })? _workRead;
  final _syncMessages = <String, String>{};
  final _syncFailures = <String, _CreatorSyncFailure>{};
  final _openSyncDialogs = <String>{};
  final _runningSyncs = <String, _CreatorSyncRun>{};
  final _syncKnowledgeRequests = <String, Object>{};
  final _mediaMessages = <String, String>{};
  final _mediaJobs = <String, CancelToken>{};
  final _portraitJobs = <String, CancelToken>{};
  final _portraitJobChanges = ValueNotifier(0);
  final _portraitFiles = <String, Future<File?>>{};
  final _seatExperts = <(LocalWorkspaceStore, String), Future<LocalRow?>>{};
  final _autoPortraitAttempts = <String, String>{};
  final _pendingSeatWrites = <String>{};
  static const _roundtableContentInset = 12.0;
  final _chatSession = RoundtableChatSession();
  final _stageFrameKey = GlobalKey();
  bool _chatOpen = false;
  bool _importingSubtitles = false;
  CreatorMediaTranscriber? _transcriber;
  String? _transcriptionProgress;
  CancelToken? _expertCancel;
  final _expertMessages = <String, String>{};

  @override
  void dispose() {
    _transcriber?.dispose();
    _expertCancel?.cancel();
    for (final run in _runningSyncs.values) {
      run.cancel();
    }
    for (final job in _mediaJobs.values) {
      job.cancel();
    }
    for (final job in _portraitJobs.values) {
      job.cancel();
    }
    _portraitJobChanges.dispose();
    super.dispose();
  }

  String? _selectedCreator;
  String? _selectedWork;
  String? _playingWork;
  String? _model;
  List<String> _seatIds = const [];
  bool _guide = true;
  bool _guideChannelConnected = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPreferences());
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _model = prefs.getString(_modelPreference);
        _guide = !(prefs.getBool(_guidePreference) ?? false);
        final seen = <String>{};
        _seatIds = [
          for (final id
              in (prefs.getStringList(_seatsPreference) ?? const <String>[])
                  .take(_seatPositions.length))
            if (id.isNotEmpty && seen.add(id)) id else '',
        ];
      });
      if (_guide) unawaited(_refreshGuideChannel());
    }
  }

  Future<void> _selectModel(String? value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value == null) {
      await prefs.remove(_modelPreference);
    } else {
      await prefs.setString(_modelPreference, value);
    }
    if (mounted) setState(() => _model = value);
  }

  Future<List<LocalRow>> _profilesFor(LocalWorkspaceStore store) {
    final read = _profileRead;
    if (read != null &&
        identical(read.store, store) &&
        read.revision == _revision) {
      return read.rows;
    }
    final rows = store.creatorProfiles();
    _profileRead = (store: store, revision: _revision, rows: rows);
    return rows;
  }

  Future<List<LocalRow>> _worksFor(LocalWorkspaceStore store, String id) {
    final read = _workRead;
    if (read != null &&
        identical(read.store, store) &&
        read.revision == _revision &&
        read.id == id) {
      return read.rows;
    }
    final rows = store.creatorWorks(id);
    _workRead = (store: store, revision: _revision, id: id, rows: rows);
    return rows;
  }

  Future<void> _addCreator(
      LocalWorkspaceStore store, String? selectedModel) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      barrierColor: const Color(0x7318273E),
      builder: (_) => _AddDouyinCreatorDialog(distill: selectedModel != null),
    );
    if (!mounted || result == null) return;
    final status = ValueNotifier<CreatorImportStatus>((
      stage: CreatorImportStage.saving,
      message: '正在保存选定范围内的作品…',
      creatorId: null,
      workCount: null,
      mediaSummary: null,
    ));
    final processing =
        _finishCreatorImport(store, result, selectedModel, status);
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        barrierColor: const Color(0x7318273E),
        builder: (_) => CreatorImportFeedback(
          status: status,
          onOpenWorks: (id) {
            if (!mounted) return;
            setState(() {
              _selectedCreator = id;
              _selectedWork = null;
              _tab = 1;
            });
          },
        ),
      );
      await processing;
    } finally {
      status.dispose();
    }
  }

  Future<void> _finishCreatorImport(
    LocalWorkspaceStore store,
    Map<String, dynamic> result,
    String? selectedModel,
    ValueNotifier<CreatorImportStatus> status,
  ) async {
    String? id;
    int? count;
    String? mediaSummary;
    void report(CreatorImportStage stage, String message) {
      status.value = (
        stage: stage,
        message: message,
        creatorId: id,
        workCount: count,
        mediaSummary: mediaSummary,
      );
    }

    try {
      final single = result['work'] as Map<String, dynamic>?;
      final incoming = single == null
          ? (result['posts'] as List).cast<Map<String, dynamic>>()
          : [single];
      final author = result['author'] as Map<String, dynamic>;
      final existing =
          (await store.creatorProfiles()).map((row) => row['id']).toSet();
      final saved = await store.importCreatorWorks(author, incoming);
      id = saved.creatorId;
      count = incoming.length;
      if (!mounted) return;
      setState(() {
        _selectedCreator = saved.creatorId;
        _revision++;
      });
      if (!existing.contains(saved.creatorId)) {
        unawaited(_seatImportedCreator({
          'id': saved.creatorId,
          'name': author['name'],
          'avatar_url': author['avatar'],
        }));
      }
      report(CreatorImportStage.downloading, '正在保存原片或图文媒体到本机…');
      mediaSummary = await _archiveRemoteMedia(
        store,
        saved.creatorId,
        incoming,
        onTranscribing: (message) =>
            report(CreatorImportStage.transcribing, message),
      );
      if (!mounted) return;
      final works = await store.creatorWorks(saved.creatorId);
      final current = await store.latestCreatorExpert(saved.creatorId);
      final evidence = creatorEvidence(works);
      final originalEvidence = current?['evidence'] as String? ?? '[]';
      if (!mounted) return;
      if (current != null &&
          !creatorEvidenceHasChanged(evidence, originalEvidence)) {
        report(CreatorImportStage.saved, '沿用此前发布的专家版本，可参与圆桌问答。');
        return;
      }
      if (evidence.isEmpty || selectedModel == null || _expertCancel != null) {
        final message = evidence.isEmpty
            ? '专家待补充作品。请先转写归档媒体、导入字幕或补充图文证据。'
            : selectedModel == null
                ? '作品已保存。请先在圆桌页选择模型，再回详情继续生成。'
                : '另一个专家任务正在处理，可稍后在博主详情生成专家。';
        report(CreatorImportStage.saved, message);
        return;
      }
      final pending = await store.lastCreatorExpertJob(saved.creatorId);
      if (!mounted) return;
      if (pending != null &&
          {'failed', 'interrupted'}.contains(pending['status']) &&
          !creatorEvidenceHasChanged(
              evidence, pending['source_snapshot'] as String)) {
        report(CreatorImportStage.saved, '原蒸馏任务可在博主详情继续。');
        return;
      }
      final published = await _distillCreator(
        store,
        {'id': saved.creatorId},
        works,
        selectedModel,
        onProgress: (message) => report(CreatorImportStage.analyzing, message),
      );
      if (!mounted) return;
      report(
        published ? CreatorImportStage.published : CreatorImportStage.failed,
        published
            ? '已提炼方法并发布专家，可参与圆桌问答。'
            : _expertMessages[saved.creatorId] ?? '请在博主详情查看任务结果。',
      );
    } catch (error) {
      final message = error is StateError
          ? error.message.toString()
          : '处理未完成，请检查网络及本机存储后重试。';
      report(CreatorImportStage.failed, message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final workspace = ref.watch(localWorkspaceProvider);
    final providers = ref.watch(modelProvidersProvider);
    final models = localTextModelOptions(providers.value ?? const []);
    final imageModels = [
      for (final provider in providers.value ?? const [])
        if (provider.enabled)
          for (final model in provider.models)
            if (model.enabled &&
                classifyModelId(model.modelId) == ModelModality.image)
              [
                provider.id,
                provider.baseUrl,
                provider.imageEditBaseUrl,
                model.modelId
              ],
    ];
    final portraitConfiguration =
        imageModels.isEmpty ? null : jsonEncode(imageModels);
    final selectedModel =
        models.any((item) => item.id == _model) ? _model : null;
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: workspace.when(
        loading: () => const Center(child: CupertinoActivityIndicator()),
        error: (_, __) => const Center(child: Text('本地工作区打开失败，请重试')),
        data: (controller) => FutureBuilder<List<LocalRow>>(
          key: ValueKey(_revision),
          future: _profilesFor(controller.store),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const Center(child: Text('博主列表读取失败'));
            }
            if (!snapshot.hasData) {
              return const Center(child: CupertinoActivityIndicator());
            }
            final creators = snapshot.data!;
            if (portraitConfiguration != null) {
              _scheduleMissingPortraits(creators, portraitConfiguration);
            }
            if (_selectedCreator != null &&
                !creators.any((row) => row['id'] == _selectedCreator)) {
              _selectedCreator = null;
            }
            _selectedCreator ??=
                creators.isEmpty ? null : creators.first['id'] as String;
            final selected = creators
                .where((row) => row['id'] == _selectedCreator)
                .firstOrNull;
            return Column(children: [
              if (_tab == 1)
                Padding(
                  padding: EdgeInsets.fromLTRB(
                      16, Platform.isMacOS ? 30 : 12, 16, 10),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      style: roundtableTextControlStyle,
                      onPressed: () {
                        setState(() => _tab = 0);
                        unawaited(_showCreatorDrawer(
                            creators, controller.store, selectedModel));
                      },
                      icon: const Icon(CupertinoIcons.arrow_left, size: 16),
                      label: const Text('返回博主列表'),
                    ),
                  ),
                )
              else
                _header(models.isNotEmpty, selectedModel),
              Expanded(
                child: switch (_tab) {
                  0 => _roundtable(creators, controller.store, selectedModel),
                  1 => _works(selected, controller.store, selectedModel),
                  _ => _knowledge(controller.store, creators, selectedModel),
                },
              ),
            ]);
          },
        ),
      ),
    );
  }

  Widget _header(bool hasModels, String? selectedModel) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.fromLTRB(
          _roundtableContentInset, Platform.isMacOS ? 30 : 0, 20, 0),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
            height: 58,
            child: LayoutBuilder(
                builder: (context, size) => Row(children: [
                      Expanded(
                          child: Text('博主圆桌',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleLarge
                                  ?.copyWith(fontWeight: FontWeight.bold))),
                      if (hasModels) ...[
                        if (size.maxWidth >= 570) const Text('使用模型'),
                        const SizedBox(width: 10),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                              maxWidth:
                                  (size.maxWidth * .44).clamp(130.0, 232.0)),
                          child: LocalModelPicker(
                            key: const ValueKey('roundtable-model-selector'),
                            selected: selectedModel,
                            openBelow: true,
                            switchHint: '切换后从下一次圆桌任务生效',
                            onSelected: (model) => _selectModel(model.id),
                          ),
                        ),
                      ],
                    ]))),
        Row(children: [
          Expanded(
            child: DefaultTabController(
              length: 2,
              initialIndex: _tab == 2 ? 1 : 0,
              child: TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                labelPadding: const EdgeInsetsDirectional.only(end: 32),
                indicatorSize: TabBarIndicatorSize.label,
                dividerHeight: 0,
                labelColor: scheme.primary,
                indicatorColor: scheme.primary,
                onTap: (index) => setState(() => _tab = index == 0 ? 0 : 2),
                tabs: const [
                  Tab(
                      height: 41,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(CupertinoIcons.person_2, size: 15),
                        SizedBox(width: 5),
                        Text('圆桌专家团'),
                      ])),
                  Tab(
                      height: 41,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(CupertinoIcons.doc_text, size: 15),
                        SizedBox(width: 5),
                        Text('知识资产'),
                      ])),
                ],
              ),
            ),
          ),
          if (!hasModels)
            TextButton(
              key: const ValueKey('roundtable-configure-model'),
              onPressed: () => context.go(RoutePaths.modelService),
              child: const Text('配置模型服务'),
            ),
        ]),
      ]),
    );
  }

  Widget _roundtable(List<LocalRow> creators, LocalWorkspaceStore store,
      String? selectedModel) {
    Future<void> openChat(
        {bool expanded = false, bool pickExperts = false}) async {
      if (_chatOpen) return;
      final duration = CreatorRoundtableChat.transitionDuration(context);
      if (!pickExperts) setState(() => _chatOpen = true);
      try {
        await showDialog<void>(
          context: context,
          useSafeArea: false,
          barrierColor: Colors.transparent,
          animationStyle: AnimationStyle(
            duration: duration,
            reverseDuration: duration,
          ),
          builder: (_) => CreatorRoundtableChat(
            store: store,
            creators: creators,
            initiallyExpanded: expanded,
            expertsOnly: pickExperts,
            avatarBuilder: _creatorAvatar,
            session: _chatSession,
            stageFrame: () {
              final frame = _stageFrameKey.currentContext?.findRenderObject();
              if (frame is! RenderBox || !frame.attached || !frame.hasSize) {
                return null;
              }
              return frame.localToGlobal(Offset.zero) & frame.size;
            },
            onOpenEvidence: (evidence) => _showArchivedWork(store, evidence),
            resolveModel: (token) =>
                _resolveRoundtableModel(selectedModel, token),
          ),
        );
      } finally {
        if (mounted) setState(() => _chatOpen = false);
      }
    }

    final ratio = creatorRoundtableSceneSize.aspectRatio;
    final stageButtonStyle =
        roundtableTextControlStyle.merge(FilledButton.styleFrom(
      backgroundColor: Colors.white,
      foregroundColor: const Color(0xFF213653),
      disabledBackgroundColor: Colors.white.withValues(alpha: .93),
      disabledForegroundColor: const Color(0xFF4B5D75),
    ));
    final byId = {for (final creator in creators) creator['id']: creator};
    final seats = {
      for (final (index, id) in _seatIds.indexed)
        if (byId[id] case final creator?) index: creator,
    };
    return Padding(
      padding: const EdgeInsets.all(_roundtableContentInset),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SizedBox.expand(
              key: _stageFrameKey,
              child: LayoutBuilder(builder: (context, stage) {
                final composer = _stageComposer(
                  experts: creators
                      .where((creator) =>
                          _chatSession.selected?.contains(creator['id']) ??
                          false)
                      .toList(),
                  enabled: creators.isNotEmpty,
                  onOpen: openChat,
                  onExperts: () => openChat(pickExperts: true),
                  onExpand: () => openChat(expanded: true),
                );
                final scene = AspectRatio(
                    aspectRatio: ratio,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(9),
                      child: Stack(fit: StackFit.expand, children: [
                        Image.asset(
                            ClientAssets.path(
                                'assets/images/creator_roundtable_empty.jpg'),
                            key: const ValueKey('roundtable-scene'),
                            fit: BoxFit.cover,
                            excludeFromSemantics: true),
                        if (_guide && creators.isEmpty)
                          const ColoredBox(color: Color(0x37132742)),
                        for (final seat in seats.entries)
                          CreatorRoundtableSeatLayer(
                            key: ValueKey('roundtable-person-${seat.key}'),
                            slot: seat.key,
                            portrait: _seatPortrait(seat.value, seat.key),
                          ),
                        for (final seat in seats.entries)
                          Align(
                            key: ValueKey('roundtable-seat-${seat.key}'),
                            alignment: _seatPositions[seat.key],
                            child: _seatBadge(store, creators, seat.value),
                          ),
                        Positioned(
                          top: 12,
                          right: 12,
                          child: FilledButton.tonal(
                            key: const ValueKey('roundtable-seat-settings'),
                            style: stageButtonStyle,
                            onPressed: creators.isEmpty
                                ? null
                                : () => _configureSeats(creators, seats),
                            child: Text(
                                '展示席位  ${seats.length} / ${_seatPositions.length}'),
                          ),
                        ),
                        if (!_chatOpen &&
                            stage.maxWidth >= 280 &&
                            stage.maxHeight >= 175)
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: composer,
                            ),
                          ),
                      ]),
                    ));
                return Align(alignment: Alignment.topCenter, child: scene);
              }),
            ),
          ),
          const SizedBox(width: 10),
          _compactCreatorRail(creators, store, selectedModel),
        ],
      ),
    );
  }

  Widget _compactCreatorRail(List<LocalRow> creators, LocalWorkspaceStore store,
      String? selectedModel) {
    final scheme = Theme.of(context).colorScheme;
    final buttonStyle = roundtableIconControlStyle.copyWith(
      foregroundColor: WidgetStatePropertyAll(scheme.onSurfaceVariant),
      shape: const WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(7)),
        ),
      ),
    );
    return Container(
      key: const ValueKey('roundtable-compact-creators'),
      width: 52,
      padding: const EdgeInsets.only(left: 5),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        children: [
          IconButton(
            key: const ValueKey('roundtable-open-creators'),
            style: buttonStyle,
            tooltip: '展开博主列表',
            onPressed: () => _showCreatorDrawer(creators, store, selectedModel),
            icon: const Icon(CupertinoIcons.sidebar_left),
          ),
          IconButton(
            style: buttonStyle,
            tooltip: '添加博主',
            onPressed: () => _addCreator(store, selectedModel),
            icon: Ink(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(6),
              ),
              child:
                  Icon(CupertinoIcons.add, color: scheme.onPrimary, size: 16),
            ),
          ),
          IconButton(
            style: buttonStyle,
            tooltip: '配置渠道',
            onPressed: _configureChannel,
            icon: const Icon(CupertinoIcons.gear_alt),
          ),
          if (creators.isNotEmpty) ...[
            const Divider(height: 16, indent: 4, endIndent: 4),
            Expanded(
              child: ListView.separated(
                primary: false,
                padding: const EdgeInsets.only(bottom: 4),
                itemCount: creators.length,
                separatorBuilder: (_, __) => const SizedBox(height: 4),
                itemBuilder: (_, index) {
                  final creator = creators[index];
                  return Center(
                    child: IconButton(
                      key: ValueKey(
                          'roundtable-compact-creator-${creator['id']}'),
                      style: buttonStyle,
                      tooltip: '${creator['name']}',
                      onPressed: () => _openCreatorWorks(creator),
                      icon: _creatorAvatar(creator, 32),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _openCreatorWorks(LocalRow creator) {
    setState(() {
      _selectedCreator = creator['id'] as String;
      _selectedWork = null;
      _tab = 1;
    });
  }

  Future<void> _showCreatorDrawer(List<LocalRow> creators,
      LocalWorkspaceStore store, String? selectedModel) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭博主列表',
      barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: .36),
      transitionDuration: CreatorRoundtableChat.transitionDuration(context),
      pageBuilder: (drawerContext, _, __) {
        void close() => Navigator.pop(drawerContext);
        return Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            key: const ValueKey('roundtable-creators-drawer'),
            width:
                MediaQuery.sizeOf(drawerContext).width.clamp(0, 360).toDouble(),
            height: double.infinity,
            child: Material(
              color: Theme.of(drawerContext).colorScheme.surface,
              child: SafeArea(
                child: StatefulBuilder(
                  builder: (context, setDrawerState) => _creatorRail(
                    creators,
                    close: close,
                    onConfigure: () {
                      close();
                      unawaited(_configureChannel());
                    },
                    onAdd: () {
                      close();
                      unawaited(_addCreator(store, selectedModel));
                    },
                    onSkipGuide: () {
                      unawaited(_skipGuide());
                      setDrawerState(() {});
                    },
                    onSelect: (creator) {
                      close();
                      _openCreatorWorks(creator);
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (_, animation, __, child) => SlideTransition(
        position: animation
            .drive(CurveTween(curve: Curves.easeOutCubic))
            .drive(Tween(begin: const Offset(1, 0), end: Offset.zero)),
        child: child,
      ),
    );
  }

  Widget _stageComposer({
    required List<LocalRow> experts,
    required bool enabled,
    required VoidCallback onOpen,
    required VoidCallback onExperts,
    required VoidCallback onExpand,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Material(
        key: const ValueKey('roundtable-stage-composer'),
        color: scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            children: [
              RoundtableExpertControl(
                key: const ValueKey('roundtable-stage-experts'),
                experts: experts,
                avatarBuilder: _creatorAvatar,
                onPressed: enabled ? onExperts : null,
              ),
              const SizedBox(width: roundtableComposerGap),
              Expanded(
                child: UiInputField(
                  key: const ValueKey('roundtable-stage-question'),
                  height: roundtableControlHeight,
                  borderRadius: roundtableControlRadius,
                  hintText: roundtableQuestionHint,
                  enabled: enabled,
                  readOnly: true,
                  onTap: onOpen,
                ),
              ),
              const SizedBox(width: roundtableComposerGap),
              UiIconButton(
                onTap: enabled ? onExpand : null,
                tooltip: '全屏展开对话',
                icon: CupertinoIcons.fullscreen,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _toggleSeatExpert(LocalWorkspaceStore store,
      List<LocalRow> creators, LocalRow creator) async {
    final id = creator['id'] as String;
    try {
      final published = _chatSession.selected == null
          ? await _publishedExperts(store, creators)
          : [
              if (await store.latestCreatorExpert(id)
                  case final LocalRow expert)
                expert
            ];
      if (!mounted || _tab != 0) return;
      if (!published.any((expert) => expert['id'] == id)) {
        _openCreatorWorks(creator);
        return;
      }
      final selected = _chatSession.selected ??
          published.map((expert) => expert['id'] as String).toSet();
      setState(() {
        if (!selected.remove(id)) selected.add(id);
        _chatSession.selected = selected;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('无法读取专家状态，请重试。')));
    }
  }

  Widget _seatBadge(
      LocalWorkspaceStore store, List<LocalRow> creators, LocalRow creator) {
    final id = creator['id'] as String;
    return FutureBuilder<LocalRow?>(
      key: ValueKey(id),
      future: _seatExperts
          .putIfAbsent((store, id), () => store.latestCreatorExpert(id)),
      builder: (context, snapshot) => _seatBadgeLabel(
        creator,
        ready: snapshot.hasData,
        pending: snapshot.connectionState == ConnectionState.done &&
            !snapshot.hasData &&
            !snapshot.hasError,
        onTap: () => _toggleSeatExpert(store, creators, creator),
      ),
    );
  }

  Widget _seatBadgeLabel(LocalRow creator,
      {required bool ready,
      required bool pending,
      required VoidCallback onTap}) {
    final selected =
        ready && (_chatSession.selected?.contains(creator['id']) ?? true);
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 112),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: selected
                  ? const Color(0xFF1957B5)
                  : Theme.of(context).colorScheme.inverseSurface,
              border: Border.all(color: const Color(0xFF91BBF5)),
              borderRadius: BorderRadius.circular(5),
              boxShadow: const [
                BoxShadow(
                    color: Color(0x500F172A),
                    blurRadius: 6,
                    offset: Offset(0, 2)),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${creator['name']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600),
                  ),
                  if (pending)
                    const Text('暂不可问',
                        style: TextStyle(color: Colors.white, fontSize: 10)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool _hasSeatAvatar(LocalRow creator) =>
      (creator['avatar_url'] as String? ?? '').trim().isNotEmpty;

  Future<File?>? _seatPortrait(LocalRow creator, int slot) {
    if (!_hasSeatAvatar(creator)) return null;
    final avatar = (creator['avatar_url'] as String).trim();
    final id = creator['id'] as String;
    final key = creatorPortraitKey(id, avatar, slot);
    return _portraitFiles.putIfAbsent(key, () async {
      final service = ref.read(creatorSeatPortraitServiceProvider);
      final root = await ref.read(creatorAssetDirectoryProvider)();
      return service.load(root, id, avatar, slot);
    });
  }

  void _scheduleMissingPortraits(
      List<LocalRow> creators, String configuration) {
    for (final (slot, id) in _seatIds.indexed) {
      if (id.isEmpty || _pendingSeatWrites.contains(id)) continue;
      final creator = creators.where((row) => row['id'] == id).firstOrNull;
      if (creator == null || !_hasSeatAvatar(creator)) continue;
      final avatar = (creator['avatar_url'] as String).trim();
      final key = creatorPortraitKey(id, avatar, slot);
      if (_autoPortraitAttempts[key] == configuration) continue;
      _autoPortraitAttempts[key] = configuration;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted || slot >= _seatIds.length || _seatIds[slot] != id) return;
        try {
          if (await _seatPortrait(creator, slot) != null ||
              !mounted ||
              slot >= _seatIds.length ||
              _seatIds[slot] != id) {
            return;
          }
          await _generateSeatPortrait(creator, slot, automatic: true);
        } catch (_) {
          // The stored portrait could not be checked. Leave the manual retry available.
        }
      });
    }
  }

  Future<void> _seatImportedCreator(LocalRow creator) async {
    if (!_hasSeatAvatar(creator)) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final id = creator['id'] as String;
      if (_seatIds.contains(id)) return;
      final seats = List<String>.generate(
        _seatPositions.length,
        (index) => index < _seatIds.length ? _seatIds[index] : '',
      );
      final slot = seats.indexOf('');
      if (slot < 0) return;
      seats[slot] = id;
      // Reserve before awaiting the preferences write so concurrent imports differ.
      _pendingSeatWrites.add(id);
      setState(() => _seatIds = seats);
      bool saved;
      try {
        saved = await prefs.setStringList(_seatsPreference, seats);
      } finally {
        _pendingSeatWrites.remove(id);
      }
      if (!saved) {
        if (mounted && slot < _seatIds.length && _seatIds[slot] == id) {
          setState(() => _seatIds = [..._seatIds]..[slot] = '');
        }
        throw const CreatorWorkflowException('自动安排席位失败，可在展示席位重试。');
      }
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('自动安排席位失败，可在展示席位重试。')),
        );
      }
    }
  }

  Future<void> _generateSeatPortrait(LocalRow creator, int slot,
      {bool automatic = false}) async {
    final id = creator['id'] as String;
    final avatar = (creator['avatar_url'] as String).trim();
    final portraitKey = creatorPortraitKey(id, avatar, slot);
    if (_portraitJobs.containsKey(portraitKey)) return;
    final cancel = _portraitJobs[portraitKey] = CancelToken();
    _portraitJobChanges.value++;
    try {
      final providers = await ref.read(modelProvidersProvider.future);
      final catalog = await ref.read(modelCatalogProvider.future);
      if (!mounted) return;
      final choices =
          <({AiProviderConfig provider, String model, String label})>[
        for (final provider in providers)
          if (provider.enabled &&
              (provider.imageEditBaseUrl.trim().isNotEmpty ||
                  catalog.endpointTypeFor(provider) ==
                      AiEndpointType.openaiCompatible))
            for (final model in provider.models)
              if (model.enabled &&
                  classifyModelId(model.modelId) == ModelModality.image)
                (
                  provider: provider,
                  model: model.modelId,
                  label: model.displayName
                ),
      ];
      if (automatic && choices.isEmpty) return;
      int? selection = choices.isEmpty ? null : 0;
      final chosen = automatic
          ? 0
          : await showDialog<int>(
              context: context,
              builder: (_) => StatefulBuilder(builder: (context, update) {
                return UiContentDialog(
                  size: UiDialogSize.compact,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        UiSheetHeader(
                            title: '生成席位形象',
                            onClose: () => Navigator.pop(context)),
                        const SizedBox(height: 12),
                        Text('${creator['name']} · 第 ${slot + 1} 席'),
                        const SizedBox(height: 8),
                        if (choices.isEmpty)
                          const Text('请先在模型服务启用支持图像编辑和透明 PNG 的图片模型。')
                        else ...[
                          const Text('将公开头像发送给所选图片服务，生成的 AI 形象保存在本机。'),
                          const SizedBox(height: 8),
                          UiSelect<int>(
                            value: selection,
                            options: [
                              for (final (index, choice) in choices.indexed)
                                UiSelectOption<int>(
                                  value: index,
                                  label: choice.label,
                                  group: choice.provider.name,
                                ),
                            ],
                            placeholder: '选择图片模型',
                            onChanged: (value) =>
                                update(() => selection = value),
                          ),
                        ],
                        const SizedBox(height: 14),
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton(
                            onPressed: selection == null
                                ? null
                                : () => Navigator.pop(context, selection),
                            child: const Text('生成形象'),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            );
      if (!mounted || chosen == null) return;
      final choice = choices[chosen];
      final service = ref.read(creatorSeatPortraitServiceProvider);
      final config = ref.read(modelServiceStoreProvider);
      final directory = ref.read(creatorAssetDirectoryProvider);
      final root = await directory();
      if (automatic && await service.load(root, id, avatar, slot) != null) {
        return;
      }
      final key = await config.getApiKey(choice.provider.id);
      final file = await service.generate(
        root: root,
        creatorId: id,
        avatar: avatar,
        slot: slot,
        provider: choice.provider,
        model: choice.model,
        key: key ?? '',
        cancel: cancel,
      );
      await FileImage(file).evict();
      if (mounted) {
        setState(() {
          _portraitFiles[portraitKey] = Future.value(file);
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('席位形象已生成。')));
      }
    } catch (error) {
      if (mounted) {
        final message =
            error is CreatorWorkflowException ? error.message : '生成席位形象失败，请重试。';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      _portraitJobs.remove(portraitKey);
      if (mounted) _portraitJobChanges.value++;
    }
  }

  Future<void> _configureSeats(
      List<LocalRow> creators, Map<int, LocalRow> seats) async {
    final limit = _seatPositions.length;
    final draft = List<String>.generate(
        limit, (index) => seats[index]?['id'] as String? ?? '');
    final saved = await showDialog<List<String>>(
      context: context,
      barrierColor: const Color(0x7318273E),
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => ListenableBuilder(
          listenable: _portraitJobChanges,
          builder: (context, _) {
            final occupied = draft.where((id) => id.isNotEmpty).length;
            final theme = Theme.of(context);
            return UiContentDialog(
              size: UiDialogSize.compact,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    UiSheetHeader(
                      title: '设置展示席位',
                      onClose: () => Navigator.pop(dialogContext),
                    ),
                    const Divider(height: 20),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: .08),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Text(
                            '已展示 $occupied / $limit 席。选择展示后可生成形象，点完成保存席位。'),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: creators.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final creator = creators[index];
                          final id = creator['id'] as String;
                          final slot = draft.indexOf(id);
                          final canGenerate =
                              slot >= 0 && _hasSeatAvatar(creator);
                          final portrait =
                              canGenerate ? _seatPortrait(creator, slot) : null;
                          final generating = canGenerate &&
                              _portraitJobs.containsKey(creatorPortraitKey(
                                  id,
                                  (creator['avatar_url'] as String).trim(),
                                  slot));
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: _creatorAvatar(creator, 30),
                            title: Text('${creator['name']}'),
                            subtitle: slot >= 0 && !canGenerate
                                ? const Text('暂无公开头像')
                                : null,
                            trailing: Wrap(
                              alignment: WrapAlignment.end,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              spacing: 6,
                              children: [
                                if (canGenerate)
                                  FutureBuilder<File?>(
                                    key: ObjectKey(portrait),
                                    future: portrait,
                                    builder: (_, snapshot) => TextButton(
                                      onPressed: generating
                                          ? null
                                          : () => _generateSeatPortrait(
                                              creator, slot),
                                      child: Text(generating
                                          ? '生成中…'
                                          : snapshot.hasData
                                              ? '重新生成'
                                              : '生成形象'),
                                    ),
                                  ),
                                OutlinedButton(
                                  onPressed: generating ||
                                          (slot == -1 && occupied == limit)
                                      ? null
                                      : () => update(() {
                                            if (slot == -1) {
                                              draft[draft.indexOf('')] = id;
                                            } else {
                                              draft[slot] = '';
                                            }
                                          }),
                                  child: Text(slot == -1 ? '在圆桌展示' : '取消展示'),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    const Divider(height: 16),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        onPressed: () => Navigator.pop(dialogContext, draft),
                        child: const Text('完成'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
    if (saved == null || !mounted) return;
    final prefs = await SharedPreferences.getInstance();
    final persisted = await prefs.setStringList(_seatsPreference, saved);
    if (!mounted) return;
    if (persisted) {
      setState(() => _seatIds = saved);
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('展示席位保存失败')));
    }
  }

  Widget _creatorRail(
    List<LocalRow> creators, {
    required VoidCallback close,
    required VoidCallback onConfigure,
    required VoidCallback onAdd,
    required VoidCallback onSkipGuide,
    required ValueChanged<LocalRow> onSelect,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final guiding = creators.isEmpty && _guide;
    final connected = _guideChannelConnected;
    ButtonStyle currentStepStyle(bool active) => OutlinedButton.styleFrom(
          side: BorderSide(
              color:
                  guiding && active ? scheme.primary : scheme.outlineVariant),
          padding: const EdgeInsets.symmetric(horizontal: 9),
          minimumSize: const Size(0, roundtableControlHeight),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.standard,
        );
    final actions = Wrap(
        alignment: WrapAlignment.spaceBetween,
        spacing: 4,
        runSpacing: 4,
        children: [
          OutlinedButton.icon(
              style: currentStepStyle(!connected),
              onPressed: onConfigure,
              icon: const Icon(CupertinoIcons.gear_alt, size: 14),
              label: const Text('配置渠道')),
          FilledButton(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, roundtableControlHeight),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.standard,
                side: guiding && connected
                    ? BorderSide(color: scheme.primaryContainer, width: 2)
                    : BorderSide.none,
              ),
              onPressed: onAdd,
              child: const Text('+ 添加博主')),
        ]);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text('博主列表',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(width: 8),
          DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              child: Text('${creators.length} 位',
                  style: Theme.of(context).textTheme.labelMedium),
            ),
          ),
          const Spacer(),
          IconButton(
              style: roundtableIconControlStyle,
              tooltip: '收起博主列表',
              onPressed: close,
              icon: const Icon(CupertinoIcons.xmark, size: 16)),
        ]),
        actions,
        const SizedBox(height: 12),
        if (guiding)
          Expanded(
            child: SingleChildScrollView(
              child: Card(
                margin: EdgeInsets.zero,
                elevation: 3,
                shadowColor: const Color(0x2314365A),
                color: scheme.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(9),
                  side:
                      BorderSide(color: scheme.primary.withValues(alpha: .18)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '快速开始 · ${connected ? 2 : 1} / 2',
                              style: theme.textTheme.labelSmall,
                            ),
                          ),
                          IconButton(
                            style: roundtableIconControlStyle,
                            tooltip: '关闭引导',
                            onPressed: onSkipGuide,
                            icon: const Icon(Icons.close, size: 15),
                          ),
                        ],
                      ),
                      Text(connected ? '添加博主' : '配置渠道',
                          style: theme.textTheme.titleSmall),
                      const SizedBox(height: 5),
                      Text(connected ? '粘贴链接或分享文案，添加第一位博主。' : '先连接一个支持的自媒体渠道。'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        children: [
                          for (final (index, title)
                              in ['1 配置渠道', '2 添加博主'].indexed)
                            DecoratedBox(
                              decoration: BoxDecoration(
                                color: index == (connected ? 1 : 0)
                                    ? scheme.primaryContainer
                                    : scheme.surfaceContainerLow,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 4),
                                child: Text(title,
                                    style: theme.textTheme.labelSmall),
                              ),
                            ),
                        ],
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: OutlinedButton(
                          style: roundtableTextControlStyle,
                          onPressed: onSkipGuide,
                          child: const Text('跳过引导'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          )
        else
          Expanded(
              child: ListView.separated(
            itemCount: creators.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final creator = creators[index];
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: _creatorAvatar(creator, 32),
                title: Text('${creator['name']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Row(children: [
                  Tooltip(
                    message: '抖音',
                    child: Image.asset(
                      ClientAssets.path(
                          'assets/images/creator_roundtable_douyin.png'),
                      width: 14,
                      height: 14,
                      semanticLabel: '抖音',
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text('${creator['work_count']} 个作品'),
                ]),
                trailing: const Icon(CupertinoIcons.chevron_right, size: 14),
                onTap: () => onSelect(creator),
              );
            },
          )),
      ]),
    );
  }

  Future<void> _skipGuide() async {
    setState(() => _guide = false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_guidePreference, true);
  }

  Future<void> _configureChannel() async {
    await showDialog<void>(
      context: context,
      barrierColor: const Color(0x7318273E),
      builder: (_) => const _AddDouyinCreatorDialog(channelOnly: true),
    );
    if (mounted && _guide) await _refreshGuideChannel();
  }

  Future<void> _refreshGuideChannel() async {
    bool connected;
    try {
      connected = (await ref.read(creatorDouyinSessionProvider)()).isNotEmpty;
    } on PlatformException {
      connected = false;
    } on MissingPluginException {
      connected = false;
    }
    if (mounted && connected != _guideChannelConnected) {
      setState(() => _guideChannelConnected = connected);
    }
  }

  Widget _works(LocalRow? selected, LocalWorkspaceStore store, String? model) {
    if (selected == null) {
      return _empty(
          icon: CupertinoIcons.doc_text_search,
          title: '暂无作品',
          body: '添加博主后，真实作品会保存在本机。');
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return FutureBuilder<List<LocalRow>>(
        future: _worksFor(store, selected['id'] as String),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text('作品列表读取失败'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CupertinoActivityIndicator());
          }
          final works = snapshot.data!;
          final work =
              works.where((row) => row['id'] == _selectedWork).firstOrNull ??
                  works.firstOrNull;
          return ListView(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 16),
              children: [
                Text('${selected['name']}',
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Row(children: [
                  _creatorDouyinMark(16),
                  const SizedBox(width: 6),
                  Text('${works.length} 个作品', style: theme.textTheme.bodySmall),
                ]),
                const Divider(height: 22),
                _syncCard(selected, store, model),
                if (selected['channel'] == 'douyin') ...[
                  const SizedBox(height: 8),
                  _expertCard(store, selected, works, model),
                ],
                const SizedBox(height: 12),
                if (work == null)
                  const Padding(
                      padding: EdgeInsets.all(24), child: Text('暂无作品'))
                else
                  LayoutBuilder(builder: (context, constraints) {
                    final list = Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
                            child: Row(children: [
                              Expanded(
                                  child: Text('作品列表',
                                      style: theme.textTheme.titleSmall)),
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  color: scheme.surfaceContainerHigh,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 7, vertical: 4),
                                  child: Text('全部渠道',
                                      style: theme.textTheme.labelSmall),
                                ),
                              ),
                            ]),
                          ),
                          for (final item in works) ...[
                            Material(
                              color: Colors.transparent,
                              child: ListTile(
                                selected: item['id'] == work['id'],
                                selectedTileColor: scheme.primaryContainer,
                                selectedColor: scheme.onPrimaryContainer,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8)),
                                minTileHeight: 62,
                                contentPadding:
                                    const EdgeInsets.symmetric(horizontal: 8),
                                leading: _workThumbnail(item),
                                title: Text('${item['title']}',
                                    style: theme.textTheme.bodyMedium
                                        ?.copyWith(fontWeight: FontWeight.w600),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis),
                                subtitle: Text(_workSubtitle(item),
                                    style: theme.textTheme.bodySmall),
                                trailing: const Icon(
                                    CupertinoIcons.chevron_right,
                                    size: 14),
                                onTap: () => setState(() {
                                  _selectedWork = item['id'] as String?;
                                  _playingWork = null;
                                }),
                              ),
                            ),
                            const Divider(height: 1),
                          ],
                        ]);
                    final detail = _workDetail(work, store);
                    if (constraints.maxWidth < 640) {
                      return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [list, const SizedBox(height: 12), detail]);
                    }
                    return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: 282, child: list),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 12),
                            child: SizedBox(
                                height: 300, child: VerticalDivider(width: 1)),
                          ),
                          Expanded(child: detail),
                        ]);
                  }),
              ]);
        });
  }

  Widget _expertCard(LocalWorkspaceStore store, LocalRow creator,
      List<LocalRow> works, String? model) {
    final id = creator['id'] as String;
    final evidence = creatorEvidence(works);
    final pendingMedia = {
      for (final work in works)
        if (work['source_work_id'] case final String sourceId)
          if ((work['transcript'] as String? ?? '').trim().isEmpty &&
              creatorArchivedMediaName(
                      jsonDecode(work['metadata'] as String? ?? '{}') as Map) !=
                  null)
            sourceId,
    };
    final busy = _expertCancel != null ||
        _importingSubtitles ||
        _mediaJobs.containsKey(id) ||
        _runningSyncs.containsKey(id) ||
        _openSyncDialogs.contains(id);
    return FutureBuilder<List<LocalRow?>>(
      key: ValueKey('roundtable-expert-$id'),
      future: Future.wait([
        store.latestCreatorExpert(id),
        store.lastCreatorExpertJob(id),
      ]),
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null) {
          return ListTile(
            title: const Text('博主专家'),
            subtitle: Text(snapshot.hasError ? '读取专家状态失败。' : '正在读取专家状态…'),
          );
        }
        final [published, task] = data;
        final canResume =
            task != null && {'failed', 'interrupted'}.contains(task['status']);
        final sameUnfinishedEvidence = canResume &&
            !creatorEvidenceHasChanged(
                evidence, task['source_snapshot'] as String);
        final hasNewEvidence = evidence.isNotEmpty &&
            creatorEvidenceHasChanged(
                evidence, published?['evidence'] as String? ?? '[]');
        final canPrepare = published == null && pendingMedia.isNotEmpty;
        final canGenerate = hasNewEvidence && !sameUnfinishedEvidence;
        final title = published != null
            ? '博主专家 · v${published['version']}'
            : canPrepare
                ? '博主专家 · 待转写'
                : evidence.isEmpty
                    ? '博主专家 · 待补充作品'
                    : '博主专家';
        final subtitle = _expertMessages[id] ??
            (published != null && !hasNewEvidence
                ? '已发布，可参与圆桌问答。'
                : canPrepare
                    ? '有 ${pendingMedia.length} 条归档作品待转写。逐字稿将在本机生成，作品证据会发送到所选文本模型。'
                    : evidence.isEmpty
                        ? '可同步作品，或在作品详情补充字幕及图文证据。'
                        : model == null
                            ? '请先回到圆桌页选择模型。'
                            : '按作品证据生成专家，可回看回答出处。');
        final request = canResume
            ? jsonDecode(task['request_payload'] as String) as Map
            : const {};
        final synced = request['trigger'] == 'work-sync';
        return Column(children: [
          ListTile(
            title: Text(title),
            subtitle: Text(subtitle),
            trailing: Wrap(spacing: 8, children: [
              if (published != null)
                IconButton(
                  tooltip: '下载专家 Skill',
                  icon: const Icon(Icons.download),
                  onPressed: () =>
                      _exportExpert(published, '${creator['name']}'),
                ),
              if (canPrepare || canGenerate)
                OutlinedButton(
                  style: roundtableTextControlStyle,
                  onPressed: busy
                      ? null
                      : model == null
                          ? () => setState(() => _tab = 0)
                          : canPrepare
                              ? () => _prepareAndDistillCreator(
                                  store, creator, model, pendingMedia,
                                  priorEvidence: sameUnfinishedEvidence
                                      ? task['source_snapshot'] as String
                                      : null)
                              : () =>
                                  _distillCreator(store, creator, works, model),
                  child: Text(model == null
                      ? '选择模型'
                      : canPrepare
                          ? '补齐逐字稿并蒸馏'
                          : published == null
                              ? '继续生成'
                              : '更新专家'),
                ),
            ]),
          ),
          if (canResume)
            ListTile(
              title: Text(synced ? '知识更新未完成' : '上一次生成未完成'),
              subtitle: Text('${task['error'] ?? '可沿用原模型和证据继续'}'),
              trailing: OutlinedButton(
                style: roundtableTextControlStyle,
                onPressed: busy
                    ? null
                    : () => _distillCreator(store, creator, works, model,
                        retry: task),
                child: Text(synced ? '重试知识更新' : '继续原任务'),
              ),
            ),
        ]);
      },
    );
  }

  Future<void> _prepareAndDistillCreator(
    LocalWorkspaceStore store,
    LocalRow creator,
    String model,
    Set<String> workIds, {
    String? priorEvidence,
  }) async {
    final id = creator['id'] as String;
    if (_mediaJobs.containsKey(id) ||
        _runningSyncs.containsKey(id) ||
        _openSyncDialogs.contains(id) ||
        _importingSubtitles ||
        _expertCancel != null) {
      return;
    }
    final transcriber = CreatorMediaTranscriber();
    final cancel = CancelToken();
    setState(() {
      _mediaJobs[id] = cancel;
      _expertMessages[id] = '正在补齐作品逐字稿…';
    });
    unawaited(cancel.whenCancel.then((_) => transcriber.dispose()));
    try {
      final root = await ref.read(creatorAssetDirectoryProvider)();
      if (!mounted || cancel.isCancelled) return;
      final report = await transcriber.transcribeArchivedWorks(
        store: store,
        creatorId: id,
        workIds: workIds,
        root: root,
        progress: (message) {
          if (mounted && !cancel.isCancelled) {
            setState(() => _expertMessages[id] = message);
          }
        },
      );
      if (!mounted || cancel.isCancelled) return;
      final works = await store.creatorWorks(id);
      if (!mounted || cancel.isCancelled) return;
      setState(() {
        if (report.saved > 0) {
          _mediaMessages[id] = '已生成 ${report.saved} 份逐字稿。'
              '${report.failed > 0 ? ' 还有 ${report.failed} 条作品转写未完成。' : ''}';
          _revision++;
        }
      });
      final evidence = creatorEvidence(works);
      if (evidence.isEmpty ||
          (priorEvidence != null &&
              !creatorEvidenceHasChanged(evidence, priorEvidence))) {
        setState(() => _expertMessages[id] =
            report.failureReason ?? '暂未取得新证据，可检查原片或补充字幕后再试。');
        return;
      }
      if (_expertCancel != null) {
        setState(() => _expertMessages[id] = '逐字稿已保存，当前专家任务结束后可继续生成。');
        return;
      }
      await _distillCreator(store, creator, works, model);
    } catch (_) {
      if (mounted && !cancel.isCancelled) {
        setState(() => _expertMessages[id] = '补齐逐字稿未完成，可重新尝试。');
      }
    } finally {
      transcriber.dispose();
      if (mounted && identical(_mediaJobs[id], cancel)) {
        setState(() => _mediaJobs.remove(id));
      }
    }
  }

  Future<RoundtableModel> _resolveRoundtableModel(
      String? selection, CancelToken cancel) async {
    if (selection == null) throw const CreatorWorkflowException('请在圆桌页选择模型。');
    final config = ref.read(modelServiceStoreProvider);
    final configured = ref.read(modelProvidersProvider).value ?? [];
    final choice = jsonDecode(selection) as List;
    final provider = configured
        .where((entry) => entry.id == choice[0] && entry.enabled)
        .firstOrNull;
    final model = provider?.models
        .where((entry) =>
            entry.modelId == choice[1] &&
            entry.enabled &&
            classifyModelId(entry.modelId) == ModelModality.text)
        .firstOrNull;
    if (provider == null || model == null) {
      throw const CreatorWorkflowException('所选模型已停用，请切换模型后重试。');
    }
    final protocol =
        (await ref.read(modelCatalogProvider.future)).endpointTypeFor(provider);
    final key = await config.getApiKey(provider.id);
    if (key == null || key.trim().isEmpty) {
      throw const CreatorWorkflowException('请先在模型服务中配置 API Key。');
    }
    final client = ref.read(creatorRoundtableModelClientProvider);
    return (
      snapshot: {
        'provider_id': provider.id,
        'model_id': model.modelId,
        'model_name': model.displayName
      },
      complete: (instruction, data) async {
        try {
          return await client.complete(
              provider: provider,
              protocol: protocol,
              model: model.modelId,
              apiKey: key,
              system: instruction,
              messages: [
                {'role': 'user', 'content': jsonEncode(data)}
              ],
              cancelToken: cancel);
        } on LocalModelException catch (error) {
          throw CreatorWorkflowException(error.message);
        }
      },
    );
  }

  Future<bool> _distillCreator(LocalWorkspaceStore store, LocalRow creator,
      List<LocalRow> works, String? selectedModel,
      {LocalRow? retry,
      bool fromSync = false,
      ValueChanged<String>? onProgress}) async {
    if (_expertCancel != null) return false;
    final id = creator['id'] as String;
    final cancel = CancelToken();
    setState(() {
      _expertCancel = cancel;
      _expertMessages[id] = '正在准备作品证据…';
    });
    onProgress?.call('正在准备作品证据…');
    String? jobId;
    try {
      final checkpoint = retry == null
          ? <String, dynamic>{}
          : jsonDecode(retry['result_payload'] as String)
              as Map<String, dynamic>;
      final evidence = retry == null
          ? creatorEvidence(works)
          : (jsonDecode(retry['source_snapshot'] as String) as List)
              .map((entry) => Map<String, Object>.from(entry as Map))
              .toList();
      if (evidence.isEmpty) {
        throw const CreatorWorkflowException('没有可引用的内容，请先添加逐字稿或识别图片文字。');
      }
      final originalModel = retry == null
          ? null
          : jsonDecode(retry['model_snapshot'] as String)
              as Map<String, dynamic>;
      final selection = originalModel == null
          ? selectedModel
          : jsonEncode(
              [originalModel['provider_id'], originalModel['model_id']]);
      final model = await _resolveRoundtableModel(selection, cancel);
      if (cancel.isCancelled) return false;
      final request = retry == null
          ? const <String, dynamic>{}
          : jsonDecode(retry['request_payload'] as String)
              as Map<String, dynamic>;
      final savedIdentity =
          request['creator_identity'] as Map<String, dynamic>?;
      final LocalRow identity;
      if (savedIdentity != null) {
        identity = savedIdentity;
      } else {
        final profile = (await store.creatorProfiles())
            .where((row) => row['id'] == id)
            .firstOrNull;
        if (profile == null) throw StateError('该博主已移除。');
        identity = {
          'name': profile['name'],
          'bio': profile['bio'],
          'channel': profile['channel'],
          'source_account_id': profile['source_account_id'],
          'has_avatar': (profile['avatar_url'] as String?)?.isNotEmpty == true,
        };
      }
      if (cancel.isCancelled) return false;
      if (retry == null) {
        jobId = await store.beginCreatorExpertJob(id, model.snapshot, evidence,
            fromSync: fromSync, creatorIdentity: identity);
      } else {
        final existing = retry['id'] as String;
        await store.resumeCreatorExpertJob(existing);
        jobId = existing;
      }
      final activeJob = jobId;
      final methods = await buildCreatorMethods(evidence, model.complete,
          resumeOffset: checkpoint['evidence_offset'] as int? ?? 0,
          resumeBatch: checkpoint['batch'] as int? ?? 0,
          acceptedMethods: (checkpoint['accepted_methods'] as List? ?? const [])
              .map((entry) => Map<String, Object>.from(entry as Map))
              .toList(),
          onCheckpoint: (offset, batch, methods) => store
              .checkpointCreatorExpertJob(activeJob, offset, batch, methods),
          onBatch: (batch) {
            if (mounted) {
              final message = '正在提炼并复核第 $batch 批证据…';
              setState(() => _expertMessages[id] = message);
              onProgress?.call(message);
            }
          });
      if (cancel.isCancelled) throw const CreatorWorkflowException('专家生成已中断。');
      final previous = await store.latestCreatorExpert(id);
      final baseVersion = previous?['version'] as int? ?? 0;
      final savedMethods = checkpoint['reconciled_base_version'] == baseVersion
          ? checkpoint['reconciled_methods'] as List?
          : null;
      final List<Map<String, Object>> merged;
      if (savedMethods != null) {
        merged = savedMethods
            .map((method) => Map<String, Object>.from(method as Map))
            .toList();
      } else {
        if (mounted && previous != null) {
          const message = '正在核对新版和已发布的方法…';
          setState(() => _expertMessages[id] = message);
          onProgress?.call(message);
        }
        merged = await reconcilePublishedCreatorMethods(
          current: methods,
          evidence: evidence,
          published: previous,
          complete: model.complete,
        );
        if (cancel.isCancelled) {
          throw const CreatorWorkflowException('专家生成已中断。');
        }
        if (previous != null) {
          await store.checkpointCreatorMethodReconciliation(
              activeJob, baseVersion, merged);
        }
      }
      if (cancel.isCancelled) throw const CreatorWorkflowException('专家生成已中断。');
      if (mounted) {
        const message = '正在整理知识图谱主题…';
        setState(() => _expertMessages[id] = message);
        onProgress?.call(message);
      }
      final topics = await buildCreatorGraphTopics(
        methods: merged,
        evidence: evidence,
        published: await store.publishedCreatorExperts(),
        previous: previous,
        complete: model.complete,
        preserveReconciledTopics: true,
      );
      if (cancel.isCancelled) throw const CreatorWorkflowException('专家生成已中断。');
      final precedence = await buildCreatorGraphPrecedence(
        methods: merged,
        evidence: evidence,
        previous: previous,
        complete: model.complete,
      );
      if (cancel.isCancelled) throw const CreatorWorkflowException('专家生成已中断。');
      final version = await store.publishCreatorExpert(
        creatorId: id,
        jobId: jobId,
        methods: merged,
        evidence: evidence,
        graphTopics: topics,
        graphPrecedence: precedence,
        skillProfile: creatorExpertProfile(
          author: identity,
          methods: merged,
          evidence: evidence,
          previousVersion: previous?['version'] as int? ?? 0,
          previousMethods: previous == null
              ? const []
              : ((jsonDecode(previous['content'] as String) as Map)['methods']
                      as List)
                  .whereType<Map<String, dynamic>>()
                  .toList(),
        ),
        expectedBaseVersion: baseVersion,
      );
      if (mounted) {
        final synced = fromSync || request['trigger'] == 'work-sync';
        setState(() {
          _seatExperts.remove((store, id));
          _expertMessages[id] = synced
              ? '知识已更新至 v$version，${merged.length} 条方法通过复核。'
              : '已发布 v$version，${merged.length} 条方法通过复核。';
        });
      }
      return true;
    } catch (error) {
      final message = switch (error) {
        CreatorWorkflowException() => error.message,
        StateError() => error.message.toString(),
        _ => '专家生成失败，请重试。',
      };
      if (jobId != null) await store.failCreatorJob(jobId, message);
      if (mounted) setState(() => _expertMessages[id] = message);
      return false;
    } finally {
      if (mounted) setState(() => _expertCancel = null);
    }
  }

  Widget _syncCard(LocalRow creator, LocalWorkspaceStore store, String? model) {
    final id = creator['id'] as String;
    final scheme = Theme.of(context).colorScheme;
    final open = _openSyncDialogs.contains(id);
    final failure = _syncFailures[id];
    final synced = creator['last_synced'] as int?;
    final date =
        synced == null ? null : DateTime.fromMillisecondsSinceEpoch(synced);
    final time =
        date == null ? null : TimeOfDay.fromDateTime(date).format(context);
    final run = _runningSyncs[id];
    final message = run?.status ??
        failure?.message ??
        _syncMessages[id] ??
        (date == null ? '尚未同步' : '已同步作品');
    final action = failure == null
        ? '立即同步'
        : failure.requiresLogin
            ? '重新授权'
            : '重试';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Color.alphaBlend(
            scheme.primary.withValues(alpha: .035), scheme.surface),
        border: Border.all(color: scheme.primary.withValues(alpha: .14)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListTile(
        onTap: run != null && !open
            ? () => _syncCreator(creator, store, model)
            : null,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        title:
            const Text('作品同步', style: TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 3),
            Text(message,
                style: TextStyle(
                    color: failure != null && run == null
                        ? scheme.error
                        : scheme.onSurfaceVariant)),
            if (run?.savedSummary case final summary?) Text(summary),
            if (date != null)
              Text('最近完成 ${date.month} 月 ${date.day} 日 $time',
                  style: Theme.of(context).textTheme.bodySmall),
            if (_visibleMediaSummary(_mediaMessages[id]) case final media?
                when media != message)
              Text(media),
          ],
        ),
        trailing: OutlinedButton(
          style: roundtableTextControlStyle,
          onPressed: run != null
              ? (open ? null : () => _syncCreator(creator, store, model))
              : (open ||
                      _mediaJobs.containsKey(id) ||
                      creator['channel'] != 'douyin'
                  ? null
                  : () => _syncCreator(creator, store, model)),
          child: Text(run == null ? action : '查看进度'),
        ),
      ),
    );
  }

  Future<void> _syncCreator(
      LocalRow creator, LocalWorkspaceStore store, String? model) async {
    final id = creator['id'] as String;
    if (_openSyncDialogs.contains(id) ||
        (_runningSyncs[id] == null && _mediaJobs.containsKey(id))) {
      return;
    }
    setState(() => _openSyncDialogs.add(id));
    try {
      final current = _runningSyncs[id];
      final pending =
          current == null ? await store.lastResumableCreatorSyncJob(id) : null;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        barrierColor: const Color(0x7318273E),
        builder: (_) => _SyncCreatorDialog(
          pending: pending,
          initialRun: current,
          initialFailure: _syncFailures[id],
          onFailure: (failure) {
            if (mounted) setState(() => _syncFailures[id] = failure);
          },
          onStart: (request) {
            final run = _CreatorSyncRun(
              ref.read(creatorDouyinAdapterProvider)(),
              latest: request.latest,
            );
            setState(() {
              _runningSyncs[id] = run;
              _syncFailures.remove(id);
            });
            unawaited(
                _runCreatorSync(creator, store, model, pending, request, run));
            return run;
          },
          onCancel: (run) => setState(run.cancel),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法读取已保存的同步进度。')));
      }
    } finally {
      if (mounted) setState(() => _openSyncDialogs.remove(id));
    }
  }

  Future<void> _runCreatorSync(
    LocalRow creator,
    LocalWorkspaceStore store,
    String? selectedModel,
    LocalRow? pending,
    _CreatorSyncRequest request,
    _CreatorSyncRun run,
  ) async {
    final id = creator['id'] as String;
    final authorId = creator['source_account_id'] as String?;
    void progress(String status) {
      if (mounted && !run.cancelled) setState(() => run.update(status));
    }

    String? jobId;
    try {
      if (authorId == null || authorId.isEmpty) {
        throw const DouyinCreatorException('缺少抖音博主标识，请重新导入该博主。');
      }
      final resume = pending != null && _syncLatest(pending) == request.latest;
      final checkpoint = resume ? _syncCheckpoint(pending) : null;
      final model = resume
          ? (jsonDecode(pending['model_snapshot'] as String)
              as Map)['selection'] as String?
          : selectedModel;
      final activeJob = await store.beginCreatorSyncJob(
        id,
        latest: request.latest,
        model: model,
        resumeId: resume ? pending['id'] as String : null,
      );
      jobId = activeJob;
      run.recordCheckpoint(checkpoint);
      var pages = run.pages;
      var restored = 0;
      var needsDelay = false;

      Future<void> beforeRequest() async {
        if (needsDelay) await Future<void>.delayed(const Duration(seconds: 1));
        run.checkActive();
        needsDelay = true;
      }

      final result = await collectDouyinWorks(
        authorId: authorId,
        latest: request.latest,
        checkpoint: checkpoint,
        archivedAuthor: {
          'id': authorId,
          'name': creator['name'],
          'bio': creator['bio'],
          'avatar': creator['avatar_url'],
          'followers': creator['followers'],
          'works': creator['work_count'],
        },
        fetch: (cursor, count) async {
          await beforeRequest();
          pages++;
          progress('第 $pages 页 · 正在读取公开作品…');
          return run.adapter.readAuthorPage(
            cookie: request.cookie,
            authorId: authorId,
            cursor: cursor,
            count: count,
            onStatus: (status) => progress('第 $pages 页 · $status'),
          );
        },
        onPage: (checkpoint) async {
          run.checkActive();
          await store.checkpointCreatorSyncJob(activeJob, checkpoint);
          run.recordCheckpoint(checkpoint);
        },
        restoreWork: (workId) async {
          await beforeRequest();
          restored++;
          progress('正在补取已读取页的第 $restored 条作品详情…');
          return run.adapter.readSyncedWork(
            cookie: request.cookie,
            authorId: authorId,
            workId: workId,
            onStatus: (_) {},
          );
        },
      );
      run.checkActive();
      run.saving = true;
      progress('正在保存 ${result.works.length} 条作品…');
      final saved = await store.importCreatorWorks(
        result.author,
        result.works,
        syncJobId: activeJob,
      );
      if (!mounted) return;
      final message =
          saved.added == 0 ? '暂无新作品，已核对所选范围。' : '已同步 ${saved.added} 条新作品。';
      setState(() {
        _syncMessages[id] = message;
        _revision++;
      });
      run.savedSummary = message;
      await _updateSyncedKnowledge(creator, store, model, result.works, run);
      if (mounted) run.finish(_expertMessages[id] ?? '同步处理完成。');
    } catch (error) {
      var message = run.cancelled
          ? _CreatorSyncRun.cancelledMessage
          : switch (error) {
              DouyinCreatorException(:final message) => message,
              StateError(:final message) => message.toString(),
              _ => '作品同步失败，请确认抖音登录状态和网络后重试。',
            };
      if (jobId != null) {
        try {
          await store.failCreatorJob(jobId, message);
        } catch (_) {
          message = '无法保存同步状态，请重开应用后检查进度。';
        }
      }
      if (mounted) {
        run.finish(message, failed: true);
        setState(() => _syncFailures[id] = (
              message: message,
              requiresLogin: !run.cancelled &&
                  error is DouyinCreatorException &&
                  error.requiresLogin,
              latest: request.latest,
            ));
      }
    } finally {
      run.adapter.close();
      if (mounted) setState(() => _runningSyncs.remove(id));
    }
  }

  Future<void> _updateSyncedKnowledge(
      LocalRow creator,
      LocalWorkspaceStore store,
      String? model,
      List<Map<String, dynamic>> synced,
      _CreatorSyncRun run) async {
    final id = creator['id'] as String;
    final request = _syncKnowledgeRequests[id] = Object();
    bool active() => mounted && identical(_syncKnowledgeRequests[id], request);
    const checking = '正在检查可更新的作品证据…';
    try {
      if (_expertCancel == null) {
        setState(() => _expertMessages[id] = checking);
      }
      run.mediaSummary =
          await _archiveRemoteMedia(store, id, synced, onProgress: run.update);
      if (!active()) return;
      run.update(checking);
      final works = await store.creatorWorks(id);
      final evidence = creatorEvidence(works);
      final published = await store.latestCreatorExpert(id);
      if (!active()) return;
      if (_expertCancel != null) return;
      if (evidence.isEmpty) {
        setState(() => _expertMessages[id] = '暂无可更新的证据，可补充逐字稿或图片文字。');
        return;
      }
      if (!creatorEvidenceHasChanged(
          evidence, published?['evidence'] as String? ?? '[]')) {
        setState(() => _expertMessages[id] = '知识已是当前版本。');
        return;
      }
      final pending = await store.lastCreatorExpertJob(id);
      if (!active() || _expertCancel != null) return;
      if (pending != null &&
          {'failed', 'interrupted'}.contains(pending['status']) &&
          !creatorEvidenceHasChanged(
              evidence, pending['source_snapshot'] as String)) {
        setState(() => _expertMessages[id] = '已有未完成的知识任务，可直接重试。');
        return;
      }
      if (model == null) {
        setState(() => _expertMessages[id] = '有新证据，选择可用模型后可更新知识。');
        return;
      }
      await _distillCreator(store, creator, works, model,
          fromSync: true, onProgress: run.update);
    } catch (_) {
      if (active()) {
        setState(() => _expertMessages[id] = '已保存作品，知识暂未更新，可手动重试。');
      }
    } finally {
      if (active() && _expertMessages[id] == checking) {
        setState(() => _expertMessages[id] = '作品已同步，可在专家任务结束后更新知识。');
      }
      if (identical(_syncKnowledgeRequests[id], request)) {
        _syncKnowledgeRequests.remove(id);
      }
    }
  }

  Future<String?> _archiveRemoteMedia(
      LocalWorkspaceStore store, String id, List<Map<String, dynamic>> works,
      {ValueChanged<String>? onTranscribing,
      ValueChanged<String>? onProgress}) async {
    if (!works.any((work) =>
        work.containsKey('media_url') ||
        work.containsKey('subtitle_url') ||
        (work['images'] as List?)?.isNotEmpty == true)) {
      return null;
    }
    _mediaJobs[id]?.cancel();
    final cancel = _mediaJobs[id] = CancelToken();
    void mediaProgress(String message) {
      if (!mounted || cancel.isCancelled) return;
      setState(() => _mediaMessages[id] = message);
      onProgress?.call(message);
    }

    mediaProgress('正在下载作品媒体…');
    final archiver = CreatorRemoteMedia();
    final transcriber = CreatorMediaTranscriber();
    unawaited(cancel.whenCancel.then((_) => transcriber.dispose()));
    try {
      final root = await ref.read(creatorAssetDirectoryProvider)();
      String? downloadFailure;
      final report = await archiver.archive(
        store: store,
        creatorId: id,
        works: works,
        root: root,
        maxBytes: maxCreatorMediaBytes,
        onVideoFailure: (reason) => downloadFailure ??= reason,
        onWork: (current, total) =>
            mediaProgress('正在处理第 $current / $total 条作品的媒体和字幕…'),
        cancel: cancel,
      );
      if (!mounted || cancel.isCancelled) return null;
      final transcription = await transcriber.transcribeArchivedWorks(
        store: store,
        creatorId: id,
        workIds: {
          for (final work in works)
            if (work['media_url'] is String) work['id'] as String,
        },
        root: root,
        progress: (message) {
          if (mounted && !cancel.isCancelled) {
            mediaProgress(message);
            onTranscribing?.call(message);
          }
        },
      );
      if (!mounted || cancel.isCancelled) return null;
      final messages = [
        if (report.archived > 0) '已下载 ${report.archived} 个视频。',
        if (report.failed > 0) '${report.failed} 个视频未下载成功，可再次同步。',
        if (downloadFailure != null) downloadFailure!,
        if (report.transcripts > 0) '已保存 ${report.transcripts} 份平台字幕。',
        if (report.failedSubtitles > 0)
          '${report.failedSubtitles} 份平台字幕未归档，可再次同步。',
        if (transcription.saved > 0) '已补充 ${transcription.saved} 份本机逐字稿。',
        if (transcription.failed > 0) '${transcription.failed} 条作品尚无逐字稿。',
        if (report.images > 0) '已归档 ${report.images} 张图片。',
        if (report.failedImages > 0) '${report.failedImages} 张图片未归档，可再次同步。',
      ];
      setState(() {
        if (messages.isEmpty) {
          _mediaMessages.remove(id);
        } else {
          _mediaMessages[id] = messages.join(' ');
        }
        _revision++;
      });
      return _mediaMessages[id];
    } catch (_) {
      if (!mounted || cancel.isCancelled) return null;
      const message = '媒体下载未完成，可再次同步。';
      setState(() => _mediaMessages[id] = message);
      return message;
    } finally {
      transcriber.dispose();
      archiver.close();
      if (identical(_mediaJobs[id], cancel)) _mediaJobs.remove(id);
    }
  }

  Future<void> _exportExpert(LocalRow expert, String name) async {
    try {
      final bytes = bundlePublishedCreatorExpert(expert, name);
      final safeName =
          name.replaceAll(RegExp(r'[^\p{L}\p{N} _-]', unicode: true), '_');
      final fileName = '$safeName-v${expert['version']}.zip';
      final location = await getSaveLocation(suggestedName: fileName);
      if (location != null) {
        await XFile.fromData(bytes, name: fileName, mimeType: 'application/zip')
            .saveTo(location.path);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法导出专家技能包。')));
      }
    }
  }

  static const _archivableMedia =
      XTypeGroup(label: '可播放音视频', extensions: ['mp4', 'mov', 'm4a']);

  Future<File> _mediaFile(String name) async {
    final root = await ref.read(creatorAssetDirectoryProvider)();
    return File('${root.path}/media/$name');
  }

  Future<void> _archiveWorkMedia(
      LocalWorkspaceStore store, LocalRow work) async {
    setState(() => _importingSubtitles = true);
    File? output;
    var saved = false;
    try {
      final input = await openFile(acceptedTypeGroups: [_archivableMedia]);
      if (!mounted || input == null) return;
      final extension = input.name.split('.').last.toLowerCase();
      if (!_archivableMedia.extensions!.contains(extension)) {
        throw const FormatException('请选择 MP4、MOV 或 M4A 文件。');
      }
      const maxBytes = maxCreatorMediaBytes;
      final length = await input.length();
      if (length <= 0 || length > maxBytes) {
        throw const FormatException('归档文件须大于 0 字节且不超过 256 MiB。');
      }
      final name = '${LocalWorkspaceStore.uuid.v4()}.$extension';
      output = await _mediaFile(name);
      await output.parent.create(recursive: true);
      final writer = output.openWrite();
      var written = 0;
      try {
        await writer.addStream(input.openRead().map((chunk) {
          written += chunk.length;
          if (written > maxBytes) {
            throw const FormatException('归档文件超过 256 MiB。');
          }
          return chunk;
        }));
      } finally {
        await writer.close();
      }
      if (written != length) throw const FormatException('媒体在归档期间发生变化，请重新选择。');
      if (!mounted) return;
      final digest = await sha256.bind(output.openRead()).first;
      saved = await store.saveCreatorMedia(
        workId: work['id'] as String,
        sourceVersion: work['source_version'] as int,
        fileName: name,
        digest: digest.toString(),
      );
      if (saved) _refreshAfterWorkEdit(work);
    } catch (error) {
      if (mounted) {
        final message = switch (error) {
          FormatException() => error.message,
          StateError() => error.message.toString(),
          _ => '媒体归档失败，请检查文件和本机存储。',
        };
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (!saved && output != null) {
        try {
          if (await output.exists()) await output.delete();
        } on FileSystemException {
          // A failed import has no reference from a work.
        }
      }
      if (mounted) setState(() => _importingSubtitles = false);
    }
  }

  Future<void> _previewWorkMedia(String name, String title) async {
    final file = await _mediaFile(name);
    final large = await file.exists() &&
        await file.length() > attachmentPreviewLimit('video');
    if (!mounted) return;
    if (large) {
      await _openCreatorLocalVideo(context, file.uri);
      return;
    }
    final extension = name.split('.').last;
    await _showFilePreview(AttachmentPreviewTarget(
      url: file.uri.toString(),
      name: '$title.$extension',
      mime: extension == 'mov' ? 'video/quicktime' : 'video/mp4',
    ));
  }

  Future<bool> _recognizeWorkImage(
      LocalWorkspaceStore store, LocalRow work, int index, String image) async {
    if (_importingSubtitles) return false;
    final readImage = ref.read(creatorImageReaderProvider);
    setState(() => _importingSubtitles = true);
    try {
      final metadata = jsonDecode(work['metadata'] as String? ?? '{}') as Map;
      final local = await _workImageFile(metadata, index, image);
      final bytes =
          local == null ? await readImage(image) : await local.readAsBytes();
      final text = await recognizeCreatorImage(bytes);
      if (!mounted) return false;
      await store.saveCreatorImageText(
        workId: work['id'] as String,
        sourceVersion: work['source_version'] as int,
        index: index,
        image: image,
        text: text,
      );
      _refreshAfterWorkEdit(work);
      return true;
    } catch (error) {
      if (mounted) {
        final message = switch (error) {
          FormatException() => error.message,
          StateError() => error.message.toString(),
          PlatformException() => error.message ?? '本机文字识别失败。',
          _ => '无法读取或识别图片，请稍后重试。',
        };
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
      return false;
    } finally {
      if (mounted) setState(() => _importingSubtitles = false);
    }
  }

  Future<File?> _workImageFile(Map metadata, int index, String source) async {
    final name = creatorArchivedImageName(metadata, index, source);
    if (name == null) return null;
    final root = await ref.read(creatorAssetDirectoryProvider)();
    final file = File('${root.path}/images/$name');
    try {
      final size = await file.length();
      return size > 0 && size <= maxCreatorImageBytes ? file : null;
    } on FileSystemException {
      return null;
    }
  }

  Widget _workThumbnail(LocalRow work) {
    const size = 48.0;
    final metadata = jsonDecode(work['metadata'] as String? ?? '{}') as Map;
    final firstImage = (metadata['images'] as List? ?? const [])
        .whereType<String>()
        .firstOrNull;
    final source = (firstImage ?? work['cover_url'] as String? ?? '').trim();
    final fallback = Center(child: _creatorDouyinMark(17));
    return SizedBox.square(
      dimension: size,
      child: source.isEmpty
          ? fallback
          : _workImage(metadata, 0, source,
              width: size,
              height: size,
              fit: BoxFit.cover,
              borderRadius: 6,
              fallback: fallback),
    );
  }

  Widget _workImage(Map metadata, int index, String source,
      {required double width,
      required double height,
      required BoxFit fit,
      double borderRadius = 0,
      Widget? fallback}) {
    final remote = UiNetworkImage(
        imageUrl: source,
        width: width,
        height: height,
        fit: fit,
        borderRadius: borderRadius,
        httpHeaders: const {},
        placeholderBuilder: fallback == null ? null : (_, __) => fallback,
        errorBuilder: fallback == null ? null : (_, __, ___) => fallback);
    if (creatorArchivedImageName(metadata, index, source) == null) {
      return remote;
    }
    return FutureBuilder<File?>(
      future: _workImageFile(metadata, index, source),
      builder: (context, snapshot) {
        final file = snapshot.data;
        if (file == null) {
          return snapshot.connectionState == ConnectionState.done
              ? remote
              : fallback ?? SizedBox(width: width, height: height);
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: Image.file(file,
              width: width,
              height: height,
              fit: fit,
              errorBuilder: (_, __, ___) => remote),
        );
      },
    );
  }

  Future<void> _importSubtitles(LocalWorkspaceStore store, LocalRow work,
      {bool media = false, String? archivedMedia}) async {
    setState(() => _importingSubtitles = true);
    CreatorMediaTranscriber? transcriber;
    try {
      final file = archivedMedia != null
          ? XFile((await _mediaFile(archivedMedia)).path)
          : await openFile(acceptedTypeGroups: [
              if (media)
                const XTypeGroup(label: '本地音视频', extensions: [
                  'mp4',
                  'mov',
                  'm4a',
                  'mkv',
                  'webm',
                  'mp3',
                  'wav',
                  'flac',
                  'aac',
                  'ogg'
                ])
              else
                const XTypeGroup(label: '字幕', extensions: ['srt', 'vtt']),
            ]);
      if (!mounted || file == null) return;
      final List<CreatorSubtitle> cues;
      var source = 'local_subtitle';
      if (media) {
        transcriber = CreatorMediaTranscriber();
        _transcriber = transcriber;
        final result = await transcriber.transcribe(
          media: file.path,
          progress: (message) {
            if (mounted) setState(() => _transcriptionProgress = message);
          },
        );
        cues = result.cues;
        source = result.source;
      } else {
        if (await file.length() > maxCreatorSubtitleBytes) {
          throw const FormatException('字幕文件不能超过 2 MB。');
        }
        cues = parseCreatorSubtitles(await file.readAsString());
      }
      if (!mounted) return;
      await store.saveCreatorTranscript(
        workId: work['id'] as String,
        sourceVersion: work['source_version'] as int,
        source: source,
        archivedMedia: archivedMedia,
        transcript: cues
            .map((cue) =>
                '${creatorTimecode(cue.startMs)} → ${creatorTimecode(cue.endMs)}\n${cue.text}')
            .join('\n\n'),
        cues: [
          for (final cue in cues)
            {'start_ms': cue.startMs, 'end_ms': cue.endMs, 'text': cue.text},
        ],
      );
      _refreshAfterWorkEdit(work);
    } catch (error) {
      if (mounted) {
        final message = switch (error) {
          FormatException() => error.message,
          StateError() => error.message.toString(),
          CreatorWorkflowException() => error.message,
          _ => '字幕读取失败，请确认文件可访问且为 UTF-8 编码。',
        };
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      transcriber?.dispose();
      _transcriber = null;
      if (mounted) {
        setState(() {
          _importingSubtitles = false;
          _transcriptionProgress = null;
        });
      }
    }
  }

  void _refreshAfterWorkEdit(LocalRow work) {
    if (!mounted) return;
    setState(() {
      if (_expertCancel == null) _expertMessages.remove(work['creator_id']);
      _revision++;
    });
  }

  Widget _creatorDouyinMark(double size) => Image.asset(
        ClientAssets.path('assets/images/creator_roundtable_douyin.png'),
        width: size,
        height: size,
        semanticLabel: '抖音',
      );

  String _workType(LocalRow work) {
    final metadata = jsonDecode(work['metadata'] as String? ?? '{}') as Map;
    if ((metadata['images'] as List?)?.isNotEmpty == true ||
        creatorArticleParagraphs(metadata).isNotEmpty ||
        Uri.tryParse('${work['source_url']}')?.path.startsWith('/note/') ==
            true) {
      return '图文';
    }
    final media = creatorArchivedMediaName(metadata)?.toLowerCase();
    return media?.endsWith('.m4a') == true ? '音频' : '视频';
  }

  String _shortWorkTime(int milliseconds) {
    final time = Duration(milliseconds: milliseconds);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.inHours > 0 ? '${two(time.inHours)}:' : ''}'
        '${two(time.inMinutes.remainder(60))}:${two(time.inSeconds.remainder(60))}';
  }

  String _workSubtitle(LocalRow work) {
    final kind = _workType(work);
    final metadata = jsonDecode(work['metadata'] as String? ?? '{}') as Map;
    final duration = metadata['duration_ms'];
    return duration is int && duration > 0 && kind != '图文'
        ? '$kind · ${_shortWorkTime(duration)}'
        : kind;
  }

  Widget _workDetail(LocalRow work, LocalWorkspaceStore store,
      {bool readOnly = false, int? highlightedParagraph}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final transcript = work['transcript'] as String? ?? '';
    final metadata = jsonDecode(work['metadata'] as String? ?? '{}') as Map;
    final archivedMedia = creatorArchivedMediaName(metadata);
    final images =
        (metadata['images'] as List? ?? const []).whereType<String>().toList();
    final cover = work['cover_url'] as String? ?? '';
    final paragraphs = creatorArticleParagraphs(metadata);
    final title = work['title'] as String? ?? '';
    final cues = [
      for (final cue in (metadata['transcript_cues'] as List? ?? const [])
          .whereType<Map>())
        if (cue['start_ms'] is int && cue['text'] is String) cue,
    ];
    final kind = _workType(work);
    final playing =
        !readOnly && archivedMedia != null && _playingWork == work['id'];
    void showTranscript() => setState(() => _playingWork = null);
    return Container(
      decoration: BoxDecoration(
        color: Color.alphaBlend(
            scheme.primary.withValues(alpha: .035), scheme.surface),
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          _creatorDouyinMark(17),
          const SizedBox(width: 6),
          Expanded(child: Text(kind == '图文' ? '抖音图文' : kind)),
          OutlinedButton.icon(
            style: roundtableTextControlStyle,
            icon: const Icon(Icons.north_east, size: 14),
            onPressed: () => launchUrl(Uri.parse('${work['source_url']}'),
                mode: LaunchMode.externalApplication),
            label: const Text('打开原地址'),
          ),
        ]),
        if (paragraphs.isEmpty) ...[
          const SizedBox(height: 10),
          Text(title,
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
        ],
        if (!readOnly && kind != '图文')
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '${archivedMedia == null ? '原片尚未下载到本机' : '原片已归档'}'
              ' · ${transcript.isEmpty ? '暂无逐字稿' : '已保存逐字稿'}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        if (archivedMedia != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: readOnly
                ? OutlinedButton.icon(
                    style: roundtableTextControlStyle,
                    onPressed: () => _previewWorkMedia(archivedMedia, title),
                    icon: const Icon(CupertinoIcons.play),
                    label: Text(kind == '音频' ? '播放音频' : '播放视频'),
                  )
                : UiSegmentedTabs<bool>(
                    key: const ValueKey('roundtable-work-view'),
                    height: roundtableControlHeight,
                    trackColor: scheme.surfaceContainerHighest,
                    pillColor: scheme.surface,
                    activeColor: scheme.primary,
                    inactiveColor: scheme.onSurfaceVariant,
                    current: playing,
                    tabs: [
                      UiSegmentedTab(
                        value: true,
                        label: kind == '音频' ? '播放音频' : '播放视频',
                        icon: CupertinoIcons.play,
                      ),
                      const UiSegmentedTab(value: false, label: '逐字稿'),
                    ],
                    onChanged: (showMedia) => setState(() =>
                        _playingWork = showMedia ? work['id'] as String : null),
                  ),
          ),
        if (playing) ...[
          const SizedBox(height: 9),
          _CreatorInlineMedia(
            key: ValueKey(archivedMedia),
            title: title,
            name: archivedMedia,
            audio: kind == '音频',
            read: _mediaFile,
            onClose: showTranscript,
          ),
        ],
        if (!playing &&
            (images.isNotEmpty ||
                (readOnly && transcript.isEmpty && cover.isNotEmpty))) ...[
          const SizedBox(height: 8),
          SizedBox(
              height: 124,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: images.isEmpty ? 1 : images.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final url = images.isEmpty ? cover : images[index];
                  return InkWell(
                    key: ValueKey('creator-work-image-$index'),
                    onTap: () => showDialog<void>(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                              title: Text(images.isEmpty
                                  ? '作品封面'
                                  : '图文 · 第 ${index + 1} 张'),
                              content: _workImage(metadata, index, url,
                                  width: 500, height: 400, fit: BoxFit.contain),
                              actions: [
                                if (Platform.isMacOS &&
                                    images.isNotEmpty &&
                                    !readOnly)
                                  FilledButton(
                                    onPressed: () async {
                                      final done = await _recognizeWorkImage(
                                          store, work, index, url);
                                      if (done && dialogContext.mounted) {
                                        Navigator.of(dialogContext).pop();
                                      }
                                    },
                                    child: const Text('识别图片文字'),
                                  ),
                              ],
                            )),
                    child: _workImage(metadata, index, url,
                        width: 150,
                        height: 124,
                        borderRadius: 6,
                        fit: BoxFit.cover),
                  );
                },
              )),
        ],
        if (paragraphs.isNotEmpty) ...[
          const SizedBox(height: 12),
          _articleBody(context, work, paragraphs, highlightedParagraph),
        ],
        const SizedBox(height: 12),
        for (final (:index, :text) in creatorImageTexts(metadata))
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('第 ${index + 1} 张图片 · 识别文字'),
                  SelectableText(text)
                ],
              ),
            ),
          ),
        if (!playing)
          Card(
            elevation: 0,
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('逐字稿', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    if (_transcriptionProgress case final String progress) ...[
                      const LinearProgressIndicator(),
                      Text(progress),
                    ],
                    if (!readOnly &&
                        kind != '图文' &&
                        archivedMedia != null &&
                        transcript.isEmpty &&
                        cues.isEmpty &&
                        _transcriptionProgress == null) ...[
                      const Text('可在上方补齐逐字稿并蒸馏，也可展开「补充资料」手动转写。'),
                      const SizedBox(height: 6),
                    ],
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: (MediaQuery.sizeOf(context).height * .42)
                            .clamp(160.0, 360.0),
                      ),
                      child: SingleChildScrollView(
                        key: ValueKey('roundtable-transcript-${work['id']}'),
                        primary: false,
                        padding: const EdgeInsets.only(right: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (readOnly || cues.isEmpty)
                              SelectableText(
                                  transcript.isEmpty ? '暂无逐字稿' : transcript)
                            else
                              for (final cue in cues)
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 6),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SizedBox(
                                        width: 66,
                                        child: Text(
                                            _shortWorkTime(
                                                cue['start_ms'] as int),
                                            style: theme.textTheme.labelSmall),
                                      ),
                                      Expanded(
                                          child: SelectableText(
                                              cue['text'] as String)),
                                    ],
                                  ),
                                ),
                          ],
                        ),
                      ),
                    ),
                  ]),
            ),
          ),
        if (!readOnly && !playing) ...[
          const SizedBox(height: 12),
          ExpansionTile(
            key: ValueKey('creator-work-tools-${work['id']}'),
            title: const Text('补充资料'),
            tilePadding: EdgeInsets.zero,
            expandedAlignment: Alignment.centerLeft,
            children: [
              Wrap(spacing: 8, runSpacing: 6, children: [
                if (!readOnly)
                  OutlinedButton(
                      style: roundtableTextControlStyle,
                      onPressed: (_importingSubtitles ||
                              _mediaJobs.containsKey(work['creator_id']))
                          ? null
                          : () => _archiveWorkMedia(store, work),
                      child:
                          Text(archivedMedia == null ? '归档本地音视频' : '更换归档媒体')),
                if (!readOnly && archivedMedia != null)
                  OutlinedButton(
                      style: roundtableTextControlStyle,
                      onPressed: (_importingSubtitles ||
                              _mediaJobs.containsKey(work['creator_id']))
                          ? null
                          : () => _importSubtitles(store, work,
                              media: true, archivedMedia: archivedMedia),
                      child: const Text('转写归档媒体')),
                OutlinedButton(
                  style: roundtableTextControlStyle,
                  onPressed: (_importingSubtitles ||
                              _mediaJobs.containsKey(work['creator_id'])) ||
                          work['source_version'] == null
                      ? null
                      : () => _importSubtitles(store, work),
                  child: const Text('导入字幕'),
                ),
                OutlinedButton(
                  style: roundtableTextControlStyle,
                  onPressed: (_importingSubtitles ||
                              _mediaJobs.containsKey(work['creator_id'])) ||
                          work['source_version'] == null
                      ? null
                      : () => _importSubtitles(store, work, media: true),
                  child: const Text('转写本地音视频'),
                ),
              ]),
            ],
          ),
        ],
        if (['likes', 'comments', 'collects']
            .any((key) => (work[key] as num? ?? 0) > 0))
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
                '${work['likes'] ?? 0} 赞 · ${work['comments'] ?? 0} 评论 · ${work['collects'] ?? 0} 收藏',
                style: theme.textTheme.bodySmall),
          ),
      ]),
    );
  }

  Widget _articleBody(BuildContext context, LocalRow work,
      List<String> paragraphs, int? highlightedParagraph) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final title = work['title'] as String? ?? '';
    final headlineIsFirstParagraph =
        creatorArticleParagraphs({'article_body': title}).join('\n') ==
                paragraphs.join('\n') ||
            title.trim() == paragraphs.first;
    final headline = title.trim().isEmpty || headlineIsFirstParagraph
        ? paragraphs.first
        : title;
    final publishedAt = work['published_at'] as int? ?? 0;
    final signals = creatorArticleSignals(paragraphs)
        .where((signal) => !headlineIsFirstParagraph || signal.index > 0)
        .toList();
    final cards = {for (final signal in signals) signal.index: signal};
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colors.primaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (publishedAt > 0)
                Text(
                    DateTime.fromMillisecondsSinceEpoch(publishedAt)
                        .toIso8601String()
                        .split('T')
                        .first,
                    style: theme.textTheme.labelSmall),
              if (headlineIsFirstParagraph && highlightedParagraph == 1)
                const Text('正文第 1 段'),
              SelectableText(headline,
                  style: theme.textTheme.titleLarge
                      ?.copyWith(color: colors.onPrimaryContainer)),
            ]),
          ),
          LayoutBuilder(builder: (context, constraints) {
            final columns = constraints.maxWidth >= 600 ? 3 : 1;
            final cardWidth =
                (constraints.maxWidth - 8 * (columns - 1)) / columns;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (index, paragraph) in paragraphs.indexed)
                  if (!headlineIsFirstParagraph || index > 0)
                    if (cards[index] case final card?)
                      Container(
                        width: cardWidth,
                        margin: const EdgeInsets.only(top: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: highlightedParagraph == index + 1
                              ? colors.primaryContainer
                              : colors.surface,
                          border: Border.all(color: colors.outlineVariant),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  creatorEvidenceLocation(
                                      {'paragraph_number': index + 1}),
                                  style: theme.textTheme.labelSmall
                                      ?.copyWith(color: colors.primary)),
                              Text(card.label,
                                  style: theme.textTheme.titleSmall),
                              SelectableText(card.text),
                            ]),
                      )
                    else
                      Container(
                        width: constraints.maxWidth,
                        margin: const EdgeInsets.only(top: 8),
                        padding: highlightedParagraph == index + 1
                            ? const EdgeInsets.all(8)
                            : EdgeInsets.zero,
                        decoration: highlightedParagraph == index + 1
                            ? BoxDecoration(
                                color: colors.primaryContainer,
                                borderRadius: BorderRadius.circular(8))
                            : null,
                        child: SelectableText(paragraph),
                      ),
              ],
            );
          }),
        ]),
      ),
    );
  }

  Future<void> _showArchivedWork(
      LocalWorkspaceStore store, Map<String, dynamic> evidence,
      {String? creatorId}) async {
    final LocalRow? work;
    try {
      final id = evidence['work_id'];
      work = creatorId == null
          ? id is String
              ? await store.creatorWork(id)
              : null
          : (await store.creatorWorks(creatorId))
              .where((row) => row['id'] == id)
              .firstOrNull;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法读取归档作品。')));
      }
      return;
    }
    if (!mounted) return;
    final historical =
        work != null && work['source_version'] != evidence['source_version'];
    final time = creatorEvidenceLocation(evidence);
    await showDialog<void>(
      context: context,
      builder: (context) => UiContentDialog(
        size: UiDialogSize.wide,
        maxHeight: 690,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            UiSheetHeader(
                title: '关联作品', onClose: () => Navigator.of(context).pop()),
            const SizedBox(height: 16),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(historical ? '历史版本引用 · $time' : '专家引用 · $time'),
                    const SizedBox(height: 6),
                    SelectableText(evidence['text'] as String),
                    const SizedBox(height: 16),
                    if (work == null)
                      const Text('本机归档中找不到该作品。')
                    else
                      _workDetail(work, store,
                          readOnly: true,
                          highlightedParagraph: historical
                              ? null
                              : evidence['paragraph_number'] as int?),
                  ],
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Future<List<LocalRow>> _publishedExperts(
          LocalWorkspaceStore store, List<LocalRow> creators) async =>
      [
        for (final creator in creators)
          if (await store.latestCreatorExpert(creator['id'] as String)
              case final LocalRow expert)
            {...expert, 'name': creator['name']},
      ];

  Widget _knowledge(LocalWorkspaceStore store, List<LocalRow> creators,
      String? selectedModel) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final frame = BoxDecoration(
      color: scheme.surface,
      border: Border.all(color: scheme.outlineVariant),
      borderRadius: BorderRadius.circular(10),
    );
    final published = _publishedExperts(store, creators);
    final assetList = store.creatorAssets();
    return ListView(padding: const EdgeInsets.all(16), children: [
      Container(
          decoration: frame,
          clipBehavior: Clip.antiAlias,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
                padding: const EdgeInsets.all(12),
                child: Text('知识图谱', style: theme.textTheme.titleMedium)),
            FutureBuilder<List<LocalRow>>(
              future: published,
              builder: (context, state) {
                if (state.hasError) {
                  return const Padding(
                      padding: EdgeInsets.all(16), child: Text('无法读取已发布的知识。'));
                }
                final experts = state.data;
                if (experts == null) {
                  return const Center(child: LinearProgressIndicator());
                }
                if (experts.isNotEmpty) {
                  return SizedBox(
                      height: 440,
                      child: CreatorRoundtableGraph(
                        experts: experts,
                        onOpenWork: (creatorId, evidence) => _showArchivedWork(
                            store, evidence,
                            creatorId: creatorId),
                      ));
                }
                return ColoredBox(
                    color: scheme.surfaceContainerLow,
                    child: SizedBox(
                        height: 210,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text('暂无知识图谱',
                                style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            const Text('蒸馏博主后，这里会展示提炼出的主题和关联作品。'),
                            const SizedBox(height: 8),
                            FilledButton(
                                onPressed: () =>
                                    _addCreator(store, selectedModel),
                                child: const Text('前往添加博主')),
                          ],
                        )));
              },
            ),
          ])),
      const SizedBox(height: 16),
      Text('资产工作台', style: theme.textTheme.titleMedium),
      const SizedBox(height: 8),
      LayoutBuilder(builder: (context, size) {
        final columns = size.maxWidth >= 660 ? 3 : 1;
        return Wrap(spacing: 12, runSpacing: 12, children: [
          for (final kind in CreatorAssetKind.values)
            Container(
              width: (size.maxWidth - 12 * (columns - 1)) / columns,
              decoration: frame,
              clipBehavior: Clip.antiAlias,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AspectRatio(
                        aspectRatio: 3.58,
                        child: Image.asset(
                          ClientAssets.path(
                              'assets/images/roundtable_${kind.name}.png'),
                          fit: BoxFit.cover,
                          excludeFromSemantics: true,
                        )),
                    Padding(
                        padding: const EdgeInsets.all(10),
                        child: Row(children: [
                          Expanded(
                              child: Text(kind.label,
                                  style: theme.textTheme.titleSmall)),
                          FutureBuilder<List<LocalRow>>(
                              future: published,
                              builder: (context, snapshot) {
                                final experts = snapshot.data ?? const [];
                                final canGenerate =
                                    selectedModel != null && experts.isNotEmpty;
                                Widget action(bool canOpen) => FilledButton(
                                    key: ValueKey(
                                        'creator-generate-${kind.name}'),
                                    onPressed: !canOpen
                                        ? null
                                        : () async {
                                            final success = await showDialog<
                                                    bool>(
                                                context: context,
                                                barrierDismissible: false,
                                                barrierColor:
                                                    const Color(0x7318273E),
                                                builder: (_) =>
                                                    CreatorAssetDialog(
                                                      kind: kind,
                                                      experts: experts,
                                                      store: store,
                                                      canGenerate: canGenerate,
                                                      resolveOriginalModel: (model,
                                                              token) =>
                                                          _resolveRoundtableModel(
                                                        jsonEncode([
                                                          model['provider_id'],
                                                          model['model_id']
                                                        ]),
                                                        token,
                                                      ),
                                                      resolveModel: (token) =>
                                                          _resolveRoundtableModel(
                                                              selectedModel,
                                                              token),
                                                    ));
                                            if (mounted && success == true) {
                                              setState(() {});
                                            }
                                          },
                                    child: const Text('开始生成'));
                                if (canGenerate) return action(true);
                                return FutureBuilder<LocalRow?>(
                                  future: store
                                      .lastResumableCreatorAssetJob(kind.name),
                                  builder: (context, pending) =>
                                      action(pending.hasData),
                                );
                              }),
                        ])),
                    const Divider(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('最近生成', style: theme.textTheme.labelSmall),
                          const SizedBox(height: 6),
                          FutureBuilder<List<LocalRow>>(
                              future: assetList,
                              builder: (context, snapshot) {
                                final rows = snapshot.data
                                    ?.where(
                                        (asset) => asset['kind'] == kind.name)
                                    .toList();
                                if (snapshot.hasError) {
                                  return const Text('无法读取生成记录');
                                }
                                if (rows == null) {
                                  return const LinearProgressIndicator();
                                }
                                if (rows.isEmpty) {
                                  return Text('暂无已生成${kind.label}');
                                }
                                return Column(children: [
                                  for (final row in rows.take(2))
                                    _assetRow(row, kind),
                                  const Divider(height: 8),
                                  Row(children: [
                                    Expanded(
                                        child: Text('共 ${rows.length} 项',
                                            style: theme.textTheme.labelSmall)),
                                    TextButton(
                                      key:
                                          ValueKey('creator-more-${kind.name}'),
                                      onPressed: () =>
                                          _showAssetList(kind, rows),
                                      child: const Text('查看更多'),
                                    ),
                                  ]),
                                ]);
                              }),
                        ],
                      ),
                    ),
                  ]),
            ),
        ]);
      }),
    ]);
  }

  Future<void> _showAssetList(CreatorAssetKind kind, List<LocalRow> rows) =>
      showDialog<void>(
        context: context,
        builder: (context) {
          final colors = Theme.of(context).colorScheme;
          return UiContentDialog(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    UiSheetHeader(
                        title: '${kind.label}资产',
                        onClose: () => Navigator.of(context).pop()),
                    const Divider(height: 20),
                    DecoratedBox(
                      decoration: BoxDecoration(
                          color: colors.primaryContainer,
                          borderRadius: BorderRadius.circular(8)),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Text('${rows.length} 项${kind.label}',
                            style: TextStyle(color: colors.onPrimaryContainer)),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: rows.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, index) => _assetRow(rows[index], kind),
                      ),
                    ),
                    const Divider(height: 16),
                    Align(
                        alignment: Alignment.centerRight,
                        child: OutlinedButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('完成'))),
                  ]),
            ),
          );
        },
      );

  Widget _assetRow(LocalRow row, CreatorAssetKind kind) {
    final type = kind.extension.toUpperCase();
    final created = row['created'] as int? ?? 0;
    final date = DateTime.fromMillisecondsSinceEpoch(created);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text('${row['title']}', overflow: TextOverflow.ellipsis),
      subtitle:
          Text(created > 0 ? '$type · ${date.month} 月 ${date.day} 日' : type),
      trailing: Wrap(children: [
        IconButton(
            tooltip: '打开',
            icon: const Icon(CupertinoIcons.eye, size: 18),
            onPressed: () => _openAsset(row, kind, export: false)),
        IconButton(
            tooltip: '下载',
            icon: const Icon(CupertinoIcons.arrow_down_to_line, size: 18),
            onPressed: () => _openAsset(row, kind, export: true)),
      ]),
    );
  }

  Future<void> _openAsset(LocalRow row, CreatorAssetKind kind,
      {required bool export}) async {
    try {
      final filename = row['file_path'] as String;
      if (!RegExp(r'^[0-9a-f-]{36}\.(pdf|html|zip)$').hasMatch(filename)) {
        throw const FormatException('invalid asset name');
      }
      final directory = await ref.read(creatorAssetDirectoryProvider)();
      final file = File('${directory.path}/$filename');
      if (!await file.exists()) {
        throw const FileSystemException('asset missing');
      }
      final name = '${row['title']}'
          .replaceAll(RegExp(r'[^\p{L}\p{N} _-]', unicode: true), '_');
      if (!export) {
        if (kind == CreatorAssetKind.skill) {
          if (await file.length() > 2 * 1024 * 1024) {
            throw const FormatException('skill bundle too large');
          }
          final bytes = await file.readAsBytes();
          verifyRenderedCreatorAsset(kind, bytes);
          final content =
              utf8.decode(ZipDecoder().decodeBytes(bytes).files.single.content);
          if (!mounted) return;
          await showDialog<void>(
            context: context,
            builder: (_) => CreatorSkillPreview(
              title: '${row['title']}',
              content: content,
              onDownload: () => _openAsset(row, kind, export: true),
            ),
          );
          return;
        }
        if (!mounted) return;
        await _showFilePreview(
          AttachmentPreviewTarget(
            url: file.uri.toString(),
            name: '$name.${kind.extension}',
          ),
          onOpenExternal: kind == CreatorAssetKind.web
              ? () => _openAssetInBrowser(file)
              : null,
        );
        return;
      }
      final target =
          await getSaveLocation(suggestedName: '$name.${kind.extension}');
      if (target != null) await XFile(file.path).saveTo(target.path);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法打开或保存该文件。')));
      }
    }
  }

  Future<void> _openAssetInBrowser(File file) async {
    try {
      final opened = Platform.isMacOS
          ? (await Process.run('/usr/bin/open', [file.path])).exitCode == 0
          : await launchUrl(file.uri, mode: LaunchMode.externalApplication);
      if (opened) return;
    } catch (_) {
      // Fall through to the error feedback for either platform.
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('无法在浏览器打开该网页。')));
    }
  }

  Future<void> _showFilePreview(AttachmentPreviewTarget target,
          {VoidCallback? onOpenExternal}) =>
      showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: 960,
            height: 690,
            child: AttachmentPreviewPanel(
              target: target,
              onOpenExternal: onOpenExternal,
              onClose: () => Navigator.of(context).pop(),
            ),
          ),
        ),
      );

  Widget _creatorAvatar(LocalRow creator, double size) {
    final url = '${creator['avatar_url'] ?? ''}'.trim();
    final fallback = CircleAvatar(
      radius: size / 2,
      child: Text('${creator['name']}'.trim().characters.firstOrNull ?? '博'),
    );
    if (url.isEmpty) return fallback;
    return UiNetworkImage(
      imageUrl: url,
      width: size,
      height: size,
      borderRadius: size / 2,
      httpHeaders: const {},
      placeholderBuilder: (_, __) => fallback,
      errorBuilder: (_, __, ___) => fallback,
    );
  }

  Widget _empty(
          {required IconData icon,
          required String title,
          required String body,
          Widget? action}) =>
      Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon,
                size: 52,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 18),
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(body,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            if (action != null) ...[const SizedBox(height: 20), action],
          ]),
        ),
      );
}

Future<void> _openCreatorLocalVideo(BuildContext context, Uri uri) async {
  try {
    if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
  } on Exception {
    // A missing default media player is shown as an inline action failure.
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('无法打开本机播放器。')),
    );
  }
}

class _CreatorInlineMedia extends StatefulWidget {
  const _CreatorInlineMedia({
    super.key,
    required this.title,
    required this.name,
    required this.audio,
    required this.read,
    required this.onClose,
  });

  final String title;
  final String name;
  final bool audio;
  final Future<File> Function(String) read;
  final VoidCallback onClose;

  @override
  State<_CreatorInlineMedia> createState() => _CreatorInlineMediaState();
}

class _CreatorInlineMediaState extends State<_CreatorInlineMedia> {
  late final _target = _load();

  Future<({AttachmentPreviewTarget target, bool large})> _load() async {
    final file = await widget.read(widget.name);
    if (!await file.exists()) throw StateError('作品媒体文件缺失');
    final extension = widget.name.split('.').last.toLowerCase();
    final mime = switch (extension) {
      'm4a' => 'audio/mp4',
      'mov' => 'video/quicktime',
      _ => 'video/mp4',
    };
    return (
      target: AttachmentPreviewTarget(
        url: file.uri.toString(),
        name: '${widget.title}.$extension',
        mime: mime,
      ),
      large: await file.length() > attachmentPreviewLimit('video'),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, layout) => SizedBox(
          height: widget.audio
              ? 180
              : (layout.maxWidth * 9 / 16 + 34).clamp(220.0, 470.0),
          child: FutureBuilder(
            future: _target,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const Center(child: Text('本机媒体不可播放，可打开原作品或查看逐字稿。'));
              }
              final data = snapshot.data;
              if (data == null) {
                return const Center(child: CupertinoActivityIndicator());
              }
              if (data.large) {
                return Center(
                  child: OutlinedButton(
                    onPressed: () => _openCreatorLocalVideo(
                        context, Uri.parse(data.target.url)),
                    child: const Text('用本机播放器打开原片'),
                  ),
                );
              }
              return ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: AttachmentPreviewPanel(
                  target: data.target,
                  onClose: widget.onClose,
                ),
              );
            },
          ),
        ),
      );
}

typedef _CreatorSyncRequest = ({int? latest, String cookie});

int? _syncLatest(LocalRow pending) =>
    (jsonDecode(pending['request_payload'] as String) as Map)['latest'] as int?;

Map<String, dynamic>? _syncCheckpoint(LocalRow pending) {
  final value =
      jsonDecode(pending['result_payload'] as String) as Map<String, dynamic>;
  return value.isEmpty ? null : value;
}

class _CreatorSyncRun extends ChangeNotifier {
  _CreatorSyncRun(this.adapter, {required this.latest});

  static const cancelledMessage = '同步已取消，可重新打开后继续。';
  final DouyinCreatorService adapter;
  final int? latest;
  String status = '正在检查所选同步范围…';
  bool cancelled = false;
  bool saving = false;
  bool finished = false;
  bool failed = false;
  int pages = 0;
  int works = 0;
  String? savedSummary, mediaSummary;

  void recordCheckpoint(Map<String, Object?>? checkpoint) {
    pages = (checkpoint?['cursors'] as List?)?.length ?? 0;
    works = (checkpoint?['works'] as Map?)?.length ?? 0;
    notifyListeners();
  }

  void update(String message) {
    status = message;
    notifyListeners();
  }

  void finish(String message, {bool failed = false}) {
    finished = true;
    this.failed = failed;
    update(message);
  }

  void cancel() {
    if (saving || cancelled || finished) return;
    cancelled = true;
    update('正在取消同步…');
    adapter.close();
  }

  void checkActive() {
    if (cancelled) throw const DouyinCreatorException(cancelledMessage);
  }
}

typedef _CreatorSyncFailure = ({
  String message,
  bool requiresLogin,
  int? latest
});

class _SyncCreatorDialog extends ConsumerStatefulWidget {
  const _SyncCreatorDialog({
    required this.pending,
    required this.initialRun,
    required this.initialFailure,
    required this.onStart,
    required this.onCancel,
    required this.onFailure,
  });
  final _CreatorSyncFailure? initialFailure;
  final ValueChanged<_CreatorSyncFailure> onFailure;
  final LocalRow? pending;
  final _CreatorSyncRun? initialRun;
  final _CreatorSyncRun Function(_CreatorSyncRequest) onStart;
  final ValueChanged<_CreatorSyncRun> onCancel;

  @override
  ConsumerState<_SyncCreatorDialog> createState() => _SyncCreatorDialogState();
}

class _SyncCreatorDialogState extends ConsumerState<_SyncCreatorDialog> {
  late final TextEditingController _limit;
  late bool _all;
  bool _checking = false;
  _CreatorSyncRun? _run;
  bool _requiresLogin = false;
  String? _error;

  bool _sameScope(int? latest) {
    final pending = widget.pending;
    return pending != null && latest == _syncLatest(pending);
  }

  @override
  void initState() {
    super.initState();
    _run = widget.initialRun;
    final failure = widget.initialFailure;
    final pending = widget.pending;
    final latest = failure != null
        ? failure.latest
        : (pending == null ? null : _syncLatest(pending));
    _all = latest == null;
    _limit = TextEditingController(text: '${latest ?? 20}');
    _error = failure?.message ?? pending?['error'] as String?;
    _requiresLogin = failure?.requiresLogin ?? false;
  }

  Future<void> _confirm() async {
    if (_checking) return;
    final latest = _all ? null : int.tryParse(_limit.text.trim());
    if (!_all && (latest == null || latest < 1)) {
      setState(() => _error = '请输入大于 0 的作品数量。');
      return;
    }
    setState(() => _checking = true);
    try {
      final cookie = await ref.read(creatorDouyinSessionProvider)();
      if (!mounted) return;
      if (cookie.isEmpty) {
        const message = '请先重新连接抖音账号。';
        setState(() {
          _error = message;
          _requiresLogin = true;
        });
        widget
            .onFailure((message: message, requiresLogin: true, latest: latest));
        return;
      }
      final run = widget.onStart((latest: latest, cookie: cookie));
      setState(() => _run = run);
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取抖音登录状态，请重试。');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  void dispose() {
    _limit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_run case final run?) return _progressDialog(context, run);
    final scheme = Theme.of(context).colorScheme;
    void close() => Navigator.pop(context);
    final latest = _all ? null : int.tryParse(_limit.text.trim());
    final pending = widget.pending;
    final checkpoint = pending == null ? null : _syncCheckpoint(pending);
    final canContinue =
        (_all || latest != null) && _sameScope(latest) && checkpoint != null;
    return PopScope(
      canPop: !_checking,
      child: UiContentDialog(
        size: UiDialogSize.compact,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              UiSheetHeader(
                  title: '立即同步', onClose: close, closeEnabled: !_checking),
              const Divider(height: 20),
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: scheme.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: RadioGroup<bool>(
                    groupValue: _all,
                    onChanged: (value) {
                      if (_checking || value == null) return;
                      setState(() {
                        _all = value;
                        if (!_requiresLogin) _error = null;
                      });
                    },
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Padding(
                          padding: EdgeInsets.fromLTRB(10, 5, 0, 1),
                          child: Text('同步范围',
                              style: TextStyle(fontWeight: FontWeight.w600)),
                        ),
                        RadioListTile<bool>(
                          value: true,
                          enabled: !_checking,
                          dense: true,
                          title: const Text('全部作品'),
                        ),
                        RadioListTile<bool>(
                          value: false,
                          enabled: !_checking,
                          dense: true,
                          title: const Text('最新作品'),
                        ),
                        if (!_all)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(10, 4, 10, 6),
                            child: TextField(
                              key: const ValueKey('roundtable-sync-quantity'),
                              controller: _limit,
                              enabled: !_checking,
                              onChanged: (_) => setState(() {}),
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly
                              ],
                              keyboardType: TextInputType.number,
                              decoration:
                                  const InputDecoration(labelText: '同步作品数量'),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: .08),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: const Padding(
                  padding: EdgeInsets.all(10),
                  child: Text(
                      '按发布时间从新到旧选取作品，跳过已导入的作品。更新专家时，所选模型会收到作品证据及已有图谱的规则摘要。'),
                ),
              ),
              if (canContinue)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                      '已读取 ${(checkpoint['cursors'] as List).length} 页，继续时会保留原同步范围。'),
                ),
              if (_checking)
                const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Text('正在检查抖音登录状态…'),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(_error!, style: TextStyle(color: scheme.error)),
                ),
              const Divider(height: 20),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                alignment: WrapAlignment.end,
                children: [
                  if (_requiresLogin)
                    TextButton(
                      style: roundtableTextControlStyle,
                      onPressed: _checking
                          ? null
                          : () => showDialog<void>(
                                context: context,
                                builder: (_) => const _AddDouyinCreatorDialog(
                                    channelOnly: true, resumeSync: true),
                              ),
                      child: const Text('重新连接抖音'),
                    ),
                  OutlinedButton(
                      style: roundtableTextControlStyle,
                      onPressed: _checking ? null : close,
                      child: const Text('取消')),
                  FilledButton(
                      style: roundtableTextControlStyle,
                      onPressed: _checking ? null : _confirm,
                      child: Text(canContinue ? '继续上次同步' : '开始同步')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _progressDialog(BuildContext context, _CreatorSyncRun run) {
    void close() => Navigator.pop(context);
    return ListenableBuilder(
      listenable: run,
      builder: (context, _) => UiContentDialog(
        key: const ValueKey('roundtable-sync-progress'),
        size: UiDialogSize.compact,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              UiSheetHeader(title: '同步进度', onClose: close),
              const Divider(height: 20),
              Text(run.status,
                  style: TextStyle(
                    color: run.failed && !run.cancelled
                        ? Theme.of(context).colorScheme.error
                        : null,
                  )),
              const SizedBox(height: 8),
              if (run.latest case final count?) Text('本次最多同步 $count 条作品'),
              Text('已核对 ${run.pages} 页 · 已读取 ${run.works} 条作品'),
              if (run.savedSummary case final summary?) Text(summary),
              if (_visibleMediaSummary(run.mediaSummary) case final summary?)
                Text(summary),
              const Divider(height: 20),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (!run.finished && run.savedSummary == null)
                    OutlinedButton(
                      style: roundtableTextControlStyle,
                      onPressed: run.saving || run.cancelled
                          ? null
                          : () => widget.onCancel(run),
                      child: const Text('取消同步'),
                    ),
                  FilledButton(
                    style: roundtableTextControlStyle,
                    onPressed: close,
                    child: Text(
                        run.finished ? (run.failed ? '关闭' : '完成') : '后台继续'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddDouyinCreatorDialog extends ConsumerStatefulWidget {
  const _AddDouyinCreatorDialog(
      {this.channelOnly = false,
      this.resumeSync = false,
      this.distill = false});
  final bool channelOnly;
  final bool resumeSync;
  final bool distill;

  @override
  ConsumerState<_AddDouyinCreatorDialog> createState() =>
      _AddDouyinCreatorDialogState();
}

enum _DouyinAuthorizationStep {
  introduction('抖音授权说明'),
  scan('连接抖音账号'),
  scope('确认授权范围'),
  done('抖音授权成功');

  const _DouyinAuthorizationStep(this.label);
  final String label;
}

class _DouyinAuthorizationDialog extends StatefulWidget {
  const _DouyinAuthorizationDialog({required this.priorSession});
  final String priorSession;

  @override
  State<_DouyinAuthorizationDialog> createState() =>
      _DouyinAuthorizationDialogState();
}

class _DouyinAuthorizationDialogState
    extends State<_DouyinAuthorizationDialog> {
  static final _home = WebUri('https://www.douyin.com/');
  static final _identifier = RegExp(r'(?:^|;\s*)sessionid(?:_ss)?=([^;]+)');

  late final Set<String> _previous = _identifiers(widget.priorSession);
  var _step = _DouyinAuthorizationStep.introduction;
  Timer? _poll;
  bool _checking = false;
  String? _error;

  Set<String> _identifiers(String cookie) =>
      _identifier.allMatches(cookie).map((match) => match.group(1)!).toSet();

  bool _hasNewLogin(String cookie) =>
      _identifiers(cookie).difference(_previous).isNotEmpty;

  void _showStep(_DouyinAuthorizationStep step) {
    _poll?.cancel();
    setState(() {
      _step = step;
      _error = null;
    });
    if (step == _DouyinAuthorizationStep.scan) {
      _poll = Timer.periodic(
          const Duration(seconds: 2), (_) => unawaited(_checkScan()));
    }
  }

  Future<void> _checkScan() async {
    if (_checking || _step != _DouyinAuthorizationStep.scan) return;
    _checking = true;
    try {
      final cookie = await _douyinLoginCookie();
      if (mounted &&
          _step == _DouyinAuthorizationStep.scan &&
          _hasNewLogin(cookie)) {
        _showStep(_DouyinAuthorizationStep.scope);
      }
    } on PlatformException {
      if (mounted) setState(() => _error = '无法读取抖音登录状态，请稍后重试。');
    } on MissingPluginException {
      _poll?.cancel();
      if (mounted) setState(() => _error = '当前环境无法读取抖音登录状态。');
    } finally {
      _checking = false;
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final scan = _step == _DouyinAuthorizationStep.scan;
    return UiContentDialog(
      size: scan ? UiDialogSize.wide : UiDialogSize.compact,
      maxHeight: 820,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UiSheetHeader(
                title: _step.label,
                onClose: () => Navigator.of(context).pop(false)),
            const Divider(height: 19),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (index, label) in const [
                  '授权说明',
                  '连接账号',
                  '确认范围',
                  '授权完成',
                ].indexed)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    CircleAvatar(
                      radius: 10,
                      backgroundColor: index == _step.index
                          ? scheme.primary
                          : scheme.surfaceContainerHigh,
                      child: Text('${index + 1}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: index == _step.index
                                ? scheme.onPrimary
                                : scheme.onSurfaceVariant,
                          )),
                    ),
                    const SizedBox(width: 5),
                    Text(label,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: index == _step.index
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        )),
                  ]),
              ],
            ),
            const SizedBox(height: 18),
            switch (_step) {
              _DouyinAuthorizationStep.introduction => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('连接你的抖音账号', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    const Text('连接后，博主圆桌可读取公开博主资料及你在抖音有权查看的作品，用于导入和同步。'),
                    const SizedBox(height: 8),
                    DecoratedBox(
                      decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(8)),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Text('请在抖音 App 扫码确认。登录状态保存在本机。',
                            style: TextStyle(color: scheme.onPrimaryContainer)),
                      ),
                    ),
                  ],
                ),
              _DouyinAuthorizationStep.scan => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('在手机抖音中确认登录', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 6),
                    Text(_previous.isEmpty
                        ? '在抖音网页选择登录，用手机抖音扫码并确认。'
                        : '如网页仍显示已登录，请先在抖音网页退出，再用手机扫码登录。'),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: (MediaQuery.sizeOf(context).height * .58)
                          .clamp(230.0, 540.0),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: InAppWebView(
                          initialUrlRequest: URLRequest(url: _home),
                          initialSettings: InAppWebViewSettings(
                              userAgent: DouyinCreatorService.userAgent,
                              useShouldOverrideUrlLoading: true,
                              mediaPlaybackRequiresUserGesture: true),
                          shouldOverrideUrlLoading: (_, action) async {
                            final uri = action.request.url;
                            final host = uri?.host ?? '';
                            return uri?.scheme == 'https' &&
                                    (host == 'douyin.com' ||
                                        host.endsWith('.douyin.com') ||
                                        host.endsWith('.iesdouyin.com'))
                                ? NavigationActionPolicy.ALLOW
                                : NavigationActionPolicy.CANCEL;
                          },
                          onLoadStop: (controller, _) {
                            assert(() {
                              CreatorRoundtablePage.debugOnLoginPageLoaded
                                  ?.call(controller);
                              return true;
                            }());
                            unawaited(_checkScan());
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              _DouyinAuthorizationStep.scope => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('确认账号与授权范围', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: Color.alphaBlend(
                            scheme.primary.withValues(alpha: .065),
                            scheme.surface),
                        border: Border.all(
                            color: scheme.primary.withValues(alpha: .1)),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Row(children: [
                          Image.asset(
                            ClientAssets.path(
                                'assets/images/creator_roundtable_douyin.png'),
                            width: 32,
                            height: 32,
                            excludeFromSemantics: true,
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                              child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('抖音账号', style: theme.textTheme.titleSmall),
                              Text('已检测到网页登录',
                                  style: theme.textTheme.labelMedium),
                            ],
                          )),
                        ]),
                      ),
                    ),
                    const SizedBox(height: 9),
                    const Text('• 读取公开博主资料'),
                    const Text('• 读取当前账号可查看的作品及列表'),
                    const SizedBox(height: 8),
                    Text('可在渠道设置中断开。', style: theme.textTheme.bodySmall),
                  ],
                ),
              _DouyinAuthorizationStep.done => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Column(
                    children: [
                      CircleAvatar(
                        backgroundColor: const Color(0xFFE2F6EC),
                        foregroundColor: const Color(0xFF188750),
                        child: const Icon(Icons.check),
                      ),
                      const SizedBox(height: 10),
                      Text('抖音已连接', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 6),
                      const Text('可继续添加博主，或回到作品同步。'),
                    ],
                  ),
                ),
            },
            if (_error case final message?)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(message, style: TextStyle(color: scheme.error)),
              ),
            const Divider(height: 22),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(spacing: 8, children: [
                if (_step == _DouyinAuthorizationStep.introduction)
                  OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('取消')),
                if (scan || _step == _DouyinAuthorizationStep.scope)
                  OutlinedButton(
                      onPressed: () => _showStep(
                          _DouyinAuthorizationStep.values[_step.index - 1]),
                      child: const Text('上一步')),
                if (_step == _DouyinAuthorizationStep.introduction)
                  FilledButton(
                      onPressed: () => _showStep(_DouyinAuthorizationStep.scan),
                      child: const Text('前往授权')),
                if (_step == _DouyinAuthorizationStep.scope)
                  FilledButton(
                      onPressed: () => _showStep(_DouyinAuthorizationStep.done),
                      child: const Text('确认范围')),
                if (_step == _DouyinAuthorizationStep.done)
                  FilledButton(
                      key: const ValueKey(
                          'roundtable-douyin-authorization-done'),
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('完成')),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddDouyinCreatorDialogState
    extends ConsumerState<_AddDouyinCreatorDialog> {
  final _link = TextEditingController();
  late final DouyinCreatorService _service;
  final _home = WebUri('https://www.douyin.com/');
  bool _busy = false;
  bool _readFailed = false;
  String _cookie = '';
  String _status = '';
  String? _error;
  Map<String, dynamic>? _result;

  @override
  void initState() {
    super.initState();
    _service = ref.read(creatorDouyinAdapterProvider)();
    if (widget.channelOnly) unawaited(_readCookies());
  }

  Future<void> _readCookies() async {
    try {
      final cookie = await ref.read(creatorDouyinSessionProvider)();
      if (mounted) {
        setState(() => _cookie = cookie);
      }
    } on MissingPluginException {
      if (mounted) setState(() => _error = '当前环境无法读取抖音登录状态。');
    } on PlatformException {
      if (mounted) setState(() => _error = '无法读取应用内抖音登录状态。');
    }
  }

  Future<void> _disconnectChannel() async {
    final manager = CookieManager.instance();
    try {
      final cookies = await manager.getCookies(url: _home);
      for (final cookie in cookies) {
        final domain = (cookie.domain ?? '').replaceFirst(RegExp(r'^\.'), '');
        if (domain == 'douyin.com' || domain.endsWith('.douyin.com')) {
          await manager.deleteCookie(
              url: _home,
              name: cookie.name,
              domain: cookie.domain,
              path: cookie.path ?? '/');
        }
      }
      await _readCookies();
      if (mounted && _cookie.isNotEmpty) {
        setState(() => _error = '仍可读取抖音登录状态，请关闭授权页后重试。');
      }
    } catch (_) {
      if (mounted) setState(() => _error = '无法断开抖音，请稍后重试。');
    }
  }

  Future<bool> _authorize({required bool renew}) async {
    final prior = renew ? _cookie : '';
    final connected = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DouyinAuthorizationDialog(priorSession: prior),
    );
    if (!mounted || connected != true) return false;
    await _readCookies();
    if (!mounted || _cookie.isEmpty) return false;
    if (widget.resumeSync) {
      Navigator.of(context).pop();
    }
    return true;
  }

  Future<void> _read() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _readFailed = false;
      _status = '正在检查链接和登录状态…';
    });
    var validLink = false;
    try {
      final link = DouyinCreatorService.normalizeLink(_link.text);
      validLink = true;
      await _readCookies();
      if (!mounted) return;
      if (_cookie.isEmpty) {
        final authorized = await _authorize(renew: false);
        if (mounted && !authorized) {
          setState(() => _error = '请在应用窗口中登录抖音后再读取。');
        }
        return;
      }
      final result = await _service.read(
          cookie: _cookie,
          link: link,
          onStatus: (status) {
            if (mounted) setState(() => _status = status);
          });
      if (mounted) {
        setState(() => _result = result);
      }
    } on DouyinCreatorException catch (error) {
      if (!mounted) return;
      if (error.requiresLogin && await _authorize(renew: true)) return;
      if (mounted) {
        setState(() {
          _error = error.message;
          _readFailed = validLink && !error.requiresLogin;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = '读取失败，请检查本机组件和网络。';
          _readFailed = validLink;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _service.close();
    _cookie = '';
    _link.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.channelOnly) return _channels();
    if (_readFailed && _result == null) return _failedRead();
    final result = _result;
    if (result == null) {
      return AlertDialog(
        alignment: const Alignment(0, -.37),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Row(children: [
          const Expanded(
              child: Text('添加博主',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
          IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(CupertinoIcons.xmark, size: 15),
          ),
        ]),
        content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('粘贴链接或分享文案 *'),
                const SizedBox(height: 8),
                UiInputField(
                    key: const ValueKey('roundtable-add-link'),
                    controller: _link,
                    enabled: !_busy,
                    hintText: '粘贴抖音作品链接或分享文本',
                    onSubmitted: (_) => _read()),
                const SizedBox(height: 10),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: const Padding(
                      padding: EdgeInsets.all(10),
                      child: Text('粘贴单条视频时，仅导入该视频。')),
                ),
                if (_busy)
                  Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(_status)),
                if (_error != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(_error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error))),
              ],
            )),
        actions: [
          OutlinedButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: _busy ? null : _read, child: const Text('读取作品')),
        ],
      );
    }
    return UiContentDialog(
      size: UiDialogSize.standard,
      maxHeight: 680,
      child: Padding(
        key: const ValueKey('roundtable-import-preview-dialog'),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UiSheetHeader(
                title: '添加博主', onClose: () => Navigator.of(context).pop()),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(children: [
                      Expanded(
                          child: Text(_cookie.isEmpty ? '尚未登录抖音' : '已登录抖音')),
                      TextButton(
                          onPressed: _busy
                              ? null
                              : () => _authorize(renew: _cookie.isNotEmpty),
                          child: Text(_cookie.isEmpty ? '去授权' : '重新授权')),
                    ]),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(
                          child: UiInputField(
                        key: const ValueKey('roundtable-add-link'),
                        controller: _link,
                        enabled: !_busy,
                        hintText: '粘贴抖音作品链接或分享文本',
                        onSubmitted: (_) => _read(),
                        suffixIcon: IconButton(
                            tooltip: '粘贴',
                            onPressed: _busy
                                ? null
                                : () async {
                                    final data = await Clipboard.getData(
                                        Clipboard.kTextPlain);
                                    if (mounted && data?.text != null) {
                                      _link.text = data!.text!;
                                    }
                                  },
                            icon: const Icon(CupertinoIcons.doc_on_clipboard,
                                size: 18)),
                      )),
                      const SizedBox(width: 12),
                      FilledButton(
                          style: roundtableTextControlStyle,
                          onPressed: _busy ? null : _read,
                          child: const Text('读取作品')),
                    ]),
                    if (_busy)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Row(children: [
                          const CupertinoActivityIndicator(),
                          const SizedBox(width: 10),
                          Expanded(child: Text(_status)),
                        ]),
                      ),
                    if (_error != null)
                      Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(_error!,
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error))),
                    const SizedBox(height: 14),
                    _preview(result),
                  ],
                ),
              ),
            ),
            const Divider(height: 24),
            if (widget.distill)
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Text('开始后自动归档作品并生成专家。所选模型会收到作品证据和图谱规则摘要。'),
              ),
            if ((result['author']?['avatar'] as String? ?? '').isNotEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text('启用图片编辑模型后，公开头像可用于生成席位形象。'),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                style: roundtableTextControlStyle,
                onPressed:
                    _busy ? null : () => Navigator.of(context).pop(result),
                child: Text(widget.distill ? '开始蒸馏' : '添加到圆桌'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _failedRead() => UiContentDialog(
        size: UiDialogSize.compact,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              UiSheetHeader(
                  title: '蒸馏失败', onClose: () => Navigator.pop(context)),
              const Divider(height: 20),
              Text(_error ?? '无法读取博主及作品。',
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
              const Divider(height: 20),
              Wrap(
                spacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () => setState(() {
                      _readFailed = false;
                      _error = null;
                    }),
                    child: const Text('修改链接'),
                  ),
                  FilledButton(onPressed: _read, child: const Text('重试')),
                ],
              ),
            ],
          ),
        ),
      );

  Widget _channels() {
    final theme = Theme.of(context);
    final connected = _cookie.isNotEmpty;
    const channels = [
      ('抖音', 'douyin.png'),
      ('小红书', 'red.svg'),
      ('公众号', 'official.png'),
      ('视频号', 'channels.png'),
      ('哔哩哔哩', 'bilibili.svg'),
      ('微博', 'weibo.png'),
    ];
    return UiContentDialog(
      size: UiDialogSize.compact,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UiSheetHeader(title: '配置渠道', onClose: () => Navigator.pop(context)),
            const Divider(height: 16),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: channels.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final (name, file) = channels[index];
                  final asset = ClientAssets.path(
                      'assets/images/creator_roundtable_$file');
                  final available = index == 0;
                  final badge =
                      available ? (connected ? '已授权' : '未授权') : '暂未开放';
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    minLeadingWidth: 24,
                    visualDensity: VisualDensity.compact,
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: file.endsWith('.svg')
                          ? SvgPicture.asset(asset, width: 29, height: 29)
                          : Image.asset(asset, width: 29, height: 29),
                    ),
                    title: Text(name, style: theme.textTheme.titleSmall),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: available && connected
                                ? const Color(0xFFE5F5EB)
                                : theme.colorScheme.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 4),
                            child:
                                Text(badge, style: theme.textTheme.labelSmall),
                          ),
                        ),
                        if (available) ...[
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: _busy
                                ? null
                                : () => _authorize(renew: connected),
                            child: Text(connected ? '重新授权' : '去授权'),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
            if (_error != null)
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            const Divider(height: 16),
            Row(children: [
              if (connected)
                TextButton(
                    onPressed: _disconnectChannel, child: const Text('断开抖音')),
              const Spacer(),
              FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('完成')),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _preview(Map<String, dynamic> result) {
    final author = result['author'] as Map;
    final work = result['work'] as Map?;
    final posts = result['posts'] as List? ?? const [];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        UiNetworkImage(
            imageUrl: '${author['avatar']}',
            width: 56,
            height: 56,
            borderRadius: 28,
            httpHeaders: const {}),
        const SizedBox(width: 12),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${author['name']}',
              style: Theme.of(context).textTheme.titleLarge),
          Text('${author['followers']} 粉丝 · ${author['works']} 个作品'),
          if ('${author['bio']}'.isNotEmpty) Text('${author['bio']}'),
        ])),
      ]),
      const Divider(height: 24),
      Text('本次导入作品', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      if (work != null)
        Text('${work['title']}')
      else
        for (final post in posts.whereType<Map>()) Text('${post['title']}'),
      const SizedBox(height: 10),
      Text(
          work == null
              ? '本次归档当前页的 ${posts.length} 条作品，后续可手动同步。'
              : '同时读取到该博主 ${posts.length} 条其他公开作品信息；本次只归档上面这一条。',
          style:
              TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
    ]);
  }
}
