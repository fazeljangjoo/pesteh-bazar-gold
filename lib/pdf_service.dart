import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'barcode_utils.dart';
import 'company_profile.dart';
import 'excel_io.dart';
import 'invoice_templates_pdf.dart';
import 'fx_doc_field.dart' show kFxRialPerStoredUnit;
import 'fmt.dart' show Fmt;
import 'utils.dart';

/// برچسب‌های جهت تراکنش که در جدول PDF نشان داده می‌شود
typedef DirectionLabels = ({String from, String fromName, String to, String toName});

/// مسیر فونت فارسی داخل assets پروژه — این دو فایل باید توسط خودتان اضافه شوند
/// (به README یا توضیحات پایین فایل مراجعه کنید). با این روش نیازی به اینترنت
/// در زمان اجرا نیست؛ فونت همراه خود اپ نصب می‌شود.
const String _kFontRegularAsset = 'assets/fonts/Vazirmatn-Regular.ttf';
const String _kFontBoldAsset = 'assets/fonts/Vazirmatn-Bold.ttf';

/// نیم‌فاصلهٔ فارسی در فونت PDF به‌صورت علامت خراب نمایش داده می‌شد (مثلاً «پرداخت‌کننده»)؛
/// برای رندر درست در PDF نیم‌فاصله با فاصلهٔ معمولی جایگزین می‌شود.
String pdfText(String s) => s.replaceAll('\u200c', ' ');

const String _kIconAsset = 'assets/images/pesteh-bazar-icon.png';

class PdfService {
  static pw.Font? _regular;
  static pw.Font? _bold;
  static pw.MemoryImage? _icon;

  static Future<void> _ensureIcon() async {
    if (_icon != null) return;
    try {
      final d = await rootBundle.load(_kIconAsset);
      _icon = pw.MemoryImage(d.buffer.asUint8List());
    } catch (_) {}
  }

  /// پای همهٔ صفحه‌ها: آیکون و نام «پسته بازار»
  static pw.Widget _brandFooter() => pw.Container(
        alignment: pw.Alignment.center,
        margin: const pw.EdgeInsets.only(top: 8),
        child: pw.Row(mainAxisSize: pw.MainAxisSize.min, children: [
          if (_icon != null) pw.Image(_icon!, width: 16, height: 16),
          if (_icon != null) pw.SizedBox(width: 5),
          pw.Text(pdfText('پسته بازار'), style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
        ]),
      );

  /// فونت فارسی را از assets داخل خود اپ بارگیری می‌کند (آفلاین، بدون اینترنت)
  static Future<void> _ensureFonts() async {
    if (_regular != null && _bold != null) {
      await _ensureIcon();
      return;
    }
    try {
      final regularData = await rootBundle.load(_kFontRegularAsset);
      final boldData = await rootBundle.load(_kFontBoldAsset);
      _regular = pw.Font.ttf(regularData);
      _bold = pw.Font.ttf(boldData);
      await _ensureIcon();
    } catch (e) {
      throw Exception(
          'فونت فارسی پیدا نشد. فایل‌های $_kFontRegularAsset و $_kFontBoldAsset را '
          'در پروژه قرار دهید و در pubspec.yaml به‌عنوان asset معرفی کنید.');
    }
  }

  static pw.ThemeData _theme() => pw.ThemeData.withFont(base: _regular, bold: _bold);

  /// S12.T12.1: public hooks used by invoice_templates_pdf.dart
  static Future<void> ensureFonts() => _ensureFonts();
  static pw.ThemeData theme() => _theme();
  static Future<File> saveDocument(pw.Document doc, String filename) => _saveDoc(doc, filename);
  static pw.Widget brandFooter() => _brandFooter();

  static Future<File> _saveDoc(pw.Document doc, String filename) async {
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, filename));
    await file.writeAsBytes(await doc.save());
    return file;
  }

  static Future<void> share(File file) async {
    final bytes = await file.readAsBytes();
    if (Platform.isWindows) {
      // ویندوز: پنجرهٔ چاپ (پرینتر لیزری/حرارتی یا «Microsoft Print to PDF» برای ذخیره)
      await Printing.layoutPdf(onLayout: (_) async => bytes, name: p.basename(file.path));
      return;
    }
    await Printing.sharePdf(bytes: bytes, filename: p.basename(file.path));
  }

  /// S06.T06.3: generic landscape table report (cheque reports; reusable by other list reports).
  static Future<File> buildTableReport({
    required String title,
    String subtitle = '',
    List<List<String>> kv = const <List<String>>[],
    required List<String> headers,
    required List<List<String>> rows,
    String filePrefix = 'report',
    String company = '',
    bool pageNumbers = false,
    List<String> signatures = const <String>[],
  }) async {
    await _ensureFonts();
    final doc = pw.Document(theme: _theme());
    final now = DateTime.now();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        textDirection: pw.TextDirection.rtl,
        header: (ctx) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          if (company.isNotEmpty) pw.Text(pdfText(company), style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
          pw.Text(pdfText(title), style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          if (subtitle.isNotEmpty) pw.Text(pdfText(subtitle), style: const pw.TextStyle(fontSize: 9)),
          pw.Text(pdfText('تاریخ تهیه گزارش: ${jalaliDateFromDt(now)}'), style: const pw.TextStyle(fontSize: 9)),
          pw.Divider(),
        ]),
        footer: (ctx) => pageNumbers
            ? pw.Column(children: [_brandFooter(), pw.Text(pdfText('صفحه ${ctx.pageNumber} از ${ctx.pagesCount}'), style: const pw.TextStyle(fontSize: 8))])
            : _brandFooter(),
        build: (ctx) => [
          if (kv.isNotEmpty)
            pw.Container(
              padding: const pw.EdgeInsets.all(8),
              margin: const pw.EdgeInsets.only(bottom: 10),
              decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.5), borderRadius: pw.BorderRadius.circular(6)),
              child: pw.Column(children: [for (final List<String> e in kv) _kv(e[0], e[1], bold: e.length > 2)]),
            ),
          if (rows.isEmpty)
            pw.Text(pdfText('موردی یافت نشد'))
          else
            pw.Table.fromTextArray(
              headers: headers.map(pdfText).toList(),
              data: rows.map((r) => r.map(pdfText).toList()).toList(),
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
              cellStyle: const pw.TextStyle(fontSize: 8.5),
              cellAlignment: pw.Alignment.centerRight,
              headerAlignment: pw.Alignment.centerRight,
              border: pw.TableBorder.all(width: 0.4),
            ),
          if (signatures.isNotEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 40),
              child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceAround, children: [for (final String sg in signatures) pw.Text(pdfText('$sg: ................'), style: const pw.TextStyle(fontSize: 10))]),
            ),
        ],
      ),
    );
    final File xf = await _saveDoc(doc, '${filePrefix}_${now.millisecondsSinceEpoch}.pdf');
    ExcelIo.register(xf.path, title, <List<String>>[headers, ...rows]);
    return xf;
  }

  static Future<File> buildStockCard({
    required String code,
    required double totalWeight,
    required double netWeight,
    required double smallSacks,
    required double largeSacks,
  }) async {
    await _ensureFonts();
    final doc = pw.Document(theme: _theme());
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a6,
      margin: const pw.EdgeInsets.all(14),
      textDirection: pw.TextDirection.rtl,
      build: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Text('کارتکس انبار', style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold)),
          pw.Divider(),
          _kv('کد پسته', code, bold: true),
          if (isPrintableCode(code)) ...[
            pw.SizedBox(height: 6),
            pw.Center(child: pdfBarcode(code)),
          ] else
            pdfBarcodeNote(),
          _kv('وزن کل (ناخالص)', '${faNum(totalWeight)} کیلو'),
          _kv('وزن پسته (خالص)', '${faNum(netWeight)} کیلو'),
          _kv('تعداد گونی', faNum(smallSacks + largeSacks)),
          _kv('تعداد گونی کوچک', faNum(smallSacks)),
          _kv('تعداد گونی بزرگ', faNum(largeSacks)),
          pw.Spacer(),
          _brandFooter(),
        ],
      ),
    ));
    return _saveDoc(doc, 'stock_card_$code.pdf');
  }

  static pw.Widget _kv(String k, String v, {bool bold = false}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(pdfText(k), style: pw.TextStyle(fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
            pw.Text(pdfText(v), style: pw.TextStyle(fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
          ],
        ),
      );

  /// رسید تراکنش‌های پرداخت (خرید) یا دریافت (فروش) برای یک رکورد مشخص
  static Future<File> buildPaymentLedger({
    required String title,
    required String pesteCode,
    required String totalLabel,
    required double total,
    required double settled,
    required double remaining,
    required String? payType,
    required String? stagedType,
    required List<Map<String, dynamic>> lump,
    required List<Map<String, dynamic>> credit,
    required List<Map<String, dynamic>> cheque,
    required DirectionLabels directionLabels,
  }) async {
    await _ensureFonts();
    final doc = pw.Document(theme: _theme());
    final now = DateTime.now();

    List<List<String>> rows = [];
    if (payType == 'lump') {
      rows = [
        ['وضعیت', 'تاریخ', directionLabels.toName, directionLabels.fromName, 'مبلغ (${Fmt.unitLabel()})'],
        for (final r in lump)
          [
            (r['paid'] as int? ?? 1) == 1 ? 'تسویه شده' : 'ثبت‌شده',
            jalaliDate(r['date'] as String),
            '${r['seller_name'] ?? r['receiver_name'] ?? '-'}',
            '${r['payer_name'] ?? '-'}',
            Fmt.money(r['amount'] as num, label: false),
          ],
      ];
    } else if (payType == 'mixed') {
      // ترکیبی: یک جدول واحد با ستون «نوع» برای هر سطر
      rows = [
        ['نوع', 'وضعیت', 'تاریخ / سررسید', 'جزئیات', 'مبلغ (${Fmt.unitLabel()})'],
        for (final r in lump)
          [
            'نقد',
            (r['paid'] as int? ?? 1) == 1 ? 'تسویه شده' : 'ثبت‌شده',
            jalaliDate(r['date'] as String),
            '${r['bank_name'] ?? '-'}',
            Fmt.money(r['amount'] as num, label: false),
          ],
        for (final r in credit)
          [
            'قسط',
            (r['paid'] as int) == 1 ? 'تسویه شده' : 'باقیمانده',
            jalaliDate(r['due_date'] as String),
            '-',
            Fmt.money(r['amount'] as num, label: false),
          ],
        for (final r in cheque)
          [
            'چک',
            (r['paid'] as int) == 1 ? 'تسویه شده' : 'باقیمانده',
            jalaliDate(r['due_date'] as String),
            '${r['bank_name'] ?? '-'} — ${r['cheque_no'] ?? '-'}',
            Fmt.money(r['amount'] as num, label: false),
          ],
      ];
    } else if (payType == 'staged' && stagedType == 'credit') {
      rows = [
        ['وضعیت', 'سررسید', directionLabels.toName, directionLabels.fromName, 'مبلغ (${Fmt.unitLabel()})'],
        for (final r in credit)
          [
            (r['paid'] as int) == 1 ? 'تسویه شده' : 'باقیمانده',
            jalaliDate(r['due_date'] as String),
            '${r['seller_name'] ?? r['receiver_name'] ?? '-'}',
            '${r['payer_name'] ?? '-'}',
            Fmt.money(r['amount'] as num, label: false),
          ],
      ];
    } else if (payType == 'staged' && stagedType == 'cheque') {
      rows = [
        ['وضعیت', 'بانک', 'شماره چک', 'سررسید', 'مبلغ (${Fmt.unitLabel()})'],
        for (final r in cheque)
          [
            (r['paid'] as int) == 1 ? 'تسویه شده' : 'باقیمانده',
            '${r['bank_name'] ?? '-'}',
            '${r['cheque_no'] ?? '-'}',
            jalaliDate(r['due_date'] as String),
            Fmt.money(r['amount'] as num, label: false),
          ],
      ];
    }

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        textDirection: pw.TextDirection.rtl,
        header: (ctx) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text(pdfText(title), style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          pw.Text(pdfText('تاریخ تهیه گزارش: ${jalaliDateFromDt(now)}'), style: const pw.TextStyle(fontSize: 9)),
          pw.Divider(),
        ]),
        footer: (ctx) => _brandFooter(),
        build: (ctx) => [
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.5), borderRadius: pw.BorderRadius.circular(6)),
            child: pw.Column(children: [
              _kv('کد پسته', pesteCode.isEmpty ? '-' : pesteCode, bold: true),
              _kv(totalLabel, Fmt.money(total), bold: true),
              _kv('تسویه شده', Fmt.money(settled)),
              _kv(remaining >= 0 ? 'باقیمانده' : 'اضافه‌پرداخت', Fmt.money(remaining.abs())),
            ]),
          ),
          pw.SizedBox(height: 16),
          if (rows.length > 1)
            pw.Table.fromTextArray(
              headers: rows.first.map(pdfText).toList(),
              data: rows.skip(1).map((r) => r.map(pdfText).toList()).toList(),
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10),
              cellStyle: const pw.TextStyle(fontSize: 9),
              cellAlignment: pw.Alignment.centerRight,
              headerAlignment: pw.Alignment.centerRight,
              border: pw.TableBorder.all(width: 0.4),
            )
          else
            pw.Text(pdfText('تراکنشی ثبت نشده است')),
        ],
      ),
    );

    final fname = 'ledger_${now.millisecondsSinceEpoch}.pdf';
    return _saveDoc(doc, fname);
  }

  /// گزارش کلی همه‌ی تراکنش‌های پرداخت یا دریافت در یک بازه‌ی زمانی
  /// PDF دفتر قرض و وام: خلاصهٔ مانده‌ها + جدول تراکنش‌ها + جدول سررسیدها
  static Future<File> buildLoanLedger({
    required String title,
    required String subtitle,
    required List<(String, String)> summary,
    required List<({String heading, List<List<String>> rows})> sections, // ردیف اول هر جدول = عنوان ستون‌ها
  }) async {
    await _ensureFonts();
    final doc = pw.Document(theme: _theme());
    final now = DateTime.now();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        textDirection: pw.TextDirection.rtl,
        header: (ctx) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text(pdfText(title), style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          if (subtitle.isNotEmpty) pw.Text(pdfText(subtitle), style: const pw.TextStyle(fontSize: 10)),
          pw.Text(pdfText('تاریخ تهیه گزارش: ${jalaliDateFromDt(now)}'), style: const pw.TextStyle(fontSize: 9)),
          pw.Divider(),
        ]),
        footer: (ctx) => _brandFooter(),
        build: (ctx) => [
          for (final s in summary) _kv(s.$1, s.$2, bold: true),
          pw.SizedBox(height: 4),
          pw.Text(pdfText('این مبالغ در سود و زیان حساب نمی‌شوند.'), style: const pw.TextStyle(fontSize: 9)),
          for (final sec in sections) ...[
            pw.SizedBox(height: 14),
            pw.Text(pdfText(sec.heading), style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 6),
            if (sec.rows.length > 1)
              pw.Table.fromTextArray(
                headers: sec.rows.first.map(pdfText).toList(),
                data: sec.rows.skip(1).map((r) => r.map(pdfText).toList()).toList(),
                headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
                cellStyle: const pw.TextStyle(fontSize: 8.5),
                cellAlignment: pw.Alignment.centerRight,
                headerAlignment: pw.Alignment.centerRight,
                border: pw.TableBorder.all(width: 0.4),
              )
            else
              pw.Text(pdfText('موردی ثبت نشده است')),
          ],
        ],
      ),
    );
    final File xf = await _saveDoc(doc, 'loan_ledger_${now.millisecondsSinceEpoch}.pdf');
    ExcelIo.register(xf.path, title, <List<String>>[for (final (String, String) k in summary) <String>[k.$1, k.$2], for (final sec in sections) ...<List<String>>[<String>[sec.heading], ...sec.rows, <String>[]]]);
    return xf;
  }

  /// T03.2 — صورت‌حساب طرف‌حساب. ردیف اول rows = عنوان ستون‌ها.
  static Future<File> buildPartyStatement({
    required String party,
    required String period,
    required List<(String, String)> summary,
    required List<List<String>> rows,
  }) async {
    await _ensureFonts();
    final doc = pw.Document(theme: _theme());
    final now = DateTime.now();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        textDirection: pw.TextDirection.rtl,
        header: (ctx) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text(pdfText('صورت‌حساب: $party'), style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          pw.Text(pdfText(period), style: const pw.TextStyle(fontSize: 10)),
          pw.Text(pdfText('تاریخ تهیه گزارش: ${jalaliDateFromDt(now)}'), style: const pw.TextStyle(fontSize: 9)),
          pw.Divider(),
        ]),
        footer: (ctx) => _brandFooter(),
        build: (ctx) => [
          for (final s in summary) _kv(s.$1, s.$2, bold: true),
          pw.SizedBox(height: 8),
          if (rows.length > 1)
            pw.Table.fromTextArray(
              headers: rows.first.map(pdfText).toList(),
              data: rows.skip(1).map((r) => r.map(pdfText).toList()).toList(),
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
              cellStyle: const pw.TextStyle(fontSize: 8.5),
              cellAlignment: pw.Alignment.centerRight,
              headerAlignment: pw.Alignment.centerRight,
              border: pw.TableBorder.all(width: 0.4),
            )
          else
            pw.Text(pdfText('تراکنشی در این بازه ثبت نشده است')),
        ],
      ),
    );
    final File xf = await _saveDoc(doc, 'party_statement_${now.millisecondsSinceEpoch}.pdf');
    ExcelIo.register(xf.path, 'صورت‌حساب', <List<String>>[<String>['طرف حساب', party], <String>['دوره', period], for (final (String, String) k in summary) <String>[k.$1, k.$2], <String>[], ...rows]);
    return xf;
  }

  static Future<File> buildGlobalReport({
    required String title,
    required String periodLabel,
    required double grandTotal,
    required List<List<String>> tableRows, // ردیف اول = عنوان ستون‌ها
  }) async {
    await _ensureFonts();
    final doc = pw.Document(theme: _theme());
    final now = DateTime.now();

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        textDirection: pw.TextDirection.rtl,
        header: (ctx) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text(pdfText(title), style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          pw.Text(pdfText(periodLabel), style: const pw.TextStyle(fontSize: 10)),
          pw.Text(pdfText('تاریخ تهیه گزارش: ${jalaliDateFromDt(now)}'), style: const pw.TextStyle(fontSize: 9)),
          pw.Divider(),
        ]),
        footer: (ctx) => _brandFooter(),
        build: (ctx) => [
          _kv('جمع کل', Fmt.money(grandTotal), bold: true),
          pw.SizedBox(height: 12),
          if (tableRows.length > 1)
            pw.Table.fromTextArray(
              headers: tableRows.first.map(pdfText).toList(),
              data: tableRows.skip(1).map((r) => r.map(pdfText).toList()).toList(),
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
              cellStyle: const pw.TextStyle(fontSize: 8),
              cellAlignment: pw.Alignment.centerRight,
              headerAlignment: pw.Alignment.centerRight,
              border: pw.TableBorder.all(width: 0.4),
            )
          else
            pw.Text(pdfText('در این بازه تراکنشی یافت نشد')),
        ],
      ),
    );

    final fname = 'report_${now.millisecondsSinceEpoch}.pdf';
    final File xf = await _saveDoc(doc, fname);
    ExcelIo.register(xf.path, title, tableRows);
    return xf;
  }

  /// گزارش جدولی انبار (T01.5: گردش / موجودی / ترکیب). [summary] = فهرست [برچسب, مقدار]؛ [tableRows] ردیف اول = عنوان ستون‌ها.
  static Future<File> buildStockReport({
    required String title,
    required String periodLabel,
    required List<List<String>> summary,
    required List<List<String>> tableRows,
  }) async {
    await _ensureFonts();
    final doc = pw.Document(theme: _theme());
    final now = DateTime.now();

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        textDirection: pw.TextDirection.rtl,
        header: (ctx) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text(pdfText(title), style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          pw.Text(pdfText(periodLabel), style: const pw.TextStyle(fontSize: 10)),
          pw.Text(pdfText('تاریخ تهیه گزارش: ${jalaliDateFromDt(now)}'), style: const pw.TextStyle(fontSize: 9)),
          pw.Divider(),
        ]),
        footer: (ctx) => _brandFooter(),
        build: (ctx) => [
          for (final List<String> s in summary) _kv(s[0], s[1], bold: true),
          pw.SizedBox(height: 12),
          if (tableRows.length > 1)
            pw.Table.fromTextArray(
              headers: tableRows.first.map(pdfText).toList(),
              data: tableRows.skip(1).map((r) => r.map(pdfText).toList()).toList(),
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
              cellStyle: const pw.TextStyle(fontSize: 8),
              cellAlignment: pw.Alignment.centerRight,
              headerAlignment: pw.Alignment.centerRight,
              border: pw.TableBorder.all(width: 0.4),
            )
          else
            pw.Text(pdfText('داده‌ای برای این گزارش یافت نشد')),
        ],
      ),
    );

    final fname = 'stock_report_${now.millisecondsSinceEpoch}.pdf';
    final File xf = await _saveDoc(doc, fname);
    ExcelIo.register(xf.path, title, <List<String>>[...summary, <String>[], ...tableRows]);
    return xf;
  }

  /// فاکتور خرید یا فروش (A4). [withUsd] = فاکتور «ریالی/ارزی» که فی و مبلغ دلاری و نرخ دلار را هم درج می‌کند.
  static Future<File> buildInvoice({
    required bool isSale,
    required bool withUsd,
    required String number,
    required String dateLabel,
    required String sellerName,
    required String buyerName,
    required String category,
    required String type,
    required String code,
    required double totalWeight,
    required double smallSacks,
    required double largeSacks,
    required double netWeight,
    required double unitPrice, // ریال به‌ازای هر کیلو
    required List<List<String>> specs, // [عنوان، مقدار]
    double? usdRate, // واحد ذخیره به‌ازای هر دلار (اسناد قدیمی)
    String? ccy, // S27c: کد ارز سند (null = سند قدیمی دلاری)
    String? ccySymbol,
    int ccyDec = 2,
    double? fxRate, // S27c: نرخ سند، ریال به‌ازای یک واحد ارز
    List<List<String>> weighRows = const <List<String>>[], // S35.T35.2b: [عنوان، مقدار] — خالی = بدون بلوک توزین
    double? paidAmount, // مبلغ پرداخت‌شده/دریافت‌شده (ریال)؛ null = بدون بخش پرداخت (مثلاً بار مخلوط)
    String? note,
  }) async {
    await _ensureFonts();
    final doc = pw.Document(theme: _theme());
    final now = DateTime.now();
    final amount = netWeight * unitPrice;
    // S27c: برای سند ارزی، نرخ سند (fxRate) و کد ارز؛ فی ذخیره‌شده در واحد ذخیرهٔ محلی است (kFxRialPerStoredUnit)
    final bool isCcy = ccy != null && ccy.isNotEmpty;
    final String cl = isCcy ? ((ccySymbol ?? '').isEmpty ? ccy : ccySymbol!) : 'دلار';
    final String rateLabel = isCcy ? 'نرخ سند (${Fmt.unitLabel()})' : 'نرخ دلار (${Fmt.unitLabel()})';
    final double? rateVal = isCcy ? fxRate : usdRate;
    String fmtFx(double v) => isCcy ? faCcy(cl, v, dec: ccyDec) : faUsd(v);
    final unitUsd = !withUsd
        ? null
        : isCcy
            ? ((fxRate != null && fxRate > 0) ? unitPrice * kFxRialPerStoredUnit / fxRate : null)
            : ((usdRate != null && usdRate > 0) ? unitPrice / usdRate : null);
    final amountUsd = unitUsd == null ? null : netWeight * unitUsd;

    final barcodes = printableCodesIn(code);

    // S12.T12.1: chosen template / company header. Legacy A4 layout below is kept when nothing is configured.
    final InvTemplate tpl = await InvoiceTemplates.chosen();
    final CompanyProfile? prof = await CompanyProfile.load();
    if (tpl != InvTemplate.a4 || prof != null) {
      final InvDoc d = InvDoc(
        title: isSale ? 'فاکتور فروش' : 'فاکتور خرید',
        fileTag: 'invoice_${number.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}',
        header: <List<String>>[
          <String>['شماره فاکتور', number],
          <String>['تاریخ', dateLabel],
          <String>['فروشنده', sellerName.isEmpty ? '-' : sellerName],
          <String>['خریدار', buyerName.isEmpty ? '-' : buyerName],
          if (withUsd && rateVal != null) <String>[rateLabel, Fmt.money(rateVal, label: false)],
        ],
        columns: <String>[
          'ردیف', 'دسته', 'نوع', 'کد پسته', 'وزن (خالص) کیلو', 'فی (${Fmt.unitLabel()})', 'مبلغ (${Fmt.unitLabel()})',
          if (withUsd) ...<String>['فی ($cl)', 'مبلغ ($cl)'],
        ],
        rows: <List<String>>[
          <String>[
            faNum(1, dec: 0), category, type, code, faNum(netWeight), Fmt.money(unitPrice, label: false), Fmt.money(amount, label: false),
            if (withUsd) ...<String>[
              unitUsd == null ? '-' : faNum(unitUsd, dec: isCcy ? ccyDec : 4),
              amountUsd == null ? '-' : faNum(amountUsd),
            ],
          ],
        ],
        blocks: <List<String>>[
          <String>['وزن کل (ناخالص - با گونی)', '${faNum(totalWeight)} کیلو'],
          <String>['گونی کوچک', faNum(smallSacks)],
          <String>['گونی بزرگ', faNum(largeSacks)],
          for (final List<String> w in weighRows) <String>[w[0], w[1]],
          <String>['وزن پسته (خالص)', '${faNum(netWeight)} کیلو'],
          for (final List<String> sp in specs) <String>[sp[0], sp[1]],
        ],
        totals: <List<String>>[
          <String>['جمع کل (${Fmt.unitLabel()})', Fmt.money(amount)],
          if (withUsd) <String>['جمع کل ($cl)', amountUsd == null ? '-' : fmtFx(amountUsd)],
          if (paidAmount != null) <String>['مبلغ پرداخت‌شده (${Fmt.unitLabel()})', Fmt.money(paidAmount)],
          if (paidAmount != null) <String>['مانده حساب (${Fmt.unitLabel()})', Fmt.money(amount - paidAmount)],
        ],
        barcodes: printableCodesIn(code),
        qrData: printableCodesIn(code).isEmpty ? null : lotQrPayload(printableCodesIn(code).first), // S31.T31.9
        note: note,
        signLabels: <String>['امضای فروشنده', 'امضای خریدار'],
      );
      return InvoiceTemplatesPdf.render(d, tpl, prof);
    }
    final headers = <String>[
      'ردیف', 'دسته', 'نوع', 'کد پسته', 'وزن (خالص) کیلو', 'فی (${Fmt.unitLabel()})', 'مبلغ (${Fmt.unitLabel()})',
      if (withUsd) ...['فی ($cl)', 'مبلغ ($cl)'],
    ];
    final row = <String>[
      faNum(1, dec: 0), category, type, code, faNum(netWeight), Fmt.money(unitPrice, label: false), Fmt.money(amount, label: false),
      if (withUsd) ...[unitUsd == null ? '-' : faNum(unitUsd, dec: isCcy ? ccyDec : 4), amountUsd == null ? '-' : faNum(amountUsd)],
    ];

    pw.Widget sign(String label) => pw.Expanded(
          child: pw.Container(
            height: 56,
            margin: const pw.EdgeInsets.symmetric(horizontal: 6),
            padding: const pw.EdgeInsets.all(6),
            decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.5), borderRadius: pw.BorderRadius.circular(4)),
            child: pw.Text(pdfText(label), style: const pw.TextStyle(fontSize: 9)),
          ),
        );

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        textDirection: pw.TextDirection.rtl,
        footer: (ctx) => _brandFooter(),
        build: (ctx) => [
          pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
            pw.Text(pdfText(isSale ? 'فاکتور فروش' : 'فاکتور خرید'),
                style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
            pw.Text(pdfText(withUsd ? 'نوع فاکتور: ریالی / ارزی' : 'نوع فاکتور: ریالی'),
                style: const pw.TextStyle(fontSize: 10)),
          ]),
          pw.Divider(),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.5), borderRadius: pw.BorderRadius.circular(6)),
            child: pw.Column(children: [
              _kv('شماره فاکتور', number, bold: true),
              _kv('تاریخ', dateLabel),
              _kv('فروشنده', sellerName.isEmpty ? '-' : sellerName),
              _kv('خریدار', buyerName.isEmpty ? '-' : buyerName),
              if (withUsd && rateVal != null) _kv(rateLabel, Fmt.money(rateVal, label: false)),
            ]),
          ),
          pw.SizedBox(height: 14),
          if (barcodes.isNotEmpty) ...[
            pw.Wrap(
              alignment: pw.WrapAlignment.center,
              spacing: 12,
              runSpacing: 6,
              children: [for (final c in barcodes) pdfBarcode(c, height: 34, width: 130)],
            ),
            pw.SizedBox(height: 10),
          ],
          pw.Table.fromTextArray(
            headers: headers.map(pdfText).toList(),
            data: [row.map(pdfText).toList()],
            headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
            cellStyle: const pw.TextStyle(fontSize: 9),
            cellAlignment: pw.Alignment.centerRight,
            headerAlignment: pw.Alignment.centerRight,
            border: pw.TableBorder.all(width: 0.4),
          ),
          pw.SizedBox(height: 12),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.5), borderRadius: pw.BorderRadius.circular(6)),
            child: pw.Column(children: [
              _kv('وزن کل (ناخالص - با گونی)', '${faNum(totalWeight)} کیلو'),
              _kv('گونی کوچک', faNum(smallSacks)),
              _kv('گونی بزرگ', faNum(largeSacks)),
              for (final List<String> w in weighRows) _kv(w[0], w[1]),
              _kv('وزن پسته (خالص)', '${faNum(netWeight)} کیلو'),
            ]),
          ),
          if (specs.isNotEmpty) ...[
            pw.SizedBox(height: 12),
            pw.Text(pdfText('مشخصات جنس'), style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11)),
            pw.SizedBox(height: 4),
            pw.Table.fromTextArray(
              headers: [pdfText('مشخصه'), pdfText('مقدار')],
              data: [for (final r in specs) [pdfText(r[0]), pdfText(r[1])]],
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
              cellStyle: const pw.TextStyle(fontSize: 9),
              cellAlignment: pw.Alignment.centerRight,
              headerAlignment: pw.Alignment.centerRight,
              border: pw.TableBorder.all(width: 0.4),
            ),
          ],
          pw.SizedBox(height: 14),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
                border: pw.Border.all(width: 1), borderRadius: pw.BorderRadius.circular(6)),
            child: pw.Column(children: [
              _kv('جمع کل (${Fmt.unitLabel()})', Fmt.money(amount), bold: true),
              if (withUsd) _kv('جمع کل ($cl)', amountUsd == null ? '-' : fmtFx(amountUsd), bold: true),
              if (paidAmount != null) ...[
                pw.Divider(),
                _kv('مبلغ پرداخت‌شده (${Fmt.unitLabel()})', Fmt.money(paidAmount)),
                _kv('مانده حساب (${Fmt.unitLabel()})', Fmt.money(amount - paidAmount), bold: true),
              ],
            ]),
          ),
          if (note != null && note.trim().isNotEmpty) ...[
            pw.SizedBox(height: 10),
            pw.Text(pdfText('توضیحات: $note'), style: const pw.TextStyle(fontSize: 9)),
          ],
          pw.SizedBox(height: 22),
          pw.Row(children: [sign('امضای فروشنده'), sign('امضای خریدار')]),
          pw.SizedBox(height: 8),
          pw.Text(pdfText('تاریخ صدور: ${jalaliDateFromDt(now)}'), style: const pw.TextStyle(fontSize: 8)),
        ],
      ),
    );

    final safe = number.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return _saveDoc(doc, 'invoice_${safe}_${now.millisecondsSinceEpoch}.pdf');
  }

  /// S04.T04.4: generic RTL document (pro-forma, return notes): title, key/value header, table, totals.
  static Future<File> buildDocument({
    required String title,
    required String fileTag,
    required List<List<String>> header, // [key, value]
    required List<String> columns,
    required List<List<String>> rows,
    required List<List<String>> totals, // [key, value]
    String? note,
    List<String> barcodes = const <String>[],
    String? qrData,
  }) async {
    // S12.T12.1: chosen template / company header (legacy A4 layout below when nothing is configured)
    final InvTemplate tpl = await InvoiceTemplates.chosen();
    final CompanyProfile? prof = await CompanyProfile.load();
    if (tpl != InvTemplate.a4 || prof != null) {
      final File tf = await InvoiceTemplatesPdf.render(
        InvDoc(
          title: title,
          fileTag: fileTag,
          header: header,
          columns: columns,
          rows: rows,
          totals: totals,
          note: note,
          barcodes: barcodes,
          qrData: qrData,
        ),
        tpl,
        prof,
      );
      ExcelIo.register(tf.path, title, <List<String>>[...header, <String>[], columns, ...rows, <String>[], ...totals]);
      return tf;
    }
    await _ensureFonts();
    final doc = pw.Document(theme: _theme());
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        textDirection: pw.TextDirection.rtl,
        footer: (ctx) => _brandFooter(),
        build: (ctx) => [
          pw.Text(pdfText(title), style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
          pw.Divider(),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.5), borderRadius: pw.BorderRadius.circular(6)),
            child: pw.Column(children: [for (final h in header) _kv(h[0], h[1])]),
          ),
          pw.SizedBox(height: 14),
          pw.Table.fromTextArray(
            headers: columns.map(pdfText).toList(),
            data: [for (final r in rows) r.map(pdfText).toList()],
            headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
            cellStyle: const pw.TextStyle(fontSize: 9),
            cellAlignment: pw.Alignment.centerRight,
            headerAlignment: pw.Alignment.centerRight,
            border: pw.TableBorder.all(width: 0.4),
          ),
          pw.SizedBox(height: 12),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.5), borderRadius: pw.BorderRadius.circular(6)),
            child: pw.Column(children: [for (final t in totals) _kv(t[0], t[1], bold: true)]),
          ),
          if (note != null && note.trim().isNotEmpty) ...[
            pw.SizedBox(height: 10),
            pw.Text(pdfText(note), style: const pw.TextStyle(fontSize: 9)),
          ],
        ],
      ),
    );
    final File xf = await _saveDoc(doc, '${fileTag}_${DateTime.now().millisecondsSinceEpoch}.pdf');
    ExcelIo.register(xf.path, title, <List<String>>[...header, <String>[], columns, ...rows, <String>[], ...totals]);
    return xf;
  }
}
