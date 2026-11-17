import 'package:flutter/material.dart';

import 'perms.dart';
import 'returns_ui.dart' show ReturnsHelp;
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;
import 'widgets.dart' show confirm, pickDate;
import 'workshop_ui.dart' show wsParseNum;

/// مرحلهٔ ۵-ب کارگاه — «موجودی پستهٔ خرجی» (نمای جدا از انبار اصلی؛ ترکیب خودکار + تعدیل دستی) + کارت صفحهٔ اصلی.
/// سرور (۵-الف): feed.stock / feed.adjust_list (مجوز workshop.feed) · feed.adjust_create / feed.adjust_delete (workshop.manage).
/// هیچ مبلغی و هیچ محاسبهٔ تازه‌ای در این فایل نیست؛ همهٔ اعداد از سرور می‌آیند (منطق: workshop_calc.dart `feedCalc`).
/// اپراتور کارگاه فقط مشاهده می‌کند: فرم تعدیل و حذف فقط با `workshop.manage`.

double _fd(dynamic v) => ReturnsHelp.d(v);
String _fkg(dynamic v) => faNum(_fd(v), dec: 3);
InputDecoration _fdec(String label) => InputDecoration(labelText: label, border: const OutlineInputBorder());

const Map<String, String> kFeedSourceLabels = <String, String>{
  'outside': 'کارگاه بیرونی',
  'crack': 'خط شکست',
  'adjust': 'تعدیل دستی',
};

// ---------------------------------------------------------------------------
// صفحهٔ «موجودی پستهٔ خرجی»
// ---------------------------------------------------------------------------

class FeedStockScreen extends StatefulWidget {
  /// embedded=true: داخل تب پوستهٔ اپراتور (بدون دکمهٔ بازگشت).
  final bool embedded;
  const FeedStockScreen({super.key, this.embedded = false});

  @override
  State<FeedStockScreen> createState() => _FeedStockScreenState();
}

class _FeedStockScreenState extends State<FeedStockScreen> {
  final TextEditingController _owner = TextEditingController();
  final TextEditingController _workshop = TextEditingController();
  DateTime? _from;
  DateTime? _to;
  bool _inclDone = false;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  Map<String, dynamic> _tot = <String, dynamic>{};

  bool get _canManage => StaffPerms.I.can('workshop.manage');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _owner.dispose();
    _workshop.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final Map<String, dynamic> q = <String, dynamic>{};
      if (_owner.text.trim().isNotEmpty) q['owner'] = _owner.text.trim();
      if (_workshop.text.trim().isNotEmpty) q['workshop'] = _workshop.text.trim();
      if (_from != null) q['from'] = ReturnsHelp.iso(_from!);
      if (_to != null) q['to'] = ReturnsHelp.iso(_to!);
      if (_inclDone) q['include_done'] = 1;
      final Map<String, dynamic> r = await StockApi.call('feed.stock', q);
      if (!mounted) return;
      setState(() {
        _items = ReturnsHelp.maps(r['items']);
        _tot = r['totals'] is Map ? Map<String, dynamic>.from(r['totals'] as Map) : <String, dynamic>{};
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

  Future<void> _pick(bool isFrom) async {
    final DateTime? d = await pickDate(context, initial: (isFrom ? _from : _to) ?? DateTime.now());
    if (d == null) return;
    setState(() => isFrom ? _from = d : _to = d);
    _load();
  }

  Future<void> _delete(Map<String, dynamic> r) async {
    if (!await confirm(context, 'این تعدیل دستی حذف شود؟')) return;
    try {
      await StockApi.call('feed.adjust_delete', <String, dynamic>{'id': r['id']});
      await _load();
    } on StockApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _addAdjust() async {
    final bool? ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext c) => const FeedAdjustSheet(),
    );
    if (ok == true) await _load();
  }

  Widget _stat(String label, dynamic v, {bool strong = false}) => Expanded(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
            child: Column(children: <Widget>[
              Text(label, style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 4),
              Text(_fkg(v), style: TextStyle(fontWeight: strong ? FontWeight.bold : FontWeight.normal, fontSize: strong ? 16 : 14)),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    const List<String> heads = <String>['تاریخ', 'منبع', 'کارگاه', 'مالک', 'شمارهٔ قبض', 'ارسالی (کیلو)', 'برگشتی (کیلو)', 'ضایعات (کیلو)', 'مانده در کارگاه (کیلو)'];
    DataCell cell(String s, {bool bold = false}) => DataCell(Text(s, style: bold ? const TextStyle(fontWeight: FontWeight.bold) : null));
    String txt(dynamic v) => v == null || '$v'.isEmpty ? '—' : '$v';
    final List<DataRow> rows = <DataRow>[
      for (final Map<String, dynamic> r in _items)
        DataRow(cells: <DataCell>[
          cell(r['date'] == null ? '—' : jalaliDate('${r['date']}')),
          cell('${kFeedSourceLabels['${r['source']}'] ?? txt(r['source'])}${r['source'] == 'adjust' ? (r['kind'] == 'out' ? ' (خروج)' : ' (ورود)') : ''}'),
          cell(txt(r['workshop'])),
          cell(txt(r['owner'])),
          cell(txt(r['receipt_no'])),
          cell(_fkg(r['sent_kg'])),
          cell(_fkg(r['returned_kg'])),
          cell(_fkg(r['waste_kg'])),
          cell(_fkg(r['remaining_kg']), bold: true),
        ]),
    ];
    final List<Map<String, dynamic>> adjusts = _items.where((Map<String, dynamic> r) => r['source'] == 'adjust').toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('موجودی پستهٔ خرجی'),
        automaticallyImplyLeading: !widget.embedded,
        actions: <Widget>[IconButton(tooltip: 'به‌روزرسانی', icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      floatingActionButton: _canManage ? FloatingActionButton.extended(onPressed: _addAdjust, icon: const Icon(Icons.tune), label: const Text('تعدیل دستی')) : null,
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: <Widget>[
          Row(children: <Widget>[
            Expanded(child: TextField(controller: _owner, onSubmitted: (_) => _load(), decoration: _fdec('فیلتر مالک'))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: _workshop, onSubmitted: (_) => _load(), decoration: _fdec('فیلتر کارگاه'))),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: <Widget>[
            OutlinedButton.icon(onPressed: () => _pick(true), icon: const Icon(Icons.event), label: Text(_from == null ? 'از تاریخ' : jalaliDateFromDt(_from!))),
            OutlinedButton.icon(onPressed: () => _pick(false), icon: const Icon(Icons.event), label: Text(_to == null ? 'تا تاریخ' : jalaliDateFromDt(_to!))),
            if (_from != null || _to != null)
              TextButton(
                onPressed: () {
                  setState(() {
                    _from = null;
                    _to = null;
                  });
                  _load();
                },
                child: const Text('پاک‌کردن تاریخ'),
              ),
            FilterChip(
              label: const Text('شامل دریافت‌شده‌ها'),
              selected: _inclDone,
              onSelected: (bool v) {
                setState(() => _inclDone = v);
                _load();
              },
            ),
            FilledButton(onPressed: _load, child: const Text('اعمال')),
          ]),
          const SizedBox(height: 10),
          if (_error != null) Card(color: Theme.of(context).colorScheme.errorContainer, child: Padding(padding: const EdgeInsets.all(10), child: Text(_error!))),
          if (_loading) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
          if (!_loading && _error == null) ...<Widget>[
            Row(children: <Widget>[
              _stat('مانده در کارگاه‌ها', _tot['remaining_kg'], strong: true),
              _stat('ارسالی', _tot['sent_kg']),
              _stat('برگشتی', _tot['returned_kg']),
              _stat('ضایعات', _tot['waste_kg']),
            ]),
            if (_items.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('پستهٔ خرجی‌ای در کارگاه‌ها نیست'))),
            if (_items.isNotEmpty)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(columns: <DataColumn>[for (final String h in heads) DataColumn(label: Text(h))], rows: rows),
              ),
            if (_canManage && adjusts.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              const Text('تعدیل‌های دستی (قابل حذف)', style: TextStyle(fontWeight: FontWeight.bold)),
              for (final Map<String, dynamic> r in adjusts)
                Card(
                  child: ListTile(
                    dense: true,
                    title: Text('${r['kind'] == 'out' ? 'خروج' : 'ورود'} ${_fkg(r['kind'] == 'out' ? r['returned_kg'] : r['sent_kg'])} کیلو · ${r['workshop'] ?? '—'} · ${r['owner'] ?? '—'}'),
                    subtitle: Text('${r['date'] == null ? '' : jalaliDate('${r['date']}')} · ${r['reason'] ?? ''}'),
                    trailing: IconButton(tooltip: 'حذف', icon: const Icon(Icons.delete_outline), onPressed: () => _delete(r)),
                  ),
                ),
            ],
          ],
          const SizedBox(height: 8),
          const Text(
            'این موجودی جدا از انبار اصلی است. خودکار از سفارش‌های کارگاه بیرونی (ارسال‌شده و دریافت‌نشده) و گزارش خط شکست پر می‌شود؛ تعدیل دستی ورود/خروج هم اضافه می‌شود. '
            'برگشتی = مغز + پوست + خاک. مانده = ارسالی − برگشتی − ضایعات.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// فرم تعدیل دستی (bottom sheet) — فقط workshop.manage
// ---------------------------------------------------------------------------

class FeedAdjustSheet extends StatefulWidget {
  const FeedAdjustSheet({super.key});

  @override
  State<FeedAdjustSheet> createState() => _FeedAdjustSheetState();
}

class _FeedAdjustSheetState extends State<FeedAdjustSheet> {
  final TextEditingController _owner = TextEditingController();
  final TextEditingController _workshop = TextEditingController();
  final TextEditingController _receipt = TextEditingController();
  final TextEditingController _kg = TextEditingController();
  final TextEditingController _reason = TextEditingController();
  final String _uid = ReturnsHelp.newUid('fa'); // idempotent: دوباره‌زدن «ثبت» رکورد دوم نمی‌سازد
  String _kind = 'in';
  DateTime _date = DateTime.now();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[_owner, _workshop, _receipt, _kg, _reason]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final double? kg = wsParseNum(_kg.text);
    if (kg == null || kg <= 0) return setState(() => _error = 'وزن را وارد کنید (بیشتر از صفر)');
    if (_reason.text.trim().isEmpty) return setState(() => _error = 'دلیل تعدیل را وارد کنید');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await StockApi.call('feed.adjust_create', <String, dynamic>{
        'uid': _uid,
        'date': ReturnsHelp.iso(_date),
        'kind': _kind,
        'kg': kg,
        'owner': _owner.text.trim(),
        'workshop': _workshop.text.trim(),
        'receipt_no': _receipt.text.trim(),
        'reason': _reason.text.trim(),
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

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
            const Text('تعدیل دستی موجودی پستهٔ خرجی', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 10),
            SegmentedButton<String>(
              segments: const <ButtonSegment<String>>[
                ButtonSegment<String>(value: 'in', label: Text('ورود به کارگاه'), icon: Icon(Icons.add)),
                ButtonSegment<String>(value: 'out', label: Text('خروج / برگشت'), icon: Icon(Icons.remove)),
              ],
              selected: <String>{_kind},
              onSelectionChanged: (Set<String> s) => setState(() => _kind = s.first),
            ),
            const SizedBox(height: 10),
            Row(children: <Widget>[
              Expanded(child: TextField(controller: _kg, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: _fdec('وزن (کیلو)'))),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  final DateTime? d = await pickDate(context, initial: _date);
                  if (d != null) setState(() => _date = d);
                },
                icon: const Icon(Icons.event),
                label: Text(jalaliDateFromDt(_date)),
              ),
            ]),
            const SizedBox(height: 8),
            TextField(controller: _workshop, decoration: _fdec('کارگاه')),
            const SizedBox(height: 8),
            Row(children: <Widget>[
              Expanded(child: TextField(controller: _owner, decoration: _fdec('مالک'))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: _receipt, decoration: _fdec('شمارهٔ قبض (اختیاری)'))),
            ]),
            const SizedBox(height: 8),
            TextField(controller: _reason, decoration: _fdec('دلیل تعدیل (الزامی)')),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
            const SizedBox(height: 12),
            FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'در حال ثبت…' : 'ثبت تعدیل')),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// کارت خلاصهٔ صفحهٔ اصلی (آنلاین؛ بدون مجوز/خطا/خالی ⇒ پنهان)
// ---------------------------------------------------------------------------

class FeedStockHomeCard extends StatefulWidget {
  const FeedStockHomeCard({super.key});

  @override
  State<FeedStockHomeCard> createState() => _FeedStockHomeCardState();
}

class _FeedStockHomeCardState extends State<FeedStockHomeCard> {
  Map<String, dynamic>? _s;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!StaffPerms.I.can('workshop.feed')) return;
    try {
      final Map<String, dynamic> r = await StockApi.call('feed.stock', <String, dynamic>{});
      final dynamic s = r['summary'];
      if (!mounted || s is! Map) return;
      setState(() => _s = Map<String, dynamic>.from(s));
    } catch (_) {
      // آفلاین/خطا: کارت پنهان می‌ماند (مثل کارت‌های دیگر)
    }
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic>? s = _s;
    if (s == null) return const SizedBox.shrink();
    final bool empty = _fd(s['total_sent_kg']) == 0 && _fd(s['total_returned_kg']) == 0 && _fd(s['open_count']) == 0;
    if (empty) return const SizedBox.shrink();
    return Card(
      child: ListTile(
        leading: const Icon(Icons.inventory_2_outlined),
        title: const Text('موجودی پستهٔ خرجی'),
        subtitle: Text('مانده در کارگاه‌ها: ${_fkg(s['total_balance_kg'])} کیلو · کارگاه: ${faNum(_fd(s['workshops_count']), dec: 0)} · باز: ${faNum(_fd(s['open_count']), dec: 0)}'),
        trailing: const Icon(Icons.chevron_left),
        onTap: () async {
          await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const FeedStockScreen()));
          _load();
        },
      ),
    );
  }
}
