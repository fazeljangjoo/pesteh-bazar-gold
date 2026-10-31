import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'pdf_service.dart' show pdfText;
import 'utils.dart';

/// فاکتور PDF اشتراک (داده‌های pay.invoice). فونت همان فایل‌های assets پروژه است.
/// این کلاس مستقل است چون متدهای فونت/ذخیرهٔ PdfService خصوصی هستند.
class PayInvoice {
  PayInvoice._();

  static pw.Font? _reg;
  static pw.Font? _bold;

  static Future<void> _loadFonts() async {
    if (_reg != null && _bold != null) return;
    final r = await rootBundle.load('assets/fonts/Vazirmatn-Regular.ttf');
    final b = await rootBundle.load('assets/fonts/Vazirmatn-Bold.ttf');
    _reg = pw.Font.ttf(r);
    _bold = pw.Font.ttf(b);
  }

  static String _money(dynamic v) {
    final n = v is num ? v.round() : 0;
    return n < 0 ? '−${faNum(-n, dec: 0)} تومان' : '${faNum(n, dec: 0)} تومان';
  }

  static String _str(dynamic v) => v == null ? '' : '$v';

  static pw.Widget _party(String title, Map<dynamic, dynamic> data, List<String> keys, List<String> labels) {
    final rows = <pw.Widget>[
      pw.Text(pdfText(title), style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
    ];
    for (var i = 0; i < keys.length; i++) {
      final v = _str(data[keys[i]]);
      if (v.isEmpty) continue;
      rows.add(pw.Text(pdfText('${labels[i]}: $v'), style: const pw.TextStyle(fontSize: 10)));
    }
    return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: rows);
  }

  static pw.Widget _cell(String text, {bool bold = false, bool right = true}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        child: pw.Text(
          pdfText(text),
          textAlign: right ? pw.TextAlign.right : pw.TextAlign.left,
          style: pw.TextStyle(fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal, fontSize: 11),
        ),
      );

  /// فایل PDF را در پوشهٔ موقت می‌سازد و مسیرش را برمی‌گرداند
  static Future<File> build(Map<String, dynamic> inv) async {
    await _loadFonts();
    final doc = pw.Document(theme: pw.ThemeData.withFont(base: _reg, bold: _bold));

    final seller = inv['seller'] is Map ? Map<dynamic, dynamic>.from(inv['seller'] as Map) : <dynamic, dynamic>{};
    final buyer = inv['buyer'] is Map ? Map<dynamic, dynamic>.from(inv['buyer'] as Map) : <dynamic, dynamic>{};
    final lines = inv['lines'] is List ? (inv['lines'] as List).whereType<Map>().toList() : <Map>[];
    final periods = inv['periods'] is List ? (inv['periods'] as List).whereType<Map>().toList() : <Map>[];
    final total = inv['total'];
    final methods = {'gateway': 'درگاه زرین‌پال', 'card': 'کارت‌به‌کارت', 'sheba': 'شبا', 'free': 'رایگان (کد تخفیف)'};
    final method = methods[_str(inv['method'])] ?? _str(inv['method']);
    final border = pw.TableBorder.all(color: PdfColors.grey400, width: 0.5);

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      textDirection: pw.TextDirection.rtl,
      margin: const pw.EdgeInsets.all(32),
      build: (ctx) => [
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text(pdfText('فاکتور اشتراک'), style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
          pw.Text(pdfText('شمارهٔ فاکتور: ${_str(inv['number'])}')),
        ]),
        pw.SizedBox(height: 4),
        pw.Text(pdfText('تاریخ: ${_str(inv['date_jalali'])}')),
        pw.Divider(),
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Expanded(
            child: _party('فروشنده', seller, ['name', 'phone', 'address', 'economic_code'],
                ['نام', 'تلفن', 'نشانی', 'کد اقتصادی']),
          ),
          pw.Expanded(
            child: _party('خریدار', buyer, ['name', 'phone'], ['نام', 'شماره موبایل']),
          ),
        ]),
        pw.SizedBox(height: 14),
        pw.Table(
          border: border,
          columnWidths: {0: const pw.FlexColumnWidth(3), 1: const pw.FlexColumnWidth(1.5)},
          children: [
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: PdfColors.grey200),
              children: [_cell('شرح', bold: true), _cell('مبلغ', bold: true, right: false)],
            ),
            for (final l in lines.where((l) => l['kind'] != 'total'))
              pw.TableRow(children: [_cell('${l['label'] ?? ''}'), _cell(_money(l['amount']), right: false)]),
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: PdfColors.grey100),
              children: [_cell('جمع کل (قابل پرداخت)', bold: true), _cell(_money(total), bold: true, right: false)],
            ),
          ],
        ),
        pw.SizedBox(height: 12),
        if (periods.isNotEmpty) ...[
          pw.Text(pdfText('دوره‌های خریداری‌شده:'), style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          for (final pr in periods) pw.Text(pdfText('• ${_str(pr['label'])}')),
          pw.SizedBox(height: 8),
        ],
        if (inv['new_expiry_jalali'] != null) pw.Text(pdfText('اعتبار اشتراک تا: ${_str(inv['new_expiry_jalali'])}')),
        pw.Text(pdfText('روش پرداخت: $method')),
        if (inv['ref_id'] != null) pw.Text(pdfText('کد پیگیری بانک: ${_str(inv['ref_id'])}')),
        pw.SizedBox(height: 18),
        pw.Text(pdfText(_str(inv['footer'])), style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
        pw.SizedBox(height: 6),
        pw.Text(pdfText('پسته بازار'), style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
      ],
    ));

    final dir = await getTemporaryDirectory();
    final safe = _str(inv['number']).replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final file = File(p.join(dir.path, 'invoice_$safe.pdf'));
    await file.writeAsBytes(await doc.save());
    return file;
  }
}
