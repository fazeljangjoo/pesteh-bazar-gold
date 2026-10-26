import 'package:flutter/material.dart';

import 'entity_store.dart' show EntityStore;
import 'scan_entry.dart';
import 'stock_count_local.dart';
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException, StockLookup, WhOption;
import 'widgets.dart';

/// S19.T19.1 — stock count (انبارگردانی), both tiers. Server: `stock_count.sheet|save|list|get|delete|approve` (perm stock.view / stock.count).
/// T19.1b: drafts are saved to the local mirror first (stock_count_local) and pushed idempotently by uid; the sheet is cached for offline counting; barcode scan finds the lot;
/// small/large sack counts are optional per line. Approval needs a connection; it writes `adjust` stock moves (kg + sacks) and, in gold, a voucher.

String _kg(dynamic v) => faNum(((v is num) ? v : num.tryParse('${v ?? 0}') ?? 0).toDouble(), dec: 1);
List<Map<String, dynamic>> _sl(dynamic v) => <Map<String, dynamic>>[for (final dynamic e in (v as List<dynamic>? ?? <dynamic>[])) Map<String, dynamic>.from(e as Map)];

class StockCountListScreen extends StatefulWidget {
  const StockCountListScreen({super.key});

  @override
  State<StockCountListScreen> createState() => _StockCountListScreenState();
}

class _StockCountListScreenState extends State<StockCountListScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _local = <Map<String, dynamic>>[]; // drafts not (yet) accepted by the server
  bool _offline = false;

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
      try {
        await StockCountLocal.pushAll();
      } catch (_) {}
      _local = await StockCountLocal.unsynced();
      final Map<String, dynamic> r = await StockApi.call('stock_count.list');
      if (!mounted) return;
      setState(() {
        _items = _sl(r['items']);
        _offline = false;
        _loading = false;
      });
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.network) {
          _offline = true; // show the local drafts only
        } else {
          _error = e.message;
        }
        _loading = false;
      });
    }
  }

  Future<void> _open(int? id, {String? uid}) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => StockCountEditScreen(countId: id, localUid: uid)));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('انبارگردانی', style: TextStyle(fontSize: 16)), actions: <Widget>[IconButton(tooltip: 'تازه‌سازی', onPressed: _load, icon: const Icon(Icons.refresh))]),
        floatingActionButton: FloatingActionButton.extended(onPressed: () => _open(null), icon: const Icon(Icons.add), label: const Text('انبارگردانی جدید')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
                : (_items.isEmpty && _local.isEmpty)
                    ? Center(child: Text(_offline ? 'آفلاین هستید؛ پیش‌نویس محلی وجود ندارد' : 'هنوز انبارگردانی ثبت نشده'))
                    : ListView(children: <Widget>[
                        if (_offline) const ListTile(dense: true, leading: Icon(Icons.cloud_off), title: Text('آفلاین — فقط پیش‌نویس‌های این دستگاه نمایش داده می‌شود')),
                        for (final Map<String, dynamic> c in _local)
                          ListTile(
                            leading: Icon(c['status'] == 'error' ? Icons.error_outline : Icons.cloud_upload_outlined, color: c['status'] == 'error' ? Colors.red : Colors.orange),
                            title: Text('${(c['payload'] as Map<String, dynamic>)['date'] ?? ''}  ·  ${c['status'] == 'error' ? 'رد شده توسط سرور' : 'ارسال‌نشده'}'),
                            subtitle: Text(c['status'] == 'error' ? '${c['error'] ?? ''}' : '${faNum((((c['payload'] as Map<String, dynamic>)['lines'] as List<dynamic>?) ?? <dynamic>[]).length, dec: 0)} قلم · در انتظار اتصال'),
                            onTap: () => _open(c['server_id'] as int?, uid: '${c['uid']}'),
                          ),
                        for (final Map<String, dynamic> c in _items)
                          ListTile(
                            leading: Icon(c['status'] == 'approved' ? Icons.check_circle_outline : Icons.edit_note, color: c['status'] == 'approved' ? Colors.green : null),
                            title: Text('${c['date']}  ·  ${c['status'] == 'approved' ? 'تأییدشده' : 'پیش‌نویس'}'),
                            subtitle: Text('${faNum(((c['lines_count'] as num?) ?? 0).toInt(), dec: 0)} قلم${(c['note'] ?? '') == '' ? '' : ' · ${c['note']}'}'),
                            onTap: () => _open((c['id'] as num).toInt()),
                          ),
                      ]),
      ),
    );
  }
}

class StockCountEditScreen extends StatefulWidget {
  final int? countId;
  final String? localUid;
  const StockCountEditScreen({super.key, this.countId, this.localUid});

  @override
  State<StockCountEditScreen> createState() => _StockCountEditScreenState();
}

class _StockCountEditScreenState extends State<StockCountEditScreen> {
  bool _loading = true;
  bool _busy = false;
  bool _offline = false;
  String? _error;
  int? _id;
  late String _uid;
  bool _approved = false;
  DateTime _date = DateTime.now();
  String? _wh;
  List<WhOption> _whs = <WhOption>[];
  List<Map<String, dynamic>> _lots = <Map<String, dynamic>>[]; // lot_id, label, system_kg, system_small, system_large
  final Map<int, TextEditingController> _counted = <int, TextEditingController>{};
  final Map<int, TextEditingController> _small = <int, TextEditingController>{};
  final Map<int, TextEditingController> _large = <int, TextEditingController>{};
  final Map<int, FocusNode> _focus = <int, FocusNode>{};
  final Map<int, double> _diff = <int, double>{}; // approved counts: stored diff
  final TextEditingController _note = TextEditingController();
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _id = widget.countId;
    _uid = widget.localUid ?? EntityStore.newUid();
    _boot();
  }

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[..._counted.values, ..._small.values, ..._large.values]) {
      c.dispose();
    }
    for (final FocusNode f in _focus.values) {
      f.dispose();
    }
    _note.dispose();
    _search.dispose();
    super.dispose();
  }

  String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  TextEditingController _ctl(int lot) => _counted.putIfAbsent(lot, () => TextEditingController());
  TextEditingController _sctl(int lot) => _small.putIfAbsent(lot, () => TextEditingController());
  TextEditingController _lctl(int lot) => _large.putIfAbsent(lot, () => TextEditingController());
  FocusNode _fn(int lot) => _focus.putIfAbsent(lot, () => FocusNode());

  String _txt(dynamic v) => v == null ? '' : '$v';

  /// Fill the line fields from a list of {lot_id, counted_kg, counted_small?, counted_large?}; existing text is kept.
  void _fill(List<Map<String, dynamic>> lines, {bool overwrite = false}) {
    for (final Map<String, dynamic> l in lines) {
      final int lot = (l['lot_id'] as num).toInt();
      if (overwrite || _ctl(lot).text.isEmpty) _ctl(lot).text = _txt(l['counted_kg']);
      if (overwrite || _sctl(lot).text.isEmpty) _sctl(lot).text = _txt(l['counted_small']);
      if (overwrite || _lctl(lot).text.isEmpty) _lctl(lot).text = _txt(l['counted_large']);
    }
  }

  Future<void> _boot() async {
    try {
      try {
        _whs = await StockLookup.warehouses();
      } catch (_) {
        _whs = <WhOption>[]; // offline: warehouse filter unavailable
      }
      Map<String, dynamic>? saved;
      Map<String, dynamic>? local;
      if (widget.localUid != null) local = await StockCountLocal.byUid(widget.localUid!);
      else if (_id != null) {
        final Map<String, dynamic>? l = await StockCountLocal.byServerId(_id!);
        if (l != null && l['status'] != 'synced') local = l;
      }
      if (local != null) {
        final Map<String, dynamic> p = local['payload'] as Map<String, dynamic>;
        _uid = '${local['uid']}';
        _id = local['server_id'] as int? ?? _id;
        _date = DateTime.tryParse('${p['date']}') ?? _date;
        _wh = p['warehouse_uid'] as String?;
        _note.text = '${p['note'] ?? ''}';
        saved = <String, dynamic>{'lines': p['lines'] ?? <dynamic>[]};
        if (local['status'] == 'error') _error = '${local['error'] ?? ''}';
      } else if (_id != null) {
        try {
          saved = await StockApi.call('stock_count.get', <String, dynamic>{'id': _id});
          _uid = '${saved['uid'] ?? _uid}';
          _approved = saved['status'] == 'approved';
          _date = DateTime.tryParse('${saved['date']}') ?? _date;
          _wh = saved['warehouse_uid'] as String?;
          _note.text = '${saved['note'] ?? ''}';
        } on StockApiException catch (e) {
          if (!e.network) rethrow;
          _offline = true;
          _error = 'برای مشاهدهٔ این انبارگردانی باید آنلاین باشید';
        }
      }
      if (_approved && saved != null) {
        _lots = <Map<String, dynamic>>[
          for (final Map<String, dynamic> l in _sl(saved['lines']))
            <String, dynamic>{'lot_id': l['lot_id'], 'label': '${l['code']} ${l['type_name']}'.trim(), 'system_kg': l['system_kg'], 'system_small': l['system_small'], 'system_large': l['system_large']}
        ];
        for (final Map<String, dynamic> l in _sl(saved['lines'])) {
          final int lot = (l['lot_id'] as num).toInt();
          _ctl(lot).text = '${l['counted_kg']}';
          _sctl(lot).text = _txt(l['counted_small']);
          _lctl(lot).text = _txt(l['counted_large']);
          _diff[lot] = ((l['diff_kg'] as num?) ?? 0).toDouble();
        }
      } else {
        await _loadSheet(saved);
      }
      if (!mounted) return;
      setState(() => _loading = false);
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  /// Sheet from the server (and cached); offline → last cached sheet of the same warehouse.
  Future<void> _loadSheet(Map<String, dynamic>? saved) async {
    List<Map<String, dynamic>> items;
    try {
      final Map<String, dynamic> r = await StockApi.call('stock_count.sheet', <String, dynamic>{if (_wh != null) 'warehouse_uid': _wh});
      items = _sl(r['items']);
      _offline = false;
      await StockCountLocal.cacheSheet(_wh, items);
    } on StockApiException catch (e) {
      if (!e.network) rethrow;
      final List<Map<String, dynamic>>? c = await StockCountLocal.cachedSheet(_wh);
      if (c == null) throw StockApiException('آفلاین هستید و برگهٔ شمارش قبلاً دانلود نشده است');
      items = c;
      _offline = true;
    }
    _lots = <Map<String, dynamic>>[
      for (final Map<String, dynamic> l in items)
        <String, dynamic>{
          'lot_id': l['lot_id'],
          'label': '${l['code'] ?? ''} ${l['type_name'] ?? ''}${l['ounce'] == null ? '' : ' · اونس ${l['ounce']}'}'.trim(),
          'code': '${l['code'] ?? ''}',
          'system_kg': l['system_kg'],
          'system_small': l['system_small'],
          'system_large': l['system_large'],
        }
    ];
    if (saved != null) _fill(_sl(saved['lines']));
  }

  double? _num(TextEditingController? c) {
    final String t = toEnDigits(c?.text.trim() ?? '');
    if (t.isEmpty) return null;
    return double.tryParse(t);
  }

  List<Map<String, dynamic>> _lines() {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> l in _lots) {
      final int lot = (l['lot_id'] as num).toInt();
      final double? v = _num(_counted[lot]);
      if (v == null) continue;
      final double? s = _num(_small[lot]);
      final double? g = _num(_large[lot]);
      out.add(<String, dynamic>{'lot_id': lot, 'counted_kg': v, if (s != null) 'counted_small': s, if (g != null) 'counted_large': g});
    }
    return out;
  }

  /// Local save first (never loses the count), then an idempotent push. Returns false only on a validation / server refusal.
  Future<bool> _save({bool needOnline = false}) async {
    final List<Map<String, dynamic>> lines = _lines();
    if (lines.isEmpty) {
      snack(context, 'وزن حداقل یک قلم را وارد کنید');
      return false;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await StockCountLocal.saveDraft(_uid, <String, dynamic>{'date': _iso(_date), if (_wh != null) 'warehouse_uid': _wh, 'note': _note.text.trim(), 'lines': lines}, serverId: _id);
      final Map<String, dynamic>? r = await StockCountLocal.push(_uid);
      if (!mounted) return false;
      if (r == null) {
        setState(() {
          _offline = true;
          _busy = false;
          if (needOnline) _error = 'برای این کار باید آنلاین باشید؛ پیش‌نویس روی دستگاه ذخیره شد';
        });
        if (!needOnline) snack(context, 'آفلاین ذخیره شد؛ با اتصال به اینترنت ارسال می‌شود');
        return !needOnline;
      }
      setState(() {
        _id = (r['id'] as num).toInt();
        _offline = false;
        _busy = false;
      });
      return true;
    } on StockApiException catch (e) {
      if (!mounted) return false;
      setState(() {
        _error = e.message;
        _busy = false;
      });
      return false;
    }
  }

  Future<void> _scan() async {
    final String? code = await scanBarcode(context);
    if (code == null || !mounted) return;
    final List<Map<String, dynamic>> hit = <Map<String, dynamic>>[for (final Map<String, dynamic> l in _lots) if ('${l['code'] ?? ''}'.toUpperCase() == code.toUpperCase()) l];
    if (hit.isEmpty) {
      snack(context, 'قلمی با کد $code در این برگه نیست');
      return;
    }
    setState(() => _search.text = code);
    final int lot = (hit.first['lot_id'] as num).toInt();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fn(lot).requestFocus();
    });
  }

  Future<void> _approve() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('تأیید انبارگردانی'),
          content: const Text('با تأیید، موجودی هر قلم (کیلو و در صورت شمارش، گونی‌ها) برابر مقدار شمارش‌شده می‌شود و (در نسخه طلایی) سند اختلاف ثبت می‌گردد. این کار برگشت‌پذیر نیست.'),
          actions: <Widget>[TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('انصراف')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('تأیید'))],
        ),
      ),
    );
    if (ok != true) return;
    if (!await _save(needOnline: true)) return;
    setState(() => _busy = true);
    try {
      await StockApi.call('stock_count.approve', <String, dynamic>{'id': _id});
      await StockCountLocal.remove(_uid);
      if (!mounted) return;
      snack(context, 'انبارگردانی تأیید شد');
      Navigator.of(context).pop();
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  Widget _numBox(TextEditingController c, String label, {FocusNode? node, double width = 100}) => SizedBox(
        width: width,
        child: TextField(
          controller: c,
          focusNode: node,
          enabled: !_approved,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: label, isDense: true),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final String q = _search.text.trim();
    final List<Map<String, dynamic>> shown = <Map<String, dynamic>>[for (final Map<String, dynamic> l in _lots) if (q.isEmpty || '${l['label']}'.contains(q)) l];
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_approved ? 'انبارگردانی تأییدشده' : 'برگه انبارگردانی', style: const TextStyle(fontSize: 16)),
          actions: <Widget>[
            if (_offline) const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Icon(Icons.cloud_off, size: 20)),
            if (!_approved) IconButton(tooltip: 'اسکن بارکد', onPressed: _busy || _loading ? null : _scan, icon: const Icon(Icons.qr_code_scanner)),
            if (!_approved) IconButton(tooltip: 'ذخیره پیش‌نویس', onPressed: _busy || _loading ? null : () async { if (await _save() && mounted && !_offline) snack(context, 'ذخیره شد'); }, icon: const Icon(Icons.save_outlined)),
            if (!_approved) IconButton(tooltip: 'تأیید نهایی (آنلاین)', onPressed: _busy || _loading ? null : _approve, icon: const Icon(Icons.done_all)),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(children: <Widget>[
                if (_busy) const LinearProgressIndicator(),
                if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: const TextStyle(color: Colors.red))),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: <Widget>[
                    OutlinedButton(
                      onPressed: _approved ? null : () async {
                        final DateTime? d = await pickDate(context, initial: _date);
                        if (d != null) setState(() => _date = d);
                      },
                      child: Text(jalaliDateFromDt(_date)),
                    ),
                    DropdownButton<String?>(
                      value: _wh,
                      hint: const Text('همه انبارها'),
                      items: <DropdownMenuItem<String?>>[
                        const DropdownMenuItem<String?>(value: null, child: Text('همه انبارها')),
                        for (final WhOption w in _whs) DropdownMenuItem<String?>(value: w.uid, child: Text(w.name)),
                      ],
                      onChanged: _approved ? null : (String? v) async {
                        setState(() {
                          _wh = v;
                          _loading = true;
                        });
                        try {
                          await _loadSheet(null);
                          _error = null;
                        } on StockApiException catch (e) {
                          _error = e.message;
                        }
                        if (mounted) setState(() => _loading = false);
                      },
                    ),
                    SizedBox(width: 180, child: TextField(controller: _note, enabled: !_approved, decoration: const InputDecoration(labelText: 'یادداشت', isDense: true))),
                    SizedBox(width: 160, child: TextField(controller: _search, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'جست‌وجوی قلم / کد', isDense: true, prefixIcon: Icon(Icons.search)))),
                  ]),
                ),
                Expanded(
                  child: shown.isEmpty
                      ? const Center(child: Text('کالایی برای شمارش نیست'))
                      : ListView(children: <Widget>[
                          for (final Map<String, dynamic> l in shown)
                            Builder(builder: (BuildContext _) {
                              final int lot = (l['lot_id'] as num).toInt();
                              final double? d = _approved ? _diff[lot] : null;
                              return Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                                  Text('${l['label']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                                  Text('سیستم: ${_kg(l['system_kg'])} کیلو · گونی کوچک ${_kg(l['system_small'])} · بزرگ ${_kg(l['system_large'])}${d == null ? '' : ' · اختلاف: ${_kg(d)}'}', style: const TextStyle(fontSize: 12)),
                                  const SizedBox(height: 4),
                                  Wrap(spacing: 8, children: <Widget>[
                                    _numBox(_ctl(lot), 'شمارش (کیلو)', node: _fn(lot), width: 120),
                                    _numBox(_sctl(lot), 'گونی کوچک', width: 90),
                                    _numBox(_lctl(lot), 'گونی بزرگ', width: 90),
                                  ]),
                                  const Divider(height: 12),
                                ]),
                              );
                            }),
                        ]),
                ),
              ]),
      ),
    );
  }
}
