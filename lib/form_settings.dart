// S35.T35.1 — on/off switches of the professional purchase/sale form features («تنظیمات فرم‌ها»).
// Server = source of truth (server/backend/api/form_settings.php, app_settings k='form.<key>'); a local mirror table keeps the
// last known values for offline use. All features default OFF => forms/PDFs behave exactly as before until a switch is turned on.
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import 'db.dart';
import 'grade_lines_ui.dart' show GradeLinesLocal;
import 'price_table_ui.dart' show PriceTableLocal, PriceTableScreen;
import 'pay_terms_ui.dart' show PayRateCard; // S35.T35.7h-6
import 'warehouse_ui.dart' show StockApi, StockApiException;
import 'widgets.dart';

/// Feature keys (must match PB_FORM_FEATURES on the server).
const List<String> kFormFeatureKeys = <String>[
  'weigh', 'grades', 'price_table', 'fin_block', 'pay_terms', 'profit_hint', 'draft', 'confirm_summary',
];

class FormSettingsLocal {
  FormSettingsLocal._();

  static Future<void> createTables(DatabaseExecutor d) async {
    await d.execute('CREATE TABLE IF NOT EXISTS form_settings(k TEXT PRIMARY KEY, on_flag INTEGER NOT NULL DEFAULT 0)');
  }

  /// Local value of one switch (false when unknown).
  static Future<bool> isOn(String key) async {
    final Database d = await AppDb.I.db;
    final List<Map<String, Object?>> r = await d.rawQuery('SELECT on_flag FROM form_settings WHERE k = ?', <Object?>[key]);
    return r.isNotEmpty && r.first['on_flag'] == 1;
  }

  static Future<Map<String, bool>> all() async {
    final Database d = await AppDb.I.db;
    final List<Map<String, Object?>> r = await d.rawQuery('SELECT k, on_flag FROM form_settings');
    return <String, bool>{for (final Map<String, Object?> x in r) '${x['k']}': x['on_flag'] == 1};
  }

  /// S35.T35.2: company sack weights in kg (small, large) from the last server sync; defaults 0.1 / 0.2.
  static Future<List<double>> sackKg() async {
    final Database d = await AppDb.I.db;
    final List<Map<String, Object?>> r = await d.rawQuery("SELECT k, v FROM meta WHERE k IN ('weigh.sack_small_kg','weigh.sack_large_kg')");
    double small = 0.1, large = 0.2;
    for (final Map<String, Object?> x in r) {
      final double? v = double.tryParse('${x['v']}');
      if (v == null) continue;
      if (x['k'] == 'weigh.sack_small_kg') small = v;
      if (x['k'] == 'weigh.sack_large_kg') large = v;
    }
    return <double>[small, large];
  }

  static Future<void> _storeSack(Object? w) async {
    if (w is! Map) return;
    final Database d = await AppDb.I.db;
    for (final MapEntry<String, String> e in <String, String>{'small_kg': 'weigh.sack_small_kg', 'large_kg': 'weigh.sack_large_kg'}.entries) {
      final double? v = w[e.key] is num ? (w[e.key] as num).toDouble() : double.tryParse('${w[e.key]}');
      if (v != null) await d.insert('meta', <String, Object?>{'k': e.value, 'v': '$v'}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  /// Saves the sack weights on the server (requires settings.manage).
  static Future<void> saveSack(double small, double large) async {
    final Map<String, dynamic> r = await StockApi.call('form_settings.save', <String, dynamic>{'weigh': <String, dynamic>{'small_kg': small, 'large_kg': large}});
    await _storeSack(r['weigh']);
  }

  static Future<void> _store(List<Map<String, dynamic>> features) async {
    final Database d = await AppDb.I.db;
    await d.transaction((Transaction t) async {
      for (final Map<String, dynamic> f in features) {
        await t.insert('form_settings', <String, Object?>{'k': '${f['key']}', 'on_flag': f['on'] == true ? 1 : 0},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  static List<Map<String, dynamic>> _list(Object? v) =>
      v is List ? v.whereType<Map>().map((Map m) => Map<String, dynamic>.from(m)).toList() : <Map<String, dynamic>>[];

  /// Refreshes the mirror from the server. Returns the server rows (key, on, help) or null when offline.
  static Future<List<Map<String, dynamic>>?> refresh() async {
    try {
      final Map<String, dynamic> r = await StockApi.call('form_settings.get');
      final List<Map<String, dynamic>> f = _list(r['features']);
      if (f.isEmpty) return null;
      await _store(f);
      await _storeSack(r['weigh']);
      await GradeLinesLocal.storeGrades(r['grades']); // S35.T35.3b
      if (f.any((Map<String, dynamic> x) => x['key'] == 'price_table' && x['on'] == true)) await PriceTableLocal.refresh(); // S35.T35.4
      return f;
    } on StockApiException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Saves switches on the server (requires settings.manage) and mirrors the answer. Throws StockApiException on refusal.
  static Future<List<Map<String, dynamic>>> save(Map<String, bool> settings) async {
    final Map<String, dynamic> r = await StockApi.call('form_settings.save', <String, dynamic>{'settings': settings});
    final List<Map<String, dynamic>> f = _list(r['features']);
    await _store(f);
    return f;
  }
}

class FormSettingsScreen extends StatefulWidget {
  const FormSettingsScreen({super.key});

  @override
  State<FormSettingsScreen> createState() => _FormSettingsScreenState();
}

class _FormSettingsScreenState extends State<FormSettingsScreen> {
  List<Map<String, dynamic>> _rows = <Map<String, dynamic>>[];
  bool _loading = true;
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final List<Map<String, dynamic>>? f = await FormSettingsLocal.refresh();
    if (!mounted) return;
    setState(() {
      _offline = f == null;
      _rows = f ?? <Map<String, dynamic>>[];
      _loading = false;
    });
  }

  Future<void> _toggle(String key, bool on) async {
    try {
      final List<Map<String, dynamic>> f = await FormSettingsLocal.save(<String, bool>{key: on});
      if (mounted) setState(() => _rows = f);
    } on StockApiException catch (e) {
      if (mounted) snack(context, e.message);
    } catch (e) {
      if (mounted) snack(context, 'ذخیره نشد؛ اتصال اینترنت را بررسی کنید');
    }
  }

  /// S35.T35.2: dialog to edit the company's small/large sack weight (kg) used for the default tare.
  Future<void> _editSack() async {
    final List<double> k = await FormSettingsLocal.sackKg();
    final TextEditingController s = TextEditingController(text: '${k[0]}');
    final TextEditingController l = TextEditingController(text: '${k[1]}');
    if (!mounted) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        title: const Text('وزن گونی‌ها (کیلو)'),
        content: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          TextField(controller: s, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'گونی کوچک')),
          TextField(controller: l, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'گونی بزرگ')),
        ]),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('انصراف')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('ذخیره')),
        ],
      ),
    );
    if (ok != true) return;
    final double? sv = double.tryParse(s.text.trim().replaceAll(',', '.'));
    final double? lv = double.tryParse(l.text.trim().replaceAll(',', '.'));
    if (sv == null || lv == null) {
      if (mounted) snack(context, 'عدد نامعتبر است');
      return;
    }
    try {
      await FormSettingsLocal.saveSack(sv, lv);
      if (mounted) snack(context, 'ذخیره شد');
    } on StockApiException catch (e) {
      if (mounted) snack(context, e.message);
    } catch (_) {
      if (mounted) snack(context, 'ذخیره نشد؛ اتصال اینترنت را بررسی کنید');
    }
  }

  /// S35.T35.3b: edit the company grade list — one grade name per line; existing names keep their key, new names get a new key.
  Future<void> _editGrades() async {
    final List<Map<String, String>> cur = await GradeLinesLocal.grades();
    final TextEditingController t = TextEditingController(text: cur.map((Map<String, String> g) => g['label']).join('\n'));
    if (!mounted) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        title: const Text('فهرست درجه‌ها'),
        content: TextField(controller: t, maxLines: 8, decoration: const InputDecoration(helperText: 'هر درجه در یک خط')),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('انصراف')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('ذخیره')),
        ],
      ),
    );
    if (ok != true) return;
    final Map<String, String> keyOf = <String, String>{for (final Map<String, String> g in cur) g['label']!: g['key']!};
    final Set<String> used = <String>{};
    int n = 1;
    final List<Map<String, String>> out = <Map<String, String>>[];
    for (final String raw in t.text.split('\n')) {
      final String lb = raw.trim();
      if (lb.isEmpty) continue;
      String k = keyOf[lb] ?? '';
      if (k.isEmpty || used.contains(k)) {
        do {
          k = 'g_${n++}';
        } while (used.contains(k) || cur.any((Map<String, String> g) => g['key'] == k));
      }
      used.add(k);
      out.add(<String, String>{'key': k, 'label': lb});
    }
    if (out.isEmpty) {
      if (mounted) snack(context, 'حداقل یک درجه لازم است');
      return;
    }
    try {
      final Map<String, dynamic> r = await StockApi.call('form_settings.save', <String, dynamic>{'grades': out});
      await GradeLinesLocal.storeGrades(r['grades']);
      if (mounted) snack(context, 'ذخیره شد');
    } on StockApiException catch (e) {
      if (mounted) snack(context, e.message);
    } catch (_) {
      if (mounted) snack(context, 'ذخیره نشد؛ اتصال اینترنت را بررسی کنید');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('تنظیمات فرم‌ها')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _rows.isEmpty
              ? Center(child: Text(_offline ? 'برای تغییر تنظیمات به اینترنت نیاز است' : 'موردی نیست'))
              : ListView(children: <Widget>[
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('همهٔ امکانات پیش‌فرض خاموش‌اند؛ تا روشن نکنید فرم‌ها و چاپ‌ها دقیقاً مثل قبل کار می‌کنند.',
                        style: TextStyle(fontSize: 12, color: Colors.black54)),
                  ),
                  for (final Map<String, dynamic> r in _rows)
                    SwitchListTile(
                      value: r['on'] == true,
                      title: Text('${r['help']}'),
                      onChanged: (bool v) => _toggle('${r['key']}', v),
                    ),
                  if (_rows.any((Map<String, dynamic> r) => r['key'] == 'weigh' && r['on'] == true))
                    ListTile(title: const Text('وزن گونی‌ها (برای تارای پیش‌فرض)'), trailing: const Icon(Icons.edit), onTap: _editSack),
                  if (_rows.any((Map<String, dynamic> r) => r['key'] == 'grades' && r['on'] == true))
                    ListTile(title: const Text('فهرست درجه‌ها'), trailing: const Icon(Icons.edit), onTap: _editGrades),
                  if (_rows.any((Map<String, dynamic> r) => r['key'] == 'price_table' && r['on'] == true))
                    ListTile(
                        title: const Text('جدول قیمت روز'),
                        trailing: const Icon(Icons.chevron_left),
                        onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const PriceTableScreen()))),
                const Padding(padding: EdgeInsets.all(12), child: PayRateCard()), // S35.T35.7h-6: monthly discount rate (online)
                ]),
    );
  }
}
