import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'entity_store.dart';

/// S12.T12.1 — company identity printed on invoices + document numbering + chosen PDF template.

/// Entities managed from the dedicated settings screen (hidden from the generic entity menu).
const Set<String> kHiddenEntityMenu = <String>{'company_profile', 'doc_sequences'};

/// Paper/layout templates for invoices and documents.
enum InvTemplate { a4, a5, roll80, roll58 }

const Map<InvTemplate, String> kInvTemplateLabels = <InvTemplate, String>{
  InvTemplate.a4: 'A4 (لیزری)',
  InvTemplate.a5: 'A5',
  InvTemplate.roll80: 'رول حرارتی ۸۰ میلی‌متر',
  InvTemplate.roll58: 'رول حرارتی ۵۸ میلی‌متر',
};

class CompanyProfile {
  final String name;
  final String logo; // data URL (data:image/...;base64,...) or ''
  final String address;
  final String phones;
  final String economicCode;
  final String nationalId;
  final String postalCode;
  final String registrationNo;
  final String footerText;

  const CompanyProfile({
    this.name = '',
    this.logo = '',
    this.address = '',
    this.phones = '',
    this.economicCode = '',
    this.nationalId = '',
    this.postalCode = '',
    this.registrationNo = '',
    this.footerText = '',
  });

  factory CompanyProfile.fromRow(Map<String, dynamic> m) {
    String s(String k) => (m[k] ?? '').toString().trim();
    return CompanyProfile(
      name: s('name'),
      logo: (m['logo'] ?? '').toString(),
      address: s('address'),
      phones: s('phones'),
      economicCode: s('economic_code'),
      nationalId: s('national_id'),
      postalCode: s('postal_code'),
      registrationNo: s('registration_no'),
      footerText: s('footer_text'),
    );
  }

  bool get isEmpty => name.isEmpty && logo.isEmpty && address.isEmpty && phones.isEmpty && footerText.isEmpty;

  /// Decoded logo bytes, or null when absent/invalid.
  Uint8List? get logoBytes {
    if (logo.isEmpty) return null;
    final int i = logo.indexOf('base64,');
    if (i < 0) return null;
    try {
      return base64Decode(logo.substring(i + 7));
    } catch (_) {
      return null;
    }
  }

  /// Identity lines for the header (only non-empty values).
  List<String> get infoLines {
    return <String>[
      if (address.isNotEmpty) address,
      if (phones.isNotEmpty) 'تلفن: $phones',
      if (economicCode.isNotEmpty) 'کد اقتصادی: $economicCode',
      if (nationalId.isNotEmpty) 'شناسه ملی: $nationalId',
      if (registrationNo.isNotEmpty) 'شمارهٔ ثبت: $registrationNo',
      if (postalCode.isNotEmpty) 'کد پستی: $postalCode',
    ];
  }

  /// The single profile row of this customer (null when never saved).
  static Future<Map<String, dynamic>?> row() async {
    try {
      final List<Map<String, dynamic>> l = await EntityStore.I.list('company_profile');
      return l.isEmpty ? null : l.last;
    } catch (_) {
      return null;
    }
  }

  static Future<CompanyProfile?> load() async {
    final Map<String, dynamic>? r = await row();
    if (r == null) return null;
    final CompanyProfile p = CompanyProfile.fromRow(r);
    return p.isEmpty ? null : p;
  }
}

class InvoiceTemplates {
  InvoiceTemplates._();
  static const String _kKey = 'pb_invoice_template';

  static Future<InvTemplate> chosen() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      final String? v = sp.getString(_kKey);
      for (final InvTemplate t in InvTemplate.values) {
        if (t.name == v) return t;
      }
    } catch (_) {}
    return InvTemplate.a4;
  }

  static Future<void> choose(InvTemplate t) async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    await sp.setString(_kKey, t.name);
  }
}

/// Document types that have number sequences (keys mirror server PB_DOC_TYPES).
const Map<String, String> kDocTypeLabels = <String, String>{
  'sale': 'فاکتور فروش',
  'purchase': 'فاکتور خرید',
  'sale_return': 'برگشت از فروش',
  'purchase_return': 'برگشت از خرید',
  'proforma': 'پیش‌فاکتور',
  'receipt': 'دریافت',
  'payment': 'پرداخت',
  'other': 'سایر',
};

/// Sequential document numbers per (doc type, fiscal year). Allocation is serialized inside the app
/// (no duplicates on one device). `fy` = 0 means one running counter (green tier / not per year).
class DocNumbering {
  DocNumbering._();
  static Future<void> _chain = Future<void>.value();

  static String format(String prefix, int n, int padding) => '$prefix${n.toString().padLeft(padding, '0')}';

  /// Returns the next number string for [docType] and advances the counter.
  static Future<String> next(String docType, {int fy = 0}) {
    final Completer<String> out = Completer<String>();
    _chain = _chain.then((_) async {
      try {
        final List<Map<String, dynamic>> all = await EntityStore.I.list('doc_sequences');
        Map<String, dynamic>? row;
        for (final Map<String, dynamic> r in all) {
          if (r['doc_type'] == docType && ((r['fy'] as num?)?.toInt() ?? 0) == fy) {
            row = r;
            break;
          }
        }
        final String prefix = (row?['prefix'] ?? '').toString();
        final int n = (row?['next_no'] as num?)?.toInt() ?? 1;
        final int pad = (row?['padding'] as num?)?.toInt() ?? 5;
        await EntityStore.I.save(
          'doc_sequences',
          <String, dynamic>{'doc_type': docType, 'fy': fy, 'prefix': prefix, 'next_no': n + 1, 'padding': pad},
          uid: row?['uid'] as String?,
        );
        out.complete(format(prefix, n, pad));
      } catch (e) {
        out.completeError(e);
      }
    });
    return out.future;
  }
}
