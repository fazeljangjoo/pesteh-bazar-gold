import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// مجوزهای کاربر فعلی (T02.2). مالک: current = null (همه‌چیز مجاز).
/// کارکن: current = {id, name, username, role, perms[]} از پاسخ staff_login / account.status.
/// این کلاس فقط برای پنهان‌کردن UI است؛ سرور هر اکشن را دوباره با pb_action_perm بررسی می‌کند.
class StaffPerms {
  StaffPerms._();
  static final StaffPerms I = StaffPerms._();

  static const String _kKey = 'license_staff';

  final ValueNotifier<Map<String, dynamic>?> current = ValueNotifier<Map<String, dynamic>?>(null);

  bool get isStaff => current.value != null;

  String get roleName => (current.value?['role'] ?? '').toString();

  bool can(String key) {
    final s = current.value;
    if (s == null) return true; // مالک
    final p = s['perms'];
    return p is List && p.contains(key);
  }

  /// raw = Map کارکن از سرور، یا null برای مالک. روی دستگاه هم ذخیره می‌شود تا آفلاین همان بماند.
  Future<void> apply(dynamic raw) async {
    final Map<String, dynamic>? next = raw is Map ? Map<String, dynamic>.from(raw) : null;
    current.value = next;
    try {
      final sp = await SharedPreferences.getInstance();
      if (next == null) {
        await sp.remove(_kKey);
      } else {
        await sp.setString(_kKey, jsonEncode(next));
      }
    } catch (_) {
      // ذخیره‌سازی محلی اختیاری است
    }
  }

  Future<void> loadSaved() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_kKey);
      if (raw == null || raw.isEmpty) return;
      final j = jsonDecode(raw);
      if (j is Map) current.value = Map<String, dynamic>.from(j);
    } catch (_) {
      current.value = null;
    }
  }

  Future<void> clear() => apply(null);
}

/// برچسب فارسی هر کلید مجوز (ترتیب گروه‌بندی در صفحهٔ نقش‌ها هم از همین فهرست است).
const Map<String, String> kPermLabels = <String, String>{
  'crm.view': 'مشاهدهٔ پیگیری مشتریان',
  'crm.edit': 'ثبت یادداشت و پیگیری مشتریان',
  'sales.view': 'مشاهدهٔ فروش',
  'sales.create': 'ثبت فروش',
  'pos.use': 'استفاده از صندوق فروش (POS)',
  'sales.update': 'ویرایش فروش',
  'sales.delete': 'حذف فروش',
  'purchases.view': 'مشاهدهٔ خرید',
  'purchases.create': 'ثبت خرید',
  'purchases.delete': 'حذف خرید',
  'mixes.create': 'ثبت ترکیب',
  'mixes.update': 'ویرایش ترکیب',
  'mixes.delete': 'حذف ترکیب',
  'payments.save': 'ثبت پرداخت',
  'receipts.save': 'ثبت دریافت',
  'dues.view': 'مشاهدهٔ سررسیدها',
  'dues.mark_paid': 'تسویهٔ سررسید',
  'parties.view': 'مشاهدهٔ طرف‌حساب‌ها',
  'parties.create': 'ثبت طرف‌حساب',
  'loans.create': 'ثبت وام / قرض',
  'loans.delete': 'حذف وام / قرض',
  'loans.due_paid': 'ثبت بازپرداخت وام',
  'catalog.manage': 'مدیریت دسته و نوع پسته',
  'stock.view': 'مشاهدهٔ موجودی و انبار',
  'stock.transfer': 'انتقال بین انبارها',
  'warehouses.view': 'مشاهدهٔ انبارها',
  'warehouses.manage': 'مدیریت انبارها',
  'ounces.view': 'مشاهدهٔ درجه‌بندی اونس',
  'ounces.manage': 'مدیریت درجه‌بندی اونس',
  'reports.view': 'گزارش‌ها',
  'profit.view': 'مشاهدهٔ سود و زیان',
  'accounting.view': 'مشاهدهٔ حسابداری',
  'accounting.post': 'ثبت سند حسابداری',
  'accounting.edit': 'ویرایش سند حسابداری',
  'accounting.close': 'بستن سال مالی و اسناد',
  'fy.manage': 'مدیریت سال‌های مالی',
  'tax.view': 'مشاهدهٔ گزارش‌های مالیاتی',
  'settings.manage': 'تنظیمات',
  'users.manage': 'مدیریت کارکنان و نقش‌ها',
  'audit.view': 'مشاهدهٔ گزارش ممیزی',
};

/// عنوان گروه (پیشوند کلید) برای گروه‌بندی ماتریس مجوز.
const Map<String, String> kModuleLabels = <String, String>{
  'sales': 'فروش',
  'purchases': 'خرید',
  'mixes': 'ترکیب',
  'payments': 'پرداخت',
  'receipts': 'دریافت',
  'dues': 'سررسیدها',
  'parties': 'طرف‌حساب‌ها',
  'loans': 'وام و قرض',
  'catalog': 'کالا',
  'stock': 'انبار و موجودی',
  'warehouses': 'انبارها',
  'ounces': 'درجه‌بندی اونس',
  'reports': 'گزارش‌ها',
  'profit': 'سود و زیان',
  'accounting': 'حسابداری',
  'settings': 'تنظیمات',
  'users': 'کاربران',
};
