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

/// S08.T08.3 — consignment screens (امانی): both directions.
///  - in  (امانی دریافتی): goods of others held in our warehouse → consignments.create/return/pay/delete
///  - out (امانی ارسالی): our goods held by others → consignments.create/return/sold/delete
/// Server: consignments.* (api/consignment.php, api/consignment_out.php). Money and stock are derived on the server.
/// Offline: create / return / pay / sold are queued (SharedPreferences, strictly ordered, idempotent through `uid`)
/// and replayed on the next load. Reads are cached (last list) so the list still shows offline.
/// Permissions: list → stock.view, create → consignments.create, return/delete → consignments.manage,
/// pay → payments.save, sold → sales.create (mirrors the server map in permissions.php).

const String kConsIn = 'in';
const String kConsOut = 'out';

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
      // thousands separator: ignore
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
    case 'open':
      return 'باز';
    case 'partial':
      return 'نیمه‌تسویه';
    case 'closed':
      return 'تسویه‌شده';
    default:
      return s;
  }
}

/// Persian labels for the `position` map of consignments.get (both directions).
const Map<String, String> _posLabels = <String, String>{
  'received_kg': 'وزن دریافتی (کیلو)',
  'sold_kg': 'وزن فروخته‌شده (کیلو)',
  'sale_returned_kg': 'برگشت فروش (کیلو)',
  'net_sold_kg': 'فروش خالص (کیلو)',
  'returned_to_owner_kg': 'برگشت به صاحب (کیلو)',
  'remaining_kg': 'مانده نزد ما (کیلو)',
  'sent_kg': 'ارسال‌شده (کیلو)',
  'returned_kg': 'برگشت به انبار (کیلو)',
  'outstanding_kg': 'مانده نزد امانت‌گیرنده (کیلو)',
  'back_at_consignee_kg': 'برگشت به امانت‌گیرنده (کیلو)',
  'gross_revenue': 'فروش ناخالص',
  'net_revenue': 'فروش خالص',
  'net_sold_revenue': 'فروش خالص',
  'sold_revenue': 'فروش',
  'sold_cost': 'بهای تمام‌شده فروش',
  'profit': 'سود',
  'commission': 'کمیسیون ما',
  'our_margin': 'سود ما (خرید هنگام فروش)',
  'our_income': 'درآمد ما',
  'owed_to_owner': 'سهم صاحب کالا',
  'paid': 'پرداخت‌شده',
  'balance': 'مانده پرداخت به صاحب',
};

/// A form field for [_form]. With [options] it becomes a dropdown (value = key).
class _F {
  final String key;
  final String label;
  final String initial;
  final bool numeric;
  final Map<String, String>? options;
  const _F(this.key, this.label, {this.initial = '', this.numeric = false, this.options});
}

Future<Map<String, String>?> _form(BuildContext context, String title, List<_F> fields) async {
  final Map<String, TextEditingController> ctrls = <String, TextEditingController>{};
  final Map<String, String?> sel = <String, String?>{};
  for (final _F f in fields) {
    if (f.options != null) {
      final bool ok = f.options!.containsKey(f.initial);
      sel[f.key] = ok ? f.initial : (f.options!.isEmpty ? null : f.options!.keys.first);
    } else {
      ctrls[f.key] = TextEditingController(text: f.initial);
    }
  }
  final Map<String, String>? out = await showDialog<Map<String, String>>(
    context: context,
    builder: (BuildContext ctx) => StatefulBuilder(
      builder: (BuildContext ctx2, StateSetter set) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final _F f in fields)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: f.options != null
                      ? DropdownButtonFormField<String>(
                          value: sel[f.key],
                          decoration: InputDecoration(labelText: f.label, border: const OutlineInputBorder()),
                          items: <DropdownMenuItem<String>>[
                            for (final MapEntry<String, String> e in f.options!.entries)
                              DropdownMenuItem<String>(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
                          ],
                          onChanged: (String? v) => set(() => sel[f.key] = v),
                        )
                      : TextField(
                          controller: ctrls[f.key],
                          keyboardType: f.numeric ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
                          decoration: InputDecoration(labelText: f.label, border: const OutlineInputBorder()),
                        ),
                ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('انصراف')),
          FilledButton(
            onPressed: () {
              final Map<String, String> res = <String, String>{};
              for (final _F f in fields) {
                res[f.key] = f.options != null ? (sel[f.key] ?? '') : (ctrls[f.key]?.text.trim() ?? '');
              }
              Navigator.pop(ctx, res);
            },
            child: const Text('ثبت'),
          ),
        ],
      ),
    ),
  );
  for (final TextEditingController c in ctrls.values) {
    c.dispose();
  }
  return out;
}

/// Queue + cache for consignment writes and the last list.
class ConsignmentStore {
  ConsignmentStore._();
  static const String _kOps = 'cons_ops_v1';
  static const String _kList = 'cons_list_v1';

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

  static Future<void> _enqueue(String action, Map<String, dynamic> payload, String label) async {
    final List<Map<String, dynamic>> ops = await pendingOps();
    ops.add(<String, dynamic>{'uid': payload['uid'], 'action': action, 'payload': payload, 'label': label});
    await _saveOps(ops);
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

  /// Online-first write. A network failure queues the op and returns queued=true; other server errors are rethrown.
  static Future<bool> write(String action, Map<String, dynamic> payload, String label) async {
    try {
      await StockApi.call(action, payload);
    } on StockApiException catch (e) {
      if (!isNetworkError(e.message)) rethrow;
      await _enqueue(action, payload, label);
      return true;
    }
    SyncService.I.syncNow(pull: true); // stock moved: refresh local inventory
    return false;
  }

  /// Replays queued writes in order. Stops at the first network failure; server-rejected ops are dropped and reported.
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

class ConsignmentsScreen extends StatefulWidget {
  const ConsignmentsScreen({super.key});

  @override
  State<ConsignmentsScreen> createState() => _ConsignmentsScreenState();
}

class _ConsignmentsScreenState extends State<ConsignmentsScreen> {
  String _dir = kConsIn;
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
    final List<String> flushErrors = await ConsignmentStore.flush();
    _queued = await ConsignmentStore.pendingOps();
    String? error;
    List<Map<String, dynamic>> items;
    try {
      final Map<String, dynamic> r = await StockApi.call('consignments.list');
      items = ReturnsHelp.maps(r['items']);
      await ConsignmentStore.cacheList(items);
    } on StockApiException catch (e) {
      error = e.message;
      items = await ConsignmentStore.cachedList();
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
        _items.where((Map<String, dynamic> c) => '${c['direction']}' == _dir).toList();
    final List<Map<String, dynamic>> queuedHere =
        _queued.where((Map<String, dynamic> o) => '${o['label']}'.isNotEmpty).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('امانی'),
        actions: <Widget>[
          if (_can('stock.view'))
            IconButton(
              tooltip: 'صورت‌حساب امانت‌گیرنده / صاحب کالا',
              icon: const Icon(Icons.receipt_long_outlined),
              onPressed: () => _open(const ConsignmentStatementScreen()),
            ),
          IconButton(tooltip: 'به‌روزرسانی', icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      floatingActionButton: _can('consignments.create')
          ? FloatingActionButton.extended(
              onPressed: () => _open(ConsignmentFormScreen(direction: _dir)),
              icon: const Icon(Icons.add),
              label: Text(_dir == kConsIn ? 'ثبت امانی دریافتی' : 'ثبت امانی ارسالی'),
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
                  label: const Text('امانی دریافتی (کالای دیگران نزد ما)'),
                  selected: _dir == kConsIn,
                  onSelected: (_) => setState(() => _dir = kConsIn),
                ),
                ChoiceChip(
                  label: const Text('امانی ارسالی (کالای ما نزد دیگران)'),
                  selected: _dir == kConsOut,
                  onSelected: (_) => setState(() => _dir = kConsOut),
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
            for (final Map<String, dynamic> o in queuedHere)
              ListTile(
                leading: const Icon(Icons.cloud_upload_outlined),
                title: Text('${o['label']}'),
                subtitle: const Text('در صف ارسال؛ پس از اتصال به اینترنت ارسال می‌شود'),
              ),
            if (!_loading && visible.isEmpty)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('موردی ثبت نشده است'))),
            for (final Map<String, dynamic> c in visible) _tile(c),
          ],
        ),
      ),
    );
  }

  Widget _tile(Map<String, dynamic> c) {
    final bool isOut = '${c['direction']}' == kConsOut;
    final String info = isOut
        ? 'ارسال ${_kg(c['sent_kg'])} · مانده نزد امانت‌گیرنده ${_kg(c['outstanding_kg'])} کیلو'
        : 'دریافت ${_kg(c['received_kg'])} · مانده ${_kg(c['remaining_kg'])} کیلو · بدهی به صاحب ${_money(c['balance'])}';
    return Card(
      child: ListTile(
        leading: Icon(isOut ? Icons.call_made : Icons.call_received),
        title: Text('${c['party']}'),
        subtitle: Text('${jalaliDate('${c['date']}')}\n$info'),
        isThreeLine: true,
        trailing: Chip(label: Text(_statusLabel('${c['status']}'))),
        onTap: () => _open(ConsignmentDetailScreen(id: _n(c['id']).toInt(), direction: '${c['direction']}')),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Create (both directions)
// ---------------------------------------------------------------------------

class _Line {
  final TextEditingController name = TextEditingController();
  final TextEditingController kg = TextEditingController();
  final TextEditingController small = TextEditingController(text: '0');
  final TextEditingController large = TextEditingController(text: '0');
  String? lotLocalId; // out: our lot (local id)
  void dispose() {
    name.dispose();
    kg.dispose();
    small.dispose();
    large.dispose();
  }
}

class ConsignmentFormScreen extends StatefulWidget {
  final String direction;
  const ConsignmentFormScreen({super.key, required this.direction});

  @override
  State<ConsignmentFormScreen> createState() => _ConsignmentFormScreenState();
}

class _ConsignmentFormScreenState extends State<ConsignmentFormScreen> {
  final TextEditingController _party = TextEditingController();
  final TextEditingController _note = TextEditingController();
  final TextEditingController _value = TextEditingController(text: '0');
  final TextEditingController _agreed = TextEditingController();
  final TextEditingController _date = TextEditingController(text: ReturnsHelp.iso(DateTime.now()));
  final List<_Line> _lines = <_Line>[_Line()];
  String _mode = 'commission'; // in: commission|purchase_on_sale ; out: to_consignee|via_consignee
  String _ctype = 'percent'; // in commission: percent|per_kg
  String? _wh;
  List<WhOption> _whs = <WhOption>[];
  Map<String, String> _lots = <String, String>{}; // out: local lot id -> label
  bool _saving = false;

  bool get _isIn => widget.direction == kConsIn;

  @override
  void initState() {
    super.initState();
    _mode = _isIn ? 'commission' : 'to_consignee';
    _init();
  }

  Future<void> _init() async {
    if (_isIn) {
      final List<WhOption> whs = await StockLookup.warehouses();
      if (!mounted) return;
      setState(() {
        _whs = whs;
        _wh = whs.isEmpty ? null : (whs.where((WhOption w) => w.isDefault).isNotEmpty ? whs.firstWhere((WhOption w) => w.isDefault).uid : whs.first.uid);
      });
    } else {
      final List<Map<String, dynamic>> rows = await AppDb.I.inventoryAll();
      final Map<String, String> lots = <String, String>{};
      for (final Map<String, dynamic> r in rows) {
        if (_n(r['is_mix']) != 0 || _n(r['remaining']) <= 0) continue; // own, unsold lots only
        lots['${r['id']}'] = '${r['code'] ?? ''} · ${r['type_name'] ?? ''} · ${_kg(r['remaining'])} کیلو';
      }
      if (!mounted) return;
      setState(() => _lots = lots);
    }
  }

  @override
  void dispose() {
    _party.dispose();
    _note.dispose();
    _value.dispose();
    _agreed.dispose();
    _date.dispose();
    for (final _Line l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _submit() async {
    final String party = _party.text.trim();
    if (party.isEmpty) return _snack(_isIn ? 'نام صاحب کالا را وارد کنید' : 'نام امانت‌گیرنده را وارد کنید');
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(_en(_date.text.trim()))) return _snack('تاریخ را به صورت yyyy-mm-dd وارد کنید');
    final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
    setState(() => _saving = true);
    try {
      for (final _Line l in _lines) {
        final double kg = _numText(l.kg.text);
        if (kg <= 0) {
          _snack('وزن هر قلم باید بیشتر از صفر باشد');
          return;
        }
        final Map<String, dynamic> it = <String, dynamic>{
          'kg': kg,
          'small_sacks': _numText(l.small.text),
          'large_sacks': _numText(l.large.text),
        };
        if (_isIn) {
          if (l.name.text.trim().isEmpty) {
            _snack('نوع/نام هر قلم را وارد کنید');
            return;
          }
          it['type_name'] = l.name.text.trim();
        } else {
          if (l.lotLocalId == null) {
            _snack('برای هر قلم، لات انبار را انتخاب کنید');
            return;
          }
          final int serverLot = await ReturnsHelp.serverId('purchase', int.parse(l.lotLocalId!));
          it['lot_id'] = serverLot;
        }
        items.add(it);
      }
      final Map<String, dynamic> payload = <String, dynamic>{
        'uid': ReturnsHelp.newUid('cons'),
        'direction': widget.direction,
        'party': party,
        'date': _en(_date.text.trim()),
        'settlement_mode': _mode,
        'note': _note.text.trim(),
        'items': items,
      };
      String label = '${_isIn ? 'امانی دریافتی' : 'امانی ارسالی'}: $party';
      if (_isIn) {
        payload['commission_type'] = _ctype;
        payload['commission_value'] = _mode == 'commission' ? _numText(_value.text) : 0;
        if (_mode == 'purchase_on_sale') payload['agreed_price'] = _numText(_agreed.text);
        if (_wh != null) payload['warehouse_uid'] = _wh;
      }
      final bool queued = await ConsignmentStore.write('consignments.create', payload, label);
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
    final String title = _isIn ? 'امانی دریافتی (کالای دیگران نزد ما)' : 'امانی ارسالی (کالای ما نزد دیگران)';
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: <Widget>[
          TextField(
            controller: _party,
            decoration: InputDecoration(labelText: _isIn ? 'صاحب کالا' : 'امانت‌گیرنده', border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _date,
            decoration: const InputDecoration(labelText: 'تاریخ (yyyy-mm-dd)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          if (_isIn) ...<Widget>[
            DropdownButtonFormField<String>(
              value: _mode,
              decoration: const InputDecoration(labelText: 'روش تسویه', border: OutlineInputBorder()),
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem(value: 'commission', child: Text('کمیسیون (فروش به نام ما، سهم صاحب کالا کسر کمیسیون)')),
                DropdownMenuItem(value: 'purchase_on_sale', child: Text('خرید هنگام فروش (قیمت توافقی هر کیلو)')),
              ],
              onChanged: (String? v) => setState(() => _mode = v ?? 'commission'),
            ),
            const SizedBox(height: 10),
            if (_mode == 'commission')
              Row(
                children: <Widget>[
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _ctype,
                      decoration: const InputDecoration(labelText: 'نوع کمیسیون', border: OutlineInputBorder()),
                      items: const <DropdownMenuItem<String>>[
                        DropdownMenuItem(value: 'percent', child: Text('درصد')),
                        DropdownMenuItem(value: 'per_kg', child: Text('ریال هر کیلو')),
                      ],
                      onChanged: (String? v) => setState(() => _ctype = v ?? 'percent'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _value,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'مقدار کمیسیون', border: OutlineInputBorder()),
                    ),
                  ),
                ],
              )
            else
              TextField(
                controller: _agreed,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'قیمت توافقی هر کیلو', border: OutlineInputBorder()),
              ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              value: _wh,
              decoration: const InputDecoration(labelText: 'انبار محل نگهداری', border: OutlineInputBorder()),
              items: <DropdownMenuItem<String>>[
                for (final WhOption w in _whs) DropdownMenuItem<String>(value: w.uid, child: Text(w.name)),
              ],
              onChanged: (String? v) => setState(() => _wh = v),
            ),
          ] else ...<Widget>[
            DropdownButtonFormField<String>(
              value: _mode,
              decoration: const InputDecoration(labelText: 'نحوه فروش', border: OutlineInputBorder()),
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem(value: 'to_consignee', child: Text('امانت‌گیرنده مستقیماً می‌فروشد و گزارش می‌دهد')),
                DropdownMenuItem(value: 'via_consignee', child: Text('از طریق امانت‌گیرنده به خریدار نهایی')),
              ],
              onChanged: (String? v) => setState(() => _mode = v ?? 'to_consignee'),
            ),
          ],
          const SizedBox(height: 16),
          Text('اقلام', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          for (int i = 0; i < _lines.length; i++) _lineCard(i),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => setState(() => _lines.add(_Line())),
              icon: const Icon(Icons.add),
              label: const Text('افزودن قلم'),
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
            label: const Text('ثبت'),
          ),
        ],
      ),
    );
  }

  Widget _lineCard(int i) {
    final _Line l = _lines[i];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          children: <Widget>[
            if (_isIn)
              TextField(
                controller: l.name,
                decoration: const InputDecoration(labelText: 'نوع کالا', border: OutlineInputBorder()),
              )
            else
              DropdownButtonFormField<String>(
                value: l.lotLocalId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'لات انبار', border: OutlineInputBorder()),
                items: <DropdownMenuItem<String>>[
                  for (final MapEntry<String, String> e in _lots.entries)
                    DropdownMenuItem<String>(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (String? v) => setState(() => l.lotLocalId = v),
              ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: l.kg,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
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
                  tooltip: 'حذف قلم',
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
// Detail: position, lots, returns, payments, sold reports; actions by direction
// ---------------------------------------------------------------------------

class ConsignmentDetailScreen extends StatefulWidget {
  final int id;
  final String direction;
  const ConsignmentDetailScreen({super.key, required this.id, required this.direction});

  @override
  State<ConsignmentDetailScreen> createState() => _ConsignmentDetailScreenState();
}

class _ConsignmentDetailScreenState extends State<ConsignmentDetailScreen> {
  bool _loading = true;
  String? _error;
  bool _changed = false;
  Map<String, dynamic> _d = <String, dynamic>{};

  bool get _isIn => widget.direction == kConsIn;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final Map<String, dynamic> r = await StockApi.call('consignments.get', <String, dynamic>{'id': widget.id});
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

  /// Runs an online-first write from a detail action, then reloads.
  Future<void> _write(String action, Map<String, dynamic> payload, String label) async {
    try {
      final bool queued = await ConsignmentStore.write(action, payload, label);
      _changed = true;
      _snack(queued ? 'آفلاین ذخیره شد؛ پس از اتصال ارسال می‌شود' : 'ثبت شد');
      if (!queued) await _load();
    } on StockApiException catch (e) {
      _snack(e.message);
    }
  }

  List<Map<String, String>> _lotOptions({bool withOutstanding = false}) {
    final List<dynamic> lots = (_d['lots'] is List) ? (_d['lots'] as List<dynamic>) : <dynamic>[];
    final List<Map<String, String>> out = <Map<String, String>>[];
    for (final dynamic x in lots) {
      if (x is! Map) continue;
      final double avail = _isIn ? _n(x['remaining']) : _n(x['outstanding_kg']);
      if (withOutstanding && avail <= 0) continue;
      out.add(<String, String>{'id': '${x['lot_id']}', 'label': '${x['code'] ?? ''} · ${x['type_name'] ?? ''} · ${_kg(avail)} کیلو'});
    }
    return out;
  }

  Map<String, String> _asOptions(List<Map<String, String>> l) => <String, String>{for (final Map<String, String> e in l) e['id']!: e['label']!};

  Future<void> _returnDialog() async {
    final Map<String, String>? r = await _form(context, _isIn ? 'برگشت کالا به صاحب' : 'برگشت از امانت‌گیرنده به انبار', <_F>[
      _F('lot', 'لات', options: _asOptions(_lotOptions(withOutstanding: true))),
      _F('kg', 'وزن (کیلو)', numeric: true),
      _F('small', 'گونی کوچک', numeric: true, initial: '0'),
      _F('large', 'گونی بزرگ', numeric: true, initial: '0'),
    ]);
    if (r == null) return;
    final double kg = _numText(r['kg'] ?? '');
    if (r['lot'] == null || r['lot']!.isEmpty || kg <= 0) return _snack('لات و وزن را وارد کنید');
    await _write('consignments.return', <String, dynamic>{
      'uid': ReturnsHelp.newUid('cret'),
      'consignment_id': widget.id,
      'lot_id': int.parse(r['lot']!),
      'kg': kg,
      'small_sacks': _numText(r['small'] ?? ''),
      'large_sacks': _numText(r['large'] ?? ''),
      'date': ReturnsHelp.iso(DateTime.now()),
    }, 'برگشت ${_kg(kg)} کیلو: ${_d['party'] ?? ''}');
  }

  Future<void> _payDialog() async {
    final Map<String, String>? r = await _form(context, 'پرداخت به صاحب کالا', <_F>[
      _F('amount', 'مبلغ', numeric: true),
      _F('note', 'یادداشت'),
    ]);
    if (r == null) return;
    final double amount = _numText(r['amount'] ?? '');
    if (amount <= 0) return _snack('مبلغ را وارد کنید');
    await _write('consignments.pay', <String, dynamic>{
      'uid': ReturnsHelp.newUid('cpay'),
      'consignment_id': widget.id,
      'amount': amount,
      'date': ReturnsHelp.iso(DateTime.now()),
      'note': r['note'] ?? '',
    }, 'پرداخت ${_money(amount)} به ${_d['party'] ?? ''}');
  }

  Future<void> _soldDialog() async {
    final bool via = '${_d['settlement_mode']}' == 'via_consignee';
    final Map<String, String>? r = await _form(context, 'ثبت فروش نزد امانت‌گیرنده', <_F>[
      _F('lot', 'لات', options: _asOptions(_lotOptions(withOutstanding: true))),
      _F('kg', 'وزن فروش (کیلو)', numeric: true),
      _F('price', 'قیمت هر کیلو', numeric: true),
      if (via) _F('buyer', 'خریدار نهایی'),
      _F('date', 'تاریخ (yyyy-mm-dd)', initial: ReturnsHelp.iso(DateTime.now())),
    ]);
    if (r == null) return;
    final double kg = _numText(r['kg'] ?? '');
    if (r['lot'] == null || r['lot']!.isEmpty || kg <= 0) return _snack('لات و وزن فروش را وارد کنید');
    if (via && (r['buyer'] ?? '').trim().isEmpty) return _snack('نام خریدار نهایی را وارد کنید');
    await _write('consignments.sold', <String, dynamic>{
      'uid': ReturnsHelp.newUid('csold'),
      'consignment_id': widget.id,
      'lot_id': int.parse(r['lot']!),
      'kg': kg,
      'price': _numText(r['price'] ?? ''),
      'date': _en(r['date'] ?? ReturnsHelp.iso(DateTime.now())),
      if (via) 'buyer': r['buyer']!.trim(),
    }, 'فروش ${_kg(kg)} کیلو: ${_d['party'] ?? ''}');
  }

  Future<void> _delete() async {
    final bool ok = await showDialog<bool>(
          context: context,
          builder: (BuildContext ctx) => AlertDialog(
            title: const Text('حذف امانی؟'),
            content: const Text('فقط در صورتی که هیچ فروش، برگشت یا پرداختی ثبت نشده باشد، حذف می‌شود.'),
            actions: <Widget>[
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('حذف')),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    try {
      await StockApi.call('consignments.delete', <String, dynamic>{'id': widget.id});
      SyncService.I.syncNow(pull: true);
      if (!mounted) return;
      Navigator.pop(context, true);
    } on StockApiException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _printNote() async {
    final List<dynamic> lots = (_d['lots'] is List) ? (_d['lots'] as List<dynamic>) : <dynamic>[];
    final List<List<String>> rows = <List<String>>[
      for (final dynamic x in lots)
        if (x is Map)
          <String>[
            '${x['code'] ?? ''}',
            '${x['type_name'] ?? ''}',
            _kg(_isIn ? x['kg'] : x['sent_kg']),
            _kg(_isIn ? x['remaining'] : x['outstanding_kg']),
          ],
    ];
    final File file = await PdfService.buildTableReport(
      title: _isIn ? 'رسید امانی دریافتی' : 'حواله امانی ارسالی',
      subtitle: '${_d['party'] ?? ''}  •  ${jalaliDate('${_d['date'] ?? ''}')}',
      kv: <List<String>>[
        <String>['وضعیت', _statusLabel('${_d['status'] ?? ''}')],
        if (_d['note'] != null && '${_d['note']}'.isNotEmpty) <String>['یادداشت', '${_d['note']}'],
      ],
      headers: <String>['کد', 'نوع', _isIn ? 'وزن اولیه' : 'ارسال‌شده', _isIn ? 'مانده' : 'مانده نزد امانت‌گیرنده'],
      rows: rows,
      filePrefix: _isIn ? 'consignment_in' : 'consignment_out',
    );
    if (!mounted) return;
    await PdfOutput.show(context, file);
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic> pos = (_d['position'] is Map) ? Map<String, dynamic>.from(_d['position'] as Map) : <String, dynamic>{};
    final bool canManage = _can('consignments.manage');
    final bool canSold = _isIn ? false : _can('sales.create');
    final bool canPay = _isIn && _can('payments.save');
    return WillPopScope(
      onWillPop: () async {
        Navigator.pop(context, _changed ? true : null);
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_d['party'] == null ? 'امانی' : '${_d['party']}'),
          actions: <Widget>[
            if (_d.isNotEmpty) IconButton(tooltip: 'چاپ', icon: const Icon(Icons.print_outlined), onPressed: _printNote),
            if (_d['deletable'] == true && canManage)
              IconButton(tooltip: 'حذف', icon: const Icon(Icons.delete_outline), onPressed: _delete),
          ],
        ),
        body: _loading && _d.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.all(14),
                  children: <Widget>[
                    if (widget.id > 0) ...<Widget>[
                      VoucherStatusChip(sourceType: _isIn ? 'cons_in' : 'cons_out', sourceId: '${widget.id}'),
                      VoucherLinkButton(sourceType: _isIn ? 'cons_in' : 'cons_out', sourceId: '${widget.id}'),
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
                              Text('${_isIn ? 'صاحب کالا' : 'امانت‌گیرنده'}: ${_d['party'] ?? ''}'),
                              Text('تاریخ: ${jalaliDate('${_d['date'] ?? ''}')}'),
                              Text('وضعیت: ${_statusLabel('${_d['status'] ?? ''}')}'),
                              if (_d['settlement_mode'] != null) Text('روش: ${_d['settlement_mode']}'),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            children: <Widget>[
                              for (final MapEntry<String, dynamic> e in pos.entries)
                                if (_posLabels.containsKey(e.key) && e.value is num)
                                  Row(
                                    children: <Widget>[
                                      Expanded(child: Text(_posLabels[e.key]!)),
                                      Text(e.key.endsWith('_kg') ? _kg(e.value) : _money(e.value)),
                                    ],
                                  ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text('اقلام / لات‌ها', style: Theme.of(context).textTheme.titleMedium),
                      for (final dynamic x in (_d['lots'] is List ? _d['lots'] as List<dynamic> : <dynamic>[]))
                        if (x is Map)
                          ListTile(
                            dense: true,
                            title: Text('${x['code'] ?? ''}  ${x['type_name'] ?? ''}'),
                            subtitle: Text(_isIn
                                ? 'دریافت ${_kg(x['kg'])} · مانده ${_kg(x['remaining'])} کیلو'
                                : 'ارسال ${_kg(x['sent_kg'])} · فروش ${_kg(x['sold_kg'])} · مانده ${_kg(x['outstanding_kg'])} کیلو'),
                          ),
                      if (!_isIn && _d['sales'] is List && (_d['sales'] as List<dynamic>).isNotEmpty) ...<Widget>[
                        const SizedBox(height: 8),
                        Text('فروش‌های ثبت‌شده', style: Theme.of(context).textTheme.titleMedium),
                        for (final dynamic s in (_d['sales'] as List<dynamic>))
                          if (s is Map)
                            ListTile(
                              dense: true,
                              title: Text('${_kg(s['kg'] ?? s['weight'])} کیلو · ${s['buyer'] ?? ''}'),
                              subtitle: Text(jalaliDate('${s['date'] ?? ''}')),
                            ),
                      ],
                      if (_isIn && _d['payments'] is List && (_d['payments'] as List<dynamic>).isNotEmpty) ...<Widget>[
                        const SizedBox(height: 8),
                        Text('پرداخت‌ها', style: Theme.of(context).textTheme.titleMedium),
                        for (final dynamic p in (_d['payments'] as List<dynamic>))
                          if (p is Map)
                            ListTile(
                              dense: true,
                              title: Text(_money(p['amount'])),
                              subtitle: Text(jalaliDate('${p['date'] ?? ''}')),
                            ),
                      ],
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <Widget>[
                          if (canManage && (_isIn || _lotOptions(withOutstanding: true).isNotEmpty) && _d['status'] != 'closed')
                            OutlinedButton.icon(
                              onPressed: _returnDialog,
                              icon: const Icon(Icons.undo),
                              label: Text(_isIn ? 'برگشت به صاحب' : 'برگشت به انبار'),
                            ),
                          if (canPay)
                            FilledButton.icon(
                              onPressed: _payDialog,
                              icon: const Icon(Icons.payments_outlined),
                              label: const Text('پرداخت به صاحب'),
                            ),
                          if (canSold && _lotOptions(withOutstanding: true).isNotEmpty)
                            FilledButton.icon(
                              onPressed: _soldDialog,
                              icon: const Icon(Icons.point_of_sale),
                              label: const Text('ثبت فروش'),
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
}

// ---------------------------------------------------------------------------
// Statement per party (consignments.statement)
// ---------------------------------------------------------------------------

class ConsignmentStatementScreen extends StatefulWidget {
  const ConsignmentStatementScreen({super.key});

  @override
  State<ConsignmentStatementScreen> createState() => _ConsignmentStatementScreenState();
}

class _ConsignmentStatementScreenState extends State<ConsignmentStatementScreen> {
  final TextEditingController _party = TextEditingController();
  String _dir = kConsIn;
  bool _busy = false;
  Map<String, dynamic>? _res;

  @override
  void dispose() {
    _party.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final String p = _party.text.trim();
    if (p.isEmpty) return;
    setState(() => _busy = true);
    try {
      final Map<String, dynamic> r =
          await StockApi.call('consignments.statement', <String, dynamic>{'party': p, 'direction': _dir});
      if (mounted) setState(() => _res = r);
    } on StockApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic>? totals = _res == null
        ? null
        : (_res!['totals'] is Map ? Map<String, dynamic>.from(_res!['totals'] as Map) : Map<String, dynamic>.from(_res!));
    return Scaffold(
      appBar: AppBar(title: const Text('صورت‌حساب امانی')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: <Widget>[
          Wrap(
            spacing: 8,
            children: <Widget>[
              ChoiceChip(
                label: const Text('دریافتی'),
                selected: _dir == kConsIn,
                onSelected: (_) => setState(() {
                  _dir = kConsIn;
                  _res = null;
                }),
              ),
              ChoiceChip(
                label: const Text('ارسالی'),
                selected: _dir == kConsOut,
                onSelected: (_) => setState(() {
                  _dir = kConsOut;
                  _res = null;
                }),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _party,
            decoration: InputDecoration(
              labelText: _dir == kConsIn ? 'صاحب کالا' : 'امانت‌گیرنده',
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _run(),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: _busy ? null : _run,
            child: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('نمایش'),
          ),
          const SizedBox(height: 14),
          if (totals != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: <Widget>[
                    for (final MapEntry<String, dynamic> e in totals.entries)
                      if (e.value is num)
                        Row(
                          children: <Widget>[
                            Expanded(child: Text(_posLabels[e.key] ?? e.key)),
                            Text(e.key.endsWith('_kg') ? _kg(e.value) : _money(e.value)),
                          ],
                        ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
