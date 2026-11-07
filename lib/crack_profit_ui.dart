import 'package:flutter/material.dart';

import 'crack_ui.dart' show CrackListScreen;
import 'edition.dart' show EditionService;
import 'perms.dart' show StaffPerms;
import 'returns_ui.dart' show ReturnsHelp;
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;

/// CP4 — سود و زیان خط شکست (اندروید/ویندوز؛ فایل مشترک).
/// سرور (S2): `reports.crack_profit`، `workshop.crack_pool_get|extra|close|reopen` — همه فقط gold + `profit.view` (نوشتنی‌ها `workshop.manage` هم).
/// مبلغ‌ها ریال صحیح و فقط از سرور می‌آیند؛ این فایل هیچ محاسبهٔ مالی ندارد (D10). اپراتور کارگاه هیچ‌کدام را نمی‌بیند (D6).

/// متن‌های ثابت (عیناً مثل وب).
const String kCpNote = 'سود مدیریتی؛ در اسناد حسابداری بهای این لات‌ها صفر است.';
const String kCpProvNote = 'سود هر لات تا بستن استخر «موقت» است (هزینه فقط روی لات‌های فروخته‌شده سهم‌بندی می‌شود)؛ کیلوی فروخته‌نشده را کنارش ببینید.';
const String kCpNeedPrice = 'برای دیدن سود، دسترسی قیمت لازم است.';
const Map<String, String> kCpConsume = <String, String>{'full': 'تبدیل کامل (هزینهٔ افت روی همین گروه)', 'lots_only': 'فقط وزن لات‌ها'};

/// فقط مدیر: پلن gold + profit.view (اپراتورِ فقط‌کارگاه هرگز).
bool cpCanProfit() => EditionService.I.edition.isGold && StaffPerms.I.can('profit.view') && !StaffPerms.I.isWorkshopOperatorOnly;

/// ثبت هزینهٔ اضافه/بستن/باز کردن.
bool cpCanManage() => cpCanProfit() && StaffPerms.I.can('workshop.manage');

String _rial(dynamic v) => faNum(((v is num) ? v : num.tryParse('${v ?? 0}') ?? 0).toDouble(), dec: 0);
String _kg(dynamic v) => faNum(ReturnsHelp.d(v), dec: 3);
Map<String, dynamic> _map(dynamic v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
bool _isClosed(Map<String, dynamic> it) => '${it['status']}' == 'closed';
Color? _signColor(dynamic v) => (v is num && v < 0) ? Colors.red.shade700 : (v is num && v > 0 ? Colors.green.shade700 : null);

/// سرور برای کارکنِ بدون price.view کلیدهای pool/profit را حذف می‌کند.
bool cpHasMoney(Map<String, dynamic> it) => it['profit'] is num && it['pool'] is Map && (it['pool'] as Map)['total'] is num;

/// ورودی ریال: ارقام فارسی/عربی و جداکننده‌ها پذیرفته؛ فقط صحیح ۰..۱۵ رقم؛ نامعتبر ⇒ null (فقط ورودی کاربر، نه محاسبهٔ مالی).
int? cpParseRial(String s) {
  const String fa = '۰۱۲۳۴۵۶۷۸۹';
  const String ar = '٠١٢٣٤٥٦٧٨٩';
  final StringBuffer b = StringBuffer();
  for (final int r in s.trim().runes) {
    final String ch = String.fromCharCode(r);
    final int i = fa.indexOf(ch) >= 0 ? fa.indexOf(ch) : ar.indexOf(ch);
    if (i >= 0) {
      b.write(i);
    } else if (ch == ',' || ch == '٬' || ch == '،' || ch == ' ' || ch == '\u200c') {
      continue;
    } else {
      b.write(ch);
    }
  }
  final String t = b.toString();
  if (!RegExp(r'^[0-9]{1,15}$').hasMatch(t)) return null;
  return int.tryParse(t);
}

/// خط خلاصهٔ pool_info برای فهرست (بدون مبلغ؛ کلید نیامده ⇒ null ⇒ چیزی نشان داده نمی‌شود).
String? cpPoolInfoLine(dynamic pi) {
  if (pi is! Map) return null;
  final String c = '${pi['consume']}';
  return 'مصرف: ${c == 'full' ? 'تبدیل کامل' : 'فقط لات‌ها'} ${_kg(pi['consumed_kg'])} کیلو · افت ${_kg(pi['loss_kg'])} · استخر ${'${pi['status']}' == 'closed' ? 'بسته' : 'باز'}';
}

/// کارت «مصرف از لات مبدأ» در جزئیات (فقط وقتی سرور pool_info داده؛ یعنی مدیر).
Widget? cpPoolInfoCard(dynamic pi) {
  if (pi is! Map) return null;
  final String c = '${pi['consume']}';
  final List<List<String>> rows = <List<String>>[
    <String>['حالت مصرف', kCpConsume[c] ?? (c.isEmpty || c == 'null' ? '—' : c)],
    <String>['مصرف‌شده از لات مبدأ (کیلو)', _kg(pi['consumed_kg'])],
    <String>['افت (کیلو)', _kg(pi['loss_kg'])],
    <String>['وضعیت استخر', '${pi['status']}' == 'closed' ? 'بسته (قطعی)' : 'باز (موقت)'],
  ];
  return Card(
    margin: const EdgeInsets.only(bottom: 14),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
        const Text('مصرف از لات مبدأ', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        for (final List<String> r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: <Widget>[Expanded(child: Text(r[0])), Flexible(child: Text(r[1], textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.bold)))]),
          ),
      ]),
    ),
  );
}

Widget _badge(Map<String, dynamic> it) {
  final bool fin = _isClosed(it);
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(color: fin ? Colors.green.shade50 : Colors.orange.shade50, borderRadius: BorderRadius.circular(10), border: Border.all(color: fin ? Colors.green : Colors.orange)),
    child: Text(fin ? 'قطعی' : 'موقت', style: TextStyle(fontSize: 11, color: fin ? Colors.green.shade800 : Colors.orange.shade900, fontWeight: FontWeight.bold)),
  );
}

Widget _kv(String k, String v, {Color? color, bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: <Widget>[
        Expanded(child: Text(k)),
        Flexible(child: Text(v, textAlign: TextAlign.end, style: TextStyle(color: color, fontWeight: bold ? FontWeight.bold : null))),
      ]),
    );

/// بدنهٔ کارت سود یک ردیف (مشترک بین جزئیات و صفحهٔ سود).
List<Widget> _itemBody(Map<String, dynamic> it) {
  if (!cpHasMoney(it)) return <Widget>[const Text(kCpNeedPrice, style: TextStyle(color: Colors.grey))];
  final Map<String, dynamic> pool = _map(it['pool']);
  final List<Map<String, dynamic>> lots = ReturnsHelp.maps(it['lots']);
  final dynamic profit = it['profit'];
  return <Widget>[
    _kv('بهای مبدأ (ریال)', _rial(pool['source_cost'])),
    _kv('هزینهٔ اضافه (ریال)', _rial(pool['extra'])),
    _kv('جمع استخر (ریال)', _rial(pool['total']), bold: true),
    _kv('درآمد (ریال)', _rial(it['revenue'])),
    _kv('سود / زیان (ریال)', _rial(profit), color: _signColor(profit), bold: true),
    _kv('حاشیه ٪', it['margin_pct'] is num ? faNum((it['margin_pct'] as num).toDouble(), dec: 2) : '—'),
    _kv('کیلوی فروخته', _kg(it['sold_kg'])),
    _kv('کیلوی فروخته‌نشده', _kg(it['unsold_kg'])),
    if (lots.isNotEmpty) ...<Widget>[
      const SizedBox(height: 8),
      const Text('سهم لات‌ها', style: TextStyle(fontWeight: FontWeight.bold)),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columnSpacing: 14,
          headingRowHeight: 36,
          columns: const <DataColumn>[
            DataColumn(label: Text('کد لات')),
            DataColumn(label: Text('خروجی')),
            DataColumn(label: Text('کیلو'), numeric: true),
            DataColumn(label: Text('مانده (کیلو)'), numeric: true),
            DataColumn(label: Text('درآمد (ریال)'), numeric: true),
            DataColumn(label: Text('سهم هزینه (ریال)'), numeric: true),
            DataColumn(label: Text('سود (ریال)'), numeric: true),
          ],
          rows: <DataRow>[
            for (final Map<String, dynamic> l in lots)
              DataRow(cells: <DataCell>[
                DataCell(Text('${l['code'] ?? ''}')),
                DataCell(Text('${l['label'] ?? ''}')),
                DataCell(Text(_kg(l['kg']))),
                DataCell(Text(_kg(l['remaining_kg']))),
                DataCell(Text(_rial(l['revenue']))),
                DataCell(Text(l['cost'] is num ? _rial(l['cost']) : '—')),
                DataCell(Text(l['profit'] is num ? _rial(l['profit']) : '—', style: TextStyle(color: _signColor(l['profit'])))),
              ]),
          ],
        ),
      ),
    ],
    const SizedBox(height: 8),
    const Text(kCpNote, style: TextStyle(fontSize: 12, color: Colors.grey)),
    const SizedBox(height: 2),
    const Text(kCpProvNote, style: TextStyle(fontSize: 12, color: Colors.grey)),
  ];
}

/// «کارت سود ردیف». [initial] داده شود ⇒ درخواست اولیه نمی‌زند (صفحهٔ سود). هر خطا/۴۰۴/۴۰۳ در بارگذاری ⇒ کارت نمایش داده نمی‌شود.
class CrackProfitCard extends StatefulWidget {
  final int runId;
  final Map<String, dynamic>? initial;

  /// بعد از ثبت هزینهٔ اضافه/بستن/باز کردن (برای تازه‌سازی صفحهٔ سود).
  final VoidCallback? onChanged;
  const CrackProfitCard({super.key, required this.runId, this.initial, this.onChanged});

  @override
  State<CrackProfitCard> createState() => _CrackProfitCardState();
}

class _CrackProfitCardState extends State<CrackProfitCard> {
  Map<String, dynamic>? _it;
  bool _hidden = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (!cpCanProfit()) {
      _hidden = true;
      return;
    }
    _it = widget.initial;
    if (_it == null) _load();
  }

  @override
  void didUpdateWidget(covariant CrackProfitCard old) {
    super.didUpdateWidget(old);
    if (widget.initial != null && !identical(widget.initial, old.initial)) _it = widget.initial; // CP4: بازخوانی صفحهٔ سود
  }

  Future<void> _load() async {
    try {
      final Map<String, dynamic> r = await StockApi.call('workshop.crack_pool_get', <String, dynamic>{'run_id': widget.runId});
      if (!mounted) return;
      setState(() => _it = r);
    } catch (_) {
      if (!mounted) return;
      setState(() => _hidden = true); // gold نیست / استخر ندارد / مجوز ندارد / آفلاین ⇒ بی‌صدا مخفی
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  /// عمل نوشتنی؛ کارت از پاسخ سرور بازسازی می‌شود، خطا فارسی نشان داده می‌شود.
  Future<void> _act(String action, [Map<String, dynamic> extra = const <String, dynamic>{}]) async {
    setState(() => _busy = true);
    try {
      final Map<String, dynamic> r = await StockApi.call(action, <String, dynamic>{'run_id': widget.runId, ...extra});
      if (!mounted) return;
      setState(() => _it = r);
      widget.onChanged?.call();
    } on StockApiException catch (e) {
      if (mounted) _snack(e.message);
    } catch (e) {
      if (mounted) _snack('خطا: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String body) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('انصراف')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('تأیید')),
          ],
        ),
      ),
    );
    return ok == true;
  }

  Future<void> _extra() async {
    final TextEditingController tc = TextEditingController();
    String? err;
    final int? v = await showDialog<int>(
      context: context,
      builder: (BuildContext c) => StatefulBuilder(
        builder: (BuildContext c, StateSetter ss) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: const Text('ثبت هزینهٔ اضافه'),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
              const Text('مبلغ کل هزینهٔ اضافهٔ این ردیف (دستمزد، برق، …) به ریال؛ جایگزین مبلغ قبلی می‌شود.'),
              const SizedBox(height: 8),
              TextField(controller: tc, autofocus: true, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: 'هزینهٔ اضافه (ریال)', border: const OutlineInputBorder(), errorText: err)),
            ]),
            actions: <Widget>[
              TextButton(onPressed: () => Navigator.pop(c), child: const Text('انصراف')),
              FilledButton(
                onPressed: () {
                  final int? n = cpParseRial(tc.text);
                  if (n == null) {
                    ss(() => err = 'مبلغ باید عدد صحیح ریال (۰ یا بیشتر) باشد');
                    return;
                  }
                  Navigator.pop(c, n);
                },
                child: const Text('ثبت'),
              ),
            ],
          ),
        ),
      ),
    );
    tc.dispose();
    if (v == null || !mounted) return;
    await _act('workshop.crack_pool_extra', <String, dynamic>{'extra_cost': v});
  }

  Future<void> _close() async {
    if (await _confirm('بستن استخر', 'سود این ردیف «قطعی» می‌شود و کیلوی فروخته‌نشده ارزش ۰ می‌گیرد. بعداً می‌شود دوباره باز کرد. ادامه می‌دهید؟')) await _act('workshop.crack_pool_close');
  }

  Future<void> _reopen() async {
    if (await _confirm('باز کردن استخر', 'استخر دوباره «باز» و سود «موقت» می‌شود. ادامه می‌دهید؟')) await _act('workshop.crack_pool_reopen');
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic>? it = _it;
    if (_hidden) return const SizedBox.shrink();
    if (it == null) return const Padding(padding: EdgeInsets.only(bottom: 14), child: LinearProgressIndicator());
    final bool closed = _isClosed(it);
    final bool money = cpHasMoney(it);
    final bool manage = money && cpCanManage();
    final Widget body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
      Row(children: <Widget>[
        const Expanded(child: Text('کارت سود ردیف', style: TextStyle(fontWeight: FontWeight.bold))),
        _badge(it),
      ]),
      const SizedBox(height: 8),
      ..._itemBody(it),
      if (manage) ...<Widget>[
        const Divider(height: 20),
        Wrap(spacing: 8, runSpacing: 6, children: <Widget>[
          OutlinedButton.icon(onPressed: (_busy || closed) ? null : _extra, icon: const Icon(Icons.add_card_outlined), label: const Text('ثبت هزینهٔ اضافه')),
          if (!closed) FilledButton.tonalIcon(onPressed: _busy ? null : _close, icon: const Icon(Icons.lock_outline), label: const Text('بستن استخر')),
          if (closed) FilledButton.tonalIcon(onPressed: _busy ? null : _reopen, icon: const Icon(Icons.lock_open_outlined), label: const Text('باز کردن')),
        ]),
        if (_busy) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
      ],
    ]);
    return Card(margin: const EdgeInsets.only(bottom: 14), child: Padding(padding: const EdgeInsets.all(12), child: body));
  }
}

/// صفحهٔ «سود خط شکست» (فقط مدیر gold + profit.view): `reports.crack_profit {from?,to?,status?}`.
class CrackProfitScreen extends StatefulWidget {
  const CrackProfitScreen({super.key});

  @override
  State<CrackProfitScreen> createState() => _CrackProfitScreenState();
}

class _CrackProfitScreenState extends State<CrackProfitScreen> {
  /// بازهٔ روز: 0 = امروز، 7، 30؛ null = همه.
  int? _days;
  String? _status; // null | open | closed
  bool _loading = false;
  String? _error;
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  Map<String, dynamic> _totals = <String, dynamic>{};

  @override
  void initState() {
    super.initState();
    if (cpCanProfit()) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final DateTime now = DateTime.now();
      final Map<String, dynamic> payload = <String, dynamic>{
        if (_days != null) 'from': ReturnsHelp.iso(now.subtract(Duration(days: _days == 0 ? 0 : _days! - 1))),
        if (_days != null) 'to': ReturnsHelp.iso(now),
        if (_status != null) 'status': _status,
      };
      final Map<String, dynamic> r = await StockApi.call('reports.crack_profit', payload);
      if (!mounted) return;
      setState(() {
        _items = ReturnsHelp.maps(r['items']);
        _totals = _map(r['totals']);
        _loading = false;
      });
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'خطا: $e';
        _loading = false;
      });
    }
  }

  Widget _chip(String label, bool sel, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(left: 6),
        child: ChoiceChip(label: Text(label), selected: sel, onSelected: (_) => onTap()),
      );

  Widget _tile(Map<String, dynamic> it) {
    final bool money = cpHasMoney(it);
    final int runId = int.tryParse('${it['run_id']}') ?? 0;
    final List<String> head = <String>[
      jalaliDate('${it['run_date']}'),
      if ('${it['line_code'] ?? ''}'.isNotEmpty) 'خط ${it['line_code']}',
      if ('${it['pistachio_type'] ?? ''}'.isNotEmpty) '${it['pistachio_type']}',
    ];
    final List<String> sub = <String>[
      if ('${it['customer_name'] ?? ''}'.isNotEmpty) '${it['customer_name']}',
      if ('${it['source_lot_code'] ?? ''}'.isNotEmpty) 'مبدأ ${it['source_lot_code']}',
      'مصرف ${_kg(it['consumed_kg'])} / افت ${_kg(it['loss_kg'])} کیلو',
      'فروخته‌نشده ${_kg(it['unsold_kg'])} کیلو',
    ];
    return ExpansionTile(
      key: PageStorageKey<String>('cp_$runId'),
      title: Text(head.join(' · ')),
      subtitle: Text(sub.join(' · '), style: const TextStyle(fontSize: 12)),
      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
        Text(money ? _rial(it['profit']) : '—', style: TextStyle(fontWeight: FontWeight.bold, color: money ? _signColor(it['profit']) : null)),
        const SizedBox(height: 2),
        _badge(it),
      ]),
      childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      children: <Widget>[CrackProfitCard(runId: runId, initial: it, onChanged: _load)],
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool allowed = cpCanProfit();
    final bool money = _items.isEmpty || cpHasMoney(_items.first);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('سود خط شکست', style: TextStyle(fontSize: 16)),
          actions: <Widget>[
            if (allowed) IconButton(tooltip: 'فهرست گزارش‌های خط شکست', onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CrackListScreen(pushed: true))), icon: const Icon(Icons.list_alt_outlined)),
            if (allowed) IconButton(tooltip: 'تازه‌سازی', onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh)),
          ],
        ),
        body: !allowed
            ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('این بخش فقط برای مدیر (نسخهٔ طلایی با دسترسی سود) است.', textAlign: TextAlign.center)))
            : Column(children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: <Widget>[
                      _chip('امروز', _days == 0, () {
                        setState(() => _days = 0);
                        _load();
                      }),
                      _chip('۷ روز', _days == 7, () {
                        setState(() => _days = 7);
                        _load();
                      }),
                      _chip('۳۰ روز', _days == 30, () {
                        setState(() => _days = 30);
                        _load();
                      }),
                      _chip('همه', _days == null, () {
                        setState(() => _days = null);
                        _load();
                      }),
                    ]),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: <Widget>[
                      _chip('همهٔ وضعیت‌ها', _status == null, () {
                        setState(() => _status = null);
                        _load();
                      }),
                      _chip('باز (موقت)', _status == 'open', () {
                        setState(() => _status = 'open');
                        _load();
                      }),
                      _chip('بسته (قطعی)', _status == 'closed', () {
                        setState(() => _status = 'closed');
                        _load();
                      }),
                    ]),
                  ),
                ),
                if (_loading) const LinearProgressIndicator(),
                if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: const TextStyle(color: Colors.red))),
                if (!money) const Padding(padding: EdgeInsets.all(12), child: Text(kCpNeedPrice, style: TextStyle(color: Colors.grey))),
                Expanded(
                  child: _items.isEmpty
                      ? Center(child: Text(_loading ? '' : 'ردیفی برای نمایش نیست'))
                      : ListView(children: <Widget>[
                          for (final Map<String, dynamic> it in _items) _tile(it),
                          if (money)
                            ListTile(
                              tileColor: Colors.black12,
                              title: const Text('جمع کل', style: TextStyle(fontWeight: FontWeight.bold)),
                              subtitle: Text('استخر ${_rial(_totals['pool'])} · درآمد ${_rial(_totals['revenue'])} ریال'),
                              trailing: Text(_rial(_totals['profit']), style: TextStyle(fontWeight: FontWeight.bold, color: _signColor(_totals['profit']))),
                            ),
                          const Padding(padding: EdgeInsets.fromLTRB(14, 8, 14, 2), child: Text(kCpNote, style: TextStyle(fontSize: 12, color: Colors.grey))),
                          const Padding(padding: EdgeInsets.fromLTRB(14, 0, 14, 16), child: Text(kCpProvNote, style: TextStyle(fontSize: 12, color: Colors.grey))),
                        ]),
                ),
              ]),
      ),
    );
  }
}
