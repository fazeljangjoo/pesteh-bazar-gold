// تسعیر ارز حرفه‌ای — مرحلهٔ ۹: لایهٔ API (بدون UI)
//
// هر متد روی StockApi.call('accounting.fx_reval.<عمل>') است و خطاها را به FxRevalException ترجمه می‌کند
// (rate_missing با فهرست همهٔ ارزها، edition_required، forbidden، conflict=۴۰۹، network).
// تاریخ ورودی DateTime است و به ISO میلادی (YYYY-MM-DD) تبدیل می‌شود؛ نمایش شمسی کار UI است.

import 'edition.dart';
import 'fx_reval_models.dart';
import 'perms.dart';
import 'returns_ui.dart' show ReturnsHelp;
import 'warehouse_ui.dart' show StockApi, StockApiException;

export 'fx_reval_models.dart';

/// تابع فراخوانی سرور؛ پیش‌فرض StockApi.call. برای تست می‌شود جایگزین کرد.
typedef FxRevalCaller = Future<Map<String, dynamic>> Function(String action, Map<String, dynamic> payload);

class FxRevalApi {
  FxRevalApi({FxRevalCaller? caller}) : _call = caller ?? _stockCall;

  /// نمونهٔ مشترک برنامه.
  static final FxRevalApi I = FxRevalApi();

  static Future<Map<String, dynamic>> _stockCall(String action, Map<String, dynamic> payload) => StockApi.call(action, payload);

  final FxRevalCaller _call;

  Future<Map<String, dynamic>> _run(String op, Map<String, dynamic> payload) async {
    try {
      return await _call('accounting.fx_reval.$op', payload);
    } on StockApiException catch (e) {
      throw FxRevalException.fromResponse(message: e.message, httpCode: e.code, network: e.network, data: e.data);
    }
  }

  /// بررسی پیش از اعمال (فقط‌خواندنی): نرخ‌ها، فاکتورهای باز، سال/قفل مالی، مشکلات.
  /// [docKeys] (اختیاری) = فاکتورهای انتخاب‌شده؛ نبودنش ⇒ همهٔ فاکتورهای بازِ هنوز تسعیرنشده.
  Future<FxRevalCheck> check(DateTime asOf, {List<String>? docKeys}) async {
    final Map<String, dynamic> r = await _run('check', <String, dynamic>{'as_of': ReturnsHelp.iso(asOf), if (docKeys != null) 'doc_keys': docKeys});
    return FxRevalCheck.fromJson(r);
  }

  /// پیش‌نمایش محاسبه (بدون ثبت). نرخ ناموجود ⇒ FxRevalException(rate_missing, ccys: همهٔ ارزها).
  Future<FxRevalPreview> preview(DateTime asOf, {List<String>? docKeys}) async {
    final Map<String, dynamic> r = await _run('preview', <String, dynamic>{'as_of': ReturnsHelp.iso(asOf), if (docKeys != null) 'doc_keys': docKeys});
    return FxRevalPreview.fromJson(r);
  }

  /// فهرست همهٔ فاکتورهای ارزیِ باز در تاریخ تسعیر برای انتخاب (نبودِ نرخ خطا نمی‌دهد؛ rate/delta = null).
  Future<List<FxRevalCandidate>> docs(DateTime asOf) async {
    final Map<String, dynamic> r = await _run('docs', <String, dynamic>{'as_of': ReturnsHelp.iso(asOf)});
    return FxRevalCandidate.listFrom(r['candidates']);
  }

  /// ثبت تسعیر برای فاکتورهای انتخاب‌شده ([docKeys]) یا (بدون آن) همهٔ فاکتورهای باز. خطاهای ۴۰۹ (duplicate/locked/…) ⇒ FxRevalException(conflict, reason:…).
  Future<FxRevalApplyResult> apply(DateTime asOf, {String? note, List<String>? docKeys}) async {
    final String n = (note ?? '').trim();
    final Map<String, dynamic> r = await _run('apply', <String, dynamic>{
      'as_of': ReturnsHelp.iso(asOf),
      if (n.isNotEmpty) 'note': n,
      if (docKeys != null) 'doc_keys': docKeys,
    });
    return FxRevalApplyResult.fromJson(r);
  }

  /// ابطال دستی؛ rev_status جدید را برمی‌گرداند (cancelled؛ ردیف قدیمی none). برگشت‌خودکارشده ⇒ conflict.
  Future<String> reverse(int id) async {
    final Map<String, dynamic> r = await _run('reverse', <String, dynamic>{'id': id});
    return (r['rev_status'] ?? 'cancelled').toString();
  }

  /// فهرست تسعیرها (حداکثر ۲۰۰ ردیف اخیر؛ بدون snapshot).
  Future<List<FxRevalRecord>> list() async {
    final Map<String, dynamic> r = await _run('list', const <String, dynamic>{});
    return FxRevalRecord.listFrom(r['revals']);
  }

  /// جزئیات یک تسعیر + snapshot ذخیره‌شده + stale.
  Future<FxRevalRecord> detail(int id) async {
    final Map<String, dynamic> r = await _run('detail', <String, dynamic>{'id': id});
    return FxRevalRecord.fromJson(r);
  }

  /// دادهٔ تخت برای Excel/PDF (از snapshot ذخیره‌شده؛ بدون بازمحاسبه).
  Future<FxRevalExport> export(int id) async {
    final Map<String, dynamic> r = await _run('export', <String, dynamic>{'id': id});
    return FxRevalExport.fromJson(r);
  }
}

/// مجوزهای تسعیر ارز برای پنهان‌کردن UI (سرور همه را دوباره بررسی می‌کند).
/// نسخه: فقط طلایی-ارزی. کلیدها: accounting.post (مشاهده)، accounting.fx_reval.apply، accounting.fx_reval.reverse.
class FxRevalPerms {
  FxRevalPerms._();

  static const String viewKey = 'accounting.post';
  static const String applyKey = 'accounting.fx_reval.apply';
  static const String reverseKey = 'accounting.fx_reval.reverse';

  static bool get editionOk {
    final Edition e = EditionService.I.edition;
    return e.isFx && e.isGold;
  }

  static bool get canView => editionOk && StaffPerms.I.can(viewKey);
  static bool get canApply => editionOk && StaffPerms.I.can(applyKey);
  static bool get canReverse => editionOk && StaffPerms.I.can(reverseKey);
}
