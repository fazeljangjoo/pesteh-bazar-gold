import 'package:flutter/material.dart';

import 'excel_io.dart';
import 'returns_ui.dart' show ReturnsHelp;
import 'utils.dart';

/// مرحلهٔ ۶-۴ کارگاه — خروجی اکسل سه گزارش (کارتکس مالک · خلاصهٔ مدیریتی · مقایسه).
/// فقط داده‌های سرور را به جدول تبدیل می‌کند (هیچ محاسبهٔ تازه‌ای نیست) و هیچ قیمتی در آن نیست.
/// سلول‌های عددی با `ExcelIo.parseCell` به عدد واقعی تبدیل می‌شوند؛ خالی = ''.
class ReportTable {
  const ReportTable({required this.columns, required this.rows, required this.sheet, required this.prefix});
  final List<String> columns;
  final List<List<String>> rows;
  final String sheet;
  final String prefix;
}

String _n(dynamic v) => v == null || '$v'.isEmpty ? '' : faNum(ReturnsHelp.d(v), dec: 3);
String _t(dynamic v) => v == null ? '' : '$v';
String _owner(dynamic v) => v == null || '$v'.trim().isEmpty ? 'بدون مالک' : '$v';
String _date(dynamic v) => v == null || '$v'.isEmpty ? '' : jalaliDate('$v');

class ReportsExcel {
  ReportsExcel._();

  static const Map<String, String> eventLabels = <String, String>{'send': 'ارسال', 'receive': 'دریافت'};
  static const Map<String, String> sourceLabels = <String, String>{'internal': 'کارگاه داخلی', 'outside': 'کارگاه بیرونی', 'crack': 'خط شکست'};

  static const List<String> cartexHeads = <String>['تاریخ', 'رویداد', 'مالک', 'عدل', 'ورود (کیلو)', 'خروج (کیلو)', 'انس', 'گرم', 'دهنبست', 'مانده مالک (کیلو)', 'مانده کل همهٔ مالک‌ها (کیلو)', 'توضیحات'];

  /// ستون‌های A..K برگهٔ «کارتکس»؛ انس/دهنبست خالی؛ ردیف جمع در انتها.
  static ReportTable cartex(List<Map<String, dynamic>> rows, Map<String, dynamic> totals) {
    final List<List<String>> out = <List<String>>[
      for (final Map<String, dynamic> r in rows)
        <String>[_date(r['date']), eventLabels['${r['event']}'] ?? _t(r['event']), _owner(r['owner']), _n(r['bale_count']), _n(r['in_kg']), _n(r['out_kg']), _n(r['ounce']), _n(r['gram_pct']), _n(r['dahanbast']), _n(r['balance_kg']), _n(r['balance_total_kg']), _t(r['note'])],
    ];
    if (rows.isNotEmpty) out.add(<String>['جمع', '', '', '', _n(totals['in_kg']), _n(totals['out_kg']), '', '', '', _n(totals['balance_kg']), _n(totals['balance_total_kg']), '']);
    return ReportTable(columns: cartexHeads, rows: out, sheet: 'کارتکس مالک', prefix: 'cartex');
  }

  static const List<List<String>> summaryInternal = <List<String>>[
    <String>['orders_count', 'تعداد عملیات'], <String>['delivered_kg', 'وزن تحویلی (کیلو)'], <String>['input_kg', 'وزن ورودی (کیلو)'], <String>['sound_kg', 'سالم (کیلو)'],
    <String>['deformed_fine_kg', 'بدشکل و ریز (کیلو)'], <String>['hull_kg', 'پوست (کیلو)'], <String>['kernel_kg', 'مغز (کیلو)'], <String>['soil_kg', 'خاک (کیلو)'],
    <String>['discolored_kg', 'بدرنگ (کیلو)'], <String>['loss_kg', 'افت وزن (کیلو)'], <String>['waste_total_kg', 'مجموع ضایعات (کیلو)'], <String>['diff_kg', 'اختلاف تراز (کیلو)'],
    <String>['undelivered_kg', 'تحویل‌نشده (کیلو)'], <String>['sound_pct', 'درصد سالم از ورودی (٪)'], <String>['check_count', 'عملیات نیازمند بررسی تراز'],
  ];
  static const List<List<String>> summaryCrack = <List<String>>[
    <String>['runs_count', 'تعداد نوبت کار'], <String>['input_kg', 'وزن ورودی (کیلو)'], <String>['kernel_kg', 'مغز خروجی (کیلو)'], <String>['hull_kg', 'پوست (کیلو)'], <String>['soil_kg', 'خاک (کیلو)'],
    <String>['sub_kernel_kg', 'مجموع زیرمجموعه‌های مغز (کیلو)'], <String>['returned_all_kg', 'برگشتی همهٔ خروجی‌ها (کیلو)'], <String>['loss_kg', 'مغزِ نشده = افت + پوست + خاک (کیلو)'], <String>['loss_pct', 'مغزِ نشده ٪ (از ورودی)'],
    <String>['kernel_pct', 'مغز از ورودی (٪)'], <String>['capacity_kgh', 'ظرفیت واقعی (کیلو/ساعت)'], <String>['run_minutes', 'زمان کارکرد (دقیقه)'], <String>['stop_minutes', 'مجموع توقف (دقیقه)'],
  ];
  static const String crackWarning = '«برگشتی همهٔ خروجی‌ها» = مغز + پوست + خاک + زیرمجموعه‌های مغز است؛ اگر زیرمجموعه‌ها بخشی از وزن مغز باشند دوبار شمرده می‌شود.';

  /// دو ستون: شاخص / مقدار؛ بخش‌ها با ردیف عنوان جدا می‌شوند.
  static ReportTable summary(Map<String, dynamic> internal, Map<String, dynamic> crack) {
    final List<List<String>> out = <List<String>>[
      <String>['کارگاه داخلی (کنترل ورود و خروج تولید)', ''],
      for (final List<String> s in summaryInternal) <String>[s[1], _n(internal[s[0]])],
      <String>['', ''],
      <String>['خط شکست', ''],
      for (final List<String> s in summaryCrack) <String>[s[1], _n(crack[s[0]])],
      <String>[crackWarning, ''],
    ];
    return ReportTable(columns: const <String>['شاخص', 'مقدار'], rows: out, sheet: 'خلاصه مدیریتی', prefix: 'workshop_summary');
  }

  static const List<String> compareHeads = <String>['منبع', 'نام', 'تعداد', 'ورودی (کیلو)', 'خروجی خوب (کیلو)', 'افت (کیلو)', 'بازده ٪', 'افت ٪', 'ظرفیت (کیلو/ساعت)', 'میانگین افت گرم'];

  static ReportTable compare(List<Map<String, dynamic>> rows, String by) {
    final List<List<String>> out = <List<String>>[
      for (final Map<String, dynamic> r in rows)
        <String>[sourceLabels['${r['source']}'] ?? _t(r['source']), _t(r['name']), _n(r['count']), _n(r['input_kg']), _n(r['good_kg']), _n(r['loss_kg']), _n(r['yield_pct']), _n(r['loss_pct']), _n(r['capacity_kgh']), _n(r['avg_gram_loss'])],
    ];
    return ReportTable(columns: compareHeads, rows: out, sheet: 'مقایسه $by', prefix: 'workshop_compare');
  }

  /// ساخت فایل و ذخیره (ویندوز) / اشتراک‌گذاری (اندروید). خطا ⇒ SnackBar.
  static Future<void> export(BuildContext context, ReportTable t) async {
    try {
      final f = await ExcelIo.exportTable(columns: t.columns, rows: t.rows, sheetName: t.sheet, filePrefix: '${t.prefix}_${ReturnsHelp.iso(DateTime.now())}');
      if (!context.mounted) return;
      await ExcelIo.saveOrShare(context, f);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('خروجی اکسل ناموفق بود: $e')));
    }
  }
}
