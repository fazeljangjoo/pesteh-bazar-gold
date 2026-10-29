import 'package:flutter/material.dart';

import 'db.dart';
import 'offline_docs.dart';
import 'pdf_output.dart';
import 'pdf_service.dart';
import 'perms.dart';
import 'utils.dart';
import 'warehouse_ui.dart' show StockApiException;
import 'widgets.dart';

/// S04.T04.4 / T04.4b — purchase / sales returns, offline-first through OfflineDocs (local mirror + sync ops).
/// Local ids of unsynced rows are negative; they are resolved to server ids when the op is pushed.
class ReturnsHelp {
  ReturnsHelp._();

  static String iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static String newUid(String p) => '$p${DateTime.now().microsecondsSinceEpoch}';

  /// Server id of a local row; throws a Persian message when it has not reached the server yet.
  static Future<int> serverId(String kind, int localId) async {
    final int? sid = await AppDb.I.serverIdOf(kind, localId) ?? await AppDb.I.aliasOf(kind, localId);
    if (sid == null || sid <= 0) {
      throw StockApiException('این سند هنوز به سرور نرسیده؛ ابتدا همگام‌سازی کنید و دوباره تلاش کنید.');
    }
    return sid;
  }

  static List<Map<String, dynamic>> maps(dynamic raw) {
    final out = <Map<String, dynamic>>[];
    if (raw is List) {
      for (final x in raw) {
        if (x is Map) out.add(Map<String, dynamic>.from(x));
      }
    }
    return out;
  }

  static double d(dynamic v) => (v is num) ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0.0);

  static const Map<String, String> saleModes = <String, String>{
    'reduce_receivable': 'کم‌کردن از مطالبات خریدار',
    'cash_refund': 'بازپرداخت نقدی به خریدار',
    'cheque_given': 'بازپرداخت با چک (صادره)',
  };
  static const Map<String, String> purchaseModes = <String, String>{
    'reduce_payable': 'کم‌کردن از بدهی به فروشنده',
    'cash_refund': 'بازپرداخت نقدی از فروشنده',
    'cheque_back': 'دریافت چک از فروشنده',
  };
}

/// Shared form body for both return kinds.
class _ReturnForm extends StatefulWidget {
  final bool isSale;
  final String title;
  final String party;
  final String subtitle;
  final double maxKg;
  final double defaultPrice;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> base) submit;
  const _ReturnForm({
    required this.isSale,
    required this.title,
    required this.party,
    required this.subtitle,
    required this.maxKg,
    required this.defaultPrice,
    required this.submit,
  });

  @override
  State<_ReturnForm> createState() => _ReturnFormState();
}

class _ReturnFormState extends State<_ReturnForm> {
  final GlobalKey<FormState> _form = GlobalKey<FormState>();
  final TextEditingController _kg = TextEditingController();
  final TextEditingController _price = TextEditingController();
  final TextEditingController _refund = TextEditingController();
  final TextEditingController _cheque = TextEditingController();
  final TextEditingController _note = TextEditingController();
  late String _mode;
  DateTime _date = DateTime.now();
  bool _busy = false;
  String? _err;

  @override
  void initState() {
    super.initState();
    _mode = widget.isSale ? 'reduce_receivable' : 'reduce_payable';
    _kg.text = faNum(widget.maxKg, dec: 3);
    _price.text = faNum(widget.defaultPrice, dec: 0);
  }

  @override
  void dispose() {
    _kg.dispose();
    _price.dispose();
    _refund.dispose();
    _cheque.dispose();
    _note.dispose();
    super.dispose();
  }

  bool get _hasRefund => _mode != 'reduce_receivable' && _mode != 'reduce_payable';

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final double kg = parseNum(_kg.text) ?? 0;
    final double price = parseNum(_price.text) ?? 0;
    if (kg <= 0) {
      snack(context, 'وزن برگشت باید بزرگ‌تر از صفر باشد');
      return;
    }
    final Map<String, dynamic> base = <String, dynamic>{
      'uid': ReturnsHelp.newUid(widget.isSale ? 'sr' : 'pr'),
      'date': ReturnsHelp.iso(_date),
      'note': _note.text.trim(),
      'refund_mode': _mode,
      'kg': kg,
      'unit_price': price,
      if (_hasRefund && _refund.text.trim().isNotEmpty) 'refund_amount': parseNum(_refund.text) ?? 0,
      if (_mode == 'cheque_given' || _mode == 'cheque_back') 'cheque_no': _cheque.text.trim(),
    };
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final r = await widget.submit(base);
      if (!mounted) return;
      snack(context, 'برگشت ثبت شد (شمارهٔ ${faNum(ReturnsHelp.d(r['number']), dec: 0)})');
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _err = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, String> modes = widget.isSale ? ReturnsHelp.saleModes : ReturnsHelp.purchaseModes;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: <Widget>[
          infoRow(widget.isSale ? 'خریدار' : 'فروشنده', widget.party.isEmpty ? '-' : widget.party),
          infoRow('سند اصلی', widget.subtitle),
          infoRow(widget.isSale ? 'حداکثر قابل برگشت' : 'حداکثر قابل برگشت (موجودی)', '${faNum(widget.maxKg, dec: 3)} کیلو'),
          const SizedBox(height: 12),
          dateField(context, 'تاریخ برگشت', _date, (DateTime d) => setState(() => _date = d)),
          numField(_kg, 'وزن برگشت', required: true, suffix: 'کیلو', max: widget.maxKg),
          numField(_price, widget.isSale ? 'فی برگشت (پیش‌فرض: فی فروش)' : 'فی برگشت (پیش‌فرض: فی خرید)',
              required: true, suffix: 'ریال', thousands: true),
          DropdownButtonFormField<String>(
            value: _mode,
            decoration: const InputDecoration(labelText: 'نحوهٔ تسویه', border: OutlineInputBorder()),
            items: <DropdownMenuItem<String>>[
              for (final MapEntry<String, String> e in modes.entries)
                DropdownMenuItem<String>(value: e.key, child: Text(e.value)),
            ],
            onChanged: (String? v) => setState(() => _mode = v ?? _mode),
          ),
          const SizedBox(height: 12),
          if (_hasRefund) numField(_refund, 'مبلغ بازپرداخت (خالی = کل ارزش برگشت)', suffix: 'ریال', thousands: true),
          if (_mode == 'cheque_given' || _mode == 'cheque_back') textField(_cheque, 'شمارهٔ چک'),
          textField(_note, 'یادداشت', lines: 2),
          if (_err != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_err!, style: const TextStyle(color: Colors.red))),
          FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: _busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.assignment_return_outlined),
            label: const Text('ثبت برگشت'),
          ),
        ]),
      ),
    );
  }
}

/// Opens the sales-return form for a local sale map (from AppDb.I.sales). Returns true when saved.
Future<bool?> openSaleReturn(BuildContext context, Map<String, dynamic> sale) {
  if (!StaffPerms.I.can('sales.return')) {
    snack(context, 'دسترسی برگشت از فروش را ندارید');
    return Future<bool?>.value(false);
  }
  final double net = ReturnsHelp.d(sale['net_weight']);
  final double price = ReturnsHelp.d(sale['price']);
  return Navigator.push<bool>(
    context,
    MaterialPageRoute<bool>(
      builder: (_) => _ReturnForm(
        isSale: true,
        title: 'برگشت از فروش',
        party: '${sale['buyer'] ?? ''}',
        subtitle: '${jalaliDate(sale['date'] as String)} — ${faNum(net, dec: 3)} کیلو',
        maxKg: net,
        defaultPrice: price,
        submit: (Map<String, dynamic> b) async {
          final int sid = sale['id'] as int; // local id is fine (resolved at sync time)
          return OfflineDocs.call('sale_returns.create', <String, dynamic>{
            'uid': b['uid'], 'date': b['date'], 'note': b['note'], 'refund_mode': b['refund_mode'],
            if (b.containsKey('refund_amount')) 'refund_amount': b['refund_amount'],
            if (b.containsKey('cheque_no')) 'cheque_no': b['cheque_no'],
            'items': <Map<String, dynamic>>[
              <String, dynamic>{'sale_id': sid, 'kg': b['kg'], 'unit_price': b['unit_price']},
            ],
          });
        },
      ),
    ),
  );
}

/// Opens the purchase-return form for a local purchase map (from AppDb.I.purchases).
Future<bool?> openPurchaseReturn(BuildContext context, Map<String, dynamic> pur) {
  if (!StaffPerms.I.can('purchases.return')) {
    snack(context, 'دسترسی برگشت از خرید را ندارید');
    return Future<bool?>.value(false);
  }
  final double remaining = ReturnsHelp.d(pur['remaining']);
  return Navigator.push<bool>(
    context,
    MaterialPageRoute<bool>(
      builder: (_) => _ReturnForm(
        isSale: false,
        title: 'برگشت از خرید',
        party: '${pur['seller'] ?? ''}',
        subtitle: '${pur['code'] ?? '-'} — ${pur['type_name'] ?? ''}',
        maxKg: remaining,
        defaultPrice: ReturnsHelp.d(pur['price']),
        submit: (Map<String, dynamic> b) async {
          final int sid = pur['id'] as int;
          return OfflineDocs.call('purchase_returns.create', <String, dynamic>{
            'uid': b['uid'], 'date': b['date'], 'note': b['note'], 'refund_mode': b['refund_mode'],
            if (b.containsKey('refund_amount')) 'refund_amount': b['refund_amount'],
            if (b.containsKey('cheque_no')) 'cheque_no': b['cheque_no'],
            'items': <Map<String, dynamic>>[
              <String, dynamic>{'lot_id': sid, 'kg': b['kg'], 'unit_price': b['unit_price']},
            ],
          });
        },
      ),
    ),
  );
}

/// List of all returns (two tabs) with detail, PDF and delete.
class ReturnsListScreen extends StatelessWidget {
  const ReturnsListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('برگشت‌ها'),
          bottom: const TabBar(tabs: <Widget>[Tab(text: 'برگشت از فروش'), Tab(text: 'برگشت از خرید')]),
        ),
        body: const TabBarView(children: <Widget>[_ReturnsTab(isSale: true), _ReturnsTab(isSale: false)]),
      ),
    );
  }
}

class _ReturnsTab extends StatefulWidget {
  final bool isSale;
  const _ReturnsTab({required this.isSale});
  @override
  State<_ReturnsTab> createState() => _ReturnsTabState();
}

class _ReturnsTabState extends State<_ReturnsTab> {
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  bool _loading = true;
  String? _err;

  String get _pre => widget.isSale ? 'sale_returns' : 'purchase_returns';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await OfflineDocs.call('$_pre.list', <String, dynamic>{});
      if (!mounted) return;
      setState(() {
        _items = ReturnsHelp.maps(r['items']);
        _loading = false;
        _err = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _err = e.toString();
      });
    }
  }

  Future<void> _open(Map<String, dynamic> row) async {
    try {
      final Map<String, dynamic> r = await OfflineDocs.call('$_pre.get', <String, dynamic>{'id': row['id']});
      final List<Map<String, dynamic>> its = ReturnsHelp.maps(r['items']);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (BuildContext ctx) => Directionality(
          textDirection: TextDirection.rtl,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text('${widget.isSale ? 'برگشت از فروش' : 'برگشت از خرید'} شمارهٔ ${faNum(ReturnsHelp.d(r['number']), dec: 0)}',
                  style: Theme.of(ctx).textTheme.titleMedium),
              infoRow('طرف‌حساب', '${r['party']}'),
              infoRow('تاریخ', jalaliDate('${r['date']}')),
              for (final Map<String, dynamic> i in its)
                infoRow('${i['type_name'] ?? i['code'] ?? ''}',
                    '${faNum(ReturnsHelp.d(i['kg']), dec: 3)} کیلو × ${faNum(ReturnsHelp.d(i['unit_price']), dec: 0)}'),
              infoRow('ارزش برگشت', '${faNum(ReturnsHelp.d(r['total']), dec: 0)} ریال'),
              infoRow('بازپرداخت', '${faNum(ReturnsHelp.d(r['refund_amount']), dec: 0)} ریال'),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: <Widget>[
                OutlinedButton.icon(
                  onPressed: () async {
                    final file = await PdfService.buildDocument(
                      title: widget.isSale ? 'سند برگشت از فروش' : 'سند برگشت از خرید',
                      fileTag: widget.isSale ? 'sale_return' : 'purchase_return',
                      header: <List<String>>[
                        <String>['شماره', faNum(ReturnsHelp.d(r['number']), dec: 0)],
                        <String>['تاریخ', jalaliDate('${r['date']}')],
                        <String>[widget.isSale ? 'خریدار' : 'فروشنده', '${r['party']}'],
                      ],
                      columns: <String>['ردیف', 'کالا', 'کد', 'وزن (کیلو)', 'فی (ریال)', 'مبلغ (ریال)'],
                      rows: <List<String>>[
                        for (int k = 0; k < its.length; k++)
                          <String>[
                            faNum(k + 1, dec: 0), '${its[k]['type_name'] ?? ''}', '${its[k]['code'] ?? '-'}',
                            faNum(ReturnsHelp.d(its[k]['kg']), dec: 3), faNum(ReturnsHelp.d(its[k]['unit_price']), dec: 0),
                            faNum(ReturnsHelp.d(its[k]['amount']), dec: 0),
                          ],
                      ],
                      totals: <List<String>>[
                        <String>['ارزش برگشت (ریال)', faNum(ReturnsHelp.d(r['total']), dec: 0)],
                        <String>['بازپرداخت (ریال)', faNum(ReturnsHelp.d(r['refund_amount']), dec: 0)],
                        <String>['اثر بر حساب (ریال)', faNum(ReturnsHelp.d(r['net_effect']), dec: 0)],
                      ],
                      note: r['note'] as String?,
                    );
                    if (!mounted) return;
                    await PdfOutput.show(context, file);
                  },
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  label: const Text('PDF'),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    if (!await confirm(ctx, 'این برگشت حذف شود؟ موجودی انبار به حالت قبل برمی‌گردد.')) return;
                    try {
                      await OfflineDocs.call('$_pre.delete', <String, dynamic>{'id': row['id']});
                      if (ctx.mounted) Navigator.pop(ctx);
                      await _load();
                    } catch (e) {
                      if (ctx.mounted) snack(ctx, e.toString());
                    }
                  },
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('حذف'),
                ),
              ]),
            ]),
          ),
        ),
      );
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_err != null) return Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(_err!)));
    if (_items.isEmpty) return const Center(child: Text('برگشتی ثبت نشده'));
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(children: <Widget>[
        for (final Map<String, dynamic> r in _items)
          ListTile(
            title: Text('${r['party']} — شمارهٔ ${faNum(ReturnsHelp.d(r['number']), dec: 0)}'),
            subtitle: Text(jalaliDate('${r['date']}')),
            trailing: Text('${faNum(ReturnsHelp.d(r['total']), dec: 0)} ریال'),
            onTap: () => _open(r),
          ),
      ]),
    );
  }
}

/// Separate net lines under the profit totals: sales returns in the report period (local mirror, works offline). Hidden when none.
class ReturnsProfitCard extends StatefulWidget {
  final (DateTime?, DateTime?) range;
  final double profit;
  const ReturnsProfitCard({super.key, required this.range, required this.profit});
  @override
  State<ReturnsProfitCard> createState() => _ReturnsProfitCardState();
}

class _ReturnsProfitCardState extends State<ReturnsProfitCard> {
  Map<String, dynamic>? _sum;

  @override
  void initState() {
    super.initState();
    AppDb.I.version.addListener(_load); // offline-created returns / sync pulls refresh the card
    _load();
  }

  @override
  void dispose() {
    AppDb.I.version.removeListener(_load);
    super.dispose();
  }

  @override
  void didUpdateWidget(ReturnsProfitCard old) {
    super.didUpdateWidget(old);
    if (old.range != widget.range) _load();
  }

  Future<void> _load() async {
    try {
      final r = await OfflineDocs.call('sale_returns.summary', <String, dynamic>{
        if (widget.range.$1 != null) 'from': ReturnsHelp.iso(widget.range.$1!),
        if (widget.range.$2 != null) 'to': ReturnsHelp.iso(widget.range.$2!),
      });
      if (mounted) setState(() => _sum = r);
    } catch (_) {
      if (mounted) setState(() => _sum = null); // offline: card simply stays hidden
    }
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic>? s = _sum;
    if (s == null || ReturnsHelp.d(s['count']) <= 0) return const SizedBox.shrink();
    final double rev = ReturnsHelp.d(s['revenue_reversed']);
    final double cogs = ReturnsHelp.d(s['cogs_reversed']);
    final double prof = ReturnsHelp.d(s['profit_reversed']);
    final double net = widget.profit - prof;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: <Widget>[
          sectionTitle(context, 'برگشت از فروش در این بازه'),
          infoRow('تعداد برگشت', faNum(ReturnsHelp.d(s['count']), dec: 0)),
          infoRow('فروش برگشتی (کسر از فروش)', '${faNum(rev, dec: 0)} ریال'),
          infoRow('بهای کالای برگشتی (کسر از بها)', '${faNum(cogs, dec: 0)} ریال'),
          infoRow('سود برگشتی', '${faNum(prof, dec: 0)} ریال'),
          infoRow(net >= 0 ? 'سود خالص پس از برگشت' : 'زیان خالص پس از برگشت', '${faNum(net.abs(), dec: 0)} ریال'),
          const Text('برگشت‌ها بر اساس تاریخ برگشت حساب می‌شوند؛ هزینهٔ کارگر و حمل فروش اصلی تغییر نمی‌کند.',
              style: TextStyle(fontSize: 11, color: Colors.black54)),
        ]),
      ),
    );
  }
}
