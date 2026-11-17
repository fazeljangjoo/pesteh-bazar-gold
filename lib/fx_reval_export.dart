// تسعیر ارز حرفه‌ای — مرحلهٔ ۱۳: خروجی Excel (چندبرگه) و PDF (A4 افقی) از `FxRevalExport`.
//
// منبع داده: `FxRevalApi.I.export(id)` برای تسعیر ثبت‌شده، یا `FxRevalExport.fromPreview(preview)` برای پیش‌نمایش
// جاری (محلی، بدون سرور). هیچ محاسبهٔ حسابداری این‌جا نیست؛ فقط قالب‌بندی مقادیر آمادهٔ مدل.
//   FxRevalExporter       ← buildExcel / buildPdf (ساخت فایل) + toExcel / toPdf (ساخت + ذخیره/پیش‌نمایش)
//   FxRevalExportButtons  ← دو دکمهٔ «Excel» و «PDF» (مشترک بین دیالوگ جزئیات و بالای جدول پیش‌نمایش)
import 'dart:io';

import 'package:flutter/material.dart';

import 'excel_io.dart';
import 'fmt.dart' show Fmt;
import 'fx_reval_api.dart'; // FxRevalExport + مدل‌ها
import 'pdf_output.dart';
import 'pdf_service.dart';
import 'utils.dart' show jalaliDate, toEnDigits;
import 'widgets.dart' show snack;

/// پانویس ثابت PDF.
const String kFxRevalPdfFootnote = 'سند خودکار برگشت می‌خورد: سند تسعیر در روز بعد از تاریخ تسعیر به‌صورت خودکار معکوس می‌شود.';
const String _kPreviewNote = 'این گزارش پیش‌نمایش است و هنوز ثبت نشده.';

class FxRevalExporter {
  FxRevalExporter._();

  // ───────────── قالب‌بندی ─────────────

  static String _jd(String iso) {
    if (iso.isEmpty) return '—';
    try {
      return jalaliDate(iso);
    } catch (_) {
      return iso;
    }
  }

  /// تاریخ شمسی با رقم لاتین و خط تیره برای نام فایل: «1405-01-01».
  static String fileDate(String iso) {
    try {
      return toEnDigits(jalaliDate(iso)).replaceAll('/', '-');
    } catch (_) {
      return iso.isEmpty ? 'نامشخص' : iso;
    }
  }

  /// نام فایل Excel: «تسعیر-ارز-<تاریخ شمسی تسعیر>.xlsx».
  static String excelFileName(FxRevalExport e) => 'تسعیر-ارز-${fileDate(e.asOf)}.xlsx';

  static String _group(String digits) {
    final StringBuffer b = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) b.write(',');
      b.write(digits[i]);
    }
    return b.toString();
  }

  /// عدد برای Excel: رقم لاتین + جداکنندهٔ «,» (تا `ExcelIo.parseCell` آن را عدد واقعی کند، حتی بالای ۱۱ رقم) و علامت «-».
  static String _xnum(num v, {int dec = 0}) {
    if (v.isNaN || v.isInfinite) return '';
    String s = v.abs().toStringAsFixed(dec);
    if (s.contains('.')) s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    final List<String> p = s.split('.');
    final String r = _group(p[0]) + (p.length > 1 ? '.${p[1]}' : '');
    return (v < 0 && RegExp(r'[1-9]').hasMatch(r)) ? '-$r' : r;
  }

  /// سلول خام سرور (رشته/عدد/null) → متن سلول Excel؛ اعشاری تا ۴ رقم.
  static String _xcell(Object? v) {
    if (v == null) return '';
    if (v is int) return _xnum(v);
    if (v is num) return _xnum(v, dec: 4);
    return v.toString();
  }

  static List<List<String>> _xtable(List<String> headers, List<List<Object?>> rows) => <List<String>>[
        headers,
        for (final List<Object?> r in rows) <String>[for (final Object? c in r) _xcell(c)],
      ];

  static String _rial(num v) => Fmt.money(v, from: 'rial', to: 'rial');

  /// مبلغ علامت‌دار PDF: بدون «-» (به‌هم‌ریختگی RTL)؛ با برچسب «سود/زیان».
  static String _effect(int effect) => effect == 0 ? _rial(0) : '${_rial(effect.abs())} ${effect > 0 ? 'سود' : 'زیان'}';

  static String _pcell(Object? v) {
    if (v == null) return '';
    if (v is int) return Fmt.number(v);
    if (v is num) return Fmt.number(v, dec: 4);
    return v.toString();
  }

  static bool _isAp(Object? sideLabel) => sideLabel == fxRevalSideLabel('ap');

  // ───────────── Excel ─────────────

  /// برگه‌ها: «خلاصه» (مشخصات + جمع‌ها + به تفکیک ارز)، «ریز فاکتورها»، «طرف‌حساب‌ها»، «نرخ‌ها».
  static List<({String name, List<List<String>> rows})> excelSheets(FxRevalExport e) {
    final FxRevalExportTotals t = e.totals;
    final List<List<String>> summary = <List<String>>[
      <String>['عنوان', e.title],
      <String>['تاریخ تسعیر', _jd(e.asOf)],
      if (e.isPreview) <String>['وضعیت', 'پیش‌نمایش (ثبت نشده)'],
      <String>['تعداد سند', _xnum(t.docCount)],
      <String>['افزایش طلب (ریال)', _xnum(t.arUp)],
      <String>['کاهش طلب (ریال)', _xnum(t.arDown)],
      <String>['افزایش بدهی (ریال)', _xnum(t.apUp)],
      <String>['کاهش بدهی (ریال)', _xnum(t.apDown)],
      <String>['جمع سودها (ریال)', _xnum(t.gain)],
      <String>['جمع زیان‌ها (ریال)', _xnum(t.loss)],
      <String>['خالص سود/زیان (ریال؛ مثبت = سود)', _xnum(t.netDelta)],
      <String>[],
      ..._xtable(e.headers, e.rows),
    ];
    // نرخ‌ها: از ستون‌های «ارز» و «نرخ تسعیر» صفحهٔ اصلی (همان نرخ استفاده‌شده در محاسبه)
    final List<List<String>> rates = <List<String>>[
      <String>['ارز', 'نرخ تسعیر (ریال)'],
      for (final List<Object?> r in e.rows)
        if (r.length >= 2) <String>[_xcell(r[0]), _xcell(r[1])],
    ];
    return <({String name, List<List<String>> rows})>[
      (name: 'خلاصه', rows: summary),
      (name: 'ریز فاکتورها', rows: _xtable(e.docsSheet.headers, e.docsSheet.rows)),
      (name: 'طرف‌حساب‌ها', rows: _xtable(e.partiesSheet.headers, e.partiesSheet.rows)),
      (name: 'نرخ‌ها', rows: rates),
    ];
  }

  static Future<File> buildExcel(FxRevalExport e) => ExcelIo.exportSheets(excelSheets(e), fileName: excelFileName(e));

  // ───────────── PDF ─────────────

  static Future<File> buildPdf(FxRevalExport e) {
    final FxRevalExportTotals t = e.totals;
    final bool hasDocs = e.docsSheet.rows.isNotEmpty;
    final List<String> headers;
    final List<List<String>> rows;
    if (hasDocs) {
      // «تفاوت (ریال)» خام سرور برای بدهی معکوس اثر می‌گذارد ⇒ ستون آخر = اثر سود/زیان شرکت (طلب: delta، بدهی: −delta)
      headers = <String>[...e.docsSheet.headers.take(e.docsSheet.headers.length - 1), 'سود/زیان (ریال)'];
      rows = <List<String>>[
        for (final List<Object?> r in e.docsSheet.rows)
          <String>[
            for (int i = 0; i < r.length - 1; i++) _pcell(r[i]),
            if (r.isNotEmpty) _effect(fxRevalEffect(_isAp(r[0]) ? 'ap' : 'ar', (r.last is num) ? (r.last as num).toInt() : 0)),
          ],
      ];
    } else {
      // ردیف قدیمی بدون ریز فاکتور: جدول به تفکیک ارز
      headers = e.headers;
      rows = <List<String>>[
        for (final List<Object?> r in e.rows) <String>[for (final Object? c in r) _pcell(c)],
      ];
    }
    return PdfService.buildTableReport(
      title: e.title.isEmpty ? 'گزارش تسعیر ارز' : e.title,
      subtitle: 'تاریخ تسعیر: ${_jd(e.asOf)}',
      kv: <List<String>>[
        <String>['تاریخ تسعیر', _jd(e.asOf)],
        if (e.isPreview) <String>['وضعیت', 'پیش‌نمایش (ثبت نشده)'],
        <String>['تعداد سند', Fmt.number(t.docCount)],
        <String>['جمع سودها', _rial(t.gain)],
        <String>['جمع زیان‌ها', _rial(t.loss)],
        <String>['خالص سود/زیان تحقق‌نیافته', _effect(t.netDelta), 'bold'],
      ],
      headers: headers,
      rows: rows,
      filePrefix: 'fx_reval',
      pageNumbers: true,
      footnote: e.isPreview ? '$kFxRevalPdfFootnote $_kPreviewNote' : kFxRevalPdfFootnote,
    );
  }

  // ───────────── ساخت + تحویل به کاربر ─────────────

  static Future<void> toExcel(BuildContext context, FxRevalExport e) async {
    final File f = await buildExcel(e);
    if (!context.mounted) return;
    await ExcelIo.saveOrShare(context, f);
  }

  static Future<void> toPdf(BuildContext context, FxRevalExport e) async {
    final File f = await buildPdf(e);
    if (!context.mounted) return;
    await PdfOutput.show(context, f);
  }
}

/// دکمه‌های «Excel» و «PDF». [loader] دادهٔ خروجی را می‌آورد (سرور یا ساخت محلی از پیش‌نمایش).
/// هنگام بارگذاری/ساخت هر دو دکمه غیرفعال‌اند؛ خطا با SnackBar فارسی نمایش داده می‌شود.
class FxRevalExportButtons extends StatefulWidget {
  final Future<FxRevalExport> Function() loader;
  final bool enabled;
  const FxRevalExportButtons({super.key, required this.loader, this.enabled = true});

  @override
  State<FxRevalExportButtons> createState() => _FxRevalExportButtonsState();
}

class _FxRevalExportButtonsState extends State<FxRevalExportButtons> {
  String? _busy; // 'xlsx' | 'pdf'

  Future<void> _run(String kind) async {
    if (_busy != null) return;
    setState(() => _busy = kind);
    try {
      final FxRevalExport e = await widget.loader();
      if (!mounted) return;
      if (kind == 'xlsx') {
        await FxRevalExporter.toExcel(context, e);
      } else {
        await FxRevalExporter.toPdf(context, e);
      }
    } catch (err) {
      if (mounted) snack(context, '${kind == 'xlsx' ? 'خروجی Excel' : 'خروجی PDF'} ناموفق بود: ${err is FxRevalException ? err.message : err}');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Widget _btn(String kind, IconData icon, String label) {
    final bool busy = _busy == kind;
    return OutlinedButton.icon(
      onPressed: (!widget.enabled || _busy != null) ? null : () => _run(kind),
      icon: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(icon),
      label: Text(label),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        _btn('xlsx', Icons.table_chart_outlined, 'Excel'),
        _btn('pdf', Icons.picture_as_pdf_outlined, 'PDF'),
      ],
    );
  }
}
