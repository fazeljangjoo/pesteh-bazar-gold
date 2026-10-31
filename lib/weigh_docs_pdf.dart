import 'dart:io';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'fmt.dart' show Fmt;
import 'pdf_service.dart' show PdfService, pdfText;
import 'utils.dart' show jalaliDateFromDt;

/// S35.T35.13b — رسید باسکول و بارنامه (PDF). قالب‌ها: A4، A5 و رول ۸۰ میلی‌متری.
/// ورودی: نقشهٔ سند ذخیره‌شده (همان کلیدهای سرور) تا عددها با ثبت یکی باشند.
enum WeighPaper { a4, a5, roll80 }

class WeighDocs {
  WeighDocs._();

  static PdfPageFormat _format(WeighPaper p) {
    switch (p) {
      case WeighPaper.a4:
        return PdfPageFormat.a4;
      case WeighPaper.a5:
        return PdfPageFormat.a5;
      case WeighPaper.roll80:
        return PdfPageFormat.roll80;
    }
  }

  static String _s(Object? v) => v == null ? '—' : '$v';

  static String _kg(Object? v) => v is num ? Fmt.kg(v) : '—';

  static pw.Widget _kv(String k, String v, {bool bold = false}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2),
        child: pw.Row(children: <pw.Widget>[
          pw.Expanded(child: pw.Text(pdfText(k), style: const pw.TextStyle(fontSize: 9))),
          pw.Text(pdfText(v), style: pw.TextStyle(fontSize: bold ? 11 : 9, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
        ]),
      );

  static String _date(Object? v) {
    final DateTime? d = v is DateTime ? v : DateTime.tryParse('$v');
    return d == null ? '—' : jalaliDateFromDt(d);
  }

  /// رسید باسکول: ناخالص، تارا، خالص، تعداد گونی؛ مخصوص توزین ورودی/خروجی.
  static Future<File> buildSlip(Map<String, dynamic> d, {WeighPaper paper = WeighPaper.a5, String company = ''}) async {
    await PdfService.ensureFonts();
    final pw.Document doc = pw.Document(theme: PdfService.theme());
    final String no = _s(d['number'] ?? d['id']);
    doc.addPage(pw.Page(
      pageFormat: _format(paper),
      textDirection: pw.TextDirection.rtl,
      build: (pw.Context ctx) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: <pw.Widget>[
        if (company.isNotEmpty) pw.Text(pdfText(company), style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
        pw.Text(pdfText('رسید باسکول'), style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
        pw.Text(pdfText('شمارهٔ رسید: $no  ·  تاریخ: ${_date(d['date'])}'), style: const pw.TextStyle(fontSize: 9)),
        pw.Divider(),
        _kv('طرف حساب', _s(d['party'])),
        _kv('نوع / کد', '${_s(d['type_name'])} / ${_s(d['code'])}'),
        _kv('شمارهٔ پلاک', _s(d['vehicle_plate'])),
        _kv('راننده', _s(d['driver_name'])),
        pw.Divider(),
        _kv('وزن ناخالص', _kg(d['gross_kg'] ?? d['total_weight'])),
        _kv('تارا', _kg(d['tare_kg'])),
        _kv('کسر کیفیت', _kg(d['quality_deduct_kg'])),
        _kv('وزن خالص', _kg(d['net_kg'] ?? d['net_weight']), bold: true),
        _kv('تعداد گونی کوچک / بزرگ', '${_s(d['small_sack_count'])} / ${_s(d['large_sack_count'])}'),
        pw.SizedBox(height: 16),
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: <pw.Widget>[
          pw.Text(pdfText('امضای توزین‌کننده'), style: const pw.TextStyle(fontSize: 8)),
          pw.Text(pdfText('امضای تحویل‌دهنده'), style: const pw.TextStyle(fontSize: 8)),
        ]),
      ]),
    ));
    return PdfService.saveDocument(doc, 'weigh_slip_$no.pdf');
  }

  /// بارنامه: مشخصات حمل، اقلام (نوع/کد/کیلو/گونی) و جمع؛ امضای فرستنده، راننده، گیرنده.
  static Future<File> buildWaybill(
    Map<String, dynamic> d, {
    List<Map<String, dynamic>> items = const <Map<String, dynamic>>[],
    WeighPaper paper = WeighPaper.a4,
    String company = '',
  }) async {
    await PdfService.ensureFonts();
    final pw.Document doc = pw.Document(theme: PdfService.theme());
    final String no = _s(d['number'] ?? d['id']);
    double totalKg = 0;
    final List<List<String>> rows = <List<String>>[];
    for (final Map<String, dynamic> it in items) {
      final double kg = ((it['weight'] as num?) ?? 0).toDouble();
      totalKg += kg;
      rows.add(<String>[_s(it['type_name']), _s(it['code']), Fmt.kg(kg, label: false), _s(it['sacks'])]);
    }
    doc.addPage(pw.MultiPage(
      pageFormat: _format(paper),
      textDirection: pw.TextDirection.rtl,
      build: (pw.Context ctx) => <pw.Widget>[
        if (company.isNotEmpty) pw.Text(pdfText(company), style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
        pw.Text(pdfText('بارنامه'), style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
        pw.Text(pdfText('شمارهٔ بارنامه: $no  ·  تاریخ: ${_date(d['date'])}'), style: const pw.TextStyle(fontSize: 9)),
        pw.Divider(),
        _kv('فرستنده / گیرنده', _s(d['party'])),
        _kv('شمارهٔ پلاک', _s(d['vehicle_plate'])),
        _kv('راننده', _s(d['driver_name'])),
        pw.SizedBox(height: 8),
        pw.TableHelper.fromTextArray(
          headers: <String>['نوع', 'کد', 'کیلو (خالص)', 'گونی'],
          data: rows,
          cellStyle: const pw.TextStyle(fontSize: 9),
          headerStyle: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
        ),
        pw.SizedBox(height: 6),
        _kv('جمع وزن خالص', Fmt.kg(totalKg), bold: true),
        pw.SizedBox(height: 24),
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: <pw.Widget>[
          pw.Text(pdfText('امضای فرستنده'), style: const pw.TextStyle(fontSize: 8)),
          pw.Text(pdfText('امضای راننده'), style: const pw.TextStyle(fontSize: 8)),
          pw.Text(pdfText('امضای گیرنده'), style: const pw.TextStyle(fontSize: 8)),
        ]),
      ],
    ));
    return PdfService.saveDocument(doc, 'waybill_$no.pdf');
  }
}
