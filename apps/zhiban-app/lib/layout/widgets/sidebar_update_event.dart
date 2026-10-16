/// Adapter for the existing native/cache wire protocol. Unknown events are ignored.
enum SidebarUpdateEventType {
  downloadStarted,
  downloadComplete,
  downloadProgress,
  installPreparing,
  sparkleDownloadStarted,
  sparkleDownloadComplete,
  installReady,
  failed,
}

class SidebarUpdateEvent {
  const SidebarUpdateEvent(
    this.type, {
    this.buildNumber,
    this.packageType,
    this.received,
    this.total,
    this.progress,
  });

  final SidebarUpdateEventType type;
  final String? buildNumber;
  final String? packageType;
  final int? received;
  final int? total;
  final double? progress;

  static SidebarUpdateEvent? fromMap(Map<String, dynamic> value) {
    final type = switch (value['event']) {
      'downloadStarted' => SidebarUpdateEventType.downloadStarted,
      'downloadComplete' => SidebarUpdateEventType.downloadComplete,
      'downloadProgress' => SidebarUpdateEventType.downloadProgress,
      'installPreparing' => SidebarUpdateEventType.installPreparing,
      'sparkleDownloadStarted' => SidebarUpdateEventType.sparkleDownloadStarted,
      'sparkleDownloadComplete' =>
        SidebarUpdateEventType.sparkleDownloadComplete,
      'installReady' => SidebarUpdateEventType.installReady,
      'failed' || 'cancelled' || 'notFound' => SidebarUpdateEventType.failed,
      _ => null,
    };
    if (type == null) return null;
    return SidebarUpdateEvent(
      type,
      buildNumber: value['buildNumber'] is String
          ? value['buildNumber'] as String
          : null,
      packageType: value['packageType'] is String
          ? value['packageType'] as String
          : null,
      received: value['receivedBytes'] is num
          ? (value['receivedBytes'] as num).toInt()
          : null,
      total: value['totalBytes'] is num
          ? (value['totalBytes'] as num).toInt()
          : null,
      progress: value['progress'] is num
          ? (value['progress'] as num).toDouble()
          : null,
    );
  }
}
