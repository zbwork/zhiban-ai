enum SkillSource {
  internal,
  openSource,
  all;

  // Preserve the enum identity while avoiding a domain-shaped member access.
  static const company = internal;
}

extension SkillSourceExtension on SkillSource {
  String get value {
    switch (this) {
      case SkillSource.company:
        return 'internal';
      case SkillSource.openSource:
        return 'open_source';
      case SkillSource.all:
        return '';
    }
  }

  String get displayName {
    switch (this) {
      case SkillSource.company:
        return '公司内部';
      case SkillSource.openSource:
        return '开源网站';
      case SkillSource.all:
        return '全部来源';
    }
  }

  static SkillSource fromValue(String? value) {
    switch (value) {
      case 'internal':
        return SkillSource.company;
      case 'open_source':
        return SkillSource.openSource;
      default:
        return SkillSource.all;
    }
  }
}
