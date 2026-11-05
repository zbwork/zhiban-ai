/// Five-field, local wall-clock cron. No timer callbacks or execution here.
class LocalTaskSchedule {
  LocalTaskSchedule(String expression) {
    final parts = expression.trim().split(RegExp(r'\s+'));
    if (parts.length != 5) throw const FormatException('请输入五字段 Cron 表达式');
    fields = [
      _field(parts[0], 0, 59),
      _field(parts[1], 0, 23),
      _field(parts[2], 1, 31),
      _field(parts[3], 1, 12),
      _field(parts[4], 0, 7).map((n) => n == 7 ? 0 : n).toSet(),
    ];
    dayWildcard = parts[2].startsWith('*');
    weekWildcard = parts[4].startsWith('*');
  }
  late final List<Set<int>> fields;
  late final bool dayWildcard, weekWildcard;

  static Set<int> _field(String value, int min, int max) {
    final result = <int>{};
    for (final item in value.split(',')) {
      final stepParts = item.split('/');
      if (stepParts.length > 2) throw const FormatException('Cron 步进格式无效');
      final step = stepParts.length == 2 ? int.tryParse(stepParts[1]) : 1;
      if (step == null || step <= 0 || step > max - min + 1) {
        throw const FormatException('Cron 步进超出范围');
      }
      final range = stepParts[0].split('-');
      final start = range[0] == '*' ? min : int.tryParse(range[0]);
      final end = range[0] == '*'
          ? max
          : range.length == 2
              ? int.tryParse(range[1])
              : stepParts.length == 2
                  ? max
                  : start;
      if (range.length > 2 ||
          start == null ||
          end == null ||
          start < min ||
          end > max ||
          start > end) {
        throw const FormatException('Cron 字段超出范围');
      }
      for (var n = start; n <= end; n += step) {
        result.add(n);
      }
    }
    return result;
  }

  DateTime next(DateTime after) {
    // Search calendar days, then matching hours/minutes; leap dates need up to
    // eight years (e.g. 2096 -> 2104), without millions of minute iterations.
    final local = after.toLocal();
    for (var day = DateTime(local.year, local.month, local.day);
        day.year <= local.year + 8;
        day = DateTime(day.year, day.month, day.day + 1)) {
      if (!fields[3].contains(day.month)) continue;
      final dom = fields[2].contains(day.day);
      final dow = fields[4].contains(day.weekday % 7);
      // Wildcards (including steps) still constrain their own field.
      // Only two explicitly restricted calendar fields use cron's OR rule.
      if (!(dayWildcard || weekWildcard ? dom && dow : dom || dow)) {
        continue;
      }
      final hours = fields[1].toList()..sort();
      final minutes = fields[0].toList()..sort();
      for (final h in hours) {
        for (final m in minutes) {
          final candidate = DateTime(day.year, day.month, day.day, h, m);
          // A nonexistent DST wall time must not roll into another hour.
          if (candidate.hour == h &&
              candidate.minute == m &&
              candidate.isAfter(after)) {
            return candidate;
          }
        }
      }
    }
    throw const FormatException('Cron 在未来八年内没有有效执行时间');
  }
}
