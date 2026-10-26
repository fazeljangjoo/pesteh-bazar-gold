import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'vouchers_links.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'db.dart';
import 'perms.dart';
import 'pdf_output.dart';
import 'pdf_service.dart';
import 'returns_ui.dart' show ReturnsHelp;
import 'sync_service.dart';
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException, StockLookup, WhOption;

/// S09.T09.3 — processing screens (فراوری): paid (برون‌سپاری) and received (فراوری امانی).
/// Server: processing.list/get/create/receive/deliver/delete, reports.* (api/processing.php).
/// Offline: create / receive / deliver / delete are queued (SharedPreferences, strictly ordered, idempotent via `uid`)
/// and replayed in order on the next load. The last list is cached for offline viewing.
/// Permissions: list/get → stock.view, create → processing.create, receive/deliver/delete → processing.manage.

const String kProcPaid = 'paid';
const String kProcReceived = 'received';

const Map<String, String> _services = <String, String>{
  'hulling': 'پوست‌گیری',
  'drying': 'خشک‌کردن',
  'sorting': 'دسته‌بندی',
  'splitting': 'مغزگیری / تفکیک',
  'other': 'سایر',
};

const Map<String, String> _feeBasis = <String, String>{
  'per_kg': 'هر کیلو',
  'fixed': 'مبلغ ثابت',
  'per_job': 'هر کار',
};

String _en(String s) {
  const String fa = '۰۱۲۳۴۵۶۷۸۹';
  const String ar = '٠١٢٣٤٥٦٧٨٩';
  final StringBuffer b = StringBuffer();
  for (final int c in s.runes) {
    final String ch = String.fromCharCode(c);
    final int fi = fa.indexOf(ch);
    final int ai = ar.indexOf(ch);
    if (fi >= 0) {
      b.write(fi);
    } else if (ai >= 0) {
      b.write(ai);
    } else if (ch == '٫') {
      b.write('.');
    } else if (ch == '٬' || ch == ',') {
      // thousands separator
    } else {
      b.write(ch);
    }
  }
  return b.toString();
}

double _numText(String s) => double.tryParse(_en(s).trim()) ?? 0.0;
double _n(dynamic v) => ReturnsHelp.d(v);
String _kg(dynamic v) => faNum(_n(v), dec: 3);
String _money(dynamic v) => faNum(_n(v), dec: 0);
bool _can(String key) => StaffPerms.I.can(key);

String _statusLabel(String s) {
  switch (s) {
    case 'in_progress':
      return 'در جریان';
    case 'done':
      return 'دریافت‌شده';
    case 'closed':
      return 'تحویل‌شده';
    default:
      return s;
  }
}

/// Queue + cache for processing writes.
class ProcessingStore {
  ProcessingStore._();
  static const String _kOps = 'proc_ops_v1';
  static const String _kList = 'proc_list_v1';

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

  static Future<void> cacheList(List<Map<String, dynamic>> items) async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    await sp.setString(_kList, jsonEncode(items));
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

  static bool isNetworkError(String m) => m.contains('اتصال به سرور') || m.contains('خطای سرور');

  /// Online-first write. A network failure queues the op (returns true); other server errors are rethrown.
  static Future<bool> write(String action, Map<String, dynamic> payload, String label) async {
    try {
      await StockApi.call(action, payload);
    } on StockApiException catch (e) {
      if (!isNetworkError(e.message)) rethrow;
      final List<Map<String, dynamic>> ops = await pendingOps();
      ops.add(<String, dynamic>{'uid': payload['uid'] ?? payload['id'], 'action': action, 'payload': payload, 'label': label});
      await _saveOps(ops);
      return true;
    }
    SyncService.I.syncNow(pull: true);
    return false;
  }

  /// Replays queued writes in order; stops at the first network failure, drops server-rejected ops and reports them.
  static Future<List<String>> flush() async {
    final List<String> errors = <String>[];
    List<Map<String, dynamic>> ops = await pendingOps();
    bool sentAny = false;
    while (ops.isNotEmpty) {
      final Map<String, dynamic> op = ops.first;
      try {
        final dynamic payload = op['payload'];
        await StockApi.call('${op['action']}', payload is Map ? Map<String, dynamic>.from(payload) : <String, dynamic>{});
        sentAny = true;
      } on StockApiException catch (e) {
        if (isNetworkError(e.message) || e.message.contains('ورود مجدد')) break;
        errors.add('${op['label'] ?? ''}: ${e.message}');
      }
      ops = ops.sublist(1);
      await _saveOps(ops);
    }
    if (sentAny) SyncService.I.syncNow(pull: true);
    return errors;
  }
}

// ---------------------------------------------------------------------------
// List
// ---------------------------------------------------------------------------

class ProcessingScreen extends StatefulWidget {
  const ProcessingScreen({super.key});

  @override
  State<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends State<ProcessingScreen> {
  String _dir = kProcPaid;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _queued = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final List<String> flushErrors = await ProcessingStore.flush();
    _queued = await ProcessingStore.pendingOps();
    String? error;
    List<Map<String, dynamic>> items;
    try {
      final Map<String, dynamic> r = await StockApi.call('processing.list');
      items = ReturnsHelp.maps(r['items']);
      await ProcessingStore.cacheList(items);
    } on StockApiException catch (e) {
      error = e.message;
      items = await ProcessingStore.cachedList();
    }
    if (!mounted) return;
    setState(() {
      _items = items;
      _error = error ?? (flushErrors.isEmpty ? null : flushErrors.join('\n'));
      _loading = false;
    });
  }

  Future<void> _open(Widget page) async {
    final Object? changed = await Navigator.push(context, MaterialPageRoute<Object>(builder: (_) => page));
    if (changed != null) _load();
  }

  @override
  Widget build(BuildContext context) {
    final List<Map<String, dynamic>> visible =
        _items.where((Map<String, dynamic> o) => '${o['direction']}' == _dir).toList();
    final List<Map<String, dynamic>> queued = _queued.where((Map<String, dynamic> o) => '${o['label']}'.isNotEmpty).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('فراوری'),
        actions: <Widget>[IconButton(tooltip: 'به‌روزرسانی', icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      floatingActionButton: _can('processing.create')
          ? FloatingActionButton.extended(
              onPressed: () => _open(ProcessingFormScreen(direction: _dir)),
              icon: const Icon(Icons.add),
              label: Text(_dir == kProcPaid ? 'سفارش برون‌سپاری' : 'سفارش فراوری امانی'),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
          children: <Widget>[
            Wrap(
              spacing: 8,
              children: <Widget>[
                ChoiceChip(
                  label: const Text('برون‌سپاری (کالای ما نزد فراوری‌کننده)'),
                  selected: _dir == kProcPaid,
                  onSelected: (_) => setState(() => _dir = kProcPaid),
                ),
                ChoiceChip(
                  label: const Text('فراوری امانی (کالای مشتری نزد ما)'),
                  selected: _dir == kProcReceived,
                  onSelected: (_) => setState(() => _dir = kProcReceived),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_error != null)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(padding: const EdgeInsets.all(10), child: Text(_error!)),
              ),
            if (_loading) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
            for (final Map<String, dynamic> o in queued)
              ListTile(
                leading: const Icon(Icons.cloud_upload_outlined),
                title: Text('${o['label']}'),
                subtitle: const Text('در صف ارسال؛ پس از اتصال به اینترنت ارسال می‌شود'),
              ),
            if (!_loading && visible.isEmpty)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('سفارشی ثبت نشده است'))),
            for (final Map<String, dynamic> o in visible) _tile(o),
          ],
        ),
      ),
    );
  }

  Widget _tile(Map<String, dynamic> o) {
    final bool rec = '${o['direction']}' == kProcReceived;
    final String info = rec
        ? 'ورودی ${_kg(o['input_kg'])} · خروجی ${_kg(o['output_kg'])} · ضایعات ${_kg(o['waste_kg'])} کیلو · مطالبه ${_money(o['charge_amount'])}'
        : 'ورودی ${_kg(o['input_kg'])} · خروجی ${_kg(o['output_kg'])} · ضایعات ${_kg(o['waste_kg'])} کیلو · کرایه ${_money(o['fee_amount'])}';
    final String yieldText = o['yield_pct'] == null ? '' : '  •  بازدهی ${faNum(_n(o['yield_pct']), dec: 1)}٪';
    return Card(
      child: ListTile(
        leading: Icon(rec ? Icons.call_received : Icons.call_made),
        title: Text('${o['party']}  •  ${_statusLabel('${o['status']}')}'),
        subtitle: Text('${jalaliDate('${o['date']}')}$yieldText\n$info'),
        isThreeLine: true,
        onTap: () => _open(ProcessingDetailScreen(id: _n(o['id']).toInt())),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Create (both directions) with live fee / mass hints
// ---------------------------------------------------------------------------

class _ProcLine {
  final TextEditingController name = TextEditingController();
  final TextEditingController kg = TextEditingController();
  final TextEditingController small = TextEditingController(text: '0');
  final TextEditingController large = TextEditingController(text: '0');
  String? lotLocalId; // paid: our lot (local id)
  void dispose() {
    name.dispose();
    kg.dispose();
    small.dispose();
    large.dispose();
  }
}

class ProcessingFormScreen extends StatefulWidget {
  final String direction;
  const ProcessingFormScreen({super.key, required this.direction});

  @override
  State<ProcessingFormScreen> createState() => _ProcessingFormScreenState();
}

class _ProcessingFormScreenState extends State<ProcessingFormScreen> {
  final TextEditingController _party = TextEditingController();
  final TextEditingController _note = TextEditingController();
  final TextEditingController _fee = TextEditingController(text: '0');
  final TextEditingController _std = TextEditingController(text: '100');
  final TextEditingController _wcharge = TextEditingController(text: '0');
  final TextEditingController _date = TextEditingController(text: ReturnsHelp.iso(DateTime.now()));
  final List<_ProcLine> _lines = <_ProcLine>[_ProcLine()];
  String _service = 'other';
  String _basis = 'per_kg';
  String? _wh;
  List<WhOption> _whs = <WhOption>[];
  Map<String, String> _lots = <String, String>{};
  bool _saving = false;

  bool get _paid => widget.direction == kProcPaid;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    if (_paid) {
      final List<Map<String, dynamic>> rows = await AppDb.I.inventoryAll();
      final Map<String, String> lots = <String, String>{};
      for (final Map<String, dynamic> r in rows) {
        if (_n(r['is_mix']) != 0 || _n(r['remaining']) <= 0) continue;
        lots['${r['id']}'] = '${r['code'] ?? ''} · ${r['type_name'] ?? ''} · ${_kg(r['remaining'])} کیلو';
      }
      if (mounted) setState(() => _lots = lots);
    } else {
      final List<WhOption> whs = await StockLookup.warehouses();
      if (!mounted) return;
      setState(() {
        _whs = whs;
        _wh = whs.isEmpty ? null : (whs.where((WhOption w) => w.isDefault).isNotEmpty ? whs.firstWhere((WhOption w) => w.isDefault).uid : whs.first.uid);
      });
    }
  }

  @override
  void dispose() {
    _party.dispose();
    _note.dispose();
    _fee.dispose();
    _std.dispose();
    _wcharge.dispose();
    _date.dispose();
    for (final _ProcLine l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  double get _inKg => _lines.fold<double>(0.0, (double s, _ProcLine l) => s + _numText(l.kg.text));

  double get _feeEstimate {
    final double v = _numText(_fee.text);
    return _basis == 'per_kg' ? v * _inKg : v;
  }

  Future<void> _submit() async {
    final String party = _party.text.trim();
    if (party.isEmpty) return _snack('نام طرف حساب را وارد کنید');
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(_en(_date.text.trim()))) return _snack('تاریخ را به صورت yyyy-mm-dd وارد کنید');
    final double std = _numText(_std.text);
    if (std <= 0 || std > 100) return _snack('بازدهی استاندارد باید بین ۰ و ۱۰۰ باشد');
    setState(() => _saving = true);
    try {
      final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
      for (final _ProcLine l in _lines) {
        final double kg = _numText(l.kg.text);
        if (kg <= 0) return _snack('وزن هر ورودی باید بیشتر از صفر باشد');
        final Map<String, dynamic> it = <String, dynamic>{
          'kg': kg,
          'small_sacks': _numText(l.small.text),
          'large_sacks': _numText(l.large.text),
        };
        if (_paid) {
          if (l.lotLocalId == null) return _snack('برای هر ورودی لات انبار را انتخاب کنید');
          it['purchase_id'] = await ReturnsHelp.serverId('purchase', int.parse(l.lotLocalId!));
        } else {
          if (l.name.text.trim().isEmpty) return _snack('نوع کالای هر ورودی را وارد کنید');
          it['type_name'] = l.name.text.trim();
        }
        items.add(it);
      }
      final Map<String, dynamic> payload = <String, dynamic>{
        'uid': ReturnsHelp.newUid('proc'),
        'direction': widget.direction,
        'party': party,
        'date': _en(_date.text.trim()),
        'service': _service,
        'fee_basis': _basis,
        'fee_value': _numText(_fee.text),
        'standard_yield_pct': std,
        'waste_charge_per_kg': _paid ? 0 : _numText(_wcharge.text),
        'note': _note.text.trim(),
        'items': items,
      };
      if (!_paid && _wh != null) payload['warehouse_uid'] = _wh;
      final bool queued = await ProcessingStore.write('processing.create', payload, '${_paid ? 'برون‌سپاری' : 'فراوری امانی'}: $party');
      if (!mounted) return;
      _snack(queued ? 'آفلاین ذخیره شد؛ پس از اتصال ارسال می‌شود' : 'ثبت شد');
      Navigator.pop(context, true);
    } on StockApiException catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('خطا: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool hintOk = _basis == 'per_kg' || _basis == 'fixed' || _basis == 'per_job';
    return Scaffold(
      appBar: AppBar(title: Text(_paid ? 'برون‌سپاری فراوری' : 'فراوری امانی')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: <Widget>[
          TextField(
            controller: _party,
            decoration: InputDecoration(labelText: _paid ? 'فراوری‌کننده' : 'مشتری (صاحب کالا)', border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _date,
                  decoration: const InputDecoration(labelText: 'تاریخ (yyyy-mm-dd)', border: OutlineInputBorder()),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _service,
                  decoration: const InputDecoration(labelText: 'نوع خدمت', border: OutlineInputBorder()),
                  items: <DropdownMenuItem<String>>[
                    for (final MapEntry<String, String> e in _services.entries) DropdownMenuItem<String>(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (String? v) => setState(() => _service = v ?? 'other'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _basis,
                  decoration: const InputDecoration(labelText: 'روش کرایه', border: OutlineInputBorder()),
                  items: <DropdownMenuItem<String>>[
                    for (final MapEntry<String, String> e in _feeBasis.entries) DropdownMenuItem<String>(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (String? v) => setState(() => _basis = v ?? 'per_kg'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _fee,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(labelText: _basis == 'per_kg' ? 'کرایه هر کیلو' : 'مبلغ کرایه', border: const OutlineInputBorder()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _std,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(labelText: 'بازدهی استاندارد ٪', border: OutlineInputBorder()),
                ),
              ),
              if (!_paid) ...<Widget>[
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _wcharge,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'نرخ ضایعات (هر کیلو)', border: OutlineInputBorder()),
                  ),
                ),
              ],
            ],
          ),
          if (!_paid) ...<Widget>[
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              value: _wh,
              decoration: const InputDecoration(labelText: 'انبار محل نگهداری', border: OutlineInputBorder()),
              items: <DropdownMenuItem<String>>[
                for (final WhOption w in _whs) DropdownMenuItem<String>(value: w.uid, child: Text(w.name)),
              ],
              onChanged: (String? v) => setState(() => _wh = v),
            ),
          ],
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'ورودی: ${faNum(_inKg, dec: 3)} کیلو  •  ${hintOk ? 'کرایه تخمینی: ${faNum(_feeEstimate, dec: 0)}' : ''}\n'
                'بازدهی استاندارد: ${faNum(_numText(_std.text), dec: 1)}٪  —  خروجی و ضایعات بعد از دریافت ثبت می‌شود.',
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text('ورودی‌ها', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          for (int i = 0; i < _lines.length; i++) _lineCard(i),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => setState(() => _lines.add(_ProcLine())),
              icon: const Icon(Icons.add),
              label: const Text('افزودن ورودی'),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _note,
            decoration: const InputDecoration(labelText: 'یادداشت', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _saving ? null : _submit,
            icon: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_outlined),
            label: const Text('ثبت سفارش'),
          ),
        ],
      ),
    );
  }

  Widget _lineCard(int i) {
    final _ProcLine l = _lines[i];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          children: <Widget>[
            if (_paid)
              DropdownButtonFormField<String>(
                value: l.lotLocalId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'لات انبار', border: OutlineInputBorder()),
                items: <DropdownMenuItem<String>>[
                  for (final MapEntry<String, String> e in _lots.entries)
                    DropdownMenuItem<String>(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (String? v) => setState(() => l.lotLocalId = v),
              )
            else
              TextField(
                controller: l.name,
                decoration: const InputDecoration(labelText: 'نوع کالا', border: OutlineInputBorder()),
              ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: l.kg,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'کیلو', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: l.small,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'گونی کوچک', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: l.large,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'گونی بزرگ', border: OutlineInputBorder()),
                  ),
                ),
              ],
            ),
            if (_lines.length > 1)
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: IconButton(
                  tooltip: 'حذف ورودی',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => setState(() {
                    _lines.removeAt(i).dispose();
                  }),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Detail: status, mass balance, yield, fees; actions by status
// ---------------------------------------------------------------------------

class ProcessingDetailScreen extends StatefulWidget {
  final int id;
  const ProcessingDetailScreen({super.key, required this.id});

  @override
  State<ProcessingDetailScreen> createState() => _ProcessingDetailScreenState();
}

class _ProcessingDetailScreenState extends State<ProcessingDetailScreen> {
  bool _loading = true;
  String? _error;
  bool _changed = false;
  Map<String, dynamic> _d = <String, dynamic>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final Map<String, dynamic> r = await StockApi.call('processing.get', <String, dynamic>{'id': widget.id});
      if (!mounted) return;
      setState(() {
        _d = r;
        _error = null;
        _loading = false;
      });
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  bool get _rec => '${_d['direction']}' == kProcReceived;
  bool get _open => '${_d['status']}' == 'in_progress';

  Future<void> _run(String action, Map<String, dynamic> payload, String label) async {
    try {
      final bool queued = await ProcessingStore.write(action, payload, label);
      _changed = true;
      _snack(queued ? 'آفلاین ذخیره شد؛ پس از اتصال ارسال می‌شود' : 'ثبت شد');
      if (!queued) await _load();
    } on StockApiException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _receive() async {
    final bool? ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute<bool>(builder: (_) => ProcessingReceivePage(order: _d)),
    );
    if (ok == true) {
      _changed = true;
      await _load();
    }
  }

  Future<void> _deliver() async {
    await _run('processing.deliver', <String, dynamic>{
      'id': widget.id,
      'uid': ReturnsHelp.newUid('pdel'),
      'date': ReturnsHelp.iso(DateTime.now()),
    }, 'تحویل فراوری امانی: ${_d['party'] ?? ''}');
  }

  Future<void> _delete() async {
    final bool ok = await showDialog<bool>(
          context: context,
          builder: (BuildContext ctx) => AlertDialog(
            title: const Text('حذف سفارش؟'),
            content: const Text('کالا به موجودی برمی‌گردد و سفارش حذف می‌شود.'),
            actions: <Widget>[
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('حذف')),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    try {
      await StockApi.call('processing.delete', <String, dynamic>{'id': widget.id});
      SyncService.I.syncNow(pull: true);
      if (!mounted) return;
      Navigator.pop(context, true);
    } on StockApiException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _print({required bool fee}) async {
    final List<dynamic> ins = (_d['inputs'] is List) ? (_d['inputs'] as List<dynamic>) : <dynamic>[];
    final List<dynamic> outs = (_d['outputs'] is List) ? (_d['outputs'] as List<dynamic>) : <dynamic>[];
    final File file;
    if (fee) {
      file = await PdfService.buildTableReport(
        title: 'پیش‌فاکتور کرایه فراوری',
        subtitle: '${_d['party'] ?? ''}  •  ${jalaliDate('${_d['date'] ?? ''}')}',
        kv: <List<String>>[
          <String>['کرایه (${_feeBasis[_d['fee_basis']] ?? ''})', _money(_d['fee_amount'])],
          if (_rec) <String>['ضایعات (کیلو)', _kg(_d['waste_kg'])],
          if (_rec) <String>['مطالبه کل', _money(_d['charge_amount'])],
        ],
        headers: const <String>['شرح', 'مبلغ'],
        rows: <List<String>>[
          <String>[_rec ? 'فراوری امانی' : 'فراوری برون‌سپاری', _money(_rec ? _d['charge_amount'] : _d['fee_amount'])],
        ],
        filePrefix: 'processing_fee',
      );
    } else {
      file = await PdfService.buildTableReport(
        title: _rec ? 'برگه کار فراوری امانی' : 'برگه کار برون‌سپاری',
        subtitle: '${_d['party'] ?? ''}  •  ${jalaliDate('${_d['date'] ?? ''}')}',
        kv: <List<String>>[
          <String>['وضعیت', _statusLabel('${_d['status'] ?? ''}')],
          <String>['بازدهی استاندارد ٪', faNum(_n(_d['standard_yield_pct']), dec: 1)],
          if (_d['yield_pct'] != null) <String>['بازدهی واقعی ٪', faNum(_n(_d['yield_pct']), dec: 1)],
        ],
        headers: const <String>['کد', 'نوع', 'ورودی (کیلو)', 'خروجی (کیلو)'],
        rows: <List<String>>[
          for (final dynamic x in ins)
            if (x is Map) <String>['${x['code'] ?? ''}', '${x['type_name'] ?? ''}', _kg(x['kg']), ''],
          for (final dynamic x in outs)
            if (x is Map) <String>['${x['code'] ?? ''}', '${x['type_name'] ?? ''}', '', _kg(x['kg'])],
        ],
        filePrefix: 'processing_order',
      );
    }
    if (!mounted) return;
    await PdfOutput.show(context, file);
  }

  @override
  Widget build(BuildContext context) {
    final bool canManage = _can('processing.manage');
    return WillPopScope(
      onWillPop: () async {
        Navigator.pop(context, _changed ? true : null);
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_d['party'] == null ? 'سفارش فراوری' : '${_d['party']}'),
          actions: <Widget>[
            if (_d.isNotEmpty) IconButton(tooltip: 'برگه کار', icon: const Icon(Icons.print_outlined), onPressed: () => _print(fee: false)),
            if (_d.isNotEmpty) IconButton(tooltip: 'پیش‌فاکتور کرایه', icon: const Icon(Icons.receipt_outlined), onPressed: () => _print(fee: true)),
            if (_d['deletable'] == true && canManage) IconButton(tooltip: 'حذف', icon: const Icon(Icons.delete_outline), onPressed: _delete),
          ],
        ),
        body: _loading && _d.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.all(14),
                  children: <Widget>[
                    if (widget.id > 0 && _rec) VoucherLinkButton(sourceType: 'proc_toll', sourceId: '${widget.id}'),
                    if (widget.id > 0 && !_rec) ...<Widget>[
                      VoucherLinkButton(sourceType: 'proc_send', sourceId: '${widget.id}', label: 'سند ارسال'),
                      VoucherLinkButton(sourceType: 'proc_recv', sourceId: '${widget.id}', label: 'سند دریافت'),
                    ], // T16.7
                    if (_error != null)
                      Card(
                        color: Theme.of(context).colorScheme.errorContainer,
                        child: Padding(padding: const EdgeInsets.all(10), child: Text(_error!)),
                      ),
                    if (_d.isNotEmpty) ...<Widget>[
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text('${_rec ? 'مشتری' : 'فراوری‌کننده'}: ${_d['party'] ?? ''}'),
                              Text('تاریخ: ${jalaliDate('${_d['date'] ?? ''}')}'),
                              Text('وضعیت: ${_statusLabel('${_d['status'] ?? ''}')}'),
                              Text('کرایه (${_feeBasis[_d['fee_basis']] ?? ''}): ${_money(_d['fee_amount'])}'),
                              if (_rec) Text('مطالبه از مشتری: ${_money(_d['charge_amount'])}'),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      _massCard(),
                      const SizedBox(height: 8),
                      Text('ورودی‌ها', style: Theme.of(context).textTheme.titleMedium),
                      for (final dynamic x in (_d['inputs'] is List ? _d['inputs'] as List<dynamic> : <dynamic>[]))
                        if (x is Map)
                          ListTile(
                            dense: true,
                            title: Text('${x['code'] ?? ''}  ${x['type_name'] ?? ''}'),
                            subtitle: Text('${_kg(x['kg'])} کیلو${x['cost'] != null ? '  •  بهای تمام‌شده ${_money(x['cost'])}' : ''}'),
                          ),
                      if ((_d['outputs'] is List) && (_d['outputs'] as List<dynamic>).isNotEmpty) ...<Widget>[
                        const SizedBox(height: 8),
                        Text('خروجی‌ها', style: Theme.of(context).textTheme.titleMedium),
                        for (final dynamic x in (_d['outputs'] as List<dynamic>))
                          if (x is Map)
                            ListTile(
                              dense: true,
                              title: Text('${x['code'] ?? ''}  ${x['type_name'] ?? ''}'),
                              subtitle: Text('${_kg(x['kg'])} کیلو${_rec ? '' : '  •  بهای تمام‌شده ${_money(x['cost'])}'}'),
                            ),
                      ],
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <Widget>[
                          if (canManage && _open)
                            FilledButton.icon(
                              onPressed: _receive,
                              icon: const Icon(Icons.inventory_2_outlined),
                              label: const Text('دریافت خروجی'),
                            ),
                          if (canManage && _rec && '${_d['status']}' == 'done')
                            OutlinedButton.icon(
                              onPressed: _deliver,
                              icon: const Icon(Icons.local_shipping_outlined),
                              label: const Text('تحویل به مشتری'),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
      ),
    );
  }

  /// Mass balance and yield of the order (server values; balance must be 0 once received).
  Widget _massCard() {
    final bool done = !_open;
    final double bal = _n((_d['check'] is Map) ? (_d['check'] as Map)['kg'] : null);
    final String yieldText = _d['yield_pct'] == null ? '—' : '${faNum(_n(_d['yield_pct']), dec: 1)}٪';
    final String varText = _d['yield_variance_pct'] == null ? '' : '  (انحراف ${faNum(_n(_d['yield_variance_pct']), dec: 1)}٪)';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: <Widget>[
            Row(children: <Widget>[const Expanded(child: Text('ورودی (کیلو)')), Text(_kg(_d['input_kg']))]),
            Row(children: <Widget>[const Expanded(child: Text('خروجی (کیلو)')), Text(_kg(_d['output_kg']))]),
            Row(children: <Widget>[const Expanded(child: Text('ضایعات (کیلو)')), Text(_kg(_d['waste_kg']))]),
            Row(children: <Widget>[const Expanded(child: Text('بازدهی')), Text('$yieldText$varText')]),
            if (done)
              Row(
                children: <Widget>[
                  const Expanded(child: Text('تراز جرمی (باید صفر باشد)')),
                  Text(
                    _kg(bal),
                    style: TextStyle(color: bal.abs() < 0.002 ? null : Theme.of(context).colorScheme.error),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Receive-back page: outputs + waste with live mass-balance and yield check
// ---------------------------------------------------------------------------

class _OutLine {
  final TextEditingController name = TextEditingController();
  final TextEditingController kg = TextEditingController();
  final TextEditingController small = TextEditingController(text: '0');
  final TextEditingController large = TextEditingController(text: '0');
  void dispose() {
    name.dispose();
    kg.dispose();
    small.dispose();
    large.dispose();
  }
}

class ProcessingReceivePage extends StatefulWidget {
  final Map<String, dynamic> order;
  const ProcessingReceivePage({super.key, required this.order});

  @override
  State<ProcessingReceivePage> createState() => _ProcessingReceivePageState();
}

class _ProcessingReceivePageState extends State<ProcessingReceivePage> {
  final TextEditingController _waste = TextEditingController(text: '0');
  final TextEditingController _date = TextEditingController(text: ReturnsHelp.iso(DateTime.now()));
  final List<_OutLine> _outs = <_OutLine>[_OutLine()];
  bool _saving = false;

  double get _inKg => _n(widget.order['input_kg']);
  double get _outKg => _outs.fold<double>(0.0, (double s, _OutLine l) => s + _numText(l.kg.text));
  double get _wasteKg => _numText(_waste.text);
  double get _balance => _inKg - _outKg - _wasteKg;
  double get _yield => _inKg > 0 ? _outKg / _inKg * 100 : 0;
  double get _standard => _n(widget.order['standard_yield_pct']);

  @override
  void dispose() {
    _waste.dispose();
    _date.dispose();
    for (final _OutLine l in _outs) {
      l.dispose();
    }
    super.dispose();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _submit() async {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(_en(_date.text.trim()))) return _snack('تاریخ را به صورت yyyy-mm-dd وارد کنید');
    if (_balance.abs() > 0.0015) {
      return _snack('تراز جرمی برقرار نیست: ${faNum(_balance, dec: 3)} کیلو اختلاف دارد');
    }
    final List<Map<String, dynamic>> outputs = <Map<String, dynamic>>[];
    for (final _OutLine l in _outs) {
      final double kg = _numText(l.kg.text);
      if (kg <= 0) return _snack('وزن هر خروجی باید بیشتر از صفر باشد');
      if (l.name.text.trim().isEmpty) return _snack('نوع هر خروجی را وارد کنید');
      outputs.add(<String, dynamic>{
        'type_name': l.name.text.trim(),
        'kg': kg,
        'small_sacks': _numText(l.small.text),
        'large_sacks': _numText(l.large.text),
      });
    }
    setState(() => _saving = true);
    try {
      final int id = _n(widget.order['id']).toInt();
      final bool queued = await ProcessingStore.write('processing.receive', <String, dynamic>{
        'uid': ReturnsHelp.newUid('precv'),
        'id': id,
        'date': _en(_date.text.trim()),
        'waste_kg': _wasteKg,
        'outputs': outputs,
      }, 'دریافت خروجی فراوری: ${widget.order['party'] ?? ''}');
      if (!mounted) return;
      _snack(queued ? 'آفلاین ذخیره شد؛ پس از اتصال ارسال می‌شود' : 'دریافت ثبت شد');
      Navigator.pop(context, true);
    } on StockApiException catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool ok = _balance.abs() <= 0.0015;
    final double dev = _yield - _standard;
    return Scaffold(
      appBar: AppBar(title: const Text('دریافت خروجی')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: <Widget>[
                  Row(children: <Widget>[const Expanded(child: Text('ورودی (کیلو)')), Text(faNum(_inKg, dec: 3))]),
                  Row(children: <Widget>[const Expanded(child: Text('جمع خروجی (کیلو)')), Text(faNum(_outKg, dec: 3))]),
                  Row(children: <Widget>[const Expanded(child: Text('ضایعات (کیلو)')), Text(faNum(_wasteKg, dec: 3))]),
                  const Divider(),
                  Row(
                    children: <Widget>[
                      const Expanded(child: Text('تراز جرمی')),
                      Text(
                        '${faNum(_balance, dec: 3)}  ${ok ? '✓' : '✗'}',
                        style: TextStyle(color: ok ? null : Theme.of(context).colorScheme.error),
                      ),
                    ],
                  ),
                  Row(
                    children: <Widget>[
                      const Expanded(child: Text('بازدهی / انحراف از استاندارد')),
                      Text('${faNum(_yield, dec: 1)}٪  (${dev >= 0 ? '+' : ''}${faNum(dev, dec: 1)})'),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _waste,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'ضایعات (کیلو)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _date,
            decoration: const InputDecoration(labelText: 'تاریخ دریافت (yyyy-mm-dd)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 14),
          Text('خروجی‌ها', style: Theme.of(context).textTheme.titleMedium),
          for (int i = 0; i < _outs.length; i++)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  children: <Widget>[
                    TextField(
                      controller: _outs[i].name,
                      decoration: const InputDecoration(labelText: 'نوع خروجی', border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: TextField(
                            controller: _outs[i].kg,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(labelText: 'کیلو', border: OutlineInputBorder()),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _outs[i].small,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(labelText: 'گونی کوچک', border: OutlineInputBorder()),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _outs[i].large,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(labelText: 'گونی بزرگ', border: OutlineInputBorder()),
                          ),
                        ),
                      ],
                    ),
                    if (_outs.length > 1)
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: IconButton(
                          tooltip: 'حذف خروجی',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => setState(() {
                            _outs.removeAt(i).dispose();
                          }),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => setState(() => _outs.add(_OutLine())),
              icon: const Icon(Icons.add),
              label: const Text('افزودن خروجی'),
            ),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _saving || !ok ? null : _submit,
            icon: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.check),
            label: const Text('ثبت دریافت'),
          ),
        ],
      ),
    );
  }
}
