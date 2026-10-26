import 'dart:io';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'barcode_utils.dart';
import 'company_profile.dart';
import 'pdf_service.dart';
import 'utils.dart';

/// S12.T12.1 — shared data model for every invoice-like PDF + one layout per template
/// (A4, A5, roll 80 mm, roll 58 mm). Layout code is purely presentational.
class InvDoc {
  final String title;
  final String fileTag;
  final List<List<String>> header; // [key, value]
  final List<String> columns;
  final List<List<String>> rows;
  final List<List<String>> blocks; // optional extra [key, value] lines under the table (weights...)
  final List<List<String>> totals; // [key, value]; the last block is emphasised
  final List<String> barcodes;
  final String? qrData; // T12.3: QR of invoice number / lot code (rendered under the table)
  final String? note;
  final List<String> signLabels; // empty = no signature boxes

  const InvDoc({
    required this.title,
    required this.fileTag,
    required this.header,
    required this.columns,
    required this.rows,
    this.blocks = const <List<String>>[],
    required this.totals,
    this.barcodes = const <String>[],
    this.qrData,
    this.note,
    this.signLabels = const <String>[],
  });
}

class InvoiceTemplatesPdf {
  InvoiceTemplatesPdf._();

  static const double _mm = PdfPageFormat.mm;

  static PdfPageFormat _roll(double widthMm) =>
      PdfPageFormat(widthMm * _mm, double.infinity, marginAll: 3 * _mm);

  static pw.Widget _kvLine(String k, String v, double fs, {bool bold = false}) {
    final pw.TextStyle st =
        pw.TextStyle(fontSize: fs, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal);
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: <pw.Widget>[
          pw.Text(pdfText(k), style: st),
          pw.SizedBox(width: 6),
          pw.Flexible(child: pw.Text(pdfText(v), style: st, textAlign: pw.TextAlign.left)),
        ],
      ),
    );
  }

  static pw.Widget _box(pw.Widget child, {double w = 0.5, double pad = 8}) => pw.Container(
        padding: pw.EdgeInsets.all(pad),
        decoration: pw.BoxDecoration(border: pw.Border.all(width: w), borderRadius: pw.BorderRadius.circular(5)),
        child: child,
      );

  /// Company identity block. [compact] = centered, for roll paper.
  static pw.Widget _companyHeader(CompanyProfile? c, double fs, {required bool compact}) {
    if (c == null) return pw.SizedBox();
    final logo = c.logoBytes;
    pw.Widget? img;
    if (logo != null) {
      try {
        img = pw.Image(pw.MemoryImage(logo), width: compact ? 40 : 56, height: compact ? 40 : 56, fit: pw.BoxFit.contain);
      } catch (_) {
        img = null;
      }
    }
    final pw.Widget texts = pw.Column(
      crossAxisAlignment: compact ? pw.CrossAxisAlignment.center : pw.CrossAxisAlignment.start,
      children: <pw.Widget>[
        if (c.name.isNotEmpty)
          pw.Text(pdfText(c.name), style: pw.TextStyle(fontSize: fs + 3, fontWeight: pw.FontWeight.bold)),
        for (final String l in c.infoLines)
          pw.Text(pdfText(l), style: pw.TextStyle(fontSize: fs - 1), textAlign: compact ? pw.TextAlign.center : pw.TextAlign.right),
      ],
    );
    if (compact) {
      return pw.Column(children: <pw.Widget>[
        if (img != null) img,
        if (img != null) pw.SizedBox(height: 3),
        texts,
        pw.Divider(thickness: 0.5),
      ]);
    }
    return pw.Column(children: <pw.Widget>[
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.center, children: <pw.Widget>[
        if (img != null) img,
        if (img != null) pw.SizedBox(width: 10),
        pw.Expanded(child: texts),
      ]),
      pw.Divider(thickness: 0.6),
    ]);
  }

  static pw.Widget _footer(CompanyProfile? c, double fs) => pw.Column(children: <pw.Widget>[
        if (c != null && c.footerText.isNotEmpty) ...<pw.Widget>[
          pw.SizedBox(height: 6),
          pw.Text(pdfText(c.footerText), style: pw.TextStyle(fontSize: fs), textAlign: pw.TextAlign.center),
        ],
        PdfService.brandFooter(),
      ]);

  static pw.Widget _table(InvDoc d, double fs) => pw.Table.fromTextArray(
        headers: d.columns.map(pdfText).toList(),
        data: <List<String>>[for (final List<String> r in d.rows) r.map(pdfText).toList()],
        headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: fs),
        cellStyle: pw.TextStyle(fontSize: fs),
        cellAlignment: pw.Alignment.centerRight,
        headerAlignment: pw.Alignment.centerRight,
        border: pw.TableBorder.all(width: 0.4),
      );

  /// Roll paper: every row becomes a small stacked block (no wide table).
  static List<pw.Widget> _rollRows(InvDoc d, double fs) {
    final List<pw.Widget> out = <pw.Widget>[];
    for (int i = 0; i < d.rows.length; i++) {
      final List<String> r = d.rows[i];
      out.add(pw.Container(
        padding: const pw.EdgeInsets.symmetric(vertical: 3),
        decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(width: 0.3))),
        child: pw.Column(children: <pw.Widget>[
          for (int k = 0; k < d.columns.length && k < r.length; k++)
            if (r[k].trim().isNotEmpty && r[k] != '-') _kvLine(d.columns[k], r[k], fs),
        ]),
      ));
    }
    return out;
  }

  static pw.Widget _signs(List<String> labels, double h, double fs) => pw.Row(children: <pw.Widget>[
        for (final String l in labels)
          pw.Expanded(
            child: pw.Container(
              height: h,
              margin: const pw.EdgeInsets.symmetric(horizontal: 5),
              padding: const pw.EdgeInsets.all(5),
              decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.5), borderRadius: pw.BorderRadius.circular(4)),
              child: pw.Text(pdfText(l), style: pw.TextStyle(fontSize: fs)),
            ),
          ),
      ]);

  static List<pw.Widget> _pageBody(InvDoc d, CompanyProfile? c, InvTemplate t) {
    final bool roll = t == InvTemplate.roll80 || t == InvTemplate.roll58;
    final double fs = switch (t) {
      InvTemplate.a4 => 9,
      InvTemplate.a5 => 8,
      InvTemplate.roll80 => 8,
      InvTemplate.roll58 => 7,
    };
    final double titleFs = switch (t) {
      InvTemplate.a4 => 20,
      InvTemplate.a5 => 16,
      InvTemplate.roll80 => 12,
      InvTemplate.roll58 => 10,
    };
    final DateTime now = DateTime.now();
    final List<List<String>> tots = d.totals;
    return <pw.Widget>[
      _companyHeader(c, fs + 1, compact: roll),
      pw.Align(
        alignment: roll ? pw.Alignment.center : pw.Alignment.centerRight,
        child: pw.Text(pdfText(d.title), style: pw.TextStyle(fontSize: titleFs, fontWeight: pw.FontWeight.bold)),
      ),
      pw.SizedBox(height: roll ? 3 : 6),
      _box(pw.Column(children: <pw.Widget>[for (final List<String> h in d.header) _kvLine(h[0], h[1], fs + 1)]),
          pad: roll ? 4 : 8),
      pw.SizedBox(height: roll ? 4 : 10),
      if (d.barcodes.isNotEmpty) ...<pw.Widget>[
        pw.Wrap(
          alignment: pw.WrapAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: <pw.Widget>[
            for (final String b in d.barcodes)
              pdfBarcode(b, height: roll ? 26 : 34, width: t == InvTemplate.roll58 ? 120 : 130),
          ],
        ),
        pw.SizedBox(height: 6),
      ],
      if (roll) ..._rollRows(d, fs) else _table(d, fs),
      if (d.qrData != null && d.qrData!.isNotEmpty) ...<pw.Widget>[
        pw.SizedBox(height: 6),
        pw.Center(
          child: pw.Directionality(
            textDirection: pw.TextDirection.ltr,
            child: pw.BarcodeWidget(
              barcode: pw.Barcode.qrCode(),
              data: d.qrData!,
              width: roll ? (t == InvTemplate.roll58 ? 70 : 90) : 80,
              height: roll ? (t == InvTemplate.roll58 ? 70 : 90) : 80,
              drawText: false,
            ),
          ),
        ),
      ],
      if (d.blocks.isNotEmpty) ...<pw.Widget>[
        pw.SizedBox(height: roll ? 4 : 10),
        _box(pw.Column(children: <pw.Widget>[for (final List<String> b in d.blocks) _kvLine(b[0], b[1], fs)]),
            pad: roll ? 4 : 8),
      ],
      pw.SizedBox(height: roll ? 4 : 10),
      _box(
        pw.Column(children: <pw.Widget>[
          for (int i = 0; i < tots.length; i++) _kvLine(tots[i][0], tots[i][1], fs + 1, bold: true),
        ]),
        w: 1,
        pad: roll ? 4 : 8,
      ),
      if (d.note != null && d.note!.trim().isNotEmpty) ...<pw.Widget>[
        pw.SizedBox(height: 6),
        pw.Text(pdfText('توضیحات: ${d.note}'), style: pw.TextStyle(fontSize: fs)),
      ],
      if (d.signLabels.isNotEmpty && !roll) ...<pw.Widget>[
        pw.SizedBox(height: t == InvTemplate.a4 ? 22 : 12),
        _signs(d.signLabels, t == InvTemplate.a4 ? 56 : 40, fs),
      ],
      pw.SizedBox(height: 6),
      pw.Text(pdfText('تاریخ صدور: ${jalaliDateFromDt(now)}'), style: pw.TextStyle(fontSize: fs - 1)),
      _footer(c, fs),
    ];
  }

  /// Renders [d] in template [t] with the company header [c] (null = none) and saves a temp PDF.
  static Future<File> render(InvDoc d, InvTemplate t, CompanyProfile? c) async {
    await PdfService.ensureFonts();
    final pw.Document doc = pw.Document(theme: PdfService.theme());
    final bool roll = t == InvTemplate.roll80 || t == InvTemplate.roll58;
    if (roll) {
      // roll paper has no fixed height: a single Page sized to its content
      final PdfPageFormat fmt = _roll(t == InvTemplate.roll80 ? 80 : 58);
      doc.addPage(pw.Page(
        pageFormat: fmt,
        textDirection: pw.TextDirection.rtl,
        build: (pw.Context ctx) => pw.Column(children: _pageBody(d, c, t)),
      ));
    } else {
      final bool a4 = t == InvTemplate.a4;
      doc.addPage(pw.MultiPage(
        pageFormat: a4 ? PdfPageFormat.a4 : PdfPageFormat.a5,
        margin: pw.EdgeInsets.all(a4 ? 28 : 18),
        textDirection: pw.TextDirection.rtl,
        build: (pw.Context ctx) => _pageBody(d, c, t),
      ));
    }
    return PdfService.saveDocument(doc, '${d.fileTag}_${t.name}_${DateTime.now().millisecondsSinceEpoch}.pdf');
  }
}
