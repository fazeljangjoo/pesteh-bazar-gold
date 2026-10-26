import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// نام فارسی چهار نسخه (ثابت مشترک با سرور: `pb_edition_names()` در features.php)
const Map<String, String> kEditionNames = <String, String>{
  'green_rial': 'پسته بازار سبز ریالی',
  'green_fx': 'پسته بازار سبز ارزی',
  'gold_rial': 'پسته بازار طلایی ریالی',
  'gold_fx': 'پسته بازار طلایی ارزی',
};

/// آینهٔ کلیدهای طلایی فهرست features.php (برای مجوز قدیمیِ بدون فهرست قابلیت)
const Set<String> kGoldFeatureKeys = <String>{
  'gold.fiscal_years', 'gold.coa', 'gold.cost_centers', 'gold.treasury', 'gold.vouchers', 'gold.vat',
  'gold.invoices', 'gold.reports', 'gold.yearend', 'gold.payroll_law', 'gold.fx_accounting',
};

/// نسخهٔ برنامه = سطح (سبز/طلایی) × پلن (ریالی/ارزی).
/// مرجع تصمیم سرور است (`edition` در پاسخ login/status)؛ این کلاس فقط برای نمایش/پنهان‌کردن UI است
/// و هیچ امنیتی ندارد (سرور هر درخواست را دوباره بررسی می‌کند).
class Edition {
  final String tier; // 'green' | 'gold'
  final String plan; // 'rial' | 'fx'
  final List<String> features;

  const Edition({this.tier = 'green', this.plan = 'rial', this.features = const <String>[]});

  bool get isGold => tier == 'gold';
  bool get isFx => plan == 'fx';
  String get code => '${tier}_$plan';

  /// آیا قابلیت در این نسخه فعال است؟ (فهرست را سرور می‌فرستد)
  bool has(String feature) => features.contains(feature);

  /// نام فارسی کامل نسخه
  String get nameFa => kEditionNames[code] ?? 'پسته بازار $tierFa $planFa';
  String get tierFa => isGold ? 'طلایی' : 'سبز';
  String get planFa => isFx ? 'ارزی' : 'ریالی';

  Map<String, dynamic> toJson() => <String, dynamic>{'tier': tier, 'plan': plan, 'features': features};

  /// ورودی: Map سرور (`edition`) یا null. [legacyPlan] = فیلد قدیمی `plan` برای سرورهای بدون edition.
  factory Edition.fromServer(dynamic raw, {dynamic legacyPlan}) {
    if (raw is Map) {
      final t = raw['tier'] == 'gold' ? 'gold' : 'green';
      final p = raw['plan'] == 'fx' ? 'fx' : 'rial';
      final f = <String>[];
      final rf = raw['features'];
      if (rf is List) {
        for (final x in rf) {
          if (x is String) f.add(x);
        }
      }
      return Edition(tier: t, plan: p, features: f);
    }
    // سرور قدیمی: سبز + پلن قبلی
    return Edition(tier: 'green', plan: legacyPlan == 'fx' ? 'fx' : 'rial');
  }
}

/// نگه‌دارندهٔ نسخهٔ فعلی؛ آخرین مقدار روی دستگاه ذخیره می‌شود تا آفلاین هم همان بماند.
class EditionService {
  EditionService._();
  static final EditionService I = EditionService._();

  static const String _kKey = 'license_edition';

  final ValueNotifier<Edition> current = ValueNotifier<Edition>(const Edition());

  Edition get edition => current.value;

  void _set(Edition e) {
    final o = current.value;
    if (o.tier == e.tier && o.plan == e.plan && listEquals(o.features, e.features)) return;
    current.value = e;
  }

  /// پس از ورود/وضعیت/همگام‌سازی صدا زده می‌شود.
  Future<void> apply(dynamic rawEdition, dynamic legacyPlan) async {
    final e = Edition.fromServer(rawEdition, legacyPlan: legacyPlan);
    _set(e);
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kKey, jsonEncode(e.toJson()));
    } catch (_) {}
  }

  /// S22.T22.2: طلایی منقضی = فقط خروجی (Q3). UI دروازه می‌تواند این را بخواند.
  final ValueNotifier<bool> readOnlyExport = ValueNotifier<bool>(false);

  /// S22.T22.2: سطح و قابلیت‌ها از مجوز امضادار. بر مقدار JSON سرور اولویت دارد؛
  /// سبز هرگز قابلیت طلایی نمی‌گیرد (حتی اگر فهرست ورودی چنین بگوید).
  Future<void> applySigned({
    required String tier,
    required String plan,
    List<String>? features,
    bool exportOnly = false,
  }) async {
    final o = current.value;
    final t = tier == 'gold' ? 'gold' : 'green';
    final p = plan == 'fx' ? 'fx' : 'rial';
    List<String> f;
    if (features != null) {
      f = List<String>.from(features);
    } else {
      // مجوز قدیمی بدون فهرست: از آخرین فهرست، طلایی‌ها را فقط وقتی سطح طلایی است نگه می‌داریم
      f = t == 'gold' ? List<String>.from(o.features) : o.features.where((String x) => !kGoldFeatureKeys.contains(x)).toList();
    }
    if (t == 'green') f = f.where((String x) => !kGoldFeatureKeys.contains(x)).toList();
    _set(Edition(tier: t, plan: p, features: f));
    readOnlyExport.value = exportOnly && t == 'gold';
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kKey, jsonEncode(Edition(tier: t, plan: p, features: f).toJson()));
    } catch (_) {}
  }

  /// فقط پلن معلوم است (مجوز امضادار آفلاین): سطح و قابلیت‌های آخرین مقدار ذخیره‌شده حفظ می‌شود.
  Future<void> applyPlanOnly(dynamic plan) async {
    final o = current.value;
    final p = plan == 'fx' ? 'fx' : 'rial';
    if (o.plan == p) return;
    final e = Edition(tier: o.tier, plan: p, features: o.features);
    _set(e);
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kKey, jsonEncode(e.toJson()));
    } catch (_) {}
  }

  /// شروع برنامه / حالت آفلاین
  Future<void> load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final s = sp.getString(_kKey);
      if (s == null || s.isEmpty) return;
      final m = jsonDecode(s);
      if (m is Map) _set(Edition.fromServer(m));
    } catch (_) {}
  }

  /// خروج از حساب
  Future<void> clear() async {
    readOnlyExport.value = false;
    _set(const Edition());
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(_kKey);
    } catch (_) {}
  }
}

/// نمایش یا پنهان‌کردن بخشی از UI بر اساس قابلیت.
/// - [lockedHint] == null: وقتی قابلیت نیست، چیزی نشان داده نمی‌شود.
/// - [lockedHint] != null: متن راهنما با آیکن قفل نشان داده می‌شود (مثلاً «در نسخهٔ طلایی»).
class FeatureGate extends StatelessWidget {
  final String feature;
  final Widget child;
  final String? lockedHint;

  const FeatureGate({super.key, required this.feature, required this.child, this.lockedHint});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Edition>(
      valueListenable: EditionService.I.current,
      builder: (BuildContext context, Edition e, Widget? _) {
        if (e.has(feature)) return child;
        final hint = lockedHint;
        if (hint == null) return const SizedBox.shrink();
        return ListTile(
          leading: const Icon(Icons.lock_outline),
          title: Text(hint),
          enabled: false,
        );
      },
    );
  }
}

/// برچسب نام نسخه (سبز/طلایی × ریالی/ارزی)
class EditionBadge extends StatelessWidget {
  const EditionBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Edition>(
      valueListenable: EditionService.I.current,
      builder: (BuildContext context, Edition e, Widget? _) {
        final Color c = e.isGold ? const Color(0xFFB8860B) : const Color(0xFF2E7D32);
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: c.withOpacity(0.12),
            border: Border.all(color: c),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(e.nameFa, style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.bold)),
        );
      },
    );
  }
}
