import 'package:flutter/material.dart';

import 'perms.dart';
import 'utils.dart';
import 'widgets.dart' show snack;
import 'warehouse_ui.dart' show StockApi, StockApiException;

/// S31.T31.12b — letters of credit (lc.list|save|set_status|delete|deadlines). FX plan only, online.
/// sale_id is the SERVER sale id. Deadline logic lives on the server (next_deadline/days_left/overdue).

const Map<String, String> _kLcStatusFa = <String, String>{
  'open': 'باز',
  'shipped': 'حمل‌شده',
  'presented': 'مدارک ارائه‌شده',
  'paid': 'پرداخت‌شده',
  'expired': 'منقضی',
  'cancelled': 'لغو',
};
const Map<String, String> _kKindFa = <String, String>{'ship': 'مهلت حمل', 'present': 'مهلت ارائه مدارک', 'expiry': 'انقضا'};
const Map<String, String> _kNextStatus = <String, String>{'open': 'shipped', 'shipped': 'presented', 'presented': 'paid'};

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

Future<String?> _pickIso(BuildContext context, String? initial) async {
  final DateTime now = DateTime.now();
  final DateTime init = DateTime.tryParse(initial ?? '') ?? now;
  final DateTime? d = await showDatePicker(context: context, initialDate: init, firstDate: DateTime(now.year - 5), lastDate: DateTime(now.year + 10));
  return d == null ? null : _iso(d);
}

List<Map<String, dynamic>> _maps(dynamic v) => v is List ? <Map<String, dynamic>>[for (final dynamic e in v) if (e is Map) Map<String, dynamic>.from(e)] : <Map<String, dynamic>>[];

class LcListScreen extends StatefulWidget {
  const LcListScreen({super.key});

  @override
  State<LcListScreen> createState() => _LcListScreenState();
}

class _LcListScreenState extends State<LcListScreen> {
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  int _overdue = 0;
  int _soon = 0;
  String _filter = '';
  bool _loading = true;
  String? _error;

  bool get _canEdit => StaffPerms.I.can('sales.update');

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
      final Map<String, dynamic> r = await StockApi.call('lc.list', <String, dynamic>{if (_filter.isNotEmpty) 'status': _filter});
      final Map<String, dynamic> dl = await StockApi.call('lc.deadlines', <String, dynamic>{'days': 14});
      if (!mounted) return;
      setState(() {
        _items = _maps(r['items']);
        _overdue = (dl['overdue_count'] as num?)?.toInt() ?? 0;
        _soon = _maps(dl['items']).length;
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

  Future<void> _edit([Map<String, dynamic>? lc]) async {
    final bool? ok = await Navigator.push<bool>(context, MaterialPageRoute<bool>(builder: (_) => LcFormScreen(lc: lc)));
    if (ok == true) _load();
  }

  Future<void> _advance(Map<String, dynamic> lc) async {
    final String? next = _kNextStatus['${lc['status']}'];
    if (next == null) return;
    final Map<String, dynamic> p = <String, dynamic>{'id': lc['id'], 'status': next};
    if (next == 'shipped' || next == 'presented') {
      final String? d = await _pickIso(context, null);
      if (d == null) return;
      p[next == 'shipped' ? 'ship_date' : 'presented_date'] = d;
    }
    await _run('lc.set_status', p);
  }

  Future<void> _run(String action, Map<String, dynamic> p) async {
    try {
      await StockApi.call(action, p);
      if (mounted) _load();
    } on StockApiException catch (e) {
      if (mounted) snack(context, e.message);
    }
  }

  Future<void> _delete(Map<String, dynamic> lc) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('حذف اعتبار اسنادی'),
          content: Text('اعتبار ${lc['lc_no']} حذف شود؟'),
          actions: <Widget>[TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('انصراف')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('حذف'))],
        ),
      ),
    );
    if (ok == true) await _run('lc.delete', <String, dynamic>{'id': lc['id']});
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('اعتبارات اسنادی'), actions: <Widget>[IconButton(icon: const Icon(Icons.refresh), onPressed: _load)]),
        floatingActionButton: _canEdit ? FloatingActionButton.extended(onPressed: () => _edit(), icon: const Icon(Icons.add), label: const Text('اعتبار جدید')) : null,
        body: Column(children: <Widget>[
          if (_loading) const LinearProgressIndicator(),
          if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: const TextStyle(color: Colors.red))),
          if (_overdue > 0 || _soon > 0)
            Container(
              width: double.infinity,
              color: _overdue > 0 ? Colors.red.withOpacity(0.12) : Colors.orange.withOpacity(0.12),
              padding: const EdgeInsets.all(8),
              child: Text('${_overdue > 0 ? '${toFaDigits('$_overdue')} مهلت گذشته · ' : ''}${toFaDigits('$_soon')} مهلت تا ۱۴ روز آینده', style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: <Widget>[
              for (final MapEntry<String, String> e in <String, String>{'': 'همه', ..._kLcStatusFa}.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: ChoiceChip(label: Text(e.value), selected: _filter == e.key, onSelected: (_) {
                    _filter = e.key;
                    _load();
                  }),
                ),
            ]),
          ),
          Expanded(
            child: _items.isEmpty && !_loading
                ? const Center(child: Text('اعتباری ثبت نشده است'))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 90),
                      itemCount: _items.length,
                      itemBuilder: (BuildContext c, int i) {
                        final Map<String, dynamic> lc = _items[i];
                        final bool overdue = lc['overdue'] == true;
                        final int? left = (lc['days_left'] as num?)?.toInt();
                        final String? next = _kNextStatus['${lc['status']}'];
                        return Card(
                          child: ListTile(
                            title: Text('${lc['lc_no']} · ${lc['issuing_bank']}'),
                            subtitle: Text(
                              '${_kLcStatusFa['${lc['status']}'] ?? lc['status']} · ${faNum((lc['amount'] as num?) ?? 0)} ${lc['ccy_code']}\n'
                              'خریدار: ${lc['buyer'] ?? '—'}  ·  فروش ${toFaDigits('${lc['sale_id']}')}'
                              '${lc['next_deadline'] != null ? '\n${_kKindFa['${lc['next_kind']}'] ?? ''}: ${toFaDigits('${lc['next_deadline']}')} (${overdue ? 'گذشته' : '${toFaDigits('${left ?? 0}')} روز مانده'})' : ''}',
                              style: TextStyle(color: overdue ? Colors.red : null),
                            ),
                            isThreeLine: true,
                            onTap: _canEdit ? () => _edit(lc) : null,
                            trailing: !_canEdit
                                ? null
                                : PopupMenuButton<String>(
                                    onSelected: (String v) {
                                      if (v == 'next') _advance(lc);
                                      if (v == 'expired' || v == 'cancelled') _run('lc.set_status', <String, dynamic>{'id': lc['id'], 'status': v});
                                      if (v == 'del') _delete(lc);
                                    },
                                    itemBuilder: (BuildContext c) => <PopupMenuEntry<String>>[
                                      if (next != null) PopupMenuItem<String>(value: 'next', child: Text('→ ${_kLcStatusFa[next]}')),
                                      if (lc['status'] == 'open' || lc['status'] == 'shipped') const PopupMenuItem<String>(value: 'expired', child: Text('علامت‌گذاری منقضی')),
                                      if (lc['status'] != 'cancelled' && lc['status'] != 'paid') const PopupMenuItem<String>(value: 'cancelled', child: Text('لغو')),
                                      const PopupMenuItem<String>(value: 'del', child: Text('حذف')),
                                    ],
                                  ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ]),
      ),
    );
  }
}

class LcFormScreen extends StatefulWidget {
  final Map<String, dynamic>? lc;
  const LcFormScreen({super.key, this.lc});

  @override
  State<LcFormScreen> createState() => _LcFormScreenState();
}

class _LcFormScreenState extends State<LcFormScreen> {
  final TextEditingController _sale = TextEditingController();
  final TextEditingController _no = TextEditingController();
  final TextEditingController _bank = TextEditingController();
  final TextEditingController _adv = TextEditingController();
  final TextEditingController _ccy = TextEditingController();
  final TextEditingController _amount = TextEditingController();
  final TextEditingController _days = TextEditingController(text: '21');
  final TextEditingController _note = TextEditingController();
  String? _open;
  String? _expiry;
  String? _ship;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final Map<String, dynamic>? l = widget.lc;
    if (l != null) {
      _sale.text = '${l['sale_id'] ?? ''}';
      _no.text = '${l['lc_no'] ?? ''}';
      _bank.text = '${l['issuing_bank'] ?? ''}';
      _adv.text = '${l['advising_bank'] ?? ''}';
      _ccy.text = '${l['ccy_code'] ?? ''}';
      _amount.text = '${l['amount'] ?? ''}';
      _days.text = '${l['presentation_days'] ?? 21}';
      _note.text = '${l['note'] ?? ''}';
      _open = l['open_date'] as String?;
      _expiry = l['expiry_date'] as String?;
      _ship = l['latest_ship_date'] as String?;
    }
  }

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[_sale, _no, _bank, _adv, _ccy, _amount, _days, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_expiry == null) {
      setState(() => _error = 'تاریخ انقضا را انتخاب کنید');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await StockApi.call('lc.save', <String, dynamic>{
        if (widget.lc != null) 'id': widget.lc!['id'],
        'sale_id': int.tryParse(_sale.text.trim()) ?? 0,
        'lc_no': _no.text.trim(),
        'issuing_bank': _bank.text.trim(),
        'advising_bank': _adv.text.trim(),
        'ccy_code': _ccy.text.trim().toUpperCase(),
        'amount': double.tryParse(_amount.text.trim().replaceAll(',', '')) ?? 0,
        'open_date': _open ?? '',
        'expiry_date': _expiry,
        'latest_ship_date': _ship ?? '',
        'presentation_days': int.tryParse(_days.text.trim()) ?? 21,
        'note': _note.text.trim(),
      });
      if (mounted) Navigator.pop(context, true);
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  Widget _tf(TextEditingController c, String label, {bool num = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(controller: c, keyboardType: num ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text, decoration: InputDecoration(labelText: label, border: const OutlineInputBorder())),
      );

  Widget _date(String label, String? v, ValueChanged<String?> set) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: OutlinedButton.icon(
          onPressed: () async {
            final String? d = await _pickIso(context, v);
            if (d != null) setState(() => set(d));
          },
          icon: const Icon(Icons.event),
          label: Text('$label: ${v == null ? '—' : toFaDigits(v)}'),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: Text(widget.lc == null ? 'اعتبار اسنادی جدید' : 'ویرایش اعتبار اسنادی')),
        body: ListView(padding: const EdgeInsets.all(12), children: <Widget>[
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_error!, style: const TextStyle(color: Colors.red))),
          _tf(_sale, 'شمارهٔ فروش (در سرور)', num: true),
          _tf(_no, 'شمارهٔ اعتبار اسنادی'),
          _tf(_bank, 'بانک گشایش‌کننده'),
          _tf(_adv, 'بانک ابلاغ‌کننده (اختیاری)'),
          _tf(_ccy, 'کد ارز (USD…)'),
          _tf(_amount, 'مبلغ', num: true),
          _date('تاریخ گشایش', _open, (String? d) => _open = d),
          _date('تاریخ انقضا *', _expiry, (String? d) => _expiry = d),
          _date('آخرین مهلت حمل', _ship, (String? d) => _ship = d),
          _tf(_days, 'مهلت ارائه مدارک پس از حمل (روز)', num: true),
          _tf(_note, 'یادداشت'),
          FilledButton.icon(onPressed: _busy ? null : _save, icon: const Icon(Icons.save_outlined), label: const Text('ذخیره')),
        ]),
      ),
    );
  }
}
