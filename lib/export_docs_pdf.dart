import 'dart:io';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'fmt.dart' show Fmt;
import 'pdf_output.dart';
import 'pdf_service.dart';
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi;
import 'widgets.dart' show snack;

/// S31.T31.11 — export documents (FX plan): packing list + certificate-of-origin data sheet.
/// Data comes from server action `sale_export.docs {sale_id}` (online only). The origin sheet is a
/// supporting document; the official certificate is issued by the Chamber of Commerce.
class ExportDocsPdf {
  static String _s(dynamic v) => v == null ? '' : pdfText(v.toString());
  static double _d(dynamic v) => v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);
  static String _kg(double v) => Fmt.money(v, label: false);

  static pw.Widget _kv(String k, String v) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2),
        child: pw.Row(children: <pw.Widget>[
          pw.SizedBox(width: 120, child: pw.Text(pdfText(k), style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold))),
          pw.Expanded(child: pw.Text(v.isEmpty ? '-' : v, style: const pw.TextStyle(fontSize: 10))),
        ]),
      );

  static List<pw.Widget> _parties(Map<String, dynamic> data) {
    final Map<String, dynamic> sale = Map<String, dynamic>.from((data['sale'] as Map?) ?? <String, dynamic>{});
    final Map<String, dynamic> co = Map<String, dynamic>.from((data['company'] as Map?) ?? <String, dynamic>{});
    final Map<String, dynamic> f = Map<String, dynamic>.from((data['fields'] as Map?) ?? <String, dynamic>{});
    final String date = DateTime.tryParse('${sale['date'] ?? ''}') != null ? jalaliDateFromDt(DateTime.parse('${sale['date']}')) : '';
    return <pw.Widget>[
      _kv('صادرکننده', _s(co['name'])),
      _kv('نشانی', _s(co['address'])),
      _kv('تلفن', _s(co['phones'])),
      _kv('شناسه ملی / کد اقتصادی', '${_s(co['national_id'])} / ${_s(co['economic_code'])}'),
      _kv('خریدار (گیرنده)', _s(sale['buyer'])),
      _kv('شمارهٔ فاکتور', _s(sale['id'])),
      _kv('تاریخ', date),
      _kv('اینکوترمز', _s(f['incoterm'])),
      _kv('بندر مبدأ', _s(f['port_loading'])),
      _kv('بندر مقصد', _s(f['port_destination'])),
    ];
  }

  /// Packing list: one row per lot + totals (net kg, packages, gross kg).
  static Future<File> buildPackingList(Map<String, dynamic> data) async {
    await PdfService.ensureFonts();
    final pw.Document doc = pw.Document(theme: PdfService.theme());
    final List<dynamic> items = (data['items'] as List?) ?? <dynamic>[];
    final Map<String, dynamic> f = Map<String, dynamic>.from((data['fields'] as Map?) ?? <String, dynamic>{});
    double net = 0;
    final List<List<String>> rows = <List<String>>[];
    int i = 0;
    for (final dynamic it in items) {
      final Map<String, dynamic> m = Map<String, dynamic>.from(it as Map);
      final double w = _d(m['weight']);
      net += w;
      i++;
      rows.add(<String>[
        '$i',
        _s(m['lot_code']),
        _s(m['type_name']),
        _kg(w),
        _s(_d(m['small_sacks']) + _d(m['large_sacks']) > 0 ? (_d(m['small_sacks']) + _d(m['large_sacks'])).toStringAsFixed(0) : ''),
      ]);
    }
    final int pkgs = f['pkg_count'] == null ? 0 : _d(f['pkg_count']).round();
    final double gross = _d(f['gross_kg']);
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      textDirection: pw.TextDirection.rtl,
      footer: (pw.Context c) => PdfService.brandFooter(),
      build: (pw.Context c) => <pw.Widget>[
        pw.Text(pdfText('لیست بسته‌بندی — Packing List'), style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
        pw.Divider(),
        ..._parties(data),
        _kv('نوع بسته', _s(f['pkg_type'])),
        _kv('علائم و شمارهٔ بسته‌ها', _s(f['marks'])),
        pw.SizedBox(height: 10),
        if (rows.isEmpty)
          pw.Text(pdfText('اقلامی برای این فروش ثبت نشده است'))
        else
          pw.Table.fromTextArray(
            headers: <String>['ردیف', 'کد لات', 'نوع محصول', 'وزن خالص (کیلو)', 'تعداد گونی'].map(pdfText).toList(),
            data: rows.map((List<String> r) => r.map(pdfText).toList()).toList(),
            headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
            cellStyle: const pw.TextStyle(fontSize: 9),
            cellAlignment: pw.Alignment.centerRight,
            headerAlignment: pw.Alignment.centerRight,
            border: pw.TableBorder.all(width: 0.4),
          ),
        pw.SizedBox(height: 10),
        _kv('جمع وزن خالص (کیلو)', _kg(net)),
        _kv('تعداد کل بسته', pkgs > 0 ? '$pkgs' : ''),
        _kv('وزن ناخالص (کیلو)', gross > 0 ? _kg(gross) : ''),
        pw.SizedBox(height: 24),
        pw.Text(pdfText('مهر و امضای صادرکننده'), style: const pw.TextStyle(fontSize: 10)),
      ],
    ));
    return PdfService.saveDocument(doc, 'packing_list_${DateTime.now().millisecondsSinceEpoch}.pdf');
  }

  /// Certificate-of-origin data sheet (supporting document, not the official chamber certificate).
  static Future<File> buildOriginCert(Map<String, dynamic> data) async {
    await PdfService.ensureFonts();
    final pw.Document doc = pw.Document(theme: PdfService.theme());
    final List<dynamic> items = (data['items'] as List?) ?? <dynamic>[];
    final Map<String, dynamic> f = Map<String, dynamic>.from((data['fields'] as Map?) ?? <String, dynamic>{});
    final Set<String> types = <String>{};
    double net = 0;
    for (final dynamic it in items) {
      final Map<String, dynamic> m = Map<String, dynamic>.from(it as Map);
      net += _d(m['weight']);
      final String t = _s(m['type_name']);
      if (t.isNotEmpty) types.add(t);
    }
    final String origin = _s(f['origin_country']).isEmpty ? 'ایران (Islamic Republic of Iran)' : _s(f['origin_country']);
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      textDirection: pw.TextDirection.rtl,
      build: (pw.Context c) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: <pw.Widget>[
        pw.Text(pdfText('برگ اطلاعات گواهی مبدأ — Certificate of Origin (data sheet)'), style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold)),
        pw.Divider(),
        _kv('شمارهٔ گواهی', _s(f['cert_no'])),
        ..._parties(data),
        _kv('کشور مبدأ کالا', origin),
        _kv('شرح کالا', types.isEmpty ? 'پسته' : types.join('، ')),
        _kv('کد تعرفه (HS)', _s(f['hs_code'])),
        _kv('وزن خالص (کیلو)', _kg(net)),
        _kv('تعداد بسته', f['pkg_count'] == null ? '' : '${_d(f['pkg_count']).round()}'),
        _kv('روش حمل', _s(f['ship_method'])),
        pw.SizedBox(height: 16),
        pw.Text(pdfText('این برگ صرفاً اطلاعات پشتیبان است؛ گواهی رسمی مبدأ توسط اتاق بازرگانی صادر می‌شود.'), style: const pw.TextStyle(fontSize: 9)),
        pw.SizedBox(height: 24),
        pw.Text(pdfText('مهر و امضا'), style: const pw.TextStyle(fontSize: 10)),
      ]),
    ));
    return PdfService.saveDocument(doc, 'origin_cert_${DateTime.now().millisecondsSinceEpoch}.pdf');
  }

  /// UI entry point: fetch data then show the PDF. kind = 'packing' | 'origin'.
  static Future<void> open(BuildContext context, int saleId, String kind) async {
    try {
      final dynamic r = await StockApi.call('sale_export.docs', <String, dynamic>{'sale_id': saleId});
      final Map<String, dynamic> data = Map<String, dynamic>.from(r as Map);
      final File file = kind == 'origin' ? await buildOriginCert(data) : await buildPackingList(data);
      if (context.mounted) await PdfOutput.show(context, file);
    } catch (e) {
      if (context.mounted) snack(context, 'خطا در ساخت PDF: $e');
    }
  }
}
