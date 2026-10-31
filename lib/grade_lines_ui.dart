// S35.T35.3b — grade lines (separately priced sub-grades inside one purchase/sale). Server = source of truth (grade_lines.php);
// local mirror table doc_grade_lines + the company grade list (meta 'grades.list'). Active only when the «ردیف درجه‌ها» switch is on.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import 'db.dart';
import 'fmt.dart' show MoneyField;
import 'utils.dart';
import 'widgets.dart';

/// Default grade list (same as the server's PB_GRADES_DEFAULT).
const List<Map<String, String>> kDefaultGrades = <Map<String, String>>[
  <String, String>{'key': 'khandan', 'label': 'خندان'},
  <String, String>{'key': 'dombest', 'label': 'دنبست'},
  <String, String>{'key': 'dahan_basteh', 'label': 'دهان‌بسته'},
  <String, String>{'key': 'kalleh_ghouchi', 'label': 'کله‌قوچی'},
  <String, String>{'key': 'pook', 'label': 'پوک'},
];

class GradeLinesLocal {
  GradeLinesLocal._();

  static Future<void> createTables(DatabaseExecutor d) async {
    await d.execute('CREATE TABLE IF NOT EXISTS doc_grade_lines('
        'id INTEGER PRIMARY KEY, doc_type TEXT NOT NULL, doc_id INTEGER NOT NULL, grade_key TEXT NOT NULL, kg REAL NOT NULL, unit_price REAL NOT NULL)');
  }

  /// Company grade list [{key,label}] from the last server sync (defaults when unknown).
  static Future<List<Map<String, String>>> grades() async {
    final Database d = await AppDb.I.db;
    final List<Map<String, Object?>> r = await d.rawQuery("SELECT v FROM meta WHERE k='grades.list'");
    if (r.isEmpty) return kDefaultGrades;
    try {
      final dynamic j = jsonDecode('${r.first['v']}');
      if (j is List) {
        final List<Map<String, String>> o = <Map<String, String>>[
          for (final dynamic g in j)
            if (g is Map && g['key'] != null && g['label'] != null) <String, String>{'key': '${g['key']}', 'label': '${g['label']}'}
        ];
        if (o.isNotEmpty) return o;
      }
    } catch (_) {}
    return kDefaultGrades;
  }

  static Future<void> storeGrades(Object? list) async {
    if (list is! List || list.isEmpty) return;
    final Database d = await AppDb.I.db;
    await d.insert('meta', <String, Object?>{'k': 'grades.list', 'v': jsonEncode(list)}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Saved lines of a document: [{grade_key, kg, unit_price}].
  static Future<List<Map<String, dynamic>>> load(String docType, int docId) async {
    final Database d = await AppDb.I.db;
    final List<Map<String, Object?>> r = await d.query('doc_grade_lines', where: 'doc_type=? AND doc_id=?', whereArgs: <Object?>[docType, docId], orderBy: 'id DESC');
    return <Map<String, dynamic>>[for (final Map<String, Object?> x in r) Map<String, dynamic>.from(x)];
  }
}

class GradeRow {
  String? key;
  final TextEditingController kg = TextEditingController();
  final TextEditingController price = TextEditingController();
  void setPrice(num v) => MoneyField.setStored(price, v);
  void dispose() {
    kg.dispose();
    price.dispose();
  }
}

/// Holds the editable rows of one document form.
class GradeLinesController {
  final List<GradeRow> rows = <GradeRow>[];

  bool get hasRows => rows.isNotEmpty;
  double get sumKg => rows.fold(0.0, (double a, GradeRow r) => a + (parseNum(r.kg.text) ?? 0));
  double get total => rows.fold(0.0, (double a, GradeRow r) => a + ((parseNum(r.kg.text) ?? 0) * (MoneyField.stored(r.price) ?? 0)).roundToDouble());
  /// Weighted unit price Σ(kg×price) ÷ Σkg (0 when no weight).
  double get weightedPrice => sumKg <= 0 ? 0 : (total / sumKg).roundToDouble();

  void add() => rows.add(GradeRow());

  void loadFrom(List<Map<String, dynamic>> lines) {
    for (final GradeRow r in rows) {
      r.dispose();
    }
    rows.clear();
    for (final Map<String, dynamic> l in lines) {
      final GradeRow r = GradeRow()
        ..key = '${l['grade_key']}'
        ..kg.text = plain((l['kg'] as num))
        ..setPrice(l['unit_price'] as num);
      rows.add(r);
    }
  }

  List<Map<String, dynamic>> toPayload() => <Map<String, dynamic>>[
        for (final GradeRow r in rows)
          if (r.key != null) <String, dynamic>{'grade_key': r.key, 'kg': parseNum(r.kg.text) ?? 0, 'unit_price': MoneyField.stored(r.price) ?? 0}
      ];

  /// null = OK; otherwise a Persian message. [netKg] = document net weight.
  String? validate(double netKg) {
    if (rows.isEmpty) return null;
    final Set<String> seen = <String>{};
    for (final GradeRow r in rows) {
      if (r.key == null) return 'درجهٔ همهٔ ردیف‌ها را انتخاب کنید';
      if (!seen.add(r.key!)) return 'یک درجه فقط یک‌بار می‌تواند بیاید';
      if ((parseNum(r.kg.text) ?? 0) <= 0) return 'وزن هر درجه باید بیشتر از صفر باشد';
    }
    if ((sumKg - netKg).abs() > 0.001) return 'مجموع وزن درجه‌ها (${faNum(sumKg)}) باید با وزن خالص (${faNum(netKg)}) برابر باشد';
    return null;
  }

  void dispose() {
    for (final GradeRow r in rows) {
      r.dispose();
    }
  }
}

class GradeLinesEditor extends StatefulWidget {
  final GradeLinesController c;
  final double netKg;
  final VoidCallback onChanged;
  const GradeLinesEditor({super.key, required this.c, required this.netKg, required this.onChanged});

  @override
  State<GradeLinesEditor> createState() => _GradeLinesEditorState();
}

class _GradeLinesEditorState extends State<GradeLinesEditor> {
  List<Map<String, String>> _grades = kDefaultGrades;

  @override
  void initState() {
    super.initState();
    GradeLinesLocal.grades().then((List<Map<String, String>> g) {
      if (mounted) setState(() => _grades = g);
    });
  }

  void _chg() {
    setState(() {});
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final GradeLinesController c = widget.c;
    final String? err = c.validate(widget.netKg);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
      sectionTitle(context, 'ردیف درجه‌ها'),
      const Padding(
        padding: EdgeInsets.only(bottom: 6),
        child: Text('برای هر درجه وزن و فی جدا وارد کنید؛ فی سند میانگین وزنی می‌شود. اگر ردیفی نگذارید، فی یکسان برای کل سند است.',
            style: TextStyle(fontSize: 12, color: Colors.black54)),
      ),
      for (int i = 0; i < c.rows.length; i++)
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: DropdownButtonFormField<String>(
                value: _grades.any((Map<String, String> g) => g['key'] == c.rows[i].key) ? c.rows[i].key : null,
                decoration: const InputDecoration(labelText: 'درجه', border: OutlineInputBorder()),
                items: <DropdownMenuItem<String>>[
                  for (final Map<String, String> g in _grades) DropdownMenuItem<String>(value: g['key'], child: Text(g['label']!)),
                ],
                onChanged: (String? v) {
                  c.rows[i].key = v;
                  _chg();
                },
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(flex: 2, child: numField(c.rows[i].kg, 'کیلو', onChanged: _chg)),
          const SizedBox(width: 6),
          Expanded(flex: 3, child: MoneyField(controller: c.rows[i].price, label: 'فی', onChanged: _chg)),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
              c.rows[i].dispose();
              c.rows.removeAt(i);
              _chg();
            },
          ),
        ]),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () {
            c.add();
            _chg();
          },
          icon: const Icon(Icons.add),
          label: const Text('افزودن درجه'),
        ),
      ),
      if (c.hasRows) ...<Widget>[
        infoRow('مجموع وزن درجه‌ها', '${faNum(c.sumKg)} کیلو', valueColor: err != null ? Theme.of(context).colorScheme.error : null),
        infoRow('فی میانگین وزنی', '${faNum(c.weightedPrice, dec: 0)}'),
        if (err != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(err, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12))),
      ],
    ]);
  }
}

/// S35.T35.3c: per-grade cost block for lot details (kg, share of net, unit price, total). Empty when the lot has no grade lines.
class GradeCostRows extends StatelessWidget {
  final String docType;
  final int docId;
  const GradeCostRows({super.key, required this.docType, required this.docId});

  Future<List<Map<String, dynamic>>> _load() async {
    final List<Map<String, dynamic>> lines = await GradeLinesLocal.load(docType, docId);
    if (lines.isEmpty) return <Map<String, dynamic>>[];
    final Map<String, String> lab = <String, String>{for (final Map<String, String> g in await GradeLinesLocal.grades()) g['key']!: g['label']!};
    double sumKg = 0;
    for (final Map<String, dynamic> l in lines) {
      sumKg += (l['kg'] as num).toDouble();
    }
    return <Map<String, dynamic>>[
      for (final Map<String, dynamic> l in lines.reversed)
        <String, dynamic>{
          'label': lab['${l['grade_key']}'] ?? '${l['grade_key']}',
          'kg': (l['kg'] as num).toDouble(),
          'price': (l['unit_price'] as num).toDouble(),
          'pct': sumKg > 0 ? (l['kg'] as num).toDouble() / sumKg * 100 : 0.0,
        },
    ];
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _load(),
      builder: (BuildContext c, AsyncSnapshot<List<Map<String, dynamic>>> snap) {
        final List<Map<String, dynamic>> rows = snap.data ?? <Map<String, dynamic>>[];
        if (rows.isEmpty) return const SizedBox.shrink();
        double total = 0;
        for (final Map<String, dynamic> r in rows) {
          total += (r['kg'] as double) * (r['price'] as double);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const SizedBox(height: 8),
            Text('هزینهٔ هر درجه', style: Theme.of(c).textTheme.titleSmall),
            for (final Map<String, dynamic> r in rows)
              infoRow(
                '${r['label']} (${faNum(r['pct'] as double, dec: 1)}٪)',
                '${faNum(r['kg'] as double)} کیلو × ${faNum(r['price'] as double, dec: 0)} = ${faNum((r['kg'] as double) * (r['price'] as double), dec: 0)}',
              ),
            infoRow('جمع درجه‌ها', faNum(total, dec: 0)),
          ],
        );
      },
    );
  }
}
