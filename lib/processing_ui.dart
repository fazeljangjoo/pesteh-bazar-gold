import 'edit_guard_ui.dart'; // فاز ۳: ویرایش امن
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'fmt.dart' show Fmt;
import 'form_layout.dart';
import 'vouchers_links.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'db.dart';
import 'outside_ui.dart';
import 'perms.dart';
import 'pdf_output.dart';
import 'pdf_service.dart';
import 'returns_ui.dart' show ReturnsHelp;
import 'sync_service.dart';
import 'utils.dart';
import 'widgets.dart' show JalaliDateField;
import 'warehouse_ui.dart' show StockApi, StockApiException, StockLookup, WhOption;
import 'workshop_calc.dart' show kWsGradeLabels, kWsOpLabels, kWsOpen;
import 'workshop_reports_ui.dart' show CrackLineReportScreen; // v81
import 'workshop_flow_ui.dart' show WorkshopOpScreen, WorkshopOpenFormScreen, wsOpTile; // فاز ۲: کارگاه مرحله‌ای
import 'workshop_ui.dart' show WorkshopFormScreen, kWsBuyLabel, kWsCostFields, kWsMissingInputCost, wsCanCost, wsParseNum, wsReadOnlyField;

/// S09.T09.3 — processing screens (فراوری): paid (برون‌سپاری) and received (فراوری امانی).
/// Server: processing.list/get/create/receive/deliver/delete, reports.* (api/processing.php).
/// Offline: create / receive / deliver / delete are queued (SharedPreferences, strictly ordered, idempotent via `uid`)
/// and replayed in order on the next load. The last list is cached for offline viewing.
/// Permissions: list/get → stock.view, create → processing.create, receive/deliver/delete → processing.manage.

const String kProcPaid = 'paid';
const String kProcReceived = 'received';
const String kProcInternal = 'internal'; // کارگاه داخلی (مرحلهٔ ۱ کارگاه)

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
String _money(dynamic v) => Fmt.money(_n(v), label: false);
bool _can(String key) => StaffPerms.I.can(key);

String _statusLabel(String s) {
  switch (s) {
    case 'in_progress':
      return 'در جریان';
    case 'open':
      return 'در کارگاه (باز)';
    case 'done':
      return 'دریافت‌شده';
    case 'closed':
      return 'تحویل‌شده';
    default:
      return s;
  }
}

/// S6: نتیجهٔ [ProcessingStore.writeWithResult].
class ProcWriteResult {
  final bool queued;
  final Map<String, dynamic> data;
  const ProcWriteResult(this.queued, this.data);
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

  // فاز ۲ کارگاه: کش جزئیات هر عملیات (کلید = uid یا id<n>) و فهرست workshop.list برای نمای آفلاین.
  static const String _kDetail = 'ws_detail_v1:';
  static const String _kWsList = 'ws_list_v1';

  static Future<void> cacheDetail(String key, Map<String, dynamic> d) async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    await sp.setString('$_kDetail$key', jsonEncode(d));
  }

  static Future<Map<String, dynamic>?> cachedDetail(String key) async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    final String? raw = sp.getString('$_kDetail$key');
    if (raw == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }

  static Future<void> cacheWorkshopList(Map<String, dynamic> r) async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    await sp.setString(_kWsList, jsonEncode(r));
  }

  static Future<Map<String, dynamic>> cachedWorkshopList() async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    final String? raw = sp.getString(_kWsList);
    if (raw == null) return <String, dynamic>{};
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return <String, dynamic>{};
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

  /// S6: مثل [write] ولی پاسخ سرور را هم برمی‌گرداند (برای نمایش کد لات‌های ساخته‌شده). آفلاین ⇒ queued=true و data خالی.
  static Future<ProcWriteResult> writeWithResult(String action, Map<String, dynamic> payload, String label) async {
    Map<String, dynamic> data;
    try {
      data = await StockApi.call(action, payload);
    } on StockApiException catch (e) {
      if (!isNetworkError(e.message)) rethrow;
      final List<Map<String, dynamic>> ops = await pendingOps();
      ops.add(<String, dynamic>{'uid': payload['uid'] ?? payload['id'], 'action': action, 'payload': payload, 'label': label});
      await _saveOps(ops);
      return const ProcWriteResult(true, <String, dynamic>{});
    }
    SyncService.I.syncNow(pull: true);
    return ProcWriteResult(false, data);
  }

  static const String _kFailed = 'proc_failed_v1';

  static Future<List<Map<String, dynamic>>> failedOps() async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    final String? raw = sp.getString(_kFailed);
    if (raw == null) return <Map<String, dynamic>>[];
    try {
      return ReturnsHelp.maps(jsonDecode(raw));
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<void> _saveFailed(List<Map<String, dynamic>> f) async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    await sp.setString(_kFailed, jsonEncode(f));
  }

  /// دوباره در انتهای صف می‌گذارد (بعد از رفع علت رد شدن).
  static Future<void> retryFailed(int i) async {
    final List<Map<String, dynamic>> failed = await failedOps();
    if (i < 0 || i >= failed.length) return;
    final Map<String, dynamic> op = Map<String, dynamic>.from(failed.removeAt(i))
      ..remove('error')
      ..remove('tries');
    await _saveFailed(failed);
    final List<Map<String, dynamic>> ops = await pendingOps();
    ops.add(op);
    await _saveOps(ops);
  }

  static Future<void> dismissFailed(int i) async {
    final List<Map<String, dynamic>> failed = await failedOps();
    if (i < 0 || i >= failed.length) return;
    failed.removeAt(i);
    await _saveFailed(failed);
  }

  /// ۴۰۱ = نشست نامعتبر/منقضی (رد عملیات نیست): صف دست‌نخورده می‌ماند تا کاربر دوباره وارد شود.
  /// (پیام ۴۰۱ سرور «دوباره وارد شوید» است و فقط «ورود مجدد» را نمی‌شناختیم ⇒ همهٔ صف دور ریخته می‌شد.)
  static bool _keepQueue(StockApiException e) =>
      e.network || e.code == 401 || e.message.contains('ورود مجدد') || e.message.contains('دوباره وارد شوید');

  /// پاسخ بدون پیام JSON (۵۰۲/صفحهٔ خطای هاست …): چند بار دوباره، بعد «ناموفق» تا صف برای همیشه قفل نشود.
  static bool _serverFault(StockApiException e) => e.message.startsWith('خطای سرور');

  /// Replays queued writes in order. Stops at the first network/session failure; a definite server rejection is kept in the
  /// «ناموفق» list (with the server message) instead of being dropped, so offline work is never lost silently.
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
        if (_keepQueue(e)) break;
        if (_serverFault(e)) {
          final int tries = ((op['tries'] as num?) ?? 0).toInt() + 1;
          if (tries < 5) {
            ops[0] = <String, dynamic>{...op, 'tries': tries};
            await _saveOps(ops);
            break;
          }
        }
        errors.add('${op['label'] ?? ''}: ${e.message}');
        final List<Map<String, dynamic>> failed = await failedOps();
        failed.add(<String, dynamic>{...op, 'error': e.message});
        await _saveFailed(failed);
      }
      ops = ops.sublist(1);
      await _saveOps(ops);
    }
    if (sentAny) SyncService.I.syncNow(pull: true);
    return errors;
  }
}

Future<bool> _confirmDropFailed(BuildContext context) async {
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext c) => AlertDialog(
      title: const Text('حذف مورد ناموفق'),
      content: const Text('این مورد هرگز به سرور ارسال نمی‌شود و اطلاعاتش از بین می‌رود. ادامه می‌دهید؟'),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('انصراف')),
        TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('حذف')),
      ],
    ),
  );
  return ok == true;
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
  bool _onlyOpen = false; // فاز ۲: فیلتر «عملیات باز» در تب کارگاه داخلی
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _queued = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _failed = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final List<String> flushErrors = await ProcessingStore.flush();
    _queued = await ProcessingStore.pendingOps();
    _failed = await ProcessingStore.failedOps();
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
    final List<Map<String, dynamic>> visible = _items
        .where((Map<String, dynamic> o) => '${o['direction']}' == _dir && (!_onlyOpen || _dir != kProcInternal || '${o['status']}' == kWsOpen))
        .toList();
    final int openCount = _items.where((Map<String, dynamic> o) => '${o['direction']}' == kProcInternal && '${o['status']}' == kWsOpen).length;
    final List<Map<String, dynamic>> queued = _queued.where((Map<String, dynamic> o) => '${o['label']}'.isNotEmpty).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('فراوری'),
        actions: <Widget>[
          if (_dir == kProcPaid)
            IconButton(
              tooltip: 'فایل خام شکست کارگاه‌ها',
              icon: const Icon(Icons.table_chart_outlined),
              onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const OutsideRawScreen())),
            ),
          if (_dir == kProcInternal && _can('processing.create'))
            IconButton(
              tooltip: 'ثبت یک‌جای عملیات (ورودی و خروجی با هم)',
              icon: const Icon(Icons.post_add),
              onPressed: () => _open(const WorkshopFormScreen()),
            ),
          if (_dir == kProcInternal)
            IconButton(
              tooltip: 'گزارش خطوط شکست (گرم پرتی واقعی در برابر اعلامی)',
              icon: const Icon(Icons.query_stats),
              onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const CrackLineReportScreen())),
            ),
          IconButton(tooltip: 'به‌روزرسانی', icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      floatingActionButton: _can('processing.create')
          ? FloatingActionButton.extended(
              onPressed: () => _open(_dir == kProcInternal ? const WorkshopOpenFormScreen() : ProcessingFormScreen(direction: _dir)),
              icon: Icon(_dir == kProcInternal ? Icons.play_arrow : Icons.add),
              label: Text(_dir == kProcPaid ? 'سفارش برون‌سپاری' : (_dir == kProcInternal ? 'شروع عملیات کارگاه' : 'سفارش فراوری امانی')),
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
                ChoiceChip(
                  label: const Text('کارگاه داخلی'),
                  selected: _dir == kProcInternal,
                  onSelected: (_) => setState(() => _dir = kProcInternal),
                ),
              ],
            ),
            if (_dir == kProcInternal)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FilterChip(
                    avatar: const Icon(Icons.pending_actions, size: 18),
                    label: Text('عملیات باز (${faNum(openCount, dec: 0)})'),
                    selected: _onlyOpen,
                    onSelected: (bool v) => setState(() => _onlyOpen = v),
                  ),
                ),
              ),
            const SizedBox(height: 10),
            if (_error != null)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(padding: const EdgeInsets.all(10), child: Text(_error!)),
              ),
            if (_loading) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
            for (int i = 0; i < _failed.length; i++)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: ListTile(
                  leading: const Icon(Icons.error_outline),
                  title: Text('${_failed[i]['label'] ?? ''}'),
                  subtitle: Text('رد شد و ارسال نشد: ${_failed[i]['error'] ?? ''}'),
                  isThreeLine: true,
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
                    IconButton(
                      tooltip: 'تلاش دوباره',
                      icon: const Icon(Icons.refresh),
                      onPressed: () async {
                        await ProcessingStore.retryFailed(i);
                        _load();
                      },
                    ),
                    IconButton(
                      tooltip: 'حذف',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        if (!await _confirmDropFailed(context)) return;
                        await ProcessingStore.dismissFailed(i);
                        _load();
                      },
                    ),
                  ]),
                ),
              ),
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
    if ('${o['direction']}' == kProcInternal) {
      // فاز ۲: عملیات باز ⇒ صفحهٔ کارگاه مرحله‌ای؛ بسته ⇒ جزئیات (با «بازکردن برای اصلاح»)
      final bool open = '${o['status']}' == kWsOpen;
      return wsOpTile(
        context,
        o,
        () => _open(open
            ? WorkshopOpScreen(orderUid: o['uid'] as String?, id: _n(o['id']).toInt())
            : ProcessingDetailScreen(id: _n(o['id']).toInt())),
      );
    }
    final bool rec = '${o['direction']}' == kProcReceived;
    final String info = rec
        ? 'ورودی ${_kg(o['input_kg'])} · خروجی ${_kg(o['output_kg'])} · ضایعات ${_kg(o['waste_kg'])} کیلو · مطالبه ${_money(o['charge_amount'])}'
        : 'ورودی ${_kg(o['input_kg'])} · خروجی ${_kg(o['output_kg'])} · ضایعات ${_kg(o['waste_kg'])} کیلو · کرایه ${_money(o['fee_amount'])}';
    final String yieldText = o['yield_pct'] == null ? '' : '  •  بازدهی ${faNum(_n(o['yield_pct']), dec: 1)}٪';
    final String rno = rec ? '' : '${o['receipt_no'] ?? ''}'; // مرحلهٔ ۴: شمارهٔ قبض کارگاه بیرونی
    final String own = rec ? '' : '${o['owner'] ?? ''}';
    return Card(
      child: ListTile(
        leading: Icon(rec ? Icons.call_received : Icons.call_made),
        title: Text('${o['party']}  •  ${_statusLabel('${o['status']}')}${rno.isEmpty ? '' : '  •  قبض $rno'}${own.isEmpty ? '' : '  •  $own'}'),
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

  /// فاز ۳: ویرایش کامل سفارش برون‌سپاری «در جریان» (پاسخ processing.get) ⇒ processing.update (اتمی، همان id و uid).
  final Map<String, dynamic>? edit;
  const ProcessingFormScreen({super.key, required this.direction, this.edit});

  @override
  State<ProcessingFormScreen> createState() => _ProcessingFormScreenState();
}

class _ProcessingFormScreenState extends State<ProcessingFormScreen> {
  final TextEditingController _party = TextEditingController();
  final TextEditingController _note = TextEditingController();
  final TextEditingController _fee = TextEditingController(text: '0');
  final TextEditingController _std = TextEditingController(text: '100');
  final TextEditingController _wcharge = TextEditingController(text: '0');
  DateTime _date = DateTime.now();
  final List<_ProcLine> _lines = <_ProcLine>[_ProcLine()];
  final OutsideReceiptCtl _rc = OutsideReceiptCtl(); // مرحلهٔ ۴: قبض کارگاه بیرونی (فقط paid)
  String _service = 'other';
  String _basis = 'per_kg';
  String? _wh;
  List<WhOption> _whs = <WhOption>[];
  Map<String, String> _lots = <String, String>{};
  bool _saving = false;

  bool get _paid => widget.direction == kProcPaid;
  bool get _isEdit => widget.edit != null;

  @override
  void initState() {
    super.initState();
    final Map<String, dynamic>? e = widget.edit;
    if (e != null) {
      _party.text = '${e['party'] ?? ''}';
      _note.text = '${e['note'] ?? ''}';
      _fee.text = '${e['fee_value'] ?? 0}';
      _std.text = '${e['standard_yield_pct'] ?? 100}';
      _date = DateTime.tryParse('${e['date'] ?? ''}') ?? _date;
      _service = _services.containsKey('${e['service']}') ? '${e['service']}' : 'other';
      _basis = _feeBasis.containsKey('${e['fee_basis']}') ? '${e['fee_basis']}' : 'per_kg';
      _lines.clear();
      for (final Map<String, dynamic> it in ReturnsHelp.maps(e['inputs'])) {
        final _ProcLine l = _ProcLine()
          ..lotLocalId = '${it['lot_id']}'
          ..kg.text = '${it['kg']}'
          ..small.text = '${it['small_sacks'] ?? 0}'
          ..large.text = '${it['large_sacks'] ?? 0}';
        _lines.add(l);
      }
      if (_lines.isEmpty) _lines.add(_ProcLine());
    }
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
      // فاز ۳: لات‌های ورودیِ همین سفارش (اکنون از موجودی کم شده‌اند) هم باید در فهرست باشند
      for (final Map<String, dynamic> it in ReturnsHelp.maps(widget.edit?['inputs'])) {
        lots.putIfAbsent('${it['lot_id']}', () => '${it['code'] ?? ''} · ${it['type_name'] ?? ''} · همین سفارش ${_kg(it['kg'])} کیلو');
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
    _rc.dispose();
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
        'date': ReturnsHelp.iso(_date),
        'service': _service,
        'fee_basis': _basis,
        'fee_value': _numText(_fee.text),
        'standard_yield_pct': std,
        'waste_charge_per_kg': _paid ? 0 : _numText(_wcharge.text),
        'note': _note.text.trim(),
        'items': items,
      };
      if (!_paid && _wh != null) payload['warehouse_uid'] = _wh;
      if (_paid && !_isEdit) payload.addAll(_rc.sentPayload(clearEmpty: false)); // ویرایش: قبض ذخیره‌شده را سرور نگه می‌دارد
      if (_isEdit) {
        payload.remove('uid');
        payload['id'] = widget.edit!['id'];
        if (widget.edit!['edit_version'] != null) payload['base_version'] = widget.edit!['edit_version'];
      }
      final bool queued = await ProcessingStore.write(_isEdit ? 'processing.update' : 'processing.create', payload,
          '${_isEdit ? 'ویرایش ' : ''}${_paid ? 'برون‌سپاری' : 'فراوری امانی'}: $party');
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
    final bool wide = kWideForm(context);
    final double g = kFormGap;
    Widget pad(Widget w) => Padding(padding: EdgeInsets.only(bottom: g), child: w);

    final Widget info = FormSection(title: 'مشخصات سفارش و کرایه', children: <Widget>[
      FormGrid(gap: 12, minColWidth: 260, children: <Widget>[
        pad(TextField(
          controller: _party,
          decoration: InputDecoration(labelText: _paid ? 'فراوری‌کننده' : 'مشتری (صاحب کالا)', border: const OutlineInputBorder()),
        )),
        pad(JalaliDateField(label: 'تاریخ', value: _date, onChanged: (DateTime d) => setState(() => _date = d))),
        pad(DropdownButtonFormField<String>(
          value: _service,
          decoration: const InputDecoration(labelText: 'نوع خدمت', border: OutlineInputBorder()),
          items: <DropdownMenuItem<String>>[
            for (final MapEntry<String, String> e in _services.entries) DropdownMenuItem<String>(value: e.key, child: Text(e.value)),
          ],
          onChanged: (String? v) => setState(() => _service = v ?? 'other'),
        )),
        pad(DropdownButtonFormField<String>(
          value: _basis,
          decoration: const InputDecoration(labelText: 'روش کرایه', border: OutlineInputBorder()),
          items: <DropdownMenuItem<String>>[
            for (final MapEntry<String, String> e in _feeBasis.entries) DropdownMenuItem<String>(value: e.key, child: Text(e.value)),
          ],
          onChanged: (String? v) => setState(() => _basis = v ?? 'per_kg'),
        )),
        pad(TextField(
          controller: _fee,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [ThousandsInputFormatter()],
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: _basis == 'per_kg' ? 'کرایه هر کیلو' : 'مبلغ کرایه', border: const OutlineInputBorder()),
        )),
        pad(TextField(
          controller: _std,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(labelText: 'بازدهی استاندارد ٪', border: OutlineInputBorder()),
        )),
        if (!_paid)
          pad(TextField(
            controller: _wcharge,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [ThousandsInputFormatter()],
            decoration: const InputDecoration(labelText: 'نرخ ضایعات (هر کیلو)', border: OutlineInputBorder()),
          )),
        if (!_paid)
          pad(DropdownButtonFormField<String>(
            value: _wh,
            decoration: const InputDecoration(labelText: 'انبار محل نگهداری', border: OutlineInputBorder()),
            items: <DropdownMenuItem<String>>[
              for (final WhOption w in _whs) DropdownMenuItem<String>(value: w.uid, child: Text(w.name)),
            ],
            onChanged: (String? v) => setState(() => _wh = v),
          )),
      ]),
    ]);

    final Widget summary = Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          'ورودی: ${faNum(_inKg, dec: 3)} کیلو  •  ${hintOk ? 'کرایه تخمینی: ${Fmt.money(_feeEstimate, label: false)}' : ''}\n'
          'بازدهی استاندارد: ${faNum(_numText(_std.text), dec: 1)}٪  —  خروجی و ضایعات بعد از دریافت ثبت می‌شود.',
        ),
      ),
    );

    final Widget receipt = FormSection(title: 'قبض کارگاه بیرونی', children: <Widget>[
      OutsideReceiptFields(ctl: _rc, sentKg: _inKg, onChanged: () => setState(() {})),
    ]);

    final Widget lines = FormSection(title: 'ورودی‌ها', children: <Widget>[
      for (int i = 0; i < _lines.length; i++) _lineCard(i),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          onPressed: () => setState(() => _lines.add(_ProcLine())),
          icon: const Icon(Icons.add),
          label: const Text('افزودن ورودی'),
        ),
      ),
    ]);

    final Widget note = pad(TextField(
      controller: _note,
      decoration: const InputDecoration(labelText: 'یادداشت', border: OutlineInputBorder()),
    ));

    return FormPage(
      title: _paid ? 'برون‌سپاری فراوری' : 'فراوری امانی',
      actions: <Widget>[
        FilledButton.icon(
          onPressed: _saving ? null : _submit,
          icon: _saving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.save_outlined),
          label: const Text('ثبت سفارش'),
        ),
      ],
      children: <Widget>[
        info,
        if (wide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(flex: 3, child: lines),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[summary, if (_paid) receipt]),
              ),
            ],
          )
        else ...<Widget>[
          summary,
          SizedBox(height: g + 2),
          if (_paid) receipt,
          lines,
        ],
        SizedBox(height: g),
        note,
      ],
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
  bool get _int => '${_d['direction']}' == kProcInternal;
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
            if (_d.isNotEmpty && !_int) IconButton(tooltip: 'پیش‌فاکتور کرایه', icon: const Icon(Icons.receipt_outlined), onPressed: () => _print(fee: true)),
            if (_d.isNotEmpty && !_int && _can('processing.manage')) IconButton(tooltip: 'ویرایش', icon: const Icon(Icons.edit_outlined), onPressed: _editDoc), // فاز ۳
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
                    if (widget.id > 0 && !_rec && !_int) ...<Widget>[
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
                              if (_int) ...<Widget>[
                                Text('عملیات: ${kWsOpLabels['${_d['op_type']}'] ?? _d['op_type'] ?? ''}'),
                                Text('تاریخ: ${jalaliDate('${_d['date'] ?? ''}')}'),
                                if ('${_d['owner'] ?? ''}'.isNotEmpty) Text('مالک: ${_d['owner']}'),
                                if ('${_d['pistachio_type'] ?? ''}'.isNotEmpty) Text('نوع پسته: ${_d['pistachio_type']}'),
                                if ('${_d['defect_note'] ?? ''}'.isNotEmpty) Text('ایراد بار: ${_d['defect_note']}'),
                                if (_d['initial_kg'] != null) Text('وزن خالص اولیه: ${_kg(_d['initial_kg'])} کیلو'),
                                if (_d['undelivered_kg'] != null) Text('مانده تحویل‌نشده: ${_kg(_d['undelivered_kg'])} کیلو'),
                                if (_d['bale_count'] != null) Text('تعداد عدل: ${faNum(_n(_d['bale_count']), dec: 0)}'),
                                Text('افت وزن: ${_kg(_d['loss_kg'])} کیلو'),
                                if (_d['sound_pct'] != null) Text('درصد سالم: ${faNum(_n(_d['sound_pct']), dec: 1)}٪'),
                                Text(
                                  _d['balance_ok'] == true ? 'تراز صحیح' : 'نیاز به بررسی — اختلاف ${_kg(_d['balance_diff_kg'])} کیلو',
                                  style: TextStyle(fontWeight: FontWeight.bold, color: _d['balance_ok'] == true ? Colors.green : Colors.orange),
                                ),
                              ] else ...<Widget>[
                                Text('${_rec ? 'مشتری' : 'فراوری‌کننده'}: ${_d['party'] ?? ''}'),
                                Text('تاریخ: ${jalaliDate('${_d['date'] ?? ''}')}'),
                                Text('وضعیت: ${_statusLabel('${_d['status'] ?? ''}')}'),
                                Text('کرایه (${_feeBasis[_d['fee_basis']] ?? ''}): ${_money(_d['fee_amount'])}'),
                                if (_rec) Text('مطالبه از مشتری: ${_money(_d['charge_amount'])}'),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (!_int && !_rec) ...<Widget>[
                        OutsideReceiptCard(order: _d, canEdit: canManage, onEdit: _editReceipt),
                        const SizedBox(height: 8),
                      ],
                      if (_int) _flowCard(),
                      if (!_int) _massCard(),
                      if (_int && wsCanCost() && '${_d['status']}' != kWsOpen) _costCard(),
                      const SizedBox(height: 8),
                      Text('ورودی‌ها', style: Theme.of(context).textTheme.titleMedium),
                      for (final dynamic x in (_d['inputs'] is List ? _d['inputs'] as List<dynamic> : <dynamic>[]))
                        if (x is Map)
                          ListTile(
                            dense: true,
                            title: Text('${x['code'] ?? ''}  ${x['type_name'] ?? ''}'),
                            subtitle: Text('${_kg(x['kg'])} کیلو${(x['cost'] != null && !_int) ? '  •  بهای تمام‌شده ${_money(x['cost'])}' : ''}'),
                          ),
                      if ((_d['outputs'] is List) && (_d['outputs'] as List<dynamic>).isNotEmpty) ...<Widget>[
                        const SizedBox(height: 8),
                        Text('خروجی‌ها', style: Theme.of(context).textTheme.titleMedium),
                        for (final dynamic x in (_d['outputs'] as List<dynamic>))
                          if (x is Map)
                            ListTile(
                              dense: true,
                              title: Text('${x['code'] ?? ''}  ${x['type_name'] ?? ''}'),
                              subtitle: Text(_int
                                  ? '${_kg(x['kg'])} کیلو  •  ${kWsGradeLabels['${x['grade']}'] ?? ''}${(wsCanCost() && x['out_price'] != null && '${x['grade']}' != 'sound') ? '  •  قیمت/کیلو ${_money(x['out_price'])}' : ''}${(wsCanCost() && x['cost'] != null) ? '  •  بها ${_money(x['cost'])}' : ''}${'${x['owner'] ?? ''}'.isEmpty ? '' : '  •  مالک ${x['owner']}'}${'${x['source_code'] ?? ''}'.isEmpty ? '' : '  •  لات اصلی ${x['source_code']}'}'
                                  : '${_kg(x['kg'])} کیلو${_rec ? '' : '  •  بهای تمام‌شده ${_money(x['cost'])}'}'),
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

  /// مرحلهٔ ۴: ویرایش قبض کارگاه بیرونی (processing.receipt_save؛ ذخیرهٔ کامل فیلدهای قبض، خالی = پاک‌کردن).
  Future<void> _editReceipt() async {
    final OutsideReceiptCtl rc = OutsideReceiptCtl(_d);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx2, StateSetter setSt) => AlertDialog(
          title: const Text('ویرایش قبض'),
          content: SingleChildScrollView(
            child: OutsideReceiptFields(ctl: rc, sentKg: _n(_d['input_kg']), showRecv: true, onChanged: () => setSt(() {})),
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ذخیره')),
          ],
        ),
      ),
    );
    final Map<String, dynamic> payload = <String, dynamic>{'id': _d['id'], 'uid': ReturnsHelp.newUid('prcpt')};
    if (ok == true) {
      payload.addAll(rc.sentPayload(clearEmpty: true));
      payload.addAll(rc.recvPayload(clearEmpty: true));
    }
    rc.dispose();
    if (ok != true) return;
    await _run('processing.receipt_save', payload, 'قبض کارگاه بیرونی: ${_d['party'] ?? ''}');
  }

  /// فاز ۳: ویرایش فراوری برون‌سپاری/امانی (processing.update). برون‌سپاری «در جریان» ⇒ فرم کامل (اقلام، کرایه، …)؛ بقیه ⇒ تاریخ و توضیح.
  Future<void> _editDoc() async {
    if ('${_d['direction']}' == kProcPaid && '${_d['status']}' == 'in_progress') {
      final bool? ok = await Navigator.push<bool>(context, MaterialPageRoute<bool>(builder: (_) => ProcessingFormScreen(direction: kProcPaid, edit: _d)));
      if (ok == true) {
        _changed = true;
        await _load();
      }
      return;
    }
    final Map<String, dynamic>? v = await showEditDocDialog(context, 'ویرایش سفارش فراوری', <EditField>[
      EditField('date', 'تاریخ', _d['date'], kind: EditKind.date),
      EditField('note', 'توضیح', _d['note']),
    ]);
    if (v == null || !mounted) return;
    if (await submitDocEdit(context, 'processing.update', <String, dynamic>{'id': _d['id'], ...v}, baseVersion: _d['edit_version']) != null) {
      _changed = true;
      await _load();
    }
  }

  /// فاز ۲: وضعیت چرخهٔ عمر عملیات داخلی + «بازکردن برای اصلاح» (فقط workshop.manage؛ پیام روشن اگر خروجی مصرف شده و در کدام سند).
  Widget _flowCard() {
    final bool open = '${_d['status']}' == kWsOpen;
    final String? block = _d['reopen_block'] as String?;
    final bool manage = _can('workshop.manage');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(open ? 'وضعیت: در کارگاه (باز) — خروجی‌ها هنوز وارد موجودی نشده‌اند' : 'وضعیت: بسته${_d['closed_at'] == null ? '' : ' در ${jalaliDate('${_d['closed_at']}')}'}'),
            const SizedBox(height: 8),
            if (open)
              FilledButton.icon(
                onPressed: () async {
                  await Navigator.pushReplacement(context, MaterialPageRoute<bool>(builder: (_) => WorkshopOpScreen(orderUid: _d['uid'] as String?, id: _n(_d['id']).toInt())));
                },
                icon: const Icon(Icons.edit_note),
                label: const Text('ادامهٔ ثبت ورودی/خروجی'),
              )
            else if (manage) ...<Widget>[
              OutlinedButton.icon(onPressed: block == null ? _reopen : null, icon: const Icon(Icons.lock_open), label: const Text('بازکردن برای اصلاح')),
              if (block != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(block, style: const TextStyle(color: Colors.orange))),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _reopen() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        title: const Text('بازکردن برای اصلاح'),
        content: const Text('لات‌های خروجی و بهای آن‌ها حذف می‌شوند تا عملیات دوباره بسته شود؛ ورودی‌ها از موجودی کم‌شده می‌مانند. ادامه می‌دهید؟'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('بازکردن')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await StockApi.call('workshop.reopen', <String, dynamic>{'id': _d['id']});
      _changed = true;
      if (!mounted) return;
      await Navigator.pushReplacement(context, MaterialPageRoute<bool>(builder: (_) => WorkshopOpScreen(orderUid: _d['uid'] as String?, id: _n(_d['id']).toInt())));
    } on StockApiException catch (e) {
      _snack(e.message);
    }
  }

  /// بهای کارگاه داخلی (مرحلهٔ ۲؛ مقادیر سرور). فقط با price.view + workshop.cost دیده می‌شود.
  Widget _costCard() {
    final bool has = _d['cost_sound'] != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('بها (${Fmt.unitLabel()})', style: Theme.of(context).textTheme.titleMedium),
            Text('قیمت خرید هر کیلو (از بهای لات‌های ورودی): ${_d['buy_per_kg'] == null ? '—' : _money(_d['buy_per_kg'])}'),
            if ('${_d['input_cost_warning'] ?? ''}' == 'missing_input_cost') const Text(kWsMissingInputCost, style: TextStyle(color: Colors.orange)),
            if (!has) const Text('بها هنوز ثبت نشده است.')
            else ...<Widget>[
              Text('ارزش ورودی (W): ${_money(_d['value_in'])}'),
              Text('هزینه تولید (Z): ${_money(_d['cost_total'])}'),
              Text('ارزش محصولات فرعی (AF): ${_money(_d['recovery_value'])}'),
              Text('بهای تمام‌شدهٔ سالم (AG): ${_money(_d['cost_sound'])}', style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(_d['cost_per_kg_sound'] == null ? 'بهای هر کیلو سالم: —' : 'بهای هر کیلو سالم (AH): ${_money(_d['cost_per_kg_sound'])}'),
              if ('${_d['cost_warning'] ?? ''}'.isNotEmpty) const Text('هشدار: بهای سالم منفی است (ارزش فرعی بیش از هزینه).', style: TextStyle(color: Colors.orange)),
            ],
            const SizedBox(height: 8),
            OutlinedButton.icon(onPressed: _editCost, icon: const Icon(Icons.edit_outlined), label: Text(has ? 'ویرایش بها' : 'ثبت بها')),
          ],
        ),
      ),
    );
  }

  Future<void> _editCost() async {
    final Map<String, TextEditingController> ctl = <String, TextEditingController>{
      for (final List<String> f in kWsCostFields) f[0]: TextEditingController(text: _d[f[0]] == null ? '' : '${_d[f[0]]}'),
    };
    // مرحلهٔ ۵: قیمت هر کیلو جلوی هر خروجی غیرسالم (id ردیف خروجی → کنترلر)
    final List<Map<dynamic, dynamic>> rows = <Map<dynamic, dynamic>>[
      if (_d['outputs'] is List)
        for (final dynamic x in (_d['outputs'] as List<dynamic>))
          if (x is Map && x['id'] != null && '${x['grade']}' != 'sound') x,
    ];
    final Map<String, TextEditingController> pctl = <String, TextEditingController>{
      for (final Map<dynamic, dynamic> x in rows) '${x['id']}': TextEditingController(text: x['out_price'] == null ? '' : '${x['out_price']}'),
    };
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('ثبت بهای کارگاه'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: wsReadOnlyField(kWsBuyLabel, _d['buy_per_kg'] == null ? '—' : _money(_d['buy_per_kg']), helper: 'محاسبهٔ خودکار؛ قابل ویرایش نیست'),
              ),
              if ('${_d['input_cost_warning'] ?? ''}' == 'missing_input_cost')
                const Padding(padding: EdgeInsets.only(bottom: 8), child: Text(kWsMissingInputCost, style: TextStyle(color: Colors.orange))),
              for (final List<String> f in kWsCostFields)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    controller: ctl[f[0]],
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(labelText: f[1], border: const OutlineInputBorder()),
                  ),
                ),
              for (final Map<dynamic, dynamic> x in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    controller: pctl['${x['id']}'],
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: 'قیمت هر کیلو — ${'${x['grade']}' == 'custom' ? '${x['type_name'] ?? 'سایر'}' : (kWsGradeLabels['${x['grade']}'] ?? '${x['type_name'] ?? ''}')} (${_kg(x['kg'])} کیلو)',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ذخیره')),
        ],
      ),
    );
    final Map<String, dynamic> payload = <String, dynamic>{'id': _d['id']};
    if (ok == true) {
      ctl.forEach((String k, TextEditingController c) {
        if (c.text.trim().isNotEmpty) payload[k] = wsParseNum(c.text);
      });
      payload['outputs'] = <Map<String, dynamic>>[
        for (final Map<dynamic, dynamic> x in rows)
          <String, dynamic>{'id': x['id'], 'price_per_kg': pctl['${x['id']}']!.text.trim().isEmpty ? null : wsParseNum(pctl['${x['id']}']!.text)},
      ];
    }
    for (final TextEditingController c in ctl.values) {
      c.dispose();
    }
    for (final TextEditingController c in pctl.values) {
      c.dispose();
    }
    if (ok != true) return;
    await _run('workshop.cost_save', payload, 'بهای کارگاه');
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
  DateTime _date = DateTime.now();
  final List<_OutLine> _outs = <_OutLine>[_OutLine()];
  late final OutsideReceiptCtl _rc = OutsideReceiptCtl(widget.order); // مرحلهٔ ۴: مغز/گرم دریافتی (فقط paid)
  bool _saving = false;

  bool get _paidOrder => '${widget.order['direction']}' == kProcPaid;

  double get _inKg => _n(widget.order['input_kg']);
  double get _outKg => _outs.fold<double>(0.0, (double s, _OutLine l) => s + _numText(l.kg.text));
  double get _wasteKg => _numText(_waste.text);
  double get _balance => _inKg - _outKg - _wasteKg;
  double get _yield => _inKg > 0 ? _outKg / _inKg * 100 : 0;
  double get _standard => _n(widget.order['standard_yield_pct']);

  @override
  void dispose() {
    _waste.dispose();
    _rc.dispose();
    for (final _OutLine l in _outs) {
      l.dispose();
    }
    super.dispose();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _submit() async {
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
        'date': ReturnsHelp.iso(_date),
        'waste_kg': _wasteKg,
        'outputs': outputs,
        if (_paidOrder) ..._rc.recvPayload(clearEmpty: false),
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
    final bool wide = kWideForm(context);
    final double g = kFormGap;

    final Widget summary = Card(
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
    );

    final Widget wasteField = TextField(
      controller: _waste,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onChanged: (_) => setState(() {}),
      decoration: const InputDecoration(labelText: 'ضایعات (کیلو)', border: OutlineInputBorder()),
    );
    final Widget dateField = JalaliDateField(label: 'تاریخ دریافت', value: _date, onChanged: (DateTime d) => setState(() => _date = d));

    Widget outLine(int i) {
      final Widget name = TextField(controller: _outs[i].name, decoration: const InputDecoration(labelText: 'نوع خروجی', border: OutlineInputBorder()));
      final Widget kg = TextField(
        controller: _outs[i].kg,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(labelText: 'کیلو', border: OutlineInputBorder()),
      );
      final Widget small = TextField(
        controller: _outs[i].small,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(labelText: 'گونی کوچک', border: OutlineInputBorder()),
      );
      final Widget large = TextField(
        controller: _outs[i].large,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(labelText: 'گونی بزرگ', border: OutlineInputBorder()),
      );
      final Widget del = IconButton(
        tooltip: 'حذف خروجی',
        icon: const Icon(Icons.delete_outline),
        onPressed: () => setState(() {
          _outs.removeAt(i).dispose();
        }),
      );
      if (wide) {
        return Padding(
          padding: EdgeInsets.only(bottom: g),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(flex: 3, child: name),
              const SizedBox(width: 8),
              Expanded(flex: 2, child: kg),
              const SizedBox(width: 8),
              Expanded(flex: 2, child: small),
              const SizedBox(width: 8),
              Expanded(flex: 2, child: large),
              if (_outs.length > 1) del else const SizedBox(width: 48),
            ],
          ),
        );
      }
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            children: <Widget>[
              name,
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(child: kg),
                  const SizedBox(width: 8),
                  Expanded(child: small),
                  const SizedBox(width: 8),
                  Expanded(child: large),
                ],
              ),
              if (_outs.length > 1) Align(alignment: AlignmentDirectional.centerEnd, child: del),
            ],
          ),
        ),
      );
    }

    final Widget outputs = FormSection(title: 'خروجی‌ها', children: <Widget>[
      for (int i = 0; i < _outs.length; i++) outLine(i),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          onPressed: () => setState(() => _outs.add(_OutLine())),
          icon: const Icon(Icons.add),
          label: const Text('افزودن خروجی'),
        ),
      ),
    ]);

    final Widget receipt = FormSection(title: 'مغز و گرم دریافتی (اختیاری)', children: <Widget>[
      OutsideReceiptFields(ctl: _rc, sentKg: _inKg, showSent: false, showRecv: true, onChanged: () => setState(() {})),
    ]);

    final Widget submit = FilledButton.icon(
      onPressed: _saving || !ok ? null : _submit,
      icon: _saving
          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.check),
      label: const Text('ثبت دریافت'),
    );

    return FormPage(
      title: 'دریافت خروجی',
      actions: <Widget>[submit],
      children: <Widget>[
        if (wide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(flex: 3, child: outputs),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
                  summary,
                  FormSection(title: 'ضایعات و تاریخ', children: <Widget>[
                    FormGrid(gap: 12, minColWidth: 200, children: <Widget>[
                      Padding(padding: EdgeInsets.only(bottom: g), child: wasteField),
                      Padding(padding: EdgeInsets.only(bottom: g), child: dateField),
                    ]),
                  ]),
                  if (_paidOrder) receipt,
                ]),
              ),
            ],
          )
        else ...<Widget>[
          summary,
          const SizedBox(height: 12),
          wasteField,
          const SizedBox(height: 10),
          dateField,
          if (_paidOrder) ...<Widget>[
            const SizedBox(height: 14),
            Text('مغز و گرم دریافتی (اختیاری)', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            OutsideReceiptFields(ctl: _rc, sentKg: _inKg, showSent: false, showRecv: true, onChanged: () => setState(() {})),
          ],
          const SizedBox(height: 14),
          Text('خروجی‌ها', style: Theme.of(context).textTheme.titleMedium),
          for (int i = 0; i < _outs.length; i++) outLine(i),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => setState(() => _outs.add(_OutLine())),
              icon: const Icon(Icons.add),
              label: const Text('افزودن خروجی'),
            ),
          ),
        ],
      ],
    );
  }
}
