import 'package:flutter/material.dart';

import 'db.dart';
import 'fmt.dart' show Fmt;
import 'perms.dart';
import 'processing_ui.dart' show ProcessingStore;
import 'returns_ui.dart' show ReturnsHelp;
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException, StockLookup, WhOption;
import 'widgets.dart' show JalaliDateField, confirm;
import 'workshop_calc.dart';
import 'workshop_ui.dart' show kWsBuyLabel, kWsCostFields, kWsMissingInputCost, wsCanCost, wsParseNum, wsReadOnlyField;

/// فاز ۲ مجد — «کارگاه مرحله‌ای» (فایل مشترک اندروید و ویندوز؛ بدون واژهٔ مخصوص پلتفرم).
///   [WorkshopOpenFormScreen]  شروع عملیات: سربرگ + ورودی‌ها ⇒ workshop.open (ورودی‌ها همان لحظه از موجودی کم می‌شوند).
///   [WorkshopOpsScreen]       فهرست عملیات کارگاه با فیلتر «عملیات باز» و جمع «در کارگاه».
///   [WorkshopOpScreen]        جزئیات یک عملیات: ورودی‌ها (افزودن/حذف)، خروجی‌ها (افزودن/ویرایش/حذف)، نوار زنده، «بستن عملیات»، «بازکردن برای اصلاح».
/// همهٔ نوشتن‌ها با ProcessingStore.write (آنلاین‌اول؛ قطع شبکه ⇒ صف FIFO با uid؛ ترتیب ثبت حفظ می‌شود: output_save قبل از close).
/// سفارش با order_uid شناخته می‌شود تا اکشن‌های صف حتی قبل از رسیدن workshop.open به سرور معتبر باشند.
/// نمای آفلاین = آخرین پاسخ workshop.get (کش) + اکشن‌های صف همین عملیات با wsFlowApply (آینهٔ قواعد سرور).

String _kg(dynamic v) => faNum(ReturnsHelp.d(v), dec: 3);
bool _can(String k) => StaffPerms.I.can(k);
void _snack(BuildContext c, String m) => ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

/// کلید کش/صف یک عملیات: uid سرور یا «id<شناسه>» برای عملیات قدیمی بدون uid.
String wsOpKey(String? uid, int? id) => (uid != null && uid.isNotEmpty) ? uid : 'id${id ?? 0}';

/// لات‌های قابل‌برداشت: اپراتور ⇒ workshop.lots (شناسهٔ سرور، بدون قیمت)؛ بقیه ⇒ موجودی محلی (شناسهٔ محلی؛ هنگام ارسال به سرور تبدیل می‌شود).
class WsLotPicker {
  WsLotPicker._();
  static bool get serverIds => StaffPerms.I.isWorkshopOperatorOnly;

  static Future<Map<String, String>> load() async {
    final Map<String, String> lots = <String, String>{};
    if (serverIds) {
      final Map<String, dynamic> r = await StockApi.call('workshop.lots');
      for (final Map<String, dynamic> l in ReturnsHelp.maps(r['items'])) {
        final double rem = ReturnsHelp.d(l['remaining']);
        if (rem > 0) lots['${l['id']}'] = '${l['code'] ?? ''} · ${l['type_name'] ?? ''} · ${faNum(rem, dec: 3)} کیلو';
      }
      return lots;
    }
    for (final Map<String, dynamic> r in await AppDb.I.inventoryAll()) {
      final double rem = ReturnsHelp.d(r['remaining']);
      if (rem <= 0 || ReturnsHelp.d(r['is_mix']) == 3) continue;
      lots['${r['id']}'] = '${r['code'] ?? ''} · ${r['type_name'] ?? ''} · ${faNum(rem, dec: 3)} کیلو';
    }
    return lots;
  }

  static Future<int> serverId(String key) async {
    if (serverIds) return int.parse(key);
    return ReturnsHelp.serverId('purchase', int.parse(key));
  }
}

// ---------------------------------------------------------------------------
// شروع عملیات (open)
// ---------------------------------------------------------------------------

class _InRow {
  final TextEditingController kg = TextEditingController();
  String? lot;
}

class WorkshopOpenFormScreen extends StatefulWidget {
  const WorkshopOpenFormScreen({super.key});

  @override
  State<WorkshopOpenFormScreen> createState() => _WorkshopOpenFormScreenState();
}

class _WorkshopOpenFormScreenState extends State<WorkshopOpenFormScreen> {
  DateTime _date = DateTime.now();
  String _op = 'dehull';
  final TextEditingController _owner = TextEditingController();
  final TextEditingController _ptype = TextEditingController();
  final TextEditingController _defect = TextEditingController();
  final TextEditingController _initial = TextEditingController();
  final TextEditingController _bales = TextEditingController();
  final TextEditingController _note = TextEditingController();
  final List<_InRow> _ins = <_InRow>[_InRow()];
  Map<String, String> _lots = <String, String>{};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    WsLotPicker.load().then((Map<String, String> l) {
      if (mounted) setState(() => _lots = l);
    }).catchError((Object e) {
      if (mounted) _snack(context, e is StockApiException ? e.message : '$e');
    });
  }

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[_owner, _ptype, _defect, _initial, _bales, _note]) {
      c.dispose();
    }
    for (final _InRow r in _ins) {
      r.kg.dispose();
    }
    super.dispose();
  }

  double get _inKg => _ins.fold<double>(0, (double s, _InRow r) => s + wsParseNum(r.kg.text));

  Future<void> _submit() async {
    final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
    for (final _InRow r in _ins) {
      if (r.lot == null) return _snack(context, 'برای هر ورودی لات انبار را انتخاب کنید');
      if (wsParseNum(r.kg.text) <= 0) return _snack(context, 'وزن هر ورودی باید بیشتر از صفر باشد');
    }
    setState(() => _saving = true);
    try {
      for (final _InRow r in _ins) {
        final double kg = wsParseNum(r.kg.text);
        items.add(<String, dynamic>{
          'uid': ReturnsHelp.newUid('wi'),
          'purchase_id': await WsLotPicker.serverId(r.lot!),
          'kg': kg,
          'code': _lots[r.lot]?.split(' · ').first, // فقط برای نمای آفلاین؛ سرور نادیده می‌گیرد
        });
      }
      final String uid = ReturnsHelp.newUid('wo');
      final Map<String, dynamic> payload = <String, dynamic>{
        'uid': uid,
        'op_type': _op,
        'start_date': ReturnsHelp.iso(_date),
        'owner': _owner.text.trim(),
        'defect_note': _defect.text.trim(),
        'note': _note.text.trim(),
        'items': items,
      };
      if (_ptype.text.trim().isNotEmpty) payload['pistachio_type'] = _ptype.text.trim();
      if (_initial.text.trim().isNotEmpty) payload['initial_kg'] = wsParseNum(_initial.text);
      if (_bales.text.trim().isNotEmpty) payload['bale_count'] = wsParseNum(_bales.text);
      final bool queued = await ProcessingStore.write('workshop.open', payload, 'شروع عملیات کارگاه: ${kWsOpLabels[_op]}');
      if (!mounted) return;
      _snack(context, queued ? 'آفلاین ذخیره شد؛ پس از اتصال ارسال می‌شود' : 'عملیات باز شد؛ خروجی‌ها را در طول کار ثبت کنید');
      Navigator.pushReplacement(context, MaterialPageRoute<bool>(builder: (_) => WorkshopOpScreen(orderUid: uid)));
    } on StockApiException catch (e) {
      _snack(context, e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _num(TextEditingController c, String label, {bool live = false}) => TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        onChanged: live ? (_) => setState(() {}) : null,
      );

  @override
  Widget build(BuildContext context) {
    const SizedBox gap = SizedBox(height: 10);
    return Scaffold(
      appBar: AppBar(title: const Text('شروع عملیات کارگاه')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: <Widget>[
          DropdownButtonFormField<String>(
            initialValue: _op,
            decoration: const InputDecoration(labelText: 'نوع عملیات', border: OutlineInputBorder()),
            items: <DropdownMenuItem<String>>[
              for (final String k in kWsOpTypes) DropdownMenuItem<String>(value: k, child: Text(kWsOpLabels[k] ?? k)),
            ],
            onChanged: (String? v) => setState(() => _op = v ?? 'dehull'),
          ),
          gap,
          JalaliDateField(label: 'تاریخ شروع', value: _date, onChanged: (DateTime d) => setState(() => _date = d)),
          gap,
          TextField(controller: _owner, decoration: const InputDecoration(labelText: 'مالک', border: OutlineInputBorder())),
          gap,
          TextField(controller: _ptype, decoration: const InputDecoration(labelText: 'نوع پسته (خالی = نوع لات اصلی)', border: OutlineInputBorder())),
          gap,
          TextField(controller: _defect, decoration: const InputDecoration(labelText: 'ایراد بار (اختیاری)', border: OutlineInputBorder())),
          gap,
          Row(children: <Widget>[
            Expanded(child: _num(_initial, 'وزن خالص اولیه (کیلو)')),
            const SizedBox(width: 8),
            Expanded(child: _num(_bales, 'تعداد عدل')),
          ]),
          const SizedBox(height: 16),
          Text('ورودی از انبار (همین حالا از موجودی کم می‌شود)', style: Theme.of(context).textTheme.titleMedium),
          for (int i = 0; i < _ins.length; i++)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Expanded(
                  flex: 3,
                  child: DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: _ins[i].lot,
                    decoration: const InputDecoration(labelText: 'لات', border: OutlineInputBorder()),
                    items: <DropdownMenuItem<String>>[
                      for (final MapEntry<String, String> e in _lots.entries)
                        DropdownMenuItem<String>(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (String? v) => setState(() => _ins[i].lot = v),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(flex: 2, child: _num(_ins[i].kg, 'وزن (کیلو)', live: true)),
                if (_ins.length > 1)
                  IconButton(
                    tooltip: 'حذف ورودی',
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: () => setState(() => _ins.removeAt(i).kg.dispose()),
                  ),
              ]),
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(onPressed: () => setState(() => _ins.add(_InRow())), icon: const Icon(Icons.add), label: const Text('ورودی دیگر')),
          ),
          Text('جمع ورودی: ${faNum(_inKg, dec: 3)} کیلو'),
          gap,
          TextField(controller: _note, decoration: const InputDecoration(labelText: 'یادداشت (اختیاری)', border: OutlineInputBorder())),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _saving ? null : _submit,
            icon: const Icon(Icons.play_arrow),
            label: Text(_saving ? 'در حال ثبت…' : 'شروع عملیات'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// فهرست عملیات
// ---------------------------------------------------------------------------

class WorkshopOpsScreen extends StatefulWidget {
  const WorkshopOpsScreen({super.key, this.onlyOpen = true});
  final bool onlyOpen;

  @override
  State<WorkshopOpsScreen> createState() => _WorkshopOpsScreenState();
}

class _WorkshopOpsScreenState extends State<WorkshopOpsScreen> {
  late bool _onlyOpen = widget.onlyOpen;
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _queuedOpens = <Map<String, dynamic>>[];
  double _inWs = 0;
  int _openCount = 0;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final List<String> flushErr = await ProcessingStore.flush();
    String? err;
    try {
      final Map<String, dynamic> r = await StockApi.call('workshop.list');
      _items = ReturnsHelp.maps(r['items']);
      _inWs = ReturnsHelp.d(r['in_workshop_kg']);
      _openCount = ReturnsHelp.d(r['open_count']).toInt();
      await ProcessingStore.cacheWorkshopList(r);
    } on StockApiException catch (e) {
      err = e.message;
      final Map<String, dynamic> c = await ProcessingStore.cachedWorkshopList();
      _items = ReturnsHelp.maps(c['items']);
      _inWs = ReturnsHelp.d(c['in_workshop_kg']);
      _openCount = ReturnsHelp.d(c['open_count']).toInt();
    }
    _queuedOpens = <Map<String, dynamic>>[
      for (final Map<String, dynamic> op in await ProcessingStore.pendingOps())
        if (op['action'] == 'workshop.open' && op['payload'] is Map) Map<String, dynamic>.from(op['payload'] as Map),
    ];
    if (!mounted) return;
    setState(() {
      _error = err ?? (flushErr.isEmpty ? null : flushErr.join('\n'));
      _loading = false;
    });
  }

  Future<void> _go(Widget page) async {
    await Navigator.push(context, MaterialPageRoute<Object>(builder: (_) => page));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final List<Map<String, dynamic>> visible = _onlyOpen ? _items.where((Map<String, dynamic> o) => o['status'] == kWsOpen).toList() : _items;
    return Scaffold(
      appBar: AppBar(
        title: const Text('عملیات کارگاه'),
        actions: <Widget>[IconButton(tooltip: 'به‌روزرسانی', icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      floatingActionButton: _can('workshop.operate') || _can('processing.create')
          ? FloatingActionButton.extended(
              onPressed: () => _go(const WorkshopOpenFormScreen()),
              icon: const Icon(Icons.play_arrow),
              label: const Text('شروع عملیات'),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
          children: <Widget>[
            Wrap(spacing: 8, children: <Widget>[
              FilterChip(
                label: Text('عملیات باز (${faNum(_openCount + _queuedOpens.length, dec: 0)})'),
                selected: _onlyOpen,
                onSelected: (bool v) => setState(() => _onlyOpen = v),
              ),
            ]),
            const SizedBox(height: 6),
            Text('در کارگاه (ورودی کم‌شده از انبار، خروجی هنوز در انبار نیست): ${faNum(_inWs, dec: 3)} کیلو'),
            if (_error != null)
              Card(color: Theme.of(context).colorScheme.errorContainer, child: Padding(padding: const EdgeInsets.all(10), child: Text(_error!))),
            if (_loading) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
            for (final Map<String, dynamic> p in _queuedOpens)
              if (!_items.any((Map<String, dynamic> o) => o['uid'] == p['uid']))
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.cloud_upload_outlined),
                    title: Text('${kWsOpLabels['${p['op_type']}'] ?? 'کارگاه'}  •  در صف ارسال'),
                    subtitle: Text('${jalaliDate('${p['start_date'] ?? ''}')}  •  مالک ${p['owner'] ?? ''}'),
                    onTap: () => _go(WorkshopOpScreen(orderUid: '${p['uid']}')),
                  ),
                ),
            if (!_loading && visible.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('عملیاتی نیست'))),
            for (final Map<String, dynamic> o in visible) wsOpTile(context, o, () => _go(WorkshopOpScreen(orderUid: o['uid'] as String?, id: ReturnsHelp.d(o['id']).toInt()))),
          ],
        ),
      ),
    );
  }
}

/// کاشی یک عملیات داخلی (فهرست کارگاه و صفحهٔ فراوری).
Widget wsOpTile(BuildContext context, Map<String, dynamic> o, VoidCallback onTap) {
  final bool open = o['status'] == kWsOpen;
  final bool? ok = o['balance_ok'] is bool ? o['balance_ok'] as bool : null;
  final String state = open ? 'در کارگاه (باز)' : (ok == false ? 'نیاز به بررسی' : 'بسته');
  return Card(
    child: ListTile(
      leading: Icon(open ? Icons.pending_actions : (ok == false ? Icons.warning_amber_rounded : Icons.factory_outlined), color: open ? Colors.blue : (ok == false ? Colors.orange : null)),
      title: Text('${kWsOpLabels['${o['op_type']}'] ?? o['op_type'] ?? 'کارگاه'}${'${o['owner'] ?? ''}'.isEmpty ? '' : '  •  ${o['owner']}'}  •  $state'),
      subtitle: Text('${jalaliDate('${o['started_at'] ?? o['date'] ?? ''}')}${o['closed_at'] == null ? '' : ' تا ${jalaliDate('${o['closed_at']}')}'}\n'
          'ورودی ${_kg(o['input_kg'])} · خروجی ${_kg(o['output_kg'])} · افت ${_kg(o['loss_kg'])} کیلو'),
      isThreeLine: true,
      onTap: onTap,
    ),
  );
}

// ---------------------------------------------------------------------------
// جزئیات عملیات
// ---------------------------------------------------------------------------

class WorkshopOpScreen extends StatefulWidget {
  const WorkshopOpScreen({super.key, this.orderUid, this.id});
  final String? orderUid;
  final int? id;

  @override
  State<WorkshopOpScreen> createState() => _WorkshopOpScreenState();
}

class _WorkshopOpScreenState extends State<WorkshopOpScreen> {
  Map<String, dynamic> _d = <String, dynamic>{};
  int _pending = 0;
  String? _error;
  bool _loading = true;
  bool _busy = false;
  bool _changed = false;

  String? get _uid => (_d['uid'] as String?) ?? widget.orderUid;
  int? get _id => _d['id'] == null ? widget.id : ReturnsHelp.d(_d['id']).toInt();
  bool get _open => _d['status'] == kWsOpen;

  /// شناسهٔ سفارش برای اکشن‌ها (هم id و هم order_uid اگر معلوم است).
  Map<String, dynamic> get _ref => <String, dynamic>{
        if (_id != null && _id! > 0) 'id': _id,
        if (_uid != null) 'order_uid': _uid,
      };

  @override
  void initState() {
    super.initState();
    _load();
  }

  bool _mine(Map<String, dynamic> op) {
    final dynamic p = op['payload'];
    if (p is! Map || !'${op['action']}'.startsWith('workshop.')) return false;
    if (_uid != null && (p['order_uid'] == _uid || (op['action'] == 'workshop.open' && p['uid'] == _uid))) return true;
    return _id != null && _id! > 0 && p['id'] == _id && op['action'] != 'workshop.open';
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    await ProcessingStore.flush();
    Map<String, dynamic> base = <String, dynamic>{};
    String? err;
    try {
      base = await StockApi.call('workshop.get', <String, dynamic>{
        if (widget.id != null && widget.id! > 0) 'id': widget.id,
        if (widget.orderUid != null) 'order_uid': widget.orderUid,
      });
      await ProcessingStore.cacheDetail(wsOpKey(base['uid'] as String? ?? widget.orderUid, ReturnsHelp.d(base['id']).toInt()), base);
    } on StockApiException catch (e) {
      base = await ProcessingStore.cachedDetail(wsOpKey(widget.orderUid, widget.id)) ?? <String, dynamic>{};
      if (!(e.network || e.code == 404)) err = e.message;
      if (e.network) err = 'آفلاین: آخرین اطلاعات ذخیره‌شده + تغییرات در صف نمایش داده می‌شود';
    }
    _d = base;
    // نمای محلی: اکشن‌های صفِ همین عملیات روی آخرین پاسخ سرور
    final List<Map<String, dynamic>> ops = (await ProcessingStore.pendingOps()).where(_mine).toList();
    for (final Map<String, dynamic> op in ops) {
      _d = wsFlowApply(_d, '${op['action']}'.substring('workshop.'.length), Map<String, dynamic>.from(op['payload'] as Map)).state;
    }
    if (!mounted) return;
    setState(() {
      _pending = ops.length;
      _error = err;
      _loading = false;
    });
  }

  /// ارسال یک اکشن با قواعد محلی (wsFlowCheck) قبل از سرور.
  Future<void> _send(String action, Map<String, dynamic> payload, String label, {String? localError}) async {
    if (localError != null) return _snack(context, kWsFlowErrors[localError] ?? localError);
    setState(() => _busy = true);
    try {
      final bool queued = await ProcessingStore.write('workshop.$action', <String, dynamic>{..._ref, ...payload}, label);
      _changed = true;
      if (mounted && queued) _snack(context, 'آفلاین ذخیره شد؛ پس از اتصال ارسال می‌شود');
      await _load();
    } on StockApiException catch (e) {
      if (mounted) _snack(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<Map<String, dynamic>> get _ins => ReturnsHelp.maps(_d['inputs']);
  List<Map<String, dynamic>> get _outs => ReturnsHelp.maps(_d['outputs']);

  // ── ورودی ──
  Future<void> _addInput() async {
    Map<String, String> lots;
    try {
      lots = await WsLotPicker.load();
    } on StockApiException catch (e) {
      if (mounted) _snack(context, e.message);
      return;
    }
    if (!mounted) return;
    String? lot;
    final TextEditingController kg = TextEditingController();
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => StatefulBuilder(
        builder: (BuildContext c, StateSetter set) => AlertDialog(
          title: const Text('افزودن ورودی'),
          content: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: lot,
              decoration: const InputDecoration(labelText: 'لات', border: OutlineInputBorder()),
              items: <DropdownMenuItem<String>>[
                for (final MapEntry<String, String> e in lots.entries) DropdownMenuItem<String>(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (String? v) => set(() => lot = v),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: kg,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'وزن (کیلو)', border: OutlineInputBorder()),
            ),
          ]),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('انصراف')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('افزودن')),
          ],
        ),
      ),
    );
    final double w = wsParseNum(kg.text);
    kg.dispose();
    if (ok != true || !mounted) return;
    if (lot == null || w <= 0) return _snack(context, 'لات و وزن بیشتر از صفر لازم است');
    await _send(
      'input_add',
      <String, dynamic>{'uid': ReturnsHelp.newUid('wi'), 'purchase_id': await WsLotPicker.serverId(lot!), 'kg': w, 'code': lots[lot]?.split(' · ').first},
      'ورودی کارگاه: ${faNum(w, dec: 3)} کیلو',
      localError: wsFlowCheck(_d['status'] as String?, 'input_add'),
    );
  }

  Future<void> _removeInput(Map<String, dynamic> r) async {
    if (!await confirm(context, 'این ورودی برداشته شود و به موجودی لات برگردد؟')) return;
    await _send(
      'input_remove',
      <String, dynamic>{if (r['id'] != null) 'input_id': r['id'], if (r['uid'] != null) 'input_uid': r['uid']},
      'برداشتن ورودی کارگاه',
      localError: wsFlowCheck(_d['status'] as String?, 'input_remove', inputs: _ins.length),
    );
  }

  // ── خروجی ──
  Future<void> _editOutput([Map<String, dynamic>? r]) async {
    final Map<String, dynamic>? res = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _OutputDialog(row: r, defaultOwner: '${_d['owner'] ?? ''}'),
    );
    if (res == null) return;
    await _send(
      'output_save',
      <String, dynamic>{
        'uid': r?['uid'] ?? ReturnsHelp.newUid('wx'),
        if (r?['id'] != null) 'output_id': r!['id'],
        ...res,
      },
      'خروجی کارگاه: ${res['grade'] == kWsCustomGrade ? res['type_name'] : kWsGradeLabels[res['grade']]} ${faNum(ReturnsHelp.d(res['kg']), dec: 3)} کیلو',
      localError: wsFlowCheck(_d['status'] as String?, 'output_save'),
    );
  }

  Future<void> _deleteOutput(Map<String, dynamic> r) async {
    if (!await confirm(context, 'این ردیف خروجی حذف شود؟')) return;
    await _send(
      'output_delete',
      <String, dynamic>{if (r['id'] != null) 'output_id': r['id'], if (r['uid'] != null) 'uid': r['uid']},
      'حذف خروجی کارگاه',
      localError: wsFlowCheck(_d['status'] as String?, 'output_delete'),
    );
  }

  // ── بستن / بازکردن ──
  Future<void> _close() async {
    final WsBalance t = wsFlowTotals(_d);
    final String? rule = wsFlowCheck(_d['status'] as String?, 'close', inputs: _ins.length, outputs: _outs.length, lossG: wsGrams(t.lossKg));
    if (rule != null) return _snack(context, kWsFlowErrors[rule]!);
    final Map<String, dynamic>? res = await showDialog<Map<String, dynamic>>(context: context, builder: (_) => _CloseDialog(detail: _d, totals: t));
    if (res == null) return;
    await _send('close', res, 'بستن عملیات کارگاه');
  }

  Future<void> _reopen() async {
    final String? block = _d['reopen_block'] as String?;
    if (block != null) return _snack(context, block);
    if (!await confirm(context, 'عملیات برای اصلاح باز شود؟ لات‌های خروجی و بهای آن‌ها حذف می‌شوند تا دوباره بسته شود؛ ورودی‌ها از موجودی کم‌شده می‌مانند.')) return;
    await _send('reopen', <String, dynamic>{}, 'بازکردن عملیات کارگاه', localError: wsFlowCheck(_d['status'] as String?, 'reopen'));
  }

  @override
  Widget build(BuildContext context) {
    final WsBalance t = wsFlowTotals(_d);
    final bool canManage = _can('workshop.manage');
    final bool edit = _open && !_busy;
    final Color tone = t.overOutput ? Colors.red : Colors.green;
    return Scaffold(
        appBar: AppBar(
          title: Text('${kWsOpLabels['${_d['op_type']}'] ?? 'عملیات کارگاه'}${_open ? ' — در کارگاه' : (_d['status'] == 'done' ? ' — بسته' : '')}'),
          leading: BackButton(onPressed: () => Navigator.pop(context, _changed)),
          actions: <Widget>[IconButton(tooltip: 'به‌روزرسانی', icon: const Icon(Icons.refresh), onPressed: _load)],
        ),
        body: _loading && _d.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
                  children: <Widget>[
                    if (_error != null)
                      Card(color: Theme.of(context).colorScheme.errorContainer, child: Padding(padding: const EdgeInsets.all(10), child: Text(_error!))),
                    if (_d.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('عملیات یافت نشد'))),
                    if (_pending > 0)
                      Card(child: ListTile(leading: const Icon(Icons.cloud_upload_outlined), title: Text('${faNum(_pending, dec: 0)} تغییر در صف ارسال'))),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                          Text('شروع: ${jalaliDate('${_d['started_at'] ?? _d['date'] ?? ''}')}${_d['closed_at'] == null ? '' : '  •  پایان: ${jalaliDate('${_d['closed_at']}')}'}'),
                          if ('${_d['owner'] ?? ''}'.isNotEmpty) Text('مالک: ${_d['owner']}'),
                          if ('${_d['pistachio_type'] ?? ''}'.isNotEmpty) Text('نوع پسته: ${_d['pistachio_type']}'),
                          if ('${_d['defect_note'] ?? ''}'.isNotEmpty) Text('ایراد بار: ${_d['defect_note']}'),
                          if (_d['initial_kg'] != null) Text('وزن خالص اولیه: ${_kg(_d['initial_kg'])} کیلو'),
                          if (_d['bale_count'] != null) Text('تعداد عدل: ${faNum(ReturnsHelp.d(_d['bale_count']), dec: 0)}'),
                        ]),
                      ),
                    ),
                    // نوار زنده
                    Card(
                      color: tone.withValues(alpha: 0.12),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Wrap(spacing: 16, runSpacing: 4, children: <Widget>[
                          Text('ورودی ${_kg(t.inputKg)}'),
                          Text('Σ خروجی ${_kg(t.inputKg - t.lossKg)}'),
                          Text('افت ${_kg(t.lossKg)}${t.lossPct == null ? '' : ' (${faNum(t.lossPct!, dec: 1)}٪)'}',
                              style: TextStyle(color: t.overOutput ? Colors.red : null, fontWeight: FontWeight.bold)),
                          Text('سالم ${t.soundPct == null ? '—' : '${faNum(t.soundPct!, dec: 1)}٪'}'),
                          if (t.overOutput) const Text('جمع خروجی‌ها از ورودی بیشتر است', style: TextStyle(color: Colors.red)),
                        ]),
                      ),
                    ),
                    _section('ورودی‌ها', <Widget>[
                      for (final Map<String, dynamic> r in _ins)
                        ListTile(
                          dense: true,
                          title: Text('${r['code'] ?? ''} ${r['type_name'] ?? ''}'.trim().isEmpty ? 'لات ${r['purchase_id'] ?? r['lot_id'] ?? ''}' : '${r['code'] ?? ''} ${r['type_name'] ?? ''}'),
                          subtitle: Text('${_kg(r['kg'])} کیلو${r['id'] == null ? '  •  در صف ارسال' : ''}'),
                          trailing: edit && _ins.length > 1
                              ? IconButton(tooltip: 'برداشتن ورودی', icon: const Icon(Icons.remove_circle_outline), onPressed: () => _removeInput(r))
                              : null,
                        ),
                    ], action: edit ? TextButton.icon(onPressed: _addInput, icon: const Icon(Icons.add), label: const Text('افزودن ورودی')) : null),
                    _section('خروجی‌ها (فقط هنگام بستن وارد موجودی می‌شوند)', <Widget>[
                      if (_outs.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('هنوز خروجی ثبت نشده')),
                      for (final Map<String, dynamic> r in _outs)
                        ListTile(
                          dense: true,
                          title: Text('${r['grade'] == kWsCustomGrade ? (r['type_name'] ?? 'سایر') : (kWsGradeLabels['${r['grade']}'] ?? r['grade'])} — ${_kg(r['kg'])} کیلو'),
                          subtitle: Text(<String>[
                            if (ReturnsHelp.d(r['small_sacks']) > 0 || ReturnsHelp.d(r['large_sacks']) > 0)
                              'گونی ${faNum(ReturnsHelp.d(r['small_sacks']), dec: 0)} کوچک / ${faNum(ReturnsHelp.d(r['large_sacks']), dec: 0)} بزرگ',
                            if ('${r['owner'] ?? ''}'.isNotEmpty) 'مالک ${r['owner']}',
                            if ('${r['code'] ?? ''}'.isNotEmpty) 'لات ${r['code']}',
                            if (r['id'] == null) 'در صف ارسال',
                          ].join('  •  ')),
                          onTap: edit ? () => _editOutput(r) : null,
                          trailing: edit ? IconButton(tooltip: 'حذف', icon: const Icon(Icons.delete_outline), onPressed: () => _deleteOutput(r)) : null,
                        ),
                    ], action: edit ? TextButton.icon(onPressed: () => _editOutput(), icon: const Icon(Icons.add), label: const Text('ثبت خروجی')) : null),
                    const SizedBox(height: 12),
                    if (_open && canManage)
                      FilledButton.icon(
                        onPressed: (_busy || t.overOutput) ? null : _close,
                        icon: const Icon(Icons.lock_outline),
                        label: const Text('بستن عملیات'),
                      ),
                    if (_open && !canManage) const Text('بستن عملیات با مدیر کارگاه است (مجوز workshop.manage).'),
                    if (_d['status'] == 'done' && canManage) ...<Widget>[
                      OutlinedButton.icon(
                        onPressed: (_busy || _d['reopen_block'] != null) ? null : _reopen,
                        icon: const Icon(Icons.lock_open),
                        label: const Text('بازکردن برای اصلاح'),
                      ),
                      if (_d['reopen_block'] != null)
                        Padding(padding: const EdgeInsets.only(top: 6), child: Text('${_d['reopen_block']}', style: const TextStyle(color: Colors.orange))),
                    ],
                  ],
                ),
              ),
    );
  }

  Widget _section(String title, List<Widget> children, {Widget? action}) => Card(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Row(children: <Widget>[Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)), if (action != null) action]),
            ...children,
          ]),
        ),
      );
}

/// فرم یک ردیف خروجی (درجه، نام برای «سایر»، کیلو، گونی، انبار، مالک، قیمت هر کیلو با مجوز بها).
class _OutputDialog extends StatefulWidget {
  const _OutputDialog({this.row, required this.defaultOwner});
  final Map<String, dynamic>? row;
  final String defaultOwner;

  @override
  State<_OutputDialog> createState() => _OutputDialogState();
}

class _OutputDialogState extends State<_OutputDialog> {
  late String _grade = '${widget.row?['grade'] ?? 'sound'}';
  late final TextEditingController _name = TextEditingController(text: widget.row?['grade'] == kWsCustomGrade ? '${widget.row?['type_name'] ?? ''}' : '');
  late final TextEditingController _kg = TextEditingController(text: widget.row == null ? '' : '${widget.row!['kg']}');
  late final TextEditingController _small = TextEditingController(text: '${widget.row?['small_sacks'] ?? 0}');
  late final TextEditingController _large = TextEditingController(text: '${widget.row?['large_sacks'] ?? 0}');
  late final TextEditingController _owner = TextEditingController(text: '${widget.row?['owner'] ?? widget.defaultOwner}');
  late final TextEditingController _price = TextEditingController(text: widget.row?['out_price'] == null ? '' : '${widget.row!['out_price']}');
  late String? _wh = widget.row?['warehouse_uid'] as String?;
  List<WhOption> _whs = <WhOption>[];

  @override
  void initState() {
    super.initState();
    StockLookup.warehouses().then((List<WhOption> w) {
      if (mounted) setState(() => _whs = w);
    }).catchError((Object _) {}); // بدون مجوز انبار ⇒ انبار پیش‌فرض عملیات
  }

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[_name, _kg, _small, _large, _owner, _price]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _num(TextEditingController c, String l) => TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: l, border: const OutlineInputBorder()),
      );

  @override
  Widget build(BuildContext context) {
    const SizedBox gap = SizedBox(height: 8);
    return AlertDialog(
      title: Text(widget.row == null ? 'ثبت خروجی' : 'ویرایش خروجی'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          DropdownButtonFormField<String>(
            initialValue: _grade,
            decoration: const InputDecoration(labelText: 'درجه', border: OutlineInputBorder()),
            items: <DropdownMenuItem<String>>[
              for (final String g in <String>[...kWsGrades, kWsCustomGrade]) DropdownMenuItem<String>(value: g, child: Text(kWsGradeLabels[g] ?? g)),
            ],
            onChanged: (String? v) => setState(() => _grade = v ?? 'sound'),
          ),
          if (_grade == kWsCustomGrade) ...<Widget>[
            gap,
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'نام خروجی', border: OutlineInputBorder())),
          ],
          gap,
          _num(_kg, 'وزن (کیلو)'),
          gap,
          Row(children: <Widget>[Expanded(child: _num(_small, 'گونی کوچک')), const SizedBox(width: 8), Expanded(child: _num(_large, 'گونی بزرگ'))]),
          gap,
          TextField(controller: _owner, decoration: const InputDecoration(labelText: 'مالک', border: OutlineInputBorder())),
          if (_whs.isNotEmpty) ...<Widget>[
            gap,
            DropdownButtonFormField<String?>(
              initialValue: _wh,
              decoration: const InputDecoration(labelText: 'انبار', border: OutlineInputBorder()),
              items: <DropdownMenuItem<String?>>[
                const DropdownMenuItem<String?>(value: null, child: Text('انبار عملیات (پیش‌فرض)')),
                for (final WhOption w in _whs) DropdownMenuItem<String?>(value: w.uid, child: Text(w.name)),
              ],
              onChanged: (String? v) => setState(() => _wh = v),
            ),
          ],
          if (wsCanCost() && _grade != 'sound') ...<Widget>[gap, _num(_price, 'قیمت فروش هر کیلو (اختیاری؛ هنگام بستن هم قابل ثبت)')],
        ]),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('انصراف')),
        FilledButton(
          onPressed: () {
            final double kg = wsParseNum(_kg.text);
            if (kg <= 0) return _snack(context, 'وزن باید بیشتر از صفر باشد');
            if (_grade == kWsCustomGrade && _name.text.trim().isEmpty) return _snack(context, 'نام خروجی جدید را وارد کنید');
            Navigator.pop(context, <String, dynamic>{
              'grade': _grade,
              'kg': kg,
              'small_sacks': wsParseNum(_small.text),
              'large_sacks': wsParseNum(_large.text),
              'owner': _owner.text.trim(),
              if (_grade == kWsCustomGrade) 'type_name': _name.text.trim(),
              if (_wh != null) 'warehouse_uid': _wh,
              if (wsCanCost() && _grade != 'sound' && _price.text.trim().isNotEmpty) 'price_per_kg': wsParseNum(_price.text),
            });
          },
          child: const Text('ذخیره'),
        ),
      ],
    );
  }
}

/// فرم بستن: تاریخ پایان + بها (فقط با مجوز). قیمت خرید (V) فقط‌نمایش از بهای لات‌های ورودی.
class _CloseDialog extends StatefulWidget {
  const _CloseDialog({required this.detail, required this.totals});
  final Map<String, dynamic> detail;
  final WsBalance totals;

  @override
  State<_CloseDialog> createState() => _CloseDialogState();
}

class _CloseDialogState extends State<_CloseDialog> {
  DateTime _end = DateTime.now();
  late final Map<String, TextEditingController> _cost = <String, TextEditingController>{
    for (final List<String> f in kWsCostFields) f[0]: TextEditingController(text: widget.detail[f[0]] == null ? '' : '${widget.detail[f[0]]}'),
  };
  late final List<Map<String, dynamic>> _rows = <Map<String, dynamic>>[
    for (final Map<String, dynamic> r in ReturnsHelp.maps(widget.detail['outputs'])) if (r['grade'] != 'sound') r,
  ];
  late final List<TextEditingController> _prices = <TextEditingController>[
    for (final Map<String, dynamic> r in _rows) TextEditingController(text: r['out_price'] == null ? '${r['price_per_kg'] ?? ''}' : '${r['out_price']}'),
  ];

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[..._cost.values, ..._prices]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool cost = wsCanCost();
    final WsBalance t = widget.totals;
    const SizedBox gap = SizedBox(height: 8);
    return AlertDialog(
      title: const Text('بستن عملیات'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
          Text('ورودی ${_kg(t.inputKg)} · Σ خروجی ${_kg(t.inputKg - t.lossKg)} · افت ${_kg(t.lossKg)} کیلو'),
          const Text('با بستن، خروجی‌ها لات می‌شوند و وارد موجودی می‌شوند.'),
          gap,
          JalaliDateField(label: 'تاریخ پایان', value: _end, onChanged: (DateTime d) => setState(() => _end = d)),
          if (cost) ...<Widget>[
            gap,
            wsReadOnlyField(kWsBuyLabel, widget.detail['buy_per_kg'] == null ? '—' : Fmt.money(ReturnsHelp.d(widget.detail['buy_per_kg']), label: false),
                helper: 'محاسبهٔ خودکار سرور؛ قابل ویرایش نیست'),
            if ('${widget.detail['input_cost_warning'] ?? ''}' == 'missing_input_cost')
              const Padding(padding: EdgeInsets.only(top: 4), child: Text(kWsMissingInputCost, style: TextStyle(color: Colors.orange))),
            for (final List<String> f in kWsCostFields) ...<Widget>[
              gap,
              TextField(
                controller: _cost[f[0]],
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: <ThousandsInputFormatter>[ThousandsInputFormatter()],
                decoration: InputDecoration(labelText: f[1], border: const OutlineInputBorder()),
              ),
            ],
            for (int i = 0; i < _rows.length; i++) ...<Widget>[
              gap,
              TextField(
                controller: _prices[i],
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: <ThousandsInputFormatter>[ThousandsInputFormatter()],
                decoration: InputDecoration(
                  labelText: 'قیمت هر کیلو — ${_rows[i]['grade'] == kWsCustomGrade ? (_rows[i]['type_name'] ?? 'سایر') : kWsGradeLabels['${_rows[i]['grade']}']} (${_kg(_rows[i]['kg'])} کیلو)',
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ] else
            const Padding(padding: EdgeInsets.only(top: 8), child: Text('بها را بعداً دارندهٔ مجوز بها ثبت می‌کند.')),
        ]),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('انصراف')),
        FilledButton(
          onPressed: () {
            final Map<String, dynamic> p = <String, dynamic>{'end_date': ReturnsHelp.iso(_end)};
            if (cost) {
              _cost.forEach((String k, TextEditingController c) {
                if (c.text.trim().isNotEmpty) p[k] = wsParseNum(c.text);
              });
              p['outputs'] = <Map<String, dynamic>>[
                for (int i = 0; i < _rows.length; i++)
                  <String, dynamic>{
                    if (_rows[i]['id'] != null) 'id': _rows[i]['id'],
                    if (_rows[i]['uid'] != null) 'uid': _rows[i]['uid'],
                    'price_per_kg': _prices[i].text.trim().isEmpty ? null : wsParseNum(_prices[i].text),
                  },
              ];
            }
            Navigator.pop(context, p);
          },
          child: const Text('بستن عملیات'),
        ),
      ],
    );
  }
}
