import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:sqflite/sqflite.dart' show DatabaseExecutor;

import 'db.dart' show AppDb;
import 'utils.dart' show jalaliDateFromDt, toEnDigits;

/// S35.T35.10 — universal formatter (single source of truth for money / weight / percent display).
/// Mirrors server/app/fmt.js and server/backend/api/pb_fmt.php (shared vectors: tests/fmt_vectors.json).
/// Storage unit = tenant money_unit ('rial'|'toman'); display unit = company setting display_unit.
/// The unit label is shown by default (never ambiguous). Nothing calls this yet (T35.11 adopts it) => no behavior change.
class Fmt {
  Fmt._();

  static String? _storedOverride; // tests only
  static String? _displayChoice; // company setting display_unit; null = same as stored unit (no change until chosen)
  static String digits = 'fa'; // 'fa' | 'en'

  /// Tenant storage unit: always follows the local mirror (AppDb.moneyUnit), so it can never disagree with the data.
  static String get storedUnit => _storedOverride ?? AppDb.I.moneyUnit;
  static String get displayUnit => _displayChoice ?? storedUnit;

  /// Loads display_unit / digits from the local meta table (called when the account DB opens and after settings refresh).
  static Future<void> loadFrom(DatabaseExecutor d) async {
    final List<Map<String, Object?>> r = await d.rawQuery("SELECT k, v FROM meta WHERE k IN ('fmt.display_unit','fmt.digits')");
    for (final Map<String, Object?> x in r) {
      if (x['k'] == 'fmt.display_unit') _displayChoice = x['v'] == 'rial' ? 'rial' : (x['v'] == 'toman' ? 'toman' : null);
      if (x['k'] == 'fmt.digits') digits = x['v'] == 'en' ? 'en' : 'fa';
    }
  }

  static void configure({String? stored, String? display, String? digitMode}) {
    if (stored != null) _storedOverride = stored == 'rial' ? 'rial' : 'toman';
    if (display != null) _displayChoice = display == 'rial' ? 'rial' : 'toman';
    if (digitMode != null) digits = digitMode == 'en' ? 'en' : 'fa';
  }

  static String unitLabel([String? u]) => (u ?? displayUnit) == 'rial' ? 'ریال' : 'تومان';

  static const String _fa = '۰۱۲۳۴۵۶۷۸۹';

  static String _localize(String s, String d) {
    if (d != 'fa') return s;
    final StringBuffer b = StringBuffer();
    for (final int c in s.runes) {
      if (c >= 0x30 && c <= 0x39) {
        b.write(_fa[c - 0x30]);
      } else if (c == 0x2C) {
        b.write('٬');
      } else if (c == 0x2E) {
        b.write('٫');
      } else {
        b.writeCharCode(c);
      }
    }
    return b.toString();
  }

  static String _group(String intStr) {
    final StringBuffer b = StringBuffer();
    for (int i = 0; i < intStr.length; i++) {
      if (i > 0 && (intStr.length - i) % 3 == 0) b.write(',');
      b.write(intStr[i]);
    }
    return b.toString();
  }

  /// Grouped number; [dec] = max decimals (trailing zeros trimmed).
  static String number(num v, {int dec = 0, String? digitMode}) {
    if (v.isNaN || v.isInfinite) return '';
    String s = v.abs().toStringAsFixed(dec);
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    }
    final List<String> p = s.split('.');
    String r = _group(p[0]) + (p.length > 1 ? '.${p[1]}' : '');
    if (v < 0 && RegExp(r'[1-9]').hasMatch(r)) r = '-$r';
    return _localize(r, digitMode ?? digits);
  }

  static int toDisplay(num stored, {String? from, String? to}) {
    final String su = from ?? storedUnit, du = to ?? displayUnit;
    if (su == du) return stored.round();
    return su == 'rial' ? (stored / 10).round() : (stored * 10).round(); // Dart round() = half away from zero
  }

  static int fromDisplay(num shown, {String? from, String? to}) {
    final String su = from ?? storedUnit, du = to ?? displayUnit;
    if (su == du) return shown.round();
    return su == 'rial' ? (shown * 10).round() : (shown / 10).round();
  }

  /// Money for display, e.g. «۱٬۲۳۴٬۵۶۷ ریال».
  static String money(num stored, {bool label = true, String? from, String? to, String? digitMode}) {
    final String du = to ?? displayUnit;
    final String s = number(toDisplay(stored, from: from, to: du), digitMode: digitMode);
    return label ? '$s ${unitLabel(du)}' : s;
  }

  static String kg(num v, {int dec = 3, bool label = true, String? digitMode}) {
    final String s = number(v, dec: dec, digitMode: digitMode);
    return label ? '$s کیلو' : s;
  }

  static String percent(num v, {int dec = 2, String? digitMode}) {
    final String d = digitMode ?? digits;
    return number(v, dec: dec, digitMode: d) + (d == 'fa' ? '٪' : '%');
  }

  /// Jalali date of a DateTime / ISO string; empty when unparsable.
  static String date(Object? v) {
    final DateTime? d = v is DateTime ? v : DateTime.tryParse((v ?? '').toString());
    return d == null ? '' : jalaliDateFromDt(d);
  }

  /// Typed text (any digits/separators) in DISPLAY unit -> stored amount; null when empty/invalid.
  static int? parseMoney(String? text, {String? from, String? to}) {
    final String t = toEnDigits((text ?? '').replaceAll('٬', ',').replaceAll('،', ',').replaceAll('٫', '.')).replaceAll(RegExp(r'[^0-9.\-]'), '');
    if (t.isEmpty || t == '-' || t == '.') return null;
    final double? n = double.tryParse(t);
    return n == null ? null : fromDisplay(n, from: from, to: to);
  }

  /// Live grouping used by [MoneyField] (en digits + ',' while typing).
  static String liveGroup(String text) {
    final String t = toEnDigits(text.replaceAll('٫', '.')).replaceAll(RegExp(r'[^0-9.]'), '');
    final int i = t.indexOf('.');
    String ip = i < 0 ? t : t.substring(0, i);
    final String dp = i < 0 ? '' : '.${t.substring(i + 1).replaceAll('.', '')}';
    ip = ip.replaceFirst(RegExp(r'^0+(?=\d)'), '');
    return _group(ip) + dp;
  }
}

class _MoneyInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final String f = Fmt.liveGroup(newValue.text);
    return TextEditingValue(text: f, selection: TextSelection.collapsed(offset: f.length));
  }
}

/// Money input: live thousand grouping, unit label always shown. The user types DISPLAY units;
/// [stored] gives the STORED amount (rial/toman per tenant) for saving. Nothing uses it yet (T35.11).
class MoneyField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool required;
  final VoidCallback? onChanged;
  final String? hint;

  const MoneyField({super.key, required this.controller, required this.label, this.required = false, this.onChanged, this.hint});

  /// Last stored value loaded into each controller by [setStored] (round-trip guard, see [stored]).
  static final Expando<num> _loaded = Expando<num>('moneyLoaded');

  static String _shown(num v) => Fmt.liveGroup(Fmt.toDisplay(v).toString());

  /// Stored amount of a controller filled by a MoneyField (null when empty).
  /// If the text is still exactly what [setStored] showed, the original stored value is returned,
  /// so opening and re-saving a document never shifts its amount by display-unit rounding.
  static int? stored(TextEditingController c) {
    final num? o = _loaded[c];
    if (o != null && c.text == _shown(o)) return o.round();
    return Fmt.parseMoney(c.text);
  }

  /// Fills [c] from a stored amount (display unit, grouped).
  /// New controller already holding [v] (stored amount), with the same round-trip guard as [setStored].
  static TextEditingController controllerFor(num? v) {
    final TextEditingController c = TextEditingController();
    setStored(c, v);
    return c;
  }

  static void setStored(TextEditingController c, num? v) {
    _loaded[c] = v;
    c.text = v == null ? '' : _shown(v);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: false),
        inputFormatters: <TextInputFormatter>[_MoneyInputFormatter()],
        decoration: InputDecoration(labelText: label, suffixText: Fmt.unitLabel(), hintText: hint, border: const OutlineInputBorder()),
        validator: required ? (String? v) => (Fmt.parseMoney(v) == null) ? 'مبلغ را وارد کنید' : null : null,
        onChanged: (_) => onChanged?.call(),
      ),
    );
  }
}
