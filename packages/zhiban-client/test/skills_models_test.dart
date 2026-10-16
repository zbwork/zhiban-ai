import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/skills/models/f03_skill_models.dart';
import 'package:zhiban_client/pages/skills/models/skill_models.dart';

void main() {
  group('Skill.fromJson', () {
    test('parses F03 skill square item fields', () {
      final skill = Skill.fromJson(const {
        'skill_uuid': 'skl_123',
        'code': 'meeting_summary',
        'name': '会议纪要',
        'description': '自动整理会议重点',
        'source': 'internal',
        'status': 'active',
        'category_id': 12,
        'is_attached_to_agent': true,
        'install_count': 42,
        'icon_url': 'https://example.test/icon.png',
      });

      expect(skill.uuid, 'skl_123');
      expect(skill.slug, 'meeting_summary');
      expect(skill.displayName, '会议纪要');
      expect(skill.description, '自动整理会议重点');
      expect(skill.source, 'internal');
      expect(skill.status, 'active');
      expect(skill.categoryId, 12);
      expect(skill.isInstalled, true);
      expect(skill.installStatus, 'installed');
      expect(skill.downloadCount, 42);
      expect(skill.iconUrl, 'https://example.test/icon.png');
    });
  });

  group('Skill billing fields', () {
    test('defaults to free/per_skill when fields absent', () {
      final skill = Skill.fromJson(const {
        'uuid': 'skl_1',
        'slug': 'test',
        'display_name': 'Test',
      });
      expect(skill.billingType, 'free');
      expect(skill.pricingMode, 'per_skill');
      expect(skill.isPaid, false);
      expect(skill.isPerOperation, false);
      expect(skill.billingBadgeText, '免费');
      expect(skill.billingHintText, '');
    });

    test('parses paid/per_skill', () {
      final skill = Skill.fromJson(const {
        'uuid': 'skl_2',
        'slug': 'premium',
        'display_name': 'Premium',
        'billing_type': 'paid',
        'pricing_mode': 'per_skill',
      });
      expect(skill.billingType, 'paid');
      expect(skill.pricingMode, 'per_skill');
      expect(skill.isPaid, true);
      expect(skill.isPerOperation, false);
      expect(skill.billingBadgeText, '付费');
      expect(skill.billingHintText, '使用该技能会消耗积分，是否继续？');
    });

    test('parses paid/per_operation', () {
      final skill = Skill.fromJson(const {
        'uuid': 'skl_3',
        'slug': 'api_tool',
        'display_name': 'API Tool',
        'billing_type': 'paid',
        'pricing_mode': 'per_operation',
      });
      expect(skill.billingType, 'paid');
      expect(skill.pricingMode, 'per_operation');
      expect(skill.isPaid, true);
      expect(skill.isPerOperation, true);
      expect(skill.billingBadgeText, '按接口计费');
      expect(skill.billingHintText, '该技能按不同接口消耗积分，是否继续？');
    });

    test('empty billing_type defaults to free', () {
      final skill = Skill.fromJson(const {
        'uuid': 'skl_4',
        'slug': 'old_skill',
        'display_name': 'Old',
        'billing_type': '',
        'pricing_mode': '',
      });
      expect(skill.billingType, 'free');
      expect(skill.pricingMode, 'per_skill');
      expect(skill.isPaid, false);
    });

    test('accepts camelCase keys', () {
      final skill = Skill.fromJson(const {
        'uuid': 'skl_5',
        'slug': 'camel',
        'display_name': 'Camel',
        'billingType': 'paid',
        'pricingMode': 'per_operation',
      });
      expect(skill.billingType, 'paid');
      expect(skill.pricingMode, 'per_operation');
    });
  });

  group('F03ChipItem billing fields', () {
    test('defaults to free/per_skill when fields absent', () {
      final chip = F03ChipItem.fromJson(const {
        'skill_uuid': 'skl_1',
        'code': 'test',
        'name': 'Test',
      });
      expect(chip.billingType, 'free');
      expect(chip.pricingMode, 'per_skill');
      expect(chip.isPaid, false);
    });

    test('parses paid billing fields', () {
      final chip = F03ChipItem.fromJson(const {
        'skill_uuid': 'skl_2',
        'code': 'premium',
        'name': 'Premium',
        'billing_type': 'paid',
        'pricing_mode': 'per_operation',
      });
      expect(chip.billingType, 'paid');
      expect(chip.pricingMode, 'per_operation');
      expect(chip.isPaid, true);
    });
  });

  group('AgentSkillItem billing fields', () {
    test('defaults to free/per_skill when fields absent', () {
      final item = AgentSkillItem.fromJson(const {
        'slug': 'test',
        'skillName': 'Test',
        'status': 'active',
        'isInstalled': true,
      });
      expect(item.billingType, 'free');
      expect(item.pricingMode, 'per_skill');
      expect(item.isPaid, false);
    });

    test('parses paid/per_operation', () {
      final item = AgentSkillItem.fromJson(const {
        'slug': 'premium',
        'name': 'Premium',
        'status': 'active',
        'isInstalled': true,
        'billing_type': 'paid',
        'pricing_mode': 'per_operation',
      });
      expect(item.billingType, 'paid');
      expect(item.pricingMode, 'per_operation');
      expect(item.isPaid, true);
    });

    test('empty billing_type defaults to free', () {
      final item = AgentSkillItem.fromJson(const {
        'slug': 'old',
        'name': 'Old',
        'status': 'active',
        'isInstalled': true,
        'billing_type': '',
        'pricing_mode': '',
      });
      expect(item.billingType, 'free');
      expect(item.pricingMode, 'per_skill');
      expect(item.isPaid, false);
    });
  });

  group('SkillCategory.fromJson', () {
    test('parses client skill category fields', () {
      final category = SkillCategory.fromJson(const {
        'id': 11,
        'code': 'office_study',
        'name': '办公学习',
        'sort_order': 10,
      });

      expect(category.id, 11);
      expect(category.code, 'office_study');
      expect(category.name, '办公学习');
      expect(category.sortOrder, 10);
    });
  });
}
