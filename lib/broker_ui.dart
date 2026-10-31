import 'dart:io';

import 'package:flutter/material.dart';

import 'db.dart';
import 'fmt.dart' show Fmt, MoneyField;
import 'pdf_output.dart';
import 'pdf_service.dart';
import 'returns_ui.dart' show ReturnsHelp;
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;
import 'widgets.dart';

/// S05.T05.2 — brokers (دلال) and commissions. ONLINE-ONLY via StockApi (same precedent as returns/transfers before T04.4b):
/// no local tables, no schemaVersion bump. Forms keep working without a broker; the broker is attached to a document that
/// already reached the server (broker.attach). Commission math mirrors server pb_broker_calc (integer rounding).
const Map<String, String> kBrokerBasisLabels = <String, String>{
  'percent': 'درصد از مبلغ',
  'per_kg': 'مبلغ ثابت به‌ازای هر کیلو',
  'fixed': 'مبلغ ثابت',
};
const Map<String, String> kBrokerPayerLabels = <String, String>{'us': 'ما می‌پردازیم', 'counterparty': 'طرف مقابل می‌پردازد'};

int brokerCalc(String basis, double value, double kg, double price) {
  if (basis == 'percent') return (kg * price * value / 100.0).round();
  if (basis == 'per_kg') return (kg * value).round();
  return value.round();
}

double _d(dynamic v) => ReturnsHelp.d(v);

/// Loads brokers (parties with id) as [{id, name}].
Future<List<Map<String, dynamic>>> _loadParties() async {
  final Map<String, dynamic> r = await StockApi.call('parties.list');
  final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
  final dynamic raw = r['parties'] ?? r['list'] ?? r['items'];
  for (final Map<String, dynamic> m in ReturnsHelp.maps(raw)) {
    final int id = _d(m['party_id']).toInt();
    if (id > 0) out.add(<String, dynamic>{'id': id, 'name': '${m['name'] ?? m['key'] ?? ''}', 'types': m['types']});
  }
  // brokers first
  out.sort((Map<String, dynamic> a, Map<String, dynamic> b) {
    final int ka = (a['types'] is List && (a['types'] as List).contains('broker')) ? 0 : 1;
    final int kb = (b['types'] is List && (b['types'] as List).contains('broker')) ? 0 : 1;
    return ka != kb ? ka - kb : '${a['name']}'.compareTo('${b['name']}');
  });
  return out;
}

/// Opens the attach-broker dialog for a purchase/sale row (local map from the cards). Needs the doc on the server.
Future<void> openBrokerDialog(BuildContext context, {required bool isSale, required Map<String, dynamic> doc}) async {
  try {
    final int localId = _d(doc['id']).toInt();
    final int sid = await ReturnsHelp.serverId(isSale ? 'sale' : 'purchase', localId);
    final List<Map<String, dynamic>> parties = await _loadParties();
    final Map<String, dynamic> rr = await StockApi.call('broker_rules.list');
    final List<Map<String, dynamic>> rules = ReturnsHelp.maps(rr['rules']);
    if (!context.mounted) return;
    final double kg = _d(doc['net_weight']);
    final double price = _d(doc['price']);
    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (_) => _BrokerDialog(isSale: isSale, serverId: sid, parties: parties, rules: rules, kg: kg, price: price, doc: doc),
    );
    if (saved == true && context.mounted) snack(context, 'دلال و کمیسیون ثبت شد');
  } on StockApiException catch (e) {
    if (context.mounted) snack(context, e.message);
  }
}

class _BrokerDialog extends StatefulWidget {
  final bool isSale;
  final int serverId;
  final List<Map<String, dynamic>> parties;
  final List<Map<String, dynamic>> rules;
  final double kg;
  final double price;
  final Map<String, dynamic> doc;
  const _BrokerDialog(
      {required this.isSale, required this.serverId, required this.parties, required this.rules, required this.kg, required this.price, required this.doc});
  @override
  State<_BrokerDialog> createState() => _BrokerDialogState();
}

class _BrokerDialogState extends State<_BrokerDialog> {
  int? _brokerId;
  String _basis = 'percent';
  String _payer = 'us';
  final TextEditingController _value = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final dynamic cur = widget.doc['broker_id'];
    if (cur != null && _d(cur) > 0) {
      _brokerId = _d(cur).toInt();
      _basis = '${widget.doc['broker_basis'] ?? 'percent'}';
      _payer = '${widget.doc['broker_payer'] ?? 'us'}';
      _value.text = '${_d(widget.doc['broker_value'])}';
    }
  }

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  void _applyRule(int id) {
    final String kind = widget.isSale ? 'sale' : 'purchase';
    for (final String applies in <String>[kind, 'both']) {
      for (final Map<String, dynamic> r in widget.rules) {
        if (_d(r['broker_id']).toInt() == id && '${r['applies']}' == applies && _d(r['active']) > 0) {
          setState(() {
            _basis = '${r['basis']}';
            _payer = '${r['payer']}';
            _value.text = '${_d(r['value'])}';
          });
          return;
        }
      }
    }
  }

  int get _preview => brokerCalc(_basis, parseNum(_value.text) ?? 0, widget.kg, widget.price);

  Future<void> _save({bool clear = false}) async {
    if (!clear && _brokerId == null) {
      snack(context, 'دلال را انتخاب کنید');
      return;
    }
    final double v = parseNum(_value.text) ?? 0;
    if (!clear && (v <= 0 || (_basis == 'percent' && v > 100))) {
      snack(context, 'مقدار کمیسیون نامعتبر است');
      return;
    }
    setState(() => _busy = true);
    try {
      await StockApi.call('broker.attach', <String, dynamic>{
        'kind': widget.isSale ? 'sale' : 'purchase',
        'doc_id': widget.serverId,
        'broker_id': clear ? 0 : _brokerId,
        if (!clear) 'broker_basis': _basis,
        if (!clear) 'broker_value': v,
        if (!clear) 'broker_payer': _payer,
      });
      if (mounted) Navigator.pop(context, true);
    } on StockApiException catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        snack(context, e.message);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Text(widget.isSale ? 'دلال فروش' : 'دلال خرید'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
            DropdownButtonFormField<int>(
              value: widget.parties.any((Map<String, dynamic> p) => p['id'] == _brokerId) ? _brokerId : null,
              decoration: const InputDecoration(labelText: 'دلال'),
              items: widget.parties
                  .map((Map<String, dynamic> p) => DropdownMenuItem<int>(value: p['id'] as int, child: Text('${p['name']}')))
                  .toList(),
              onChanged: (int? v) {
                setState(() => _brokerId = v);
                if (v != null) _applyRule(v);
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _basis,
              decoration: const InputDecoration(labelText: 'مبنای کمیسیون'),
              items: kBrokerBasisLabels.entries
                  .map((MapEntry<String, String> e) => DropdownMenuItem<String>(value: e.key, child: Text(e.value)))
                  .toList(),
              onChanged: (String? v) => setState(() => _basis = v ?? 'percent'),
            ),
            const SizedBox(height: 12),
            numField(_value, _basis == 'percent' ? 'درصد' : 'مبلغ (ریال)', onChanged: () => setState(() {})),
            DropdownButtonFormField<String>(
              value: _payer,
              decoration: const InputDecoration(labelText: 'پرداخت‌کننده'),
              items: kBrokerPayerLabels.entries
                  .map((MapEntry<String, String> e) => DropdownMenuItem<String>(value: e.key, child: Text(e.value)))
                  .toList(),
              onChanged: (String? v) => setState(() => _payer = v ?? 'us'),
            ),
            const SizedBox(height: 12),
            infoRow('کمیسیون محاسبه‌شده', '${Fmt.money(_preview)}'),
            Text(
              _payer != 'us'
                  ? 'کمیسیون را طرف مقابل می‌پردازد؛ روی هزینه و سود شما اثری ندارد.'
                  : (widget.isSale ? 'به‌عنوان هزینهٔ فروش از سود کم می‌شود.' : 'به قیمت تمام‌شدهٔ این خرید اضافه می‌شود.'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ]),
        ),
        actions: <Widget>[
          if (_d(widget.doc['broker_id']) > 0) TextButton(onPressed: _busy ? null : () => _save(clear: true), child: const Text('حذف دلال')),
          TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('انصراف')),
          FilledButton(onPressed: _busy ? null : _save, child: const Text('ثبت')),
        ],
      ),
    );
  }
}

/// Commission report + settlement payments + default rules.
class BrokerScreen extends StatefulWidget {
  const BrokerScreen({super.key});
  @override
  State<BrokerScreen> createState() => _BrokerScreenState();
}

class _BrokerScreenState extends State<BrokerScreen> {
  DateTime? _from;
  DateTime? _to;
  Map<String, dynamic>? _rep;
  List<Map<String, dynamic>> _rules = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _pays = <Map<String, dynamic>>[];
  bool _loading = true;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final Map<String, dynamic> rep = await StockApi.call('reports.broker_commission', <String, dynamic>{
        if (_from != null) 'from': ReturnsHelp.iso(_from!),
        if (_to != null) 'to': ReturnsHelp.iso(_to!),
      });
      final Map<String, dynamic> ru = await StockApi.call('broker_rules.list');
      final Map<String, dynamic> pa = await StockApi.call('broker_payments.list');
      if (!mounted) return;
      setState(() {
        _rep = rep;
        _rules = ReturnsHelp.maps(ru['rules']);
        _pays = ReturnsHelp.maps(pa['payments']);
        _loading = false;
      });
    } on StockApiException catch (e) {
      if (mounted) {
        setState(() {
          _err = e.message;
          _loading = false;
        });
      }
    }
  }

  Future<void> _pickRange(bool from) async {
    final DateTime? d = await pickDate(context, initial: (from ? _from : _to) ?? DateTime.now());
    if (d == null) return;
    setState(() => from ? _from = d : _to = d);
    _load();
  }

  Future<void> _addPayment(Map<String, dynamic> broker) async {
    final TextEditingController amount = TextEditingController();
    final TextEditingController note = TextEditingController();
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text('پرداخت به ${broker['broker_name']}'),
          content: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
            MoneyField(controller: amount, label: 'مبلغ'),
            textField(note, 'توضیح'),
          ]),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('انصراف')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('ثبت')),
          ],
        ),
      ),
    );
    final double a = (MoneyField.stored(amount) ?? 0).toDouble();
    if (ok != true) return;
    if (a <= 0) {
      if (mounted) snack(context, 'مبلغ نامعتبر است');
      return;
    }
    try {
      await StockApi.call('broker_payments.save', <String, dynamic>{
        'uid': ReturnsHelp.newUid('bp'),
        'broker_id': _d(broker['broker_id']).toInt(),
        'amount': a,
        'date': ReturnsHelp.iso(DateTime.now()),
        if (note.text.trim().isNotEmpty) 'note': note.text.trim(),
      });
      _load();
    } on StockApiException catch (e) {
      if (mounted) snack(context, e.message);
    }
  }

  Future<void> _addRule() async {
    List<Map<String, dynamic>> parties;
    try {
      parties = await _loadParties();
    } on StockApiException catch (e) {
      if (mounted) snack(context, e.message);
      return;
    }
    if (!mounted) return;
    int? bid;
    String basis = 'percent';
    String applies = 'both';
    String payer = 'us';
    final TextEditingController value = TextEditingController();
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => Directionality(
        textDirection: TextDirection.rtl,
        child: StatefulBuilder(
          builder: (BuildContext c, StateSetter set) => AlertDialog(
            title: const Text('قانون پیش‌فرض کمیسیون'),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
                DropdownButtonFormField<int>(
                  value: bid,
                  decoration: const InputDecoration(labelText: 'دلال'),
                  items: parties
                      .map((Map<String, dynamic> p) => DropdownMenuItem<int>(value: p['id'] as int, child: Text('${p['name']}')))
                      .toList(),
                  onChanged: (int? v) => set(() => bid = v),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: basis,
                  decoration: const InputDecoration(labelText: 'مبنا'),
                  items: kBrokerBasisLabels.entries
                      .map((MapEntry<String, String> e) => DropdownMenuItem<String>(value: e.key, child: Text(e.value)))
                      .toList(),
                  onChanged: (String? v) => set(() => basis = v ?? 'percent'),
                ),
                const SizedBox(height: 8),
                numField(value, basis == 'percent' ? 'درصد' : 'مبلغ (ریال)'),
                DropdownButtonFormField<String>(
                  value: applies,
                  decoration: const InputDecoration(labelText: 'برای'),
                  items: const <DropdownMenuItem<String>>[
                    DropdownMenuItem<String>(value: 'both', child: Text('خرید و فروش')),
                    DropdownMenuItem<String>(value: 'purchase', child: Text('فقط خرید')),
                    DropdownMenuItem<String>(value: 'sale', child: Text('فقط فروش')),
                  ],
                  onChanged: (String? v) => set(() => applies = v ?? 'both'),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: payer,
                  decoration: const InputDecoration(labelText: 'پرداخت‌کننده'),
                  items: kBrokerPayerLabels.entries
                      .map((MapEntry<String, String> e) => DropdownMenuItem<String>(value: e.key, child: Text(e.value)))
                      .toList(),
                  onChanged: (String? v) => set(() => payer = v ?? 'us'),
                ),
              ]),
            ),
            actions: <Widget>[
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('انصراف')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('ذخیره')),
            ],
          ),
        ),
      ),
    );
    if (ok != true) return;
    final double v = parseNum(value.text) ?? 0;
    if (bid == null || v <= 0) {
      if (mounted) snack(context, 'دلال و مقدار را وارد کنید');
      return;
    }
    try {
      await StockApi.call('broker_rules.save',
          <String, dynamic>{'broker_id': bid, 'basis': basis, 'value': v, 'applies': applies, 'payer': payer});
      _load();
    } on StockApiException catch (e) {
      if (mounted) snack(context, e.message);
    }
  }

  Future<void> _pdf() async {
    final Map<String, dynamic>? rep = _rep;
    if (rep == null) return;
    final Map<String, dynamic> t = (rep['totals'] is Map) ? Map<String, dynamic>.from(rep['totals'] as Map) : <String, dynamic>{};
    final File file = await PdfService.buildDocument(
      title: 'گزارش کمیسیون دلال‌ها',
      fileTag: 'broker_commission',
      header: <List<String>>[
        <String>['از تاریخ', _from == null ? '—' : jalaliDateFromDt(_from!)],
        <String>['تا تاریخ', _to == null ? '—' : jalaliDateFromDt(_to!)],
      ],
      columns: <String>['دلال', 'کمیسیون خرید', 'کمیسیون فروش', 'پرداخت‌شده', 'مانده'],
      rows: ReturnsHelp.maps(rep['brokers'])
          .map((Map<String, dynamic> b) => <String>[
                '${b['broker_name']}',
                Fmt.money(_d(b['purchase_commission']), label: false),
                Fmt.money(_d(b['sale_commission']), label: false),
                Fmt.money(_d(b['paid']), label: false),
                Fmt.money(_d(b['balance']), label: false),
              ])
          .toList(),
      totals: <List<String>>[
        <String>['جمع کمیسیون (ما می‌پردازیم)', Fmt.money(_d(t['due']), label: false)],
        <String>['جمع پرداخت‌شده', Fmt.money(_d(t['paid']), label: false)],
      ],
    );
    if (!mounted) return;
    await PdfOutput.show(context, file);
  }

  @override
  Widget build(BuildContext context) {
    final List<Map<String, dynamic>> brokers = ReturnsHelp.maps(_rep?['brokers']);
    final Map<String, dynamic> t = (_rep?['totals'] is Map) ? Map<String, dynamic>.from(_rep!['totals'] as Map) : <String, dynamic>{};
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('دلال‌ها و کمیسیون'), actions: <Widget>[
          IconButton(tooltip: 'PDF', onPressed: _rep == null ? null : _pdf, icon: const Icon(Icons.picture_as_pdf_outlined)),
        ]),
        floatingActionButton: FloatingActionButton.extended(onPressed: _addRule, icon: const Icon(Icons.rule), label: const Text('قانون کمیسیون')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _err != null
                ? Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(_err!)))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(padding: const EdgeInsets.all(12), children: <Widget>[
                      Row(children: <Widget>[
                        Expanded(
                            child: OutlinedButton(
                                onPressed: () => _pickRange(true), child: Text(_from == null ? 'از تاریخ' : jalaliDateFromDt(_from!)))),
                        const SizedBox(width: 8),
                        Expanded(
                            child: OutlinedButton(
                                onPressed: () => _pickRange(false), child: Text(_to == null ? 'تا تاریخ' : jalaliDateFromDt(_to!)))),
                        if (_from != null || _to != null)
                          IconButton(
                              onPressed: () {
                                setState(() {
                                  _from = null;
                                  _to = null;
                                });
                                _load();
                              },
                              icon: const Icon(Icons.clear)),
                      ]),
                      const SizedBox(height: 8),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(children: <Widget>[
                            sectionTitle(context, 'جمع بازه'),
                            infoRow('کمیسیون خرید (به بهای تمام‌شده)', '${Fmt.money(_d(t['purchase_commission']))}'),
                            infoRow('کمیسیون فروش (هزینهٔ فروش)', '${Fmt.money(_d(t['sale_commission']))}'),
                            infoRow('پرداخت‌شده در بازه', '${Fmt.money(_d(t['paid']))}'),
                            infoRow('کمیسیون به‌عهدهٔ طرف مقابل', '${Fmt.money(_d(t['counterparty_commission']))}'),
                          ]),
                        ),
                      ),
                      for (final Map<String, dynamic> b in brokers)
                        Card(
                          child: ListTile(
                            title: Text('${b['broker_name']}'),
                            subtitle: Text('خرید: ${Fmt.money(_d(b['purchase_commission']), label: false)}  ·  فروش: ${Fmt.money(_d(b['sale_commission']), label: false)}\n'
                                'پرداخت‌شده کل: ${Fmt.money(_d(b['total_paid_all']), label: false)}  ·  مانده بدهی ما: ${Fmt.money(_d(b['balance']), label: false)}'),
                            isThreeLine: true,
                            trailing: IconButton(tooltip: 'ثبت پرداخت', icon: const Icon(Icons.payments_outlined), onPressed: () => _addPayment(b)),
                          ),
                        ),
                      if (brokers.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('کمیسیونی در این بازه ثبت نشده است'))),
                      const SizedBox(height: 8),
                      sectionTitle(context, 'قوانین پیش‌فرض'),
                      for (final Map<String, dynamic> r in _rules)
                        ListTile(
                          dense: true,
                          title: Text('${r['broker_name']}'),
                          subtitle: Text('${kBrokerBasisLabels['${r['basis']}'] ?? ''}: ${faNum(_d(r['value']), dec: 2)} · '
                              '${r['applies'] == 'both' ? 'خرید و فروش' : (r['applies'] == 'sale' ? 'فروش' : 'خرید')} · ${kBrokerPayerLabels['${r['payer']}'] ?? ''}'),
                          trailing: IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () async {
                                if (!await confirm(context, 'این قانون حذف شود؟')) return;
                                try {
                                  await StockApi.call('broker_rules.delete', <String, dynamic>{'id': _d(r['id']).toInt()});
                                  _load();
                                } on StockApiException catch (e) {
                                  if (mounted) snack(context, e.message);
                                }
                              }),
                        ),
                      const SizedBox(height: 8),
                      sectionTitle(context, 'پرداخت‌های انجام‌شده'),
                      for (final Map<String, dynamic> p in _pays)
                        ListTile(
                          dense: true,
                          title: Text('${p['broker_name']} — ${Fmt.money(_d(p['amount']))}'),
                          subtitle: Text(jalaliDate('${p['date']}') + ((p['note'] ?? '') == '' ? '' : ' · ${p['note']}')),
                          trailing: IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () async {
                                if (!await confirm(context, 'این پرداخت حذف شود؟')) return;
                                try {
                                  await StockApi.call('broker_payments.delete', <String, dynamic>{'id': _d(p['id']).toInt()});
                                  _load();
                                } on StockApiException catch (e) {
                                  if (mounted) snack(context, e.message);
                                }
                              }),
                        ),
                      const SizedBox(height: 80),
                    ]),
                  ),
      ),
    );
  }
}

/// Profit-screen line «کارمزد دلال» (sale commission paid by us in the period). Hidden when offline or zero.
class BrokerProfitCard extends StatefulWidget {
  final (DateTime?, DateTime?) range;
  final double profit;
  const BrokerProfitCard({super.key, required this.range, required this.profit});
  @override
  State<BrokerProfitCard> createState() => _BrokerProfitCardState();
}

class _BrokerProfitCardState extends State<BrokerProfitCard> {
  double _saleComm = 0;

  @override
  void initState() {
    super.initState();
    AppDb.I.version.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    AppDb.I.version.removeListener(_load);
    super.dispose();
  }

  @override
  void didUpdateWidget(BrokerProfitCard old) {
    super.didUpdateWidget(old);
    if (old.range != widget.range) _load();
  }

  Future<void> _load() async {
    try {
      final Map<String, dynamic> r = await StockApi.call('reports.broker_commission', <String, dynamic>{
        if (widget.range.$1 != null) 'from': ReturnsHelp.iso(widget.range.$1!),
        if (widget.range.$2 != null) 'to': ReturnsHelp.iso(widget.range.$2!),
      });
      final Map<String, dynamic> t = (r['totals'] is Map) ? Map<String, dynamic>.from(r['totals'] as Map) : <String, dynamic>{};
      if (mounted) setState(() => _saleComm = _d(t['sale_commission']));
    } catch (_) {
      if (mounted) setState(() => _saleComm = 0); // offline: hidden
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_saleComm <= 0) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: <Widget>[
          sectionTitle(context, 'کارمزد دلال (فروش)'),
          infoRow('کارمزد دلال فروش در این بازه', '${Fmt.money(_saleComm)}'),
          infoRow('سود پس از کارمزد دلال', '${Fmt.money(widget.profit - _saleComm)}'),
        ]),
      ),
    );
  }
}
