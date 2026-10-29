// S35.T35.4 — optional daily price table («جدول قیمت روز») + «قیمت پیشنهادی روز» hint in purchase/sale forms.
// Server = source of truth (server/backend/api/grade_prices.php); rows are mirrored in meta k='grade_prices.rows' (JSON) for offline
// suggestions (no schema bump). Everything is inert unless the form.price_table switch is on. A suggestion is never forced.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import 'db.dart';
import 'form_settings.dart' show FormSettingsLocal;
import 'grade_lines_ui.dart' show GradeLinesLocal;
import 'import_screen.dart' show ImportScreen;
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;
import 'widgets.dart';

class PriceTableLocal {
  PriceTableLocal._();

  static const String _k = 'grade_prices.rows';

  static List<Map<String, dynamic>> _decode(String? s) {
    if (s == null || s.isEmpty) return <Map<String, dynamic>>[];
    try {
      final dynamic j = jsonDecode(s);
      if (j is List) return j.whereType<Map>().map((Map m) => Map<String, dynamic>.from(m)).toList();
    } catch (_) {}
    return <Map<String, dynamic>>[];
  }

  /// Local mirror rows (newest first), empty when never synced.
  static Future<List<Map<String, dynamic>>> rows() async {
    final Database d = await AppDb.I.db;
    final List<Map<String, Object?>> r = await d.rawQuery('SELECT v FROM meta WHERE k = ?', <Object?>[_k]);
    return r.isEmpty ? <Map<String, dynamic>>[] : _decode('${r.first['v']}');
  }

  /// Pulls the table from the server into the mirror. Returns rows, or null when offline / refused.
  static Future<List<Map<String, dynamic>>?> refresh() async {
    try {
      final Map<String, dynamic> r = await StockApi.call('grade_prices.list', <String, dynamic>{'limit': 2000});
      final List<Map<String, dynamic>> l = r['rows'] is List
          ? (r['rows'] as List).whereType<Map>().map((Map m) => Map<String, dynamic>.from(m)).toList()
          : <Map<String, dynamic>>[];
      final Database d = await AppDb.I.db;
      await d.insert('meta', <String, Object?>{'k': _k, 'v': jsonEncode(l)}, conflictAlgorithm: ConflictAlgorithm.replace);
      return l;
    } catch (_) {
      return null;
    }
  }

  /// Latest price on/before [dateIso] (yyyy-MM-dd) for the type; rows matching the ounce/grade beat generic rows, then the newest date.
  /// Null when the switch is off or nothing matches.
  static Future<Map<String, dynamic>?> suggest(String typeName, {String? ounceUid, String? gradeKey, String? dateIso}) async {
    if (typeName.trim().isEmpty || !await FormSettingsLocal.isOn('price_table')) return null;
    final String day = dateIso ?? DateTime.now().toIso8601String().substring(0, 10);
    Map<String, dynamic>? best;
    int bestSpec = -1;
    for (final Map<String, dynamic> r in await rows()) {
      if ('${r['type_name']}' != typeName.trim()) continue;
      final String pd = '${r['price_date']}';
      if (pd.compareTo(day) > 0) continue;
      final String? ou = r['ounce_uid'] as String?;
      final String? gk = r['grade_key'] as String?;
      if (ou != null && ou != ounceUid) continue;
      if (gk != null && gk != gradeKey) continue;
      final int spec = (ou != null ? 1 : 0) + (gk != null ? 1 : 0);
      if (best == null || spec > bestSpec || (spec == bestSpec && pd.compareTo('${best['price_date']}') > 0)) {
        best = r;
        bestSpec = spec;
      }
    }
    return best;
  }
}

/// «قیمت پیشنهادی روز» line shown under the price field; tapping «استفاده» calls [onAccept] (the user can always type another price).
class PriceSuggestionHint extends StatelessWidget {
  final String typeName;
  final String? ounceUid;
  final String? gradeKey;
  final ValueChanged<num> onAccept;
  const PriceSuggestionHint({super.key, required this.typeName, this.ounceUid, this.gradeKey, required this.onAccept});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>?>(
      key: ValueKey<String>('psh|$typeName|$ounceUid|$gradeKey'),
      future: PriceTableLocal.suggest(typeName, ounceUid: ounceUid, gradeKey: gradeKey),
      builder: (BuildContext c, AsyncSnapshot<Map<String, dynamic>?> snap) {
        final Map<String, dynamic>? s = snap.data;
        if (s == null) return const SizedBox.shrink();
        final num price = (s['price_per_kg'] as num);
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(children: <Widget>[
            Expanded(
              child: Text('قیمت پیشنهادی روز: ${faNum(price.toDouble(), dec: 0)} (${jalaliDate('${s['price_date']}')})',
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ),
            TextButton(onPressed: () => onAccept(price), child: const Text('استفاده')),
          ]),
        );
      },
    );
  }
}

class PriceTableScreen extends StatefulWidget {
  const PriceTableScreen({super.key});

  @override
  State<PriceTableScreen> createState() => _PriceTableScreenState();
}

class _PriceTableScreenState extends State<PriceTableScreen> {
  List<Map<String, dynamic>> _rows = <Map<String, dynamic>>[];
  Map<String, String> _gradeLabel = <String, String>{};
  bool _loading = true;
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final List<Map<String, dynamic>>? r = await PriceTableLocal.refresh();
    final List<Map<String, dynamic>> rows = r ?? await PriceTableLocal.rows();
    final Map<String, String> lab = <String, String>{for (final Map<String, String> g in await GradeLinesLocal.grades()) g['key']!: g['label']!};
    if (!mounted) return;
    setState(() {
      _offline = r == null;
      _rows = rows;
      _gradeLabel = lab;
      _loading = false;
    });
  }

  Future<void> _delete(Map<String, dynamic> r) async {
    try {
      await StockApi.call('grade_prices.delete', <String, dynamic>{'id': r['id']});
      await _load();
    } on StockApiException catch (e) {
      if (mounted) snack(context, e.message);
    } catch (_) {
      if (mounted) snack(context, 'حذف نشد؛ اتصال اینترنت را بررسی کنید');
    }
  }

  Future<void> _add() async {
    final TextEditingController type = TextEditingController();
    final TextEditingController price = TextEditingController();
    String? grade;
    DateTime day = DateTime.now();
    final List<Map<String, String>> grades = await GradeLinesLocal.grades();
    if (!mounted) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => StatefulBuilder(
        builder: (BuildContext c, StateSetter set) => AlertDialog(
          title: const Text('قیمت روز'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
              TextField(controller: type, decoration: const InputDecoration(labelText: 'نوع پسته (دقیقاً مثل نام نوع)')),
              DropdownButtonFormField<String?>(
                value: grade,
                decoration: const InputDecoration(labelText: 'درجه (اختیاری)'),
                items: <DropdownMenuItem<String?>>[
                  const DropdownMenuItem<String?>(value: null, child: Text('همهٔ درجه‌ها')),
                  for (final Map<String, String> g in grades) DropdownMenuItem<String?>(value: g['key'], child: Text(g['label']!)),
                ],
                onChanged: (String? v) => set(() => grade = v),
              ),
              TextField(controller: price, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'قیمت هر کیلو')),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('تاریخ: ${jalaliDateFromDt(day)}'),
                trailing: const Icon(Icons.calendar_today),
                onTap: () async {
                  final DateTime? d = await pickDate(c, initial: day);
                  if (d != null) set(() => day = d);
                },
              ),
            ]),
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('انصراف')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('ذخیره')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final double? pv = parseNum(price.text);
    if (type.text.trim().isEmpty || pv == null || pv <= 0) {
      if (mounted) snack(context, 'نوع و قیمت را درست وارد کنید');
      return;
    }
    try {
      await StockApi.call('grade_prices.save', <String, dynamic>{
        'type_name': type.text.trim(),
        'grade_key': grade,
        'price_per_kg': pv.round(),
        'price_date': day.toIso8601String().substring(0, 10),
      });
      await _load();
    } on StockApiException catch (e) {
      if (mounted) snack(context, e.message);
    } catch (_) {
      if (mounted) snack(context, 'ذخیره نشد؛ اتصال اینترنت را بررسی کنید');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('جدول قیمت روز'), actions: <Widget>[
        if (!_offline)
          IconButton(
            tooltip: 'واردکردن از اکسل',
            icon: const Icon(Icons.upload_file),
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const ImportScreen(initialKind: 'grade_prices')));
              if (mounted) _load();
            },
          ),
      ]),
      floatingActionButton: _offline ? null : FloatingActionButton(onPressed: _add, child: const Icon(Icons.add)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _rows.isEmpty
              ? Center(child: Text(_offline ? 'برای ثبت قیمت به اینترنت نیاز است' : 'هنوز قیمتی ثبت نشده است'))
              : ListView(children: <Widget>[
                  if (_offline)
                    const Padding(padding: EdgeInsets.all(12), child: Text('آفلاین: آخرین فهرست ذخیره‌شده نمایش داده می‌شود', style: TextStyle(fontSize: 12))),
                  for (final Map<String, dynamic> r in _rows)
                    ListTile(
                      title: Text('${r['type_name']}${r['grade_key'] == null ? '' : ' - ${_gradeLabel['${r['grade_key']}'] ?? r['grade_key']}'}'),
                      subtitle: Text('${jalaliDate('${r['price_date']}')} · ${faNum((r['price_per_kg'] as num).toDouble(), dec: 0)}'),
                      trailing: _offline ? null : IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _delete(r)),
                    ),
                ]),
    );
  }
}
