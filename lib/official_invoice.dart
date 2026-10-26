import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart' show FileSaveLocation, XTypeGroup, getSaveLocation;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart' as sp;

import 'company_profile.dart';
import 'db.dart';
import 'excel_io.dart';
import 'pdf_output.dart';
import 'pdf_service.dart';
import 'utils.dart';
import 'widgets.dart';

/// S17.T17.3 — official (tax) sale invoice: validation, A4 PDF, JSON/Excel export with Moadian-style field names.
/// No live API (DECISIONS Q9). Amounts: stored value × [kRialFactor] (DECISIONS Q1: official outputs in rial).
/// The unique tax invoice ID (شماره مالیاتی / irtaxid) is a PLACEHOLDER: the tax memory ID + Verhoeff check digit
/// are issued by the tax authority flow and are intentionally not generated here.
const int kRialFactor = 10;

class InvIssue {
  const InvIssue(this.error, this.text);
  final bool error; // true = blocks issuing, false = warning
  final String text;
}

class OfficialLine {
  OfficialLine(this.desc, this.qty, this.fee, this.discount, this.rate, this.status);
  final String desc;
  final double qty; // kg
  final int fee; // rial per kg
  final int discount; // rial
  final int rate; // milli-percent (9% = 9000)
  final String status; // taxable|exempt|zero|''
  int get amount => (qty * fee).round();
  int get net => amount - discount;
  int get tax => status == 'taxable' ? (net * rate / 100000).round() : 0;
}

class OfficialInvoice {
  OfficialInvoice({
    required this.number,
    required this.dateIso,
    required this.seller,
    required this.buyerName,
    required this.buyerNationalId,
    required this.buyerEconomicCode,
    required this.buyerPostal,
    required this.buyerAddress,
    required this.lines,
    required this.paymentMethod,
    required this.taxId,
  });

  final String number;
  final String dateIso;
  final CompanyProfile? seller;
  final String buyerName;
  final String buyerNationalId;
  final String buyerEconomicCode;
  final String buyerPostal;
  final String buyerAddress;
  final List<OfficialLine> lines;
  final String paymentMethod;
  final String taxId; // placeholder (empty until issued by the tax flow)

  int get total => lines.fold<int>(0, (int a, OfficialLine l) => a + l.amount);
  int get totalDiscount => lines.fold<int>(0, (int a, OfficialLine l) => a + l.discount);
  int get totalTax => lines.fold<int>(0, (int a, OfficialLine l) => a + l.tax);
  int get totalNet => total - totalDiscount;
  int get grand => totalNet + totalTax;

  static String _s(dynamic v) => (v ?? '').toString().trim();
  static double _n(dynamic v) => v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0.0);

  /// [sale] = row from `AppDb.sales()` (with `items`), [party] = matching parties row (may be null).
  static OfficialInvoice fromSale(Map<String, dynamic> sale, CompanyProfile? seller, Map<String, dynamic>? party) {
    final String status = _s(sale['tax_status']);
    final int rate = _n(sale['tax_rate_milli']).round();
    final List<dynamic> items = (sale['items'] as List?) ?? <dynamic>[];
    final int saleDisc = (_n(sale['discount']) * kRialFactor).round();
    final List<OfficialLine> lines = <OfficialLine>[];
    int allocated = 0;
    final double sumAmt = items.fold<double>(0, (double a, dynamic it) => a + _n(it['weight']) * _n(it['item_price']));
    for (int i = 0; i < items.length; i++) {
      final dynamic it = items[i];
      final double w = _n(it['weight']);
      final double price = _n(it['item_price']) == 0 ? _n(sale['price']) : _n(it['item_price']);
      final int fee = (price * kRialFactor).round();
      int d;
      if (i == items.length - 1) {
        d = saleDisc - allocated;
      } else {
        d = sumAmt <= 0 ? 0 : (saleDisc * (w * _n(it['item_price'])) / sumAmt).round();
        allocated += d;
      }
      final String desc = 'پستهٔ ${_s(it['type_name']).isEmpty ? '' : _s(it['type_name'])} ${_s(it['code'])}'.trim();
      lines.add(OfficialLine(desc, w, fee, d < 0 ? 0 : d, rate, status));
    }
    final int id = (sale['id'] as num?)?.toInt() ?? 0;
    return OfficialInvoice(
      number: 'S${id.abs().toString().padLeft(5, '0')}',
      dateIso: _s(sale['date']),
      seller: seller,
      buyerName: _s(sale['buyer']),
      buyerNationalId: _s(party?['national_id']),
      buyerEconomicCode: _s(party?['economic_code']),
      buyerPostal: _s(party?['postal_code']),
      buyerAddress: _s(party?['address']),
      lines: lines,
      paymentMethod: _s(sale['payment_method']),
      taxId: _s(sale['tax_invoice_id']),
    );
  }

  /// Mandatory-data check run BEFORE issuing (Accept: missing data flagged).
  List<InvIssue> validate() {
    final List<InvIssue> o = <InvIssue>[];
    final CompanyProfile? s = seller;
    if (s == null || s.name.isEmpty) o.add(const InvIssue(true, 'نام فروشنده (مشخصات شرکت) ثبت نشده است'));
    if (s == null || s.economicCode.isEmpty) {
      o.add(const InvIssue(true, 'کد اقتصادی فروشنده ثبت نشده است'));
    } else if (!economicCodeValid(s.economicCode)) {
      o.add(const InvIssue(false, 'کد اقتصادی فروشنده باید ۱۲ یا ۱۴ رقم باشد'));
    }
    if (s == null || s.postalCode.isEmpty) {
      o.add(const InvIssue(false, 'کد پستی فروشنده ثبت نشده است'));
    } else if (!postalCodeValid(s.postalCode)) {
      o.add(const InvIssue(false, 'کد پستی فروشنده باید ۱۰ رقم باشد'));
    }
    if (buyerName.isEmpty) o.add(const InvIssue(true, 'نام خریدار ثبت نشده است'));
    final bool eco = buyerEconomicCode.isNotEmpty;
    final bool nid = buyerNationalId.isNotEmpty;
    if (!eco && !nid) {
      o.add(const InvIssue(true, 'شناسهٔ خریدار (کد اقتصادی یا کد/شناسه ملی) ثبت نشده است'));
    } else {
      if (eco && !economicCodeValid(buyerEconomicCode)) o.add(const InvIssue(true, 'کد اقتصادی خریدار نامعتبر است (۱۲ یا ۱۴ رقم)'));
      if (nid && !nationalIdValid(buyerNationalId) && !legalIdValid(buyerNationalId)) {
        o.add(const InvIssue(true, 'کد ملی/شناسه ملی خریدار نامعتبر است (رقم کنترلی)'));
      }
    }
    if (buyerPostal.isEmpty) {
      o.add(const InvIssue(false, 'کد پستی خریدار ثبت نشده است'));
    } else if (!postalCodeValid(buyerPostal)) {
      o.add(const InvIssue(false, 'کد پستی خریدار باید ۱۰ رقم باشد'));
    }
    if (lines.isEmpty) o.add(const InvIssue(true, 'فاکتور قلم ندارد'));
    if (lines.any((OfficialLine l) => l.status.isEmpty)) o.add(const InvIssue(false, 'وضعیت مالیاتی فروش مشخص نیست (مشمول/معاف/نرخ صفر)'));
    if (lines.any((OfficialLine l) => l.status == 'taxable' && l.rate <= 0)) o.add(const InvIssue(true, 'نرخ مالیات فروش مشمول ثبت نشده است'));
    if (paymentMethod.isEmpty) o.add(const InvIssue(false, 'روش پرداخت مشخص نیست'));
    return o;
  }

  bool get canIssue => !validate().any((InvIssue i) => i.error);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'invoice_no': number,
        'date': dateIso,
        'date_jalali': dateIso.isEmpty ? '' : jalaliDate(dateIso),
        'tax_invoice_id': taxId, // placeholder
        'seller': <String, dynamic>{
          'name': seller?.name ?? '',
          'economic_code': seller?.economicCode ?? '',
          'national_id': seller?.nationalId ?? '',
          'postal_code': seller?.postalCode ?? '',
          'address': seller?.address ?? '',
        },
        'buyer': <String, dynamic>{
          'name': buyerName,
          'economic_code': buyerEconomicCode,
          'national_id': buyerNationalId,
          'postal_code': buyerPostal,
          'address': buyerAddress,
        },
        'payment_method': paymentMethod,
        'unit': 'rial',
        'items': <Map<String, dynamic>>[
          for (final OfficialLine l in lines)
            <String, dynamic>{
              'description': l.desc,
              'qty_kg': l.qty,
              'unit_price': l.fee,
              'amount': l.amount,
              'discount': l.discount,
              'net': l.net,
              'tax_status': l.status,
              'vat_rate_milli': l.rate,
              'vat': l.tax,
              'total': l.net + l.tax,
              'item_id': '', // شناسهٔ کالا/خدمت (sstid) — to be filled from the official registry
            },
        ],
        'totals': <String, dynamic>{'amount': total, 'discount': totalDiscount, 'net': totalNet, 'vat': totalTax, 'grand_total': grand},
        // Moadian-style field names (tinb/bid/bpc confirmed by tax-authority error docs; the rest follow the public schema — verify before live use)
        'moadian': <String, dynamic>{
          'inno': number,
          'irtaxid': taxId,
          'tins': seller?.economicCode ?? '',
          'tinb': buyerEconomicCode,
          'bid': buyerNationalId,
          'bpc': buyerPostal,
          'tprdis': total,
          'tdis': totalDiscount,
          'tadis': totalNet,
          'tvam': totalTax,
          'tbill': grand,
          'setm': paymentMethod,
        },
      };

  // ---- identity validators ----
  static String _en(String s) {
    const String fa = '۰۱۲۳۴۵۶۷۸۹';
    const String ar = '٠١٢٣٤٥٦٧٨٩';
    final StringBuffer b = StringBuffer();
    for (final int c in s.runes) {
      final String ch = String.fromCharCode(c);
      final int i = fa.indexOf(ch) >= 0 ? fa.indexOf(ch) : ar.indexOf(ch);
      b.write(i >= 0 ? '$i' : ch);
    }
    return b.toString().trim();
  }

  static bool nationalIdValid(String raw) {
    final String s = _en(raw);
    if (!RegExp(r'^\d{10}$').hasMatch(s) || RegExp(r'^(\d)\1{9}$').hasMatch(s)) return false;
    int sum = 0;
    for (int i = 0; i < 9; i++) {
      sum += int.parse(s[i]) * (10 - i);
    }
    final int r = sum % 11;
    final int check = r < 2 ? r : 11 - r;
    return check == int.parse(s[9]);
  }

  static bool legalIdValid(String raw) {
    final String s = _en(raw);
    if (!RegExp(r'^\d{11}$').hasMatch(s)) return false;
    const List<int> coef = <int>[29, 27, 23, 19, 17, 29, 27, 23, 19, 17];
    final int d10 = int.parse(s[9]) + 2;
    int sum = 0;
    for (int i = 0; i < 10; i++) {
      sum += (int.parse(s[i]) + d10) * coef[i];
    }
    int r = sum % 11;
    if (r == 10) r = 0;
    return r == int.parse(s[10]);
  }

  static bool economicCodeValid(String raw) => RegExp(r'^(\d{12}|\d{14})$').hasMatch(_en(raw));
  static bool postalCodeValid(String raw) => RegExp(r'^\d{10}$').hasMatch(_en(raw));
}

// ---- amount in words (Persian) ----
const List<String> _ones = <String>['', 'یک', 'دو', 'سه', 'چهار', 'پنج', 'شش', 'هفت', 'هشت', 'نه', 'ده', 'یازده', 'دوازده', 'سیزده', 'چهارده', 'پانزده', 'شانزده', 'هفده', 'هجده', 'نوزده'];
const List<String> _tens = <String>['', '', 'بیست', 'سی', 'چهل', 'پنجاه', 'شصت', 'هفتاد', 'هشتاد', 'نود'];
const List<String> _hund = <String>['', 'صد', 'دویست', 'سیصد', 'چهارصد', 'پانصد', 'ششصد', 'هفتصد', 'هشتصد', 'نهصد'];
const List<String> _scales = <String>['', 'هزار', 'میلیون', 'میلیارد', 'هزار میلیارد'];

String _below1000(int n) {
  final List<String> parts = <String>[];
  if (n >= 100) parts.add(_hund[n ~/ 100]);
  final int r = n % 100;
  if (r >= 20) {
    parts.add(_tens[r ~/ 10]);
    if (r % 10 > 0) parts.add(_ones[r % 10]);
  } else if (r > 0) {
    parts.add(_ones[r]);
  }
  return parts.join(' و ');
}

String amountInWords(int n) {
  if (n == 0) return 'صفر';
  if (n < 0) return 'منفی ${amountInWords(-n)}';
  final List<String> groups = <String>[];
  int i = 0;
  int x = n;
  while (x > 0 && i < _scales.length) {
    final int g = x % 1000;
    if (g > 0) groups.insert(0, i == 0 ? _below1000(g) : '${_below1000(g)} ${_scales[i]}');
    x ~/= 1000;
    i++;
  }
  return groups.join(' و ');
}

String _m(num v) => faNum(v, dec: 0);

class OfficialInvoicePdf {
  OfficialInvoicePdf._();

  static pw.Widget _kv(String k, String v) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
        child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: <pw.Widget>[
          pw.Text(pdfText(k), style: const pw.TextStyle(fontSize: 9)),
          pw.Text(pdfText(v.isEmpty ? '-' : v), style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
        ]),
      );

  static pw.Widget _party(String title, List<List<String>> rows) => pw.Expanded(
        child: pw.Container(
          padding: const pw.EdgeInsets.all(6),
          decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.5)),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: <pw.Widget>[
            pw.Text(pdfText(title), style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
            pw.Divider(thickness: 0.4),
            for (final List<String> r in rows) _kv(r[0], r[1]),
          ]),
        ),
      );

  static Future<File> render(OfficialInvoice inv) async {
    await PdfService.ensureFonts();
    final pw.Document doc = pw.Document(theme: PdfService.theme());
    final CompanyProfile? s = inv.seller;
    final List<List<String>> rows = <List<String>>[];
    for (int i = 0; i < inv.lines.length; i++) {
      final OfficialLine l = inv.lines[i];
      rows.add(<String>[
        _m(i + 1), l.desc, faNum(l.qty, dec: 2), _m(l.fee), _m(l.amount), _m(l.discount), _m(l.net),
        l.status == 'taxable' ? _m(l.tax) : (l.status == 'zero' ? 'نرخ صفر' : 'معاف'), _m(l.net + l.tax),
      ]);
    }
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(24),
      textDirection: pw.TextDirection.rtl,
      build: (pw.Context ctx) => <pw.Widget>[
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: <pw.Widget>[
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: <pw.Widget>[
            _kv('شمارهٔ صورتحساب', inv.number),
            _kv('تاریخ', inv.dateIso.isEmpty ? '' : jalaliDate(inv.dateIso)),
            _kv('شناسهٔ یکتای مالیاتی', inv.taxId.isEmpty ? '(پس از صدور در سامانه)' : inv.taxId),
          ]),
          pw.Text(pdfText('صورتحساب فروش کالا و خدمات'), style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
        ]),
        pw.SizedBox(height: 8),
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: <pw.Widget>[
          _party('مشخصات فروشنده', <List<String>>[
            <String>['نام', s?.name ?? ''],
            <String>['کد اقتصادی', s?.economicCode ?? ''],
            <String>['شناسه ملی', s?.nationalId ?? ''],
            <String>['کد پستی', s?.postalCode ?? ''],
            <String>['نشانی', s?.address ?? ''],
          ]),
          pw.SizedBox(width: 8),
          _party('مشخصات خریدار', <List<String>>[
            <String>['نام', inv.buyerName],
            <String>['کد اقتصادی', inv.buyerEconomicCode],
            <String>['کد/شناسه ملی', inv.buyerNationalId],
            <String>['کد پستی', inv.buyerPostal],
            <String>['نشانی', inv.buyerAddress],
          ]),
        ]),
        pw.SizedBox(height: 8),
        pw.Table.fromTextArray(
          headers: <String>['ردیف', 'شرح کالا', 'مقدار (کیلوگرم)', 'فی (ریال)', 'مبلغ (ریال)', 'تخفیف (ریال)', 'مبلغ پس از تخفیف', 'مالیات (ریال)', 'جمع (ریال)'].map(pdfText).toList(),
          data: <List<String>>[for (final List<String> r in rows) r.map(pdfText).toList()],
          headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8),
          cellStyle: const pw.TextStyle(fontSize: 8),
          cellAlignment: pw.Alignment.centerRight,
          headerAlignment: pw.Alignment.centerRight,
          border: pw.TableBorder.all(width: 0.4),
        ),
        pw.SizedBox(height: 8),
        pw.Container(
          padding: const pw.EdgeInsets.all(6),
          decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.5)),
          child: pw.Column(children: <pw.Widget>[
            _kv('جمع مبلغ (ریال)', _m(inv.total)),
            _kv('جمع تخفیف (ریال)', _m(inv.totalDiscount)),
            _kv('مبلغ پس از تخفیف (ریال)', _m(inv.totalNet)),
            _kv('مالیات بر ارزش افزوده (ریال)', _m(inv.totalTax)),
            pw.Divider(thickness: 0.4),
            _kv('مبلغ قابل پرداخت (ریال)', _m(inv.grand)),
            pw.SizedBox(height: 3),
            pw.Text(pdfText('مبلغ به حروف: ${amountInWords(inv.grand)} ریال'), style: const pw.TextStyle(fontSize: 9)),
            pw.SizedBox(height: 3),
            pw.Text(pdfText('روش پرداخت: ${inv.paymentMethod.isEmpty ? '-' : inv.paymentMethod}'), style: const pw.TextStyle(fontSize: 9)),
          ]),
        ),
        pw.SizedBox(height: 24),
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceAround, children: <pw.Widget>[
          pw.Text(pdfText('مهر و امضای فروشنده'), style: const pw.TextStyle(fontSize: 9)),
          pw.Text(pdfText('امضای خریدار'), style: const pw.TextStyle(fontSize: 9)),
        ]),
        PdfService.brandFooter(),
      ],
    ));
    return PdfService.saveDocument(doc, 'official_${inv.number}_${DateTime.now().millisecondsSinceEpoch}.pdf');
  }
}

/// Export helpers (JSON + Excel) over a list of invoices.
class OfficialInvoiceExport {
  OfficialInvoiceExport._();

  static const List<String> columns = <String>[
    'شماره', 'تاریخ', 'شناسهٔ مالیاتی', 'کد اقتصادی فروشنده', 'خریدار', 'کد اقتصادی خریدار', 'کد/شناسه ملی خریدار', 'کد پستی خریدار',
    'جمع مبلغ', 'تخفیف', 'مبلغ پس از تخفیف', 'مالیات', 'مبلغ نهایی', 'روش پرداخت',
  ];

  static List<List<String>> rows(List<OfficialInvoice> list) => <List<String>>[
        for (final OfficialInvoice i in list)
          <String>[
            i.number, i.dateIso.isEmpty ? '' : jalaliDate(i.dateIso), i.taxId, i.seller?.economicCode ?? '', i.buyerName, i.buyerEconomicCode,
            i.buyerNationalId, i.buyerPostal, '${i.total}', '${i.totalDiscount}', '${i.totalNet}', '${i.totalTax}', '${i.grand}', i.paymentMethod,
          ],
      ];

  static Future<void> excel(BuildContext context, List<OfficialInvoice> list) async {
    try {
      final File f = await ExcelIo.exportTable(columns: columns, rows: rows(list), sheetName: 'Invoices', filePrefix: 'official_invoices');
      if (!context.mounted) return;
      await ExcelIo.saveOrShare(context, f);
    } catch (e) {
      if (context.mounted) snack(context, 'خروجی اکسل ناموفق بود: $e');
    }
  }

  static Future<void> json(BuildContext context, List<OfficialInvoice> list) async {
    try {
      final Directory dir = await getTemporaryDirectory();
      final File f = File(p.join(dir.path, 'official_invoices_${DateTime.now().millisecondsSinceEpoch}.json'));
      await f.writeAsString(const JsonEncoder.withIndent('  ').convert(<String, dynamic>{'invoices': list.map((OfficialInvoice i) => i.toJson()).toList()}));
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        final FileSaveLocation? loc = await getSaveLocation(suggestedName: p.basename(f.path), acceptedTypeGroups: <XTypeGroup>[const XTypeGroup(label: 'JSON', extensions: <String>['json'])]);
        if (loc == null) return;
        await f.copy(loc.path.toLowerCase().endsWith('.json') ? loc.path : '${loc.path}.json');
        if (context.mounted) snack(context, 'فایل JSON ذخیره شد');
        return;
      }
      await sp.Share.shareXFiles(<sp.XFile>[sp.XFile(f.path, mimeType: 'application/json')]);
    } catch (e) {
      if (context.mounted) snack(context, 'خروجی JSON ناموفق بود: $e');
    }
  }
}

/// List of sales → issue check, official PDF, JSON/Excel export of the listed invoices.
class OfficialInvoicesScreen extends StatefulWidget {
  const OfficialInvoicesScreen({super.key});
  @override
  State<OfficialInvoicesScreen> createState() => _OfficialInvoicesScreenState();
}

class _OfficialInvoicesScreenState extends State<OfficialInvoicesScreen> {
  bool _loading = true;
  String? _error;
  List<OfficialInvoice> _list = <OfficialInvoice>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final CompanyProfile? c = await CompanyProfile.load();
      final List<Map<String, dynamic>> sales = await AppDb.I.sales();
      final List<Map<String, dynamic>> parties = await AppDb.I.partyRecords();
      final Map<String, Map<String, dynamic>> byName = <String, Map<String, dynamic>>{
        for (final Map<String, dynamic> r in parties) '${r['name']}'.trim(): r,
      };
      final List<OfficialInvoice> out = <OfficialInvoice>[];
      for (final Map<String, dynamic> s in sales.take(200)) {
        out.add(OfficialInvoice.fromSale(s, c, byName['${s['buyer'] ?? ''}'.trim()]));
      }
      if (!mounted) return;
      setState(() {
        _list = out;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _pdf(OfficialInvoice inv) async {
    final List<InvIssue> issues = inv.validate();
    if (issues.any((InvIssue i) => i.error)) {
      await _showIssues(inv, issues, blocked: true);
      return;
    }
    if (issues.isNotEmpty) {
      final bool ok = await _showIssues(inv, issues, blocked: false);
      if (!ok) return;
    }
    try {
      final File f = await OfficialInvoicePdf.render(inv);
      if (!mounted) return;
      await PdfOutput.show(context, f);
    } catch (e) {
      if (mounted) snack(context, 'ساخت PDF ناموفق بود: $e');
    }
  }

  Future<bool> _showIssues(OfficialInvoice inv, List<InvIssue> issues, {required bool blocked}) async {
    final bool? r = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text(blocked ? 'صدور ممکن نیست — ${inv.number}' : 'هشدارها — ${inv.number}'),
          content: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              for (final InvIssue i in issues)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('${i.error ? '⛔' : '⚠️'} ${i.text}'),
                ),
            ]),
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(blocked ? 'بستن' : 'انصراف')),
            if (!blocked) FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('ادامه و ساخت PDF')),
          ],
        ),
      ),
    );
    return r == true;
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('فاکتور رسمی فروش'),
          actions: <Widget>[
            IconButton(tooltip: 'خروجی JSON', onPressed: _list.isEmpty ? null : () => OfficialInvoiceExport.json(context, _list.where((OfficialInvoice i) => i.canIssue).toList()), icon: const Icon(Icons.data_object)),
            IconButton(tooltip: 'خروجی اکسل', onPressed: _list.isEmpty ? null : () => OfficialInvoiceExport.excel(context, _list.where((OfficialInvoice i) => i.canIssue).toList()), icon: const Icon(Icons.table_chart_outlined)),
            IconButton(tooltip: 'تازه‌سازی', onPressed: _load, icon: const Icon(Icons.refresh)),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Text(_error!))
                : _list.isEmpty
                    ? const Center(child: Text('فروشی ثبت نشده است'))
                    : ListView.separated(
                        itemCount: _list.length,
                        separatorBuilder: (BuildContext c, int i) => const Divider(height: 1),
                        itemBuilder: (BuildContext c, int idx) {
                          final OfficialInvoice inv = _list[idx];
                          final List<InvIssue> issues = inv.validate();
                          final int errs = issues.where((InvIssue i) => i.error).length;
                          return ListTile(
                            title: Text('${inv.number} · ${inv.buyerName.isEmpty ? '-' : inv.buyerName}'),
                            subtitle: Text('${inv.dateIso.isEmpty ? '' : jalaliDate(inv.dateIso)} · ${_m(inv.grand)} ریال'),
                            leading: Icon(errs > 0 ? Icons.error_outline : (issues.isNotEmpty ? Icons.warning_amber : Icons.check_circle_outline),
                                color: errs > 0 ? Colors.red : (issues.isNotEmpty ? Colors.orange : Colors.green)),
                            trailing: IconButton(tooltip: 'PDF رسمی', onPressed: () => _pdf(inv), icon: const Icon(Icons.picture_as_pdf_outlined)),
                            onTap: issues.isEmpty ? null : () => _showIssues(inv, issues, blocked: errs > 0),
                          );
                        },
                      ),
      ),
    );
  }
}
