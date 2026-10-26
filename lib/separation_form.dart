import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'vouchers_links.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'barcode_utils.dart';
import 'db.dart';
import 'pdf_output.dart';
import 'pdf_service.dart';
import 'returns_ui.dart' show ReturnsHelp;
import 'sync_service.dart';
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;
import 'widgets.dart';

/// S07.T07.3 — multi-output separation (جداسازی چندخروجی) + lineage (ردیابی).
/// Server actions: separations.create/get/list/delete/settings, lots.lineage, lots.find_code (separation.php).
/// Offline: a new job is queued (SharedPreferences, strictly ordered, idempotent through `uid`) and replayed
/// when the server is reachable; stock already promised to queued jobs is subtracted in the form so the same
/// lot cannot be separated twice while offline. No local SQLite table / schemaVersion change: output lots
/// (purchases.is_mix = 2) arrive through the normal pull after the job reaches the server.

double _d(dynamic v) => ReturnsHelp.d(v);

/// Queue + caches for separation jobs.
class SeparationStore {
  SeparationStore._();
  static const String _kOps = 'sep_ops_v1';
  static const String _kList = 'sep_list_v1';
  static const String _kCfg = 'sep_cfg_v1';

  static Future<List<Map<String, dynamic>>> pendingOps() async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    final String? raw = sp.getString(_kOps);
    if (raw == null) return <Map<String, dynamic>>[];
    try {
      return ReturnsHelp.maps(jsonDecode(raw));
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<void> _saveOps(List<Map<String, dynamic>> ops) async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    await sp.setString(_kOps, jsonEncode(ops));
  }

  static Future<void> enqueue(Map<String, dynamic> op) async {
    final List<Map<String, dynamic>> ops = await pendingOps();
    ops.add(op);
    await _saveOps(ops);
  }

  static Future<void> dropOp(String uid) async {
    final List<Map<String, dynamic>> ops = await pendingOps();
    ops.removeWhere((Map<String, dynamic> o) => '${o['uid']}' == uid);
    await _saveOps(ops);
  }

  static bool isNetworkError(String m) => m.contains('اتصال به سرور') || m.contains('خطای سرور');

  /// Replays queued jobs in order. Stops at the first network failure. Returns the messages of jobs the server rejected
  /// (those are dropped from the queue so they cannot block the following ones).
  static Future<List<String>> flush() async {
    final List<String> errors = <String>[];
    List<Map<String, dynamic>> ops = await pendingOps();
    bool sentAny = false;
    while (ops.isNotEmpty) {
      final Map<String, dynamic> op = ops.first;
      try {
        final dynamic payload = op['payload'];
        await StockApi.call('separations.create', payload is Map ? Map<String, dynamic>.from(payload) : <String, dynamic>{});
        sentAny = true;
      } on StockApiException catch (e) {
        if (isNetworkError(e.message) || e.message.contains('ورود مجدد')) break;
        errors.add('جداسازی ${op['label'] ?? ''}: ${e.message}');
      }
      ops = ops.sublist(1);
      await _saveOps(ops);
    }
    if (sentAny) {
      SyncService.I.syncNow(pull: true); // fetch the new output lots (is_mix = 2) and the reduced input stock
    }
    return errors;
  }

  /// kg / small sacks / large sacks already promised to queued jobs, per input lot id.
  static Map<int, List<double>> reserved(List<Map<String, dynamic>> ops) {
    final Map<int, List<double>> m = <int, List<double>>{};
    for (final Map<String, dynamic> op in ops) {
      final dynamic p = op['payload'];
      if (p is! Map) continue;
      final dynamic ins = p['inputs'];
      if (ins is! List) continue;
      for (final dynamic i in ins) {
        if (i is! Map) continue;
        final int id = _d(i['purchase_id']).toInt();
        final List<double> r = m.putIfAbsent(id, () => <double>[0, 0, 0]);
        r[0] += _d(i['weight']);
        r[1] += _d(i['small_sacks']);
        r[2] += _d(i['large_sacks']);
      }
    }
    return m;
  }

  static Future<List<Map<String, dynamic>>> cachedList() async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    final String? raw = sp.getString(_kList);
    if (raw == null) return <Map<String, dynamic>>[];
    try {
      return ReturnsHelp.maps(jsonDecode(raw));
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<void> saveList(List<Map<String, dynamic>> items) async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    await sp.setString(_kList, jsonEncode(items));
  }

  /// {tolerance_kg, abnormal_pct}; server values when reachable, else the last cached, else the server defaults.
  static Future<Map<String, double>> settings({bool refresh = true}) async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    Map<String, double> cur = <String, double>{'tolerance_kg': 0.0015, 'abnormal_pct': 5.0};
    final String? raw = sp.getString(_kCfg);
    if (raw != null) {
      try {
        final dynamic j = jsonDecode(raw);
        if (j is Map) {
          cur = <String, double>{'tolerance_kg': _d(j['tolerance_kg']), 'abnormal_pct': _d(j['abnormal_pct'])};
        }
      } catch (_) {}
    }
    if (!refresh) return cur;
    try {
      final Map<String, dynamic> r = await StockApi.call('separations.settings');
      cur = <String, double>{'tolerance_kg': _d(r['tolerance_kg']), 'abnormal_pct': _d(r['abnormal_pct'])};
      await sp.setString(_kCfg, jsonEncode(cur));
    } catch (_) {}
    return cur;
  }
}

class _InRow {
  final TextEditingController weight = TextEditingController();
  final TextEditingController small = TextEditingController();
  final TextEditingController large = TextEditingController();
  void dispose() {
    weight.dispose();
    small.dispose();
    large.dispose();
  }
}

class _OutRow {
  final TextEditingController name = TextEditingController();
  final TextEditingController kg = TextEditingController();
  final TextEditingController small = TextEditingController();
  final TextEditingController large = TextEditingController();
  final TextEditingController ounce = TextEditingController();
  final TextEditingController price = TextEditingController(); // alloc_price (only for by_value)
  void dispose() {
    name.dispose();
    kg.dispose();
    small.dispose();
    large.dispose();
    ounce.dispose();
    price.dispose();
  }
}

class _Calc {
  double inKg = 0;
  double inCost = 0;
  double outKg = 0;
  double waste = 0;
  double labor = 0;
  double transport = 0;
  double diff = 0;
  double abKg = 0;
  double abCost = 0;
  double distributable = 0;
  List<double> outCost = <double>[];
}

/// New multi-output separation job. Cannot be saved while the mass balance is off (Σ input = Σ output + waste ± tolerance).
class SeparationForm extends StatefulWidget {
  const SeparationForm({super.key});
  @override
  State<SeparationForm> createState() => _SeparationFormState();
}

class _SeparationFormState extends State<SeparationForm> with EditGuard<SeparationForm> {
  List<Map<String, dynamic>> _lots = <Map<String, dynamic>>[];
  final Map<int, bool> _sel = <int, bool>{};
  final Map<int, _InRow> _rows = <int, _InRow>{};
  final List<_OutRow> _outs = <_OutRow>[_OutRow()];
  final TextEditingController _waste = TextEditingController();
  final TextEditingController _labor = TextEditingController();
  final TextEditingController _transport = TextEditingController();
  final TextEditingController _note = TextEditingController();
  String _alloc = 'by_weight';
  DateTime _date = DateTime.now();
  String _query = '';
  bool _loading = true;
  bool _saving = false;
  double _tol = 0.0015;
  double _abPct = 5.0;
  Map<int, List<double>> _reserved = <int, List<double>>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final _InRow r in _rows.values) {
      r.dispose();
    }
    for (final _OutRow o in _outs) {
      o.dispose();
    }
    _waste.dispose();
    _labor.dispose();
    _transport.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final List<Map<String, dynamic>> all = await AppDb.I.lots();
    final List<Map<String, dynamic>> ops = await SeparationStore.pendingOps();
    final Map<int, List<double>> res = SeparationStore.reserved(ops);
    final Map<String, double> cfg = await SeparationStore.settings(refresh: false);
    if (!mounted) return;
    setState(() {
      // only lots already known to the server (positive id) can be an input of a queued job
      _lots = all.where((Map<String, dynamic> e) => _d(e['id']) > 0).toList();
      _reserved = res;
      _tol = cfg['tolerance_kg'] ?? 0.0015;
      _abPct = cfg['abnormal_pct'] ?? 5.0;
      _loading = false;
    });
    final Map<String, double> fresh = await SeparationStore.settings();
    if (mounted) {
      setState(() {
        _tol = fresh['tolerance_kg'] ?? _tol;
        _abPct = fresh['abnormal_pct'] ?? _abPct;
      });
    }
  }

  double _avail(Map<String, dynamic> lot) {
    final List<double>? r = _reserved[_d(lot['id']).toInt()];
    return _d(lot['remaining']) - (r == null ? 0 : r[0]);
  }

  double _availSmall(Map<String, dynamic> lot) {
    final List<double>? r = _reserved[_d(lot['id']).toInt()];
    return _d(lot['small_left']) - (r == null ? 0 : r[1]);
  }

  double _availLarge(Map<String, dynamic> lot) {
    final List<double>? r = _reserved[_d(lot['id']).toInt()];
    return _d(lot['large_left']) - (r == null ? 0 : r[2]);
  }

  List<Map<String, dynamic>> get _selected =>
      _lots.where((Map<String, dynamic> e) => _sel[_d(e['id']).toInt()] ?? false).toList();

  double _r2(double v) => double.parse(v.toStringAsFixed(2));

  /// Same arithmetic as pb_sep_apply (cost preview is approximate: server adds broker commission to the lot cost).
  _Calc _calc() {
    final _Calc c = _Calc();
    for (final Map<String, dynamic> e in _selected) {
      final _InRow? r = _rows[_d(e['id']).toInt()];
      final double w = parseNum(r?.weight.text) ?? 0;
      if (w <= 0) continue;
      c.inKg += w;
      c.inCost += w * _d(e['price']);
    }
    c.waste = parseNum(_waste.text) ?? 0;
    c.labor = parseNum(_labor.text) ?? 0;
    c.transport = parseNum(_transport.text) ?? 0;
    final List<double> wts = <double>[];
    double sumW = 0;
    for (final _OutRow o in _outs) {
      final double kg = parseNum(o.kg.text) ?? 0;
      c.outKg += kg;
      final double wt = _alloc == 'by_value' ? kg * (parseNum(o.price.text) ?? 0) : kg;
      wts.add(wt);
      sumW += wt;
    }
    c.diff = double.parse((c.inKg - c.outKg - c.waste).toStringAsFixed(3));
    c.abKg = c.inKg > 0 ? (c.waste - c.inKg * _abPct / 100.0).clamp(0.0, double.infinity).toDouble() : 0;
    c.abCost = c.inKg > 0 ? _r2(c.abKg * (c.inCost / c.inKg)) : 0;
    c.distributable = _r2(_r2(c.inCost) + c.labor + c.transport - c.abCost);
    c.outCost = <double>[];
    double acc = 0;
    int bigIdx = 0;
    for (int i = 0; i < wts.length; i++) {
      final double v = sumW > 0 ? _r2(c.distributable * wts[i] / sumW) : 0;
      c.outCost.add(v);
      acc += v;
      if (wts[i] > wts[bigIdx]) bigIdx = i;
    }
    if (c.outCost.isNotEmpty) c.outCost[bigIdx] = _r2(c.outCost[bigIdx] + (c.distributable - acc));
    return c;
  }

  /// First reason why the job cannot be saved, or null.
  String? _problem(_Calc c) {
    if (_selected.isEmpty || c.inKg <= 0) return 'حداقل یک ورودی با وزن بیشتر از صفر انتخاب کنید';
    for (final Map<String, dynamic> e in _selected) {
      final _InRow? r = _rows[_d(e['id']).toInt()];
      final double w = parseNum(r?.weight.text) ?? 0;
      if (w <= 0) return 'وزن برداشتی «${e['type_name']}» را وارد کنید';
      if (w > _avail(e) + 1e-6) return 'وزن برداشتی «${e['type_name']}» از موجودی (${faNum(_avail(e))} کیلو) بیشتر است';
      if ((parseNum(r?.small.text) ?? 0) > _availSmall(e) + 1e-6) return 'گونی کوچک مصرفی «${e['type_name']}» بیشتر از موجودی است';
      if ((parseNum(r?.large.text) ?? 0) > _availLarge(e) + 1e-6) return 'گونی بزرگ مصرفی «${e['type_name']}» بیشتر از موجودی است';
    }
    if (_outs.isEmpty) return 'حداقل یک خروجی ثبت کنید';
    for (final _OutRow o in _outs) {
      if (o.name.text.trim().isEmpty) return 'نام/نوع هر خروجی را وارد کنید';
      if ((parseNum(o.kg.text) ?? 0) <= 0) return 'وزن هر خروجی باید بیشتر از صفر باشد';
      if (_alloc == 'by_value' && (parseNum(o.price.text) ?? 0) <= 0) return 'برای تسهیم بر اساس ارزش، فی مبنای همهٔ خروجی‌ها را وارد کنید';
    }
    if (c.diff.abs() > _tol + 1e-9) {
      return c.diff > 0
          ? '${faNum(c.diff, dec: 3)} کیلو اختلاف ثبت‌نشده دارید؛ خروجی یا ضایعات را اصلاح کنید'
          : 'خروجی + ضایعات به اندازهٔ ${faNum(-c.diff, dec: 3)} کیلو از ورودی بیشتر است';
    }
    if (c.distributable < 0) return 'هزینهٔ قابل تسهیم منفی شد؛ ورودی‌ها را بررسی کنید';
    return null;
  }

  Future<void> _save() async {
    if (_saving) return;
    final _Calc c = _calc();
    final String? bad = _problem(c);
    if (bad != null) {
      snack(context, bad);
      return;
    }
    setState(() => _saving = true);
    try {
      final String uid = 'sep${DateTime.now().microsecondsSinceEpoch}';
      final List<Map<String, dynamic>> inputs = <Map<String, dynamic>>[];
      final List<String> codes = <String>[];
      for (final Map<String, dynamic> e in _selected) {
        final _InRow r = _rows[_d(e['id']).toInt()]!;
        inputs.add(<String, dynamic>{
          'purchase_id': _d(e['id']).toInt(),
          'weight': parseNum(r.weight.text) ?? 0,
          'small_sacks': parseNum(r.small.text) ?? 0,
          'large_sacks': parseNum(r.large.text) ?? 0,
        });
        codes.add('${e['code'] ?? e['id']}');
      }
      final List<Map<String, dynamic>> outputs = <Map<String, dynamic>>[];
      for (final _OutRow o in _outs) {
        final double? ounce = parseNum(o.ounce.text);
        final double? price = parseNum(o.price.text);
        outputs.add(<String, dynamic>{
          'type_name': o.name.text.trim(),
          'kg': parseNum(o.kg.text) ?? 0,
          'small_sacks': parseNum(o.small.text) ?? 0,
          'large_sacks': parseNum(o.large.text) ?? 0,
          if (ounce != null) 'ounce': ounce,
          if (_alloc == 'by_value' && price != null) 'alloc_price': price,
        });
      }
      final Map<String, dynamic> payload = <String, dynamic>{
        'uid': uid,
        'date': ReturnsHelp.iso(_date),
        'cost_alloc': _alloc,
        'waste_kg': c.waste,
        'labor_cost': c.labor,
        'transport_cost': c.transport,
        'inputs': inputs,
        'outputs': outputs,
        if (_note.text.trim().isNotEmpty) 'note': _note.text.trim(),
      };
      await SeparationStore.enqueue(<String, dynamic>{
        'uid': uid,
        'label': codes.join('، '),
        'at': DateTime.now().toIso8601String(),
        'payload': payload,
      });
      final List<String> errs = await SeparationStore.flush();
      final bool stillQueued = (await SeparationStore.pendingOps()).any((Map<String, dynamic> o) => '${o['uid']}' == uid);
      if (!mounted) return;
      if (errs.isNotEmpty) {
        snack(context, errs.first);
        setState(() => _saving = false);
        return;
      }
      snack(context, stillQueued ? 'آفلاین هستید؛ جداسازی در صف ماند و پس از اتصال ثبت می‌شود' : 'جداسازی ثبت شد');
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      snack(context, friendlyError(e));
    }
  }

  Widget _num(TextEditingController c, String label, {String? suffix, bool wide = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: label, suffixText: suffix, border: const OutlineInputBorder(), isDense: true),
          onChanged: (_) => setState(() {}),
        ),
      );

  Widget _inputCard(Map<String, dynamic> e) {
    final int id = _d(e['id']).toInt();
    final bool on = _sel[id] ?? false;
    final _InRow row = _rows.putIfAbsent(id, () => _InRow());
    return Card(
      child: Column(children: <Widget>[
        CheckboxListTile(
          dense: true,
          value: on,
          onChanged: (bool? v) => setState(() => _sel[id] = v ?? false),
          title: Text('${e['category_name']} - ${e['type_name']}'),
          subtitle: Text('کد ${e['code'] ?? '-'}  •  موجود ${faNum(_avail(e))} کیلو  •  فی ${faNum(_d(e['price']), dec: 0)}'
              '  •  گونی ${faNum(_availSmall(e))}/${faNum(_availLarge(e))}'),
        ),
        if (on)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Row(children: <Widget>[
              Expanded(flex: 3, child: _num(row.weight, 'وزن برداشتی', suffix: 'کیلو')),
              const SizedBox(width: 6),
              Expanded(flex: 2, child: _num(row.small, 'گونی کوچک')),
              const SizedBox(width: 6),
              Expanded(flex: 2, child: _num(row.large, 'گونی بزرگ')),
            ]),
          ),
      ]),
    );
  }

  Widget _outputCard(int i, _Calc c) {
    final _OutRow o = _outs[i];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
          Row(children: <Widget>[
            Expanded(child: Text('خروجی ${faNum(i + 1, dec: 0)}', style: const TextStyle(fontWeight: FontWeight.bold))),
            if (_outs.length > 1)
              IconButton(
                tooltip: 'حذف خروجی',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => setState(() {
                  _outs.removeAt(i).dispose();
                }),
              ),
          ]),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextField(
              controller: o.name,
              decoration: const InputDecoration(labelText: 'نوع / نام خروجی (مثلاً دمبست، خندان)', border: OutlineInputBorder(), isDense: true),
              onChanged: (_) => setState(() {}),
            ),
          ),
          Row(children: <Widget>[
            Expanded(flex: 3, child: _num(o.kg, 'وزن خالص', suffix: 'کیلو')),
            const SizedBox(width: 6),
            Expanded(flex: 2, child: _num(o.small, 'گونی کوچک')),
            const SizedBox(width: 6),
            Expanded(flex: 2, child: _num(o.large, 'گونی بزرگ')),
          ]),
          Row(children: <Widget>[
            Expanded(child: _num(o.ounce, 'انس (اختیاری)')),
            if (_alloc == 'by_value') ...<Widget>[
              const SizedBox(width: 6),
              Expanded(child: _num(o.price, 'فی مبنا (برای تسهیم)')),
            ],
          ]),
          if (i < c.outCost.length && (parseNum(o.kg.text) ?? 0) > 0)
            Text(
              'هزینهٔ تقریبی: ${faNum(c.outCost[i], dec: 0)}  •  فی هر کیلو: ${faNum(c.outCost[i] / (parseNum(o.kg.text) ?? 1), dec: 0)}',
              style: const TextStyle(color: Colors.black54, fontSize: 12),
            ),
        ]),
      ),
    );
  }

  Widget _balanceCard(_Calc c, String? problem) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool balanced = c.inKg > 0 && c.diff.abs() <= _tol + 1e-9;
    return Card(
      color: balanced ? Colors.green.shade50 : scheme.errorContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
          infoRow('جمع ورودی', '${faNum(c.inKg, dec: 3)} کیلو'),
          infoRow('جمع خروجی', '${faNum(c.outKg, dec: 3)} کیلو'),
          infoRow('ضایعات/خاک', '${faNum(c.waste, dec: 3)} کیلو'),
          infoRow('اختلاف (ورودی − خروجی − ضایعات)', '${faNum(c.diff, dec: 3)} کیلو',
              valueColor: balanced ? Colors.green.shade700 : scheme.error),
          const Divider(),
          infoRow('ارزش ورودی‌ها (تقریبی)', faNum(c.inCost, dec: 0)),
          infoRow('هزینه‌های سرشکن‌شده (دستمزد + حمل)', faNum(c.labor + c.transport, dec: 0)),
          if (c.abCost > 0) infoRow('ضایعات غیرعادی (هزینهٔ دوره، سرشکن نمی‌شود)', faNum(c.abCost, dec: 0)),
          infoRow('قابل تسهیم روی خروجی‌ها', faNum(c.distributable, dec: 0)),
          const SizedBox(height: 4),
          Text(
            problem == null ? '✓ وزن‌ها برابرند؛ آمادهٔ ثبت' : problem,
            style: TextStyle(color: problem == null ? Colors.green.shade800 : scheme.error, fontWeight: FontWeight.w600),
          ),
          if (c.abKg > 0)
            Text('ضایعات بیش از ${faNum(_abPct, dec: 1)}٪ وزن ورودی «غیرعادی» حساب می‌شود و جزو هزینهٔ خروجی‌ها نیست.',
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final _Calc c = _calc();
    final String? problem = _problem(c);
    final String q = _query.trim();
    final List<Map<String, dynamic>> shown = _lots.where((Map<String, dynamic> e) {
      final int id = _d(e['id']).toInt();
      if (_sel[id] ?? false) return true;
      if (_avail(e) <= 0.0005) return false;
      return q.isEmpty || '${e['code']} ${e['category_name']} ${e['type_name']}'.contains(q);
    }).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('جداسازی چندخروجی')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(12), children: <Widget>[
              sectionTitle(context, '۱) ورودی‌ها (از انبار)'),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextField(
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'جستجوی کد یا نوع', border: OutlineInputBorder(), isDense: true),
                  onChanged: (String v) => setState(() => _query = v),
                ),
              ),
              if (shown.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('بار موجودی برای انتخاب نیست (بارهایی که هنوز همگام نشده‌اند در این فرم دیده نمی‌شوند).')),
              for (final Map<String, dynamic> e in shown) _inputCard(e),
              sectionTitle(context, '۲) خروجی‌ها'),
              for (int i = 0; i < _outs.length; i++) _outputCard(i, c),
              OutlinedButton.icon(
                onPressed: _outs.length >= 100 ? null : () => setState(() => _outs.add(_OutRow())),
                icon: const Icon(Icons.add),
                label: const Text('افزودن خروجی'),
              ),
              sectionTitle(context, '۳) ضایعات و هزینه‌ها'),
              _num(_waste, 'ضایعات/خاک', suffix: 'کیلو'),
              Row(children: <Widget>[
                Expanded(child: _num(_labor, 'دستمزد')),
                const SizedBox(width: 6),
                Expanded(child: _num(_transport, 'حمل')),
              ]),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: DropdownButtonFormField<String>(
                  value: _alloc,
                  decoration: const InputDecoration(labelText: 'روش تسهیم هزینه بین خروجی‌ها', border: OutlineInputBorder(), isDense: true),
                  items: const <DropdownMenuItem<String>>[
                    DropdownMenuItem<String>(value: 'by_weight', child: Text('بر اساس وزن')),
                    DropdownMenuItem<String>(value: 'by_value', child: Text('بر اساس ارزش (فی مبنا)')),
                  ],
                  onChanged: (String? v) => setState(() => _alloc = v ?? 'by_weight'),
                ),
              ),
              dateField(context, 'تاریخ', _date, (DateTime d) => setState(() => _date = d)),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextField(controller: _note, maxLines: 2, decoration: const InputDecoration(labelText: 'توضیحات', border: OutlineInputBorder(), isDense: true)),
              ),
              sectionTitle(context, 'بالانس جرم و هزینه'),
              _balanceCard(c, problem),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: (problem == null && !_saving) ? _save : null,
                icon: _saving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check),
                label: const Text('ثبت جداسازی'),
              ),
              const SizedBox(height: 32),
            ]),
    );
  }
}

// ============================ list + detail ============================

/// List of separation jobs (server list cached for offline) + queued jobs waiting to be sent.
class SeparationsScreen extends StatefulWidget {
  const SeparationsScreen({super.key});
  @override
  State<SeparationsScreen> createState() => _SeparationsScreenState();
}

class _SeparationsScreenState extends State<SeparationsScreen> {
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _pending = <Map<String, dynamic>>[];
  bool _loading = true;
  String? _note;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    _items = await SeparationStore.cachedList();
    _pending = await SeparationStore.pendingOps();
    if (mounted) setState(() => _loading = false);
    final List<String> errs = await SeparationStore.flush();
    try {
      final Map<String, dynamic> r = await StockApi.call('separations.list');
      _items = ReturnsHelp.maps(r['items']);
      await SeparationStore.saveList(_items);
      _note = errs.isEmpty ? null : errs.first;
    } on StockApiException catch (e) {
      _note = SeparationStore.isNetworkError(e.message) ? 'آفلاین: فهرست ذخیره‌شدهٔ قبلی نمایش داده می‌شود' : e.message;
    }
    _pending = await SeparationStore.pendingOps();
    if (mounted) setState(() {});
  }

  Future<void> _new() async {
    final bool? ok = await Navigator.push<bool>(context, MaterialPageRoute<bool>(builder: (_) => const SeparationForm()));
    if (ok == true) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('جداسازی چندخروجی'),
        actions: <Widget>[
          IconButton(
            tooltip: 'ردیابی با کد',
            icon: const Icon(Icons.account_tree_outlined),
            onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const LotLineageScreen())),
          ),
          IconButton(tooltip: 'بروزرسانی', icon: const Icon(Icons.refresh), onPressed: _refresh),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(onPressed: _new, icon: const Icon(Icons.call_split), label: const Text('جداسازی جدید')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(padding: const EdgeInsets.all(12), children: <Widget>[
                if (_note != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_note!, style: const TextStyle(color: Colors.black54))),
                for (final Map<String, dynamic> op in _pending)
                  Card(
                    color: Colors.amber.shade50,
                    child: ListTile(
                      leading: const Icon(Icons.schedule),
                      title: Text('در صف ارسال: ${op['label'] ?? ''}'),
                      subtitle: Text('ثبت‌شده در حالت آفلاین؛ پس از اتصال ارسال می‌شود'),
                      trailing: IconButton(
                        tooltip: 'لغو این جداسازی',
                        icon: const Icon(Icons.close),
                        onPressed: () async {
                          if (!await confirm(context, 'این جداسازیِ ارسال‌نشده لغو شود؟')) return;
                          await SeparationStore.dropOp('${op['uid']}');
                          await _refresh();
                        },
                      ),
                    ),
                  ),
                if (_items.isEmpty && _pending.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('هنوز جداسازی ثبت نشده است'))),
                for (final Map<String, dynamic> s in _items)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.call_split),
                      title: Text('${jalaliDate('${s['date']}')}  •  ${faNum(_d(s['input_kg']), dec: 3)} کیلو ورودی'),
                      subtitle: Text('${faNum(_d(s['inputs_count']), dec: 0)} ورودی ← ${faNum(_d(s['outputs_count']), dec: 0)} خروجی '
                          '(${faNum(_d(s['output_kg']), dec: 3)} کیلو)  •  ضایعات ${faNum(_d(s['waste_kg']), dec: 3)} کیلو'),
                      onTap: () async {
                        await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => SeparationDetailScreen(id: _d(s['id']).toInt())));
                        await _refresh();
                      },
                    ),
                  ),
                const SizedBox(height: 72),
              ]),
            ),
    );
  }
}

class SeparationDetailScreen extends StatefulWidget {
  final int id;
  const SeparationDetailScreen({super.key, required this.id});
  @override
  State<SeparationDetailScreen> createState() => _SeparationDetailScreenState();
}

class _SeparationDetailScreenState extends State<SeparationDetailScreen> {
  Map<String, dynamic>? _s;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final Map<String, dynamic> r = await StockApi.call('separations.get', <String, dynamic>{'id': widget.id});
      if (mounted) setState(() => _s = r);
    } on StockApiException catch (e) {
      if (mounted) setState(() => _err = e.message);
    }
  }

  Future<void> _delete() async {
    if (!await confirm(context, 'جداسازی حذف شود؟ ورودی‌ها به انبار برمی‌گردند و خروجی‌ها از بین می‌روند.')) return;
    try {
      await StockApi.call('separations.delete', <String, dynamic>{'id': widget.id});
      SyncService.I.syncNow(pull: true);
      if (mounted) Navigator.pop(context);
    } on StockApiException catch (e) {
      if (mounted) snack(context, e.message);
    }
  }

  Future<void> _label(Map<String, dynamic> o) async {
    final File file = await PdfService.buildStockCard(
      code: '${o['code'] ?? '-'}',
      totalWeight: _d(o['kg']),
      netWeight: _d(o['kg']),
      smallSacks: _d(o['small_sacks']),
      largeSacks: _d(o['large_sacks']),
    );
    if (mounted) await PdfOutput.show(context, file);
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic>? s = _s;
    return Scaffold(
      appBar: AppBar(title: const Text('جزئیات جداسازی')),
      body: s == null
          ? Center(child: _err == null ? const CircularProgressIndicator() : Padding(padding: const EdgeInsets.all(24), child: Text(_err!)))
          : ListView(padding: const EdgeInsets.all(12), children: <Widget>[
              if (widget.id > 0) ...<Widget>[
                VoucherStatusChip(sourceType: 'sep', sourceId: '${widget.id}'),
                VoucherLinkButton(sourceType: 'sep', sourceId: '${widget.id}'),
              ], // T16.7
              infoRow('تاریخ', jalaliDate('${s['date']}')),
              infoRow('جمع ورودی', '${faNum(_d(s['input_kg']), dec: 3)} کیلو'),
              infoRow('ضایعات', '${faNum(_d(s['waste_kg']), dec: 3)} کیلو'),
              infoRow('دستمزد', faNum(_d(s['labor_cost']), dec: 0)),
              infoRow('حمل', faNum(_d(s['transport_cost']), dec: 0)),
              if (_d(s['abnormal_cost']) > 0) infoRow('ضایعات غیرعادی (هزینهٔ دوره)', faNum(_d(s['abnormal_cost']), dec: 0)),
              if ('${s['note'] ?? ''}'.isNotEmpty) infoRow('توضیحات', '${s['note']}'),
              sectionTitle(context, 'ورودی‌ها'),
              for (final Map<String, dynamic> i in ReturnsHelp.maps(s['inputs']))
                Card(
                  child: ListTile(
                    dense: true,
                    title: Text('${i['type_name'] ?? ''}  •  ${i['code'] ?? ''}'),
                    subtitle: Text('${faNum(_d(i['kg']), dec: 3)} کیلو  •  ارزش ${faNum(_d(i['cost']), dec: 0)}'),
                    onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => LotLineageScreen(lotId: _d(i['lot_id']).toInt()))),
                  ),
                ),
              sectionTitle(context, 'خروجی‌ها (محصول جداسازی)'),
              for (final Map<String, dynamic> o in ReturnsHelp.maps(s['outputs']))
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                      Text('${o['type_name'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text('کد ردیابی: ${o['code'] ?? '-'}'),
                      Text('${faNum(_d(o['kg']), dec: 3)} کیلو  •  هزینه ${faNum(_d(o['cost']), dec: 0)}  •  فی ${faNum(_d(o['unit_cost']), dec: 0)}'),
                      if (isPrintableCode(o['code'] as String?)) BarcodeBox('${o['code']}', height: 48),
                      Row(children: <Widget>[
                        TextButton.icon(
                          onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => LotLineageScreen(lotId: _d(o['lot_id']).toInt()))),
                          icon: const Icon(Icons.account_tree_outlined),
                          label: const Text('ردیابی'),
                        ),
                        TextButton.icon(onPressed: () => _label(o), icon: const Icon(Icons.print_outlined), label: const Text('چاپ برچسب A6')),
                      ]),
                    ]),
                  ),
                ),
              if (s['check'] is Map) ...<Widget>[
                sectionTitle(context, 'کنترل تطبیق'),
                infoRow('اختلاف جرم', '${faNum(_d((s['check'] as Map)['mass_diff_kg']), dec: 3)} کیلو'),
                infoRow('اختلاف هزینه', faNum(_d((s['check'] as Map)['cost_diff']), dec: 2)),
              ],
              const SizedBox(height: 8),
              if (s['editable'] == true)
                OutlinedButton.icon(onPressed: _delete, icon: const Icon(Icons.delete_outline), label: const Text('حذف جداسازی'))
              else
                const Text('از خروجی‌ها فروش یا مصرف شده؛ حذف/ویرایش ممکن نیست.', style: TextStyle(color: Colors.black54)),
              const SizedBox(height: 24),
            ]),
    );
  }
}

// ============================ lineage ============================

/// Ancestors / descendants tree of one lot (server `lots.lineage`; covers purchases, mixes and separations).
/// Opened either with a lot id, or empty with a tracking-code box (KH… / MX… / K-…).
class LotLineageScreen extends StatefulWidget {
  final int? lotId;
  const LotLineageScreen({super.key, this.lotId});
  @override
  State<LotLineageScreen> createState() => _LotLineageScreenState();
}

class _LotLineageScreenState extends State<LotLineageScreen> {
  final TextEditingController _code = TextEditingController();
  Map<String, dynamic>? _data;
  String? _err;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.lotId != null) _load(<String, dynamic>{'lot_id': widget.lotId});
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _load(Map<String, dynamic> payload) async {
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final Map<String, dynamic> r = await StockApi.call('lots.lineage', payload);
      if (mounted) setState(() => _data = r);
    } on StockApiException catch (e) {
      if (mounted) {
        setState(() {
          _data = null;
          _err = SeparationStore.isNetworkError(e.message) ? 'ردیابی به اینترنت نیاز دارد؛ اتصال را بررسی کنید.' : e.message;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _lookup() async {
    final String raw = _code.text.trim();
    if (raw.isEmpty) return;
    await _load(<String, dynamic>{'code': normalizeScan(raw) ?? raw});
  }

  String _kind(dynamic k) => k == 'separation' ? 'جداسازی' : (k == 'mix' ? 'مخلوط' : 'خرید');
  String _via(dynamic v) => v == 'mix' ? 'مخلوط' : 'جداسازی';

  List<Widget> _nodes(List<Map<String, dynamic>> nodes, int level) {
    final List<Widget> out = <Widget>[];
    for (final Map<String, dynamic> n in nodes) {
      out.add(Padding(
        padding: EdgeInsetsDirectional.only(start: 14.0 * level),
        child: Card(
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.subdirectory_arrow_left),
            title: Text('${n['type_name'] ?? ''}  •  ${n['code'] ?? '-'}'),
            subtitle: Text('${_via(n['via'])}  •  ${faNum(_d(n['kg']), dec: 3)} کیلو'
                '${n['remaining'] != null ? '  •  مانده ${faNum(_d(n['remaining']), dec: 3)}' : ''}'),
            onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => LotLineageScreen(lotId: _d(n['lot_id']).toInt()))),
          ),
        ),
      ));
      out.addAll(_nodes(ReturnsHelp.maps(n['children']), level + 1));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic>? d = _data;
    final Map<String, dynamic> lot = d != null && d['lot'] is Map ? Map<String, dynamic>.from(d['lot'] as Map) : <String, dynamic>{};
    final List<Map<String, dynamic>> up = d == null ? <Map<String, dynamic>>[] : ReturnsHelp.maps(d['ancestors_tree']);
    final List<Map<String, dynamic>> down = d == null ? <Map<String, dynamic>>[] : ReturnsHelp.maps(d['descendants_tree']);
    return Scaffold(
      appBar: AppBar(title: const Text('ردیابی لات')),
      body: ListView(padding: const EdgeInsets.all(12), children: <Widget>[
        Row(children: <Widget>[
          Expanded(
            child: TextField(
              controller: _code,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(labelText: 'کد پسته (KH… / MX… / K-…)', border: OutlineInputBorder(), isDense: true),
              onSubmitted: (_) => _lookup(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(onPressed: _busy ? null : _lookup, child: const Text('جستجو')),
        ]),
        const SizedBox(height: 8),
        if (_busy) const LinearProgressIndicator(),
        if (_err != null) Padding(padding: const EdgeInsets.all(12), child: Text(_err!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        if (d != null) ...<Widget>[
          Card(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: ListTile(
              title: Text('${lot['type_name'] ?? ''}  •  ${lot['code'] ?? '-'}'),
              subtitle: Text('${_kind(lot['kind'])}  •  ${faNum(_d(lot['net_weight']), dec: 3)} کیلو  •  مانده ${faNum(_d(lot['remaining']), dec: 3)}'),
            ),
          ),
          sectionTitle(context, 'از چه ساخته شده (منشأ)'),
          if (up.isEmpty) const Text('خرید مستقیم است؛ منشأ دیگری ندارد.', style: TextStyle(color: Colors.black54)) else ..._nodes(up, 0),
          sectionTitle(context, 'چه چیزهایی از آن ساخته شده'),
          if (down.isEmpty) const Text('هنوز در مخلوط یا جداسازی دیگری استفاده نشده.', style: TextStyle(color: Colors.black54)) else ..._nodes(down, 0),
        ],
      ]),
    );
  }
}

/// Bottom sheet for a separation output lot (is_mix = 2) in the inventory list.
Future<void> showSeparationLotSheet(BuildContext context, Map<String, dynamic> l) async {
  final String code = '${l['code'] ?? '-'}';
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (BuildContext ctx) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text('${l['category_name']} - ${l['type_name']}', style: Theme.of(ctx).textTheme.titleMedium),
          const Text('محصول جداسازی', style: TextStyle(color: Colors.black54)),
          infoRow('کد ردیابی', code),
          BarcodeBox(code),
          infoRow('وزن این قلم (خالص)', '${faNum(_d(l['net_weight']))} کیلو'),
          infoRow('مانده فعلی (خالص)', '${faNum(_d(l['remaining']))} کیلو'),
          infoRow('گونی کوچک مانده', faNum(_d(l['small_left']))),
          infoRow('گونی بزرگ مانده', faNum(_d(l['large_left']))),
          if (l['ounce'] != null) infoRow('انس', faNum(_d(l['ounce']))),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.push(context, MaterialPageRoute<void>(builder: (_) => LotLineageScreen(lotId: _d(l['id']).toInt())));
            },
            icon: const Icon(Icons.account_tree_outlined),
            label: const Text('ردیابی (منشأ و مشتقات)'),
          ),
          OutlinedButton.icon(
            onPressed: () async {
              final File file = await PdfService.buildStockCard(
                code: code,
                totalWeight: _d(l['total_weight']),
                netWeight: _d(l['net_weight']),
                smallSacks: _d(l['small_sack_count']),
                largeSacks: _d(l['large_sack_count']),
              );
              if (context.mounted) await PdfOutput.show(context, file);
            },
            icon: const Icon(Icons.print_outlined),
            label: const Text('چاپ برچسب A6'),
          ),
        ]),
      ),
    ),
  );
}
