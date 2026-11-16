import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:excel/excel.dart';

import 'excel_io.dart';
import 'utils.dart';

// S13.T13.2a — client side of the import engine: kind schemas, template, xlsx/csv parsing,
// Persian header auto-match, per-row validation (preview). Server commit = T13.2b (import.commit).
// The server MUST validate again; nothing here is trusted.

const int kImportMaxRows = 5000;

enum ImpType { text, integer, decimal, enumeration, boolean }

class ImpField {
  final String key;
  final String label; // Persian header used in the template
  final List<String> aliases;
  final ImpType type;
  final bool required;
  final int max;
  final Map<String, String> enumMap; // Persian/English word -> stored value
  final String example;
  const ImpField(this.key, this.label,
      {this.aliases = const <String>[],
      this.type = ImpType.text,
      this.required = false,
      this.max = 200,
      this.enumMap = const <String, String>{},
      this.example = ''});
}

class ImpKind {
  final String id; // sent to the server as `kind`
  final String label;
  final List<ImpField> fields;
  final List<String> keyFields; // idempotency / duplicate key inside the file
  const ImpKind(this.id, this.label, this.fields, this.keyFields);
}

const Map<String, String> _kBool = <String, String>{
  'بله': '1', 'خیر': '0', 'فعال': '1', 'غیرفعال': '0', 'yes': '1', 'no': '0', '1': '1', '0': '0', 'true': '1', 'false': '0',
};

const List<ImpKind> kImportKinds = <ImpKind>[
  ImpKind('parties', 'طرف‌حساب‌ها (با مانده اول دوره)', <ImpField>[
    ImpField('name', 'نام', aliases: <String>['نام طرف حساب', 'نام و نام خانوادگی', 'مشتری'], required: true, max: 100, example: 'علی رضایی'),
    ImpField('phone', 'تلفن', aliases: <String>['موبایل', 'شماره تماس', 'همراه'], max: 30, example: '09120000000'),
    ImpField('address', 'نشانی', aliases: <String>['آدرس'], max: 300),
    ImpField('national_id', 'کد ملی', aliases: <String>['شناسه ملی'], max: 20),
    ImpField('opening_balance', 'مانده اول دوره', aliases: <String>['مانده', 'مانده اول'], type: ImpType.decimal, example: '0'),
    ImpField('opening_side', 'وضعیت مانده', aliases: <String>['بدهکار/بستانکار', 'ماهیت'], type: ImpType.enumeration,
        enumMap: <String, String>{'بدهکار': 'debtor', 'بستانکار': 'creditor', 'debtor': 'debtor', 'creditor': 'creditor'}, example: 'بدهکار'),
    ImpField('note', 'توضیح', aliases: <String>['یادداشت'], max: 500),
  ], <String>['name']),
  ImpKind('opening_stock', 'موجودی اول دوره (لات‌ها)', <ImpField>[
    ImpField('code', 'کد لات', aliases: <String>['کد', 'کد پسته'], required: true, max: 40, example: 'L-001'),
    ImpField('category', 'دسته', aliases: <String>['گروه', 'دسته‌بندی'], required: true, max: 100, example: 'پسته خشک'),
    ImpField('type', 'نوع', aliases: <String>['نوع پسته', 'رقم'], required: true, max: 100, example: 'اکبری'),
    ImpField('weight', 'وزن (کیلو)', aliases: <String>['وزن', 'مقدار'], type: ImpType.decimal, required: true, example: '100'),
    ImpField('price', 'فی خرید', aliases: <String>['قیمت', 'فی', 'قیمت هر کیلو'], type: ImpType.decimal, required: true, example: '1000000'),
    ImpField('ounce', 'اونس', aliases: <String>['درجه'], max: 40),
    ImpField('warehouse', 'انبار', aliases: <String>['نام انبار'], max: 100),
  ], <String>['code']),
  ImpKind('categories_types', 'دسته‌ها و انواع پسته', <ImpField>[
    ImpField('category', 'دسته', aliases: <String>['گروه'], required: true, max: 100, example: 'پسته خشک'),
    ImpField('type', 'نوع', aliases: <String>['نوع پسته', 'رقم'], required: true, max: 100, example: 'اکبری'),
  ], <String>['category', 'type']),
  ImpKind('ounces', 'درجه‌بندی اونس', <ImpField>[
    ImpField('code', 'کد', aliases: <String>['درجه', 'اونس'], required: true, max: 40, example: '28-30'),
    ImpField('from_val', 'از', aliases: <String>['حداقل'], type: ImpType.decimal, example: '28'),
    ImpField('to_val', 'تا', aliases: <String>['حداکثر'], type: ImpType.decimal, example: '30'),
    ImpField('note', 'توضیح', aliases: <String>['یادداشت'], max: 250),
  ], <String>['code']),
  ImpKind('warehouses', 'انبارها', <ImpField>[
    ImpField('name', 'نام انبار', aliases: <String>['نام', 'انبار'], required: true, max: 100, example: 'انبار مرکزی'),
    ImpField('type', 'نوع', type: ImpType.enumeration,
        enumMap: <String, String>{
          'اصلی': 'main', 'امانی': 'consignment', 'فرآوری': 'processing', 'مجازی': 'virtual',
          'main': 'main', 'consignment': 'consignment', 'processing': 'processing', 'virtual': 'virtual',
        },
        example: 'اصلی'),
    ImpField('address', 'نشانی', aliases: <String>['آدرس'], max: 250),
    ImpField('active', 'فعال', type: ImpType.boolean, enumMap: _kBool, example: 'بله'),
  ], <String>['name']),
  // S35.T35.4b — daily price table (date: Jalali 1405/08/07 or 2026-10-29; grade: name from the grade list, empty = all grades)
  ImpKind('grade_prices', 'قیمت روز (جدول قیمت)', <ImpField>[
    ImpField('type', 'نوع', aliases: <String>['نوع پسته', 'رقم'], required: true, max: 100, example: 'اکبری'),
    ImpField('grade', 'درجه', aliases: <String>['کیفیت'], max: 40, example: 'خندان'),
    ImpField('price', 'قیمت هر کیلو', aliases: <String>['قیمت', 'فی'], type: ImpType.decimal, required: true, example: '1000000'),
    ImpField('date', 'تاریخ', aliases: <String>['تاریخ قیمت'], required: true, max: 30, example: '1405/08/07'),
  ], <String>['type', 'grade', 'date']),
  // S31.T31.16 — daily currency rates (FX plan only; date: Jalali 1405/08/07 or 2026-10-29; one rate per currency per day)
  ImpKind('fx_rates', 'نرخ روزانهٔ ارز (پلن ارزی)', <ImpField>[
    ImpField('ccy', 'کد ارز', aliases: <String>['ارز', 'واحد پول'], required: true, max: 8, example: 'USD'),
    ImpField('date', 'تاریخ', aliases: <String>['تاریخ نرخ'], required: true, max: 30, example: '1405/08/07'),
    ImpField('rate', 'نرخ', aliases: <String>['نرخ تبدیل', 'قیمت'], type: ImpType.decimal, required: true, example: '1000000'),
    ImpField('source', 'منبع', aliases: <String>['مرجع'], max: 60, example: 'صرافی'),
  ], <String>['ccy', 'date']),
  // S15.T15.2b — chart of accounts (gold only; parents first, `parent_code` for level 2/3)
  ImpKind('accounts', 'سرفصل حساب‌ها (طلایی)', <ImpField>[
    ImpField('code', 'کد حساب', aliases: <String>['کد'], required: true, max: 20, example: '1101'),
    ImpField('name', 'نام حساب', aliases: <String>['نام', 'عنوان'], required: true, max: 150, example: 'صندوق'),
    ImpField('level', 'سطح', aliases: <String>['سطح حساب'], type: ImpType.decimal, required: true, example: '2'),
    ImpField('parent_code', 'کد والد', aliases: <String>['حساب والد', 'والد'], max: 20, example: '11'),
    ImpField('type', 'نوع', aliases: <String>['نوع حساب'], type: ImpType.enumeration, required: true,
        enumMap: <String, String>{
          'دارایی': 'asset', 'بدهی': 'liability', 'سرمایه': 'equity', 'حقوق صاحبان سهام': 'equity', 'درآمد': 'revenue', 'هزینه': 'expense',
          'انتظامی': 'memo', 'asset': 'asset', 'liability': 'liability', 'equity': 'equity', 'revenue': 'revenue', 'expense': 'expense', 'memo': 'memo',
        },
        example: 'دارایی'),
    ImpField('nature', 'ماهیت', aliases: <String>['ماهیت حساب'], type: ImpType.enumeration,
        enumMap: <String, String>{'بدهکار': 'debit', 'بستانکار': 'credit', 'debit': 'debit', 'credit': 'credit'}, example: 'بدهکار'),
    ImpField('active', 'فعال', type: ImpType.boolean, enumMap: _kBool, example: 'بله'),
  ], <String>['code']),
];

class ImpSheet {
  final List<String> headers;
  final List<List<String>> rows;
  const ImpSheet(this.headers, this.rows);
}

class ImpRow {
  final int rowNo; // 1-based spreadsheet row (header = 1)
  final Map<String, dynamic> values;
  final List<String> errors;
  ImpRow(this.rowNo, this.values, this.errors);
  bool get ok => errors.isEmpty;
}

class ImportEngine {
  ImportEngine._();

  static String _norm(String s) => toEnDigits(s)
      .replaceAll('ي', 'ی')
      .replaceAll('ك', 'ک')
      .replaceAll('\u200c', ' ')
      .replaceAll('\u200f', '')
      .replaceAll('\u200e', '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .toLowerCase();

  /// Template xlsx with Persian headers + one example row.
  static Future<File> template(ImpKind k) => ExcelIo.exportTable(
        columns: <String>[for (final ImpField f in k.fields) f.label],
        rows: <List<String>>[
          <String>[for (final ImpField f in k.fields) f.example],
        ],
        sheetName: k.label,
        filePrefix: 'template_${k.id}',
      );

  /// Parses xlsx (first sheet) or csv by file name. Throws Exception with Persian text.
  static ImpSheet parse(String fileName, Uint8List bytes) {
    final String low = fileName.toLowerCase();
    List<List<String>> all;
    if (low.endsWith('.xlsx')) {
      final Excel ex = Excel.decodeBytes(bytes);
      if (ex.tables.isEmpty) throw Exception('فایل اکسل خالی است');
      final Sheet sh = ex.tables[ex.tables.keys.first]!;
      all = <List<String>>[];
      for (final List<Data?> r in sh.rows) {
        all.add(<String>[for (final Data? c in r) c?.value == null ? '' : c!.value.toString().trim()]);
      }
    } else if (low.endsWith('.csv')) {
      all = _csv(utf8.decode(bytes, allowMalformed: true));
    } else {
      throw Exception('فقط فایل xlsx یا csv پذیرفته می‌شود');
    }
    while (all.isNotEmpty && all.last.every((String c) => c.isEmpty)) {
      all.removeLast();
    }
    if (all.length < 2) throw Exception('فایل باید یک ردیف عنوان و حداقل یک ردیف داده داشته باشد');
    if (all.length - 1 > kImportMaxRows) throw Exception('حداکثر $kImportMaxRows ردیف در هر فایل مجاز است');
    return ImpSheet(all.first, all.sublist(1));
  }

  static List<List<String>> _csv(String text) {
    var t = text.startsWith('\uFEFF') ? text.substring(1) : text;
    final String first = t.split('\n').first;
    final String d = <String>[',', ';', '\t'].reduce((String a, String b) => first.split(a).length >= first.split(b).length ? a : b);
    final List<List<String>> out = <List<String>>[];
    List<String> row = <String>[];
    final StringBuffer cur = StringBuffer();
    bool q = false;
    for (int i = 0; i < t.length; i++) {
      final String c = t[i];
      if (q) {
        if (c == '"') {
          if (i + 1 < t.length && t[i + 1] == '"') {
            cur.write('"');
            i++;
          } else {
            q = false;
          }
        } else {
          cur.write(c);
        }
      } else if (c == '"') {
        q = true;
      } else if (c == d) {
        row.add(cur.toString().trim());
        cur.clear();
      } else if (c == '\n' || c == '\r') {
        if (c == '\r' && i + 1 < t.length && t[i + 1] == '\n') i++;
        row.add(cur.toString().trim());
        cur.clear();
        out.add(row);
        row = <String>[];
      } else {
        cur.write(c);
      }
    }
    if (cur.isNotEmpty || row.isNotEmpty) {
      row.add(cur.toString().trim());
      out.add(row);
    }
    return out;
  }

  /// field key -> column index (-1 = not matched). Matches label, aliases or key.
  static Map<String, int> autoMap(ImpKind k, List<String> headers) {
    final List<String> h = headers.map(_norm).toList();
    final Map<String, int> m = <String, int>{};
    final Set<int> used = <int>{};
    for (final ImpField f in k.fields) {
      int idx = -1;
      final List<String> names = <String>[f.label, f.key, ...f.aliases].map(_norm).toList();
      for (int i = 0; i < h.length && idx < 0; i++) {
        if (!used.contains(i) && names.contains(h[i])) idx = i;
      }
      if (idx >= 0) used.add(idx);
      m[f.key] = idx;
    }
    return m;
  }

  /// Validates every row (dry run on the client). Duplicate keys inside the file are errors.
  static List<ImpRow> validate(ImpKind k, ImpSheet s, Map<String, int> map) {
    final List<ImpRow> out = <ImpRow>[];
    final Map<String, int> seen = <String, int>{};
    for (int r = 0; r < s.rows.length; r++) {
      final List<String> src = s.rows[r];
      if (src.every((String c) => c.trim().isEmpty)) continue;
      final Map<String, dynamic> v = <String, dynamic>{};
      final List<String> err = <String>[];
      for (final ImpField f in k.fields) {
        final int ci = map[f.key] ?? -1;
        final String raw = (ci >= 0 && ci < src.length) ? src[ci].trim() : '';
        if (raw.isEmpty) {
          if (f.required) err.add('«${f.label}» الزامی است');
          continue;
        }
        switch (f.type) {
          case ImpType.text:
            if (raw.length > f.max) {
              err.add('«${f.label}» بیش از ${f.max} نویسه است');
            } else {
              v[f.key] = raw;
            }
          case ImpType.integer:
          case ImpType.decimal:
            final num? n = ExcelIo.parseCell(raw);
            if (n == null) {
              err.add('«${f.label}» عدد معتبر نیست');
            } else if (n < 0) {
              err.add('«${f.label}» نمی‌تواند منفی باشد');
            } else if (f.type == ImpType.integer && n is! int) {
              err.add('«${f.label}» باید عدد صحیح باشد');
            } else {
              v[f.key] = n;
            }
          case ImpType.enumeration:
          case ImpType.boolean:
            final String? e = f.enumMap[_norm(raw)] ?? f.enumMap[raw];
            if (e == null) {
              err.add('«${f.label}» مقدار نامعتبر است: $raw');
            } else {
              v[f.key] = f.type == ImpType.boolean ? e == '1' : e;
            }
        }
      }
      if (err.isEmpty && k.keyFields.every((String kf) => v[kf] != null)) {
        final String key = k.keyFields.map((String kf) => _norm('${v[kf]}')).join('|');
        final int? prev = seen[key];
        if (prev != null) {
          err.add('کلید تکراری در فایل (مثل ردیف $prev)');
        } else {
          seen[key] = r + 2;
        }
      }
      out.add(ImpRow(r + 2, v, err));
    }
    return out;
  }

  /// Payload for the server action import.commit (T13.2b).
  static Map<String, dynamic> payload(ImpKind k, List<ImpRow> rows, {required String batchId, bool dryRun = true, bool allOrNothing = true}) =>
      <String, dynamic>{
        'kind': k.id,
        'import_batch_id': batchId,
        'dry_run': dryRun,
        'all_or_nothing': allOrNothing,
        'rows': <Map<String, dynamic>>[for (final ImpRow r in rows) if (r.ok) <String, dynamic>{...r.values, '_row': r.rowNo}],
      };
}
