// فاز ۳ مجد — «ویرایش امن»: آینهٔ توابع خالص سرور (backend/api/pb_edit_guard.php).
// تست مشترک: test/edit_guard_cases.json (کپی بایت‌به‌بایت backend/api/edit_guard_cases.json) + test/edit_guard_test.dart.
// این فایل عمداً هیچ import ندارد (تست خالص Dart). UI: lib/edit_guard_ui.dart.

const String kEditConflictMsg = 'این سند در این فاصله تغییر کرده؛ دوباره باز کنید';
const String kEditConflictCode = 'edit_conflict';
const double _eps = 1e-6;

num? _asNum(Object? v) {
  if (v is num) return v;
  if (v is String) return num.tryParse(v.trim());
  return null;
}

/// آینهٔ pb_eg_same: عدد با تلورانس، null ≡ '' ≡ ۰، متن trim.
bool editGuardSame(Object? a, Object? b) {
  final Object? na = (a == null || a == '') ? null : a;
  final Object? nb = (b == null || b == '') ? null : b;
  if (na == null || nb == null) {
    final Object? other = na ?? nb;
    if (other == null) return true;
    final num? o = _asNum(other);
    return o != null && o.abs() < _eps;
  }
  final num? x = _asNum(na), y = _asNum(nb);
  if (x != null && y != null) return (x - y).abs() < _eps;
  return '$na'.trim() == '$nb'.trim();
}

/// آینهٔ pb_eg_changed: کلیدهای [fields] که بین before و after فرق دارند (کلید غایب در after = بدون تغییر).
List<String> editGuardChanged(Map<String, Object?> before, Map<String, Object?> after, List<String> fields) => <String>[
      for (final String f in fields)
        if (after.containsKey(f) && !editGuardSame(before[f], after[f])) f,
    ];

/// آینهٔ pb_eg_decide: پیام رد یا null.
String? editGuardDecide(String? usedDoc, List<String> changed, List<String> neutral, [Map<String, String> labels = const <String, String>{}]) {
  if (usedDoc == null) return null;
  final List<String> locked = changed.where((String f) => !neutral.contains(f)).toList();
  if (locked.isEmpty) return null;
  final String names = locked.map((String f) => labels[f] ?? f).join('، ');
  return 'چون «$usedDoc» به این سند وابسته است، فقط توضیح، تاریخ (در همان سال مالی) و طرف‌حساب قابل ویرایش است؛ تغییر «$names» ممکن نیست';
}

/// آینهٔ pb_eg_version_ok: base خالی (کلاینت قدیمی) ⇒ مجاز.
bool editGuardVersionOk(Object? base, int current) {
  if (base == null || base == '') return true;
  return _asNum(base)?.toInt() == current;
}

/// آیا پاسخ خطای سرور تعارض نسخه است؟ (کد ۴۰۹ و error=edit_conflict)
bool editGuardIsConflict(int? code, Map<String, dynamic>? data) => code == 409 && data?['error'] == kEditConflictCode;
