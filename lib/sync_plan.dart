// S7 — منطق خالصِ تصمیم‌گیری همگام‌سازی لحظه‌ای (بدون Flutter و بدون I/O؛ با تست واحد قابل‌اجراست).
//
// ورودی: فهرست `changes` که سرور برای `since_ver` می‌دهد + اکشن‌هایی که خودِ همین دستگاه ارسال کرده.
// خروجی: [SyncPlan] = کدام entityها فقط دلتا (`entity.changes`) شوند و آیا دریافت کامل لازم است.

/// یک ردیف `sync_log` سرور
class SyncChange {
  final int ver;
  final String action;
  final String? entity;
  const SyncChange(this.ver, this.action, this.entity);

  factory SyncChange.fromJson(Map<dynamic, dynamic> j) => SyncChange(
        int.tryParse('${j['ver']}') ?? 0,
        '${j['action'] ?? ''}',
        j['entity'] == null ? null : '${j['entity']}',
      );
}

class SyncPlan {
  /// entityهایی که باید با `entity.changes(since_rev)` دلتا شوند
  final Set<String> entities;

  /// یک ناحیهٔ غیر-entity (خرید، فروش، …) یا `reset` ⇒ `backup.export` کامل
  final bool fullPull;

  /// کلیدهای «تغییرِ خودِ این دستگاه» که با ردیف‌های سرور جور شدند (باید از فهرست own حذف شوند)
  final List<String> consumedOwn;

  /// تعداد تغییرات دستگاه‌های دیگر
  final int foreignCount;

  const SyncPlan({
    required this.entities,
    required this.fullPull,
    required this.consumedOwn,
    required this.foreignCount,
  });

  bool get hasWork => fullPull || entities.isNotEmpty;
}

class SyncPlanner {
  SyncPlanner._();

  /// entityهای پذیرش اتاق انس؛ هر اکشن `intake.*` همهٔ این‌ها را تغییر می‌دهد (سرور فقط `lot_intakes` را گزارش می‌کند)
  static const List<String> intakeEntities = <String>['lot_intakes', 'lot_intake_pcts', 'pct_defs'];

  /// کلید مقایسهٔ «اکشن + ناحیه»؛ همان قاعدهٔ سرور (`pb_sync_bump`): `entity.*` ⇒ نام entity، `intake.*` ⇒ lot_intakes،
  /// بقیه ⇒ بخش اول اکشن. اگر قاعده با سرور نخواند، فقط یک دریافت اضافه انجام می‌شود (ایمن).
  static String keyOf(String action, String? entity) => '$action|${entity ?? ''}';

  static String? entityOfOwn(String action, Map<String, dynamic> payload) {
    if (action.startsWith('entity.')) {
      final e = payload['entity'];
      return e is String ? e : null;
    }
    if (action.startsWith('intake.')) return 'lot_intakes';
    final i = action.indexOf('.');
    return i > 0 ? action.substring(0, i) : action;
  }

  /// [isKnownEntity]: آیا این نسخهٔ اپ این entity را می‌شناسد و حساب به آن دسترسی دارد؟
  static SyncPlan plan({
    required List<SyncChange> changes,
    required bool reset,
    required List<String> ownKeys,
    required bool Function(String entity) isKnownEntity,
  }) {
    if (reset) {
      return SyncPlan(entities: <String>{}, fullPull: true, consumedOwn: <String>[], foreignCount: 0);
    }
    final own = <String, int>{};
    for (final k in ownKeys) {
      own[k] = (own[k] ?? 0) + 1;
    }
    final consumed = <String>[];
    final ents = <String>{};
    var full = false;
    var foreign = 0;
    for (final c in changes) {
      final k = keyOf(c.action, c.entity);
      final n = own[k] ?? 0;
      if (n > 0) {
        own[k] = n - 1;
        consumed.add(k);
        continue;
      }
      foreign++;
      final a = c.action;
      if (a.startsWith('entity.')) {
        // entityِ ناشناخته (نسخهٔ جدیدتر سرور) یا بدون دسترسی: چیزی برای نمایش نیست
        final e = c.entity;
        if (e != null && isKnownEntity(e)) ents.add(e);
        continue;
      }
      if (a.startsWith('intake.')) {
        for (final e in intakeEntities) {
          if (isKnownEntity(e)) ents.add(e);
        }
        // قطعی‌سازی علاوه بر پذیرش، ردیف خرید/موجودی هم می‌سازد
        if (a == 'intake.confirm') full = true;
        continue;
      }
      full = true; // هر ناحیهٔ غیر-entity (purchases, sales, payments, settings, …)
    }
    return SyncPlan(entities: ents, fullPull: full, consumedOwn: consumed, foreignCount: foreign);
  }

  /// فاصلهٔ poll بعدی: موفق ⇒ [pollSec]؛ خطا ⇒ دو برابر شونده تا سقف ۶۰ ثانیه
  static int nextDelaySec({required int pollSec, required int failStreak}) {
    final base = pollSec < 2 ? 2 : (pollSec > 60 ? 60 : pollSec);
    if (failStreak <= 0) return base;
    var d = base;
    for (var i = 0; i < failStreak && d < 60; i++) {
      d *= 2;
    }
    return d > 60 ? 60 : d;
  }
}
