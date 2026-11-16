/// S6 — ثبت خروجی‌های خط شکست به‌عنوان لات جدید: تابع‌های خالص (آینهٔ pb_cr_lots_plan در workshop_crack.php و crLotsPlan در modules_crack.js).
/// وزن‌ها روی گرم صحیح؛ ترتیب ثابت = ترتیب [kCrLotLabels] (همان ترتیب سرور ⇒ کدها قابل پیش‌بینی). Z (پوست باقی‌مانده) لات نمی‌شود.
/// هیچ فیلد قیمتی نیست.

/// کلید ستون ⇒ برچسب فارسی (نام لات).
const Map<String, String> kCrLotLabels = <String, String>{
  'kernel_kg': 'مغز',
  'hull_kg': 'پوست',
  'soil_kg': 'خاک',
  'sound_kg': 'مغز سالم',
  'wheat_kg': 'گندمی و موشو',
  'super_fine_kg': 'سوپر خیلی ریز',
  'flower_kg': 'گلدار',
  'split_kg': 'لپه و شکسته',
  'unbreakable_kg': 'ناشکن',
  'pink_kg': 'کال سوپر و صورتی',
  'waste_kernel_kg': 'مغز ضایعاتی',
};

/// تفکیک مغز (AA..AH): همراه با «مغز» (U) لات نمی‌شود (مغز دو بار شمرده می‌شود).
const Set<String> kCrLotSub = <String>{'sound_kg', 'wheat_kg', 'super_fine_kg', 'flower_kg', 'split_kg', 'unbreakable_kg', 'pink_kg', 'waste_kernel_kg'};

class CrLotItem {
  final String field;
  final String label;
  final int g;
  const CrLotItem(this.field, this.label, this.g);
  double get kg => g / 1000;
}

class CrLotsPlan {
  final List<CrLotItem> items;
  final int totalG;
  final String? error;
  const CrLotsPlan(this.items, this.totalG, [this.error]);
  const CrLotsPlan.fail(String message)
      : items = const <CrLotItem>[],
        totalG = 0,
        error = message;
  bool get ok => error == null;
  double get totalKg => totalG / 1000;
}

/// آیا انتخاب این فیلد با انتخاب‌های فعلی تداخل دارد؟ (U ↔ AA..AH)
bool crLotsConflict(Iterable<String> fields, String candidate) {
  final Set<String> s = fields.toSet();
  if (candidate == 'kernel_kg') return s.any(kCrLotSub.contains);
  if (kCrLotSub.contains(candidate)) return s.contains('kernel_kg');
  return false;
}

/// kgByField: کیلوی هر ستون (null/خالی = ندارد). fields: خروجی‌های انتخابی.
CrLotsPlan crLotsPlan(Map<String, double?> kgByField, Iterable<String> fields) {
  final List<String> f = <String>[];
  for (final String x in fields) {
    if (!f.contains(x)) f.add(x);
  }
  if (f.isEmpty) return const CrLotsPlan.fail('حداقل یک خروجی را برای ساخت لات انتخاب کنید');
  for (final String x in f) {
    if (!kCrLotLabels.containsKey(x)) return CrLotsPlan.fail('خروجی نامعتبر برای لات: $x');
  }
  if (f.contains('kernel_kg') && f.any(kCrLotSub.contains)) {
    return const CrLotsPlan.fail('«مغز» و تفکیک آن (مغز سالم، گندمی، …) را هم‌زمان لات نکنید؛ مغز دو بار شمرده می‌شود');
  }
  final List<CrLotItem> items = <CrLotItem>[];
  int tot = 0;
  for (final MapEntry<String, String> e in kCrLotLabels.entries) {
    if (!f.contains(e.key)) continue;
    final int g = ((kgByField[e.key] ?? 0) * 1000).round();
    if (g <= 0) return CrLotsPlan.fail('برای «${e.value}» وزنی وارد نشده است');
    items.add(CrLotItem(e.key, e.value, g));
    tot += g;
  }
  return CrLotsPlan(items, tot);
}
