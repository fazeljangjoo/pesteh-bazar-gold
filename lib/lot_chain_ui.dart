import 'dart:io';

import 'package:flutter/material.dart';

import 'code_kind.dart';
import 'lot_chain_calc.dart';
import 'pdf_output.dart' show PdfOutput; // v83: چاپ ردیابی
import 'pdf_service.dart' show PdfService;
import 'scan_entry.dart';
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;

/// T5 — «مسیر پسته»: خط زمانی عمودی (مبدأ ← مراحل ← این پسته ← مراحل ← مقصد) از `lot_chain.get`. فقط آنلاین؛ بدون هیچ مبلغ.
/// ورود: کد/شمارهٔ لات (تایپ یا اسکن) یا `lotId` / `code` از کارت لات. لمس هر لات = باز کردن مسیر همان لات.

/// ارقام فارسی/عربی → لاتین (برای تشخیص «شمارهٔ لات»).
String _latin(String s) {
  const String fa = '۰۱۲۳۴۵۶۷۸۹';
  const String ar = '٠١٢٣٤٥٦٧٨٩';
  final StringBuffer b = StringBuffer();
  for (final int r in s.runes) {
    final String ch = String.fromCharCode(r);
    final int i = fa.indexOf(ch) >= 0 ? fa.indexOf(ch) : ar.indexOf(ch);
    b.write(i >= 0 ? '$i' : ch);
  }
  return b.toString();
}

String _kg(num v) => '${faNum(v, dec: 1)} کیلو';
double _d(dynamic v) => v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);

String _date(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  try {
    return jalaliDate(iso.length >= 10 ? iso.substring(0, 10) : iso);
  } catch (_) {
    return toFaDigits(iso);
  }
}

class LotChainScreen extends StatefulWidget {
  final int? lotId;
  final String? code;
  const LotChainScreen({super.key, this.lotId, this.code});

  @override
  State<LotChainScreen> createState() => _LotChainScreenState();
}

class _LotChainScreenState extends State<LotChainScreen> {
  final TextEditingController _c = TextEditingController();
  ChainTimeline? _t;
  Map<String, dynamic> _raw = <String, dynamic>{}; // v83: پاسخ خام (منشأ/محصول مستقیم)
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _c.text = widget.code ?? (widget.lotId != null ? '${widget.lotId}' : '');
    if (widget.lotId != null || (widget.code ?? '').trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _go());
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    final String t = _c.text.trim();
    if (t.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final int? id = int.tryParse(_latin(t));
      final Map<String, dynamic> r = await StockApi.call('lot_chain.get', <String, dynamic>{if (id != null) 'lot_id': id else 'code': t});
      if (!mounted) return;
      setState(() {
        _t = chainToTimeline(r);
        _raw = r;
        _loading = false;
      });
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _t = null;
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _scan() async {
    final String? code = await scanBarcode(context);
    if (code == null || !mounted) return;
    _c.text = code;
    await _go();
  }

  void _open(ChainStep s) {
    final int? id = s.lotId;
    if (id == null) return;
    Navigator.push<void>(context, MaterialPageRoute<void>(builder: (_) => LotChainScreen(lotId: id)));
  }

  List<Map<String, dynamic>> _list(String k) => <Map<String, dynamic>>[
        for (final dynamic x in (_raw[k] as List<dynamic>? ?? const <dynamic>[]))
          if (x is Map) Map<String, dynamic>.from(x),
      ];

  String _lotLine(Map<String, dynamic> x) => <String>[
        if ('${x['category'] ?? ''}'.isNotEmpty || '${x['type_name'] ?? ''}'.isNotEmpty) '${x['category'] ?? ''} ${x['type_name'] ?? ''}'.trim(),
        if ('${x['seller'] ?? ''}'.isNotEmpty && x['seller'] != '—') 'طرف: ${x['seller']}',
        if (_date(x['date'] as String?).isNotEmpty) _date(x['date'] as String?),
      ].join(' · ');

  /// v83: «از چه پسته‌ای آمده» (لات‌های ورودی عملیاتی که این لات را ساخت) و «به چه پسته‌ای تبدیل شده».
  Widget _directCard(String title, List<Map<String, dynamic>> rows, {List<Map<String, dynamic>> origin = const <Map<String, dynamic>>[]}) {
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          for (final Map<String, dynamic> o in origin)
            Text('${chainKindLabel('${o['kind']}')} · ${o['label']}${_date(o['date'] as String?).isNotEmpty ? ' · ${_date(o['date'] as String?)}' : ''} · ${_kg(_d(o['kg']))}'),
          for (final Map<String, dynamic> x in rows)
            InkWell(
              onTap: x['lot_id'] == null ? null : () => Navigator.push<void>(context, MaterialPageRoute<void>(builder: (_) => LotChainScreen(lotId: (x['lot_id'] as num).toInt()))),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: <Widget>[
                  CodeChip(code: '${x['code'] ?? '#${x['lot_id']}'}', isMix: ((x['is_mix'] as num?) ?? 0).toInt(), fontSize: 12),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                      Text('${_kg(_d(x['kg']))} — ${x['via'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(_lotLine(x), style: const TextStyle(fontSize: 12, color: Colors.black54)),
                    ]),
                  ),
                  const Icon(Icons.chevron_left, size: 18),
                ]),
              ),
            ),
          if (rows.isEmpty && origin.isEmpty) const Text('—', style: TextStyle(color: Colors.grey)),
        ]),
      ),
    );
  }

  /// v83: برگهٔ چاپی ردیابی: مشخصات لات، منشأ مستقیم، محصولات، مراحل قبل و بعد، مقصد.
  Future<void> _print() async {
    final ChainTimeline? t = _t;
    if (t == null) return;
    final Map<String, dynamic> lot = _raw['lot'] is Map ? Map<String, dynamic>.from(_raw['lot'] as Map) : <String, dynamic>{};
    String step(ChainStep s) => s.isLot ? '${s.code} ${s.label}'.trim() : '${chainKindLabel(s.kind)} ${s.label}';
    final File file = await PdfService.buildTableReport(
      title: 'ردیابی پسته — ${lot['code'] ?? ''}',
      subtitle: '${lot['category'] ?? ''} ${lot['type_name'] ?? ''}  •  ورود ${_date(lot['date'] as String?)}',
      kv: <List<String>>[
        <String>['وزن خالص / مانده', '${_kg(_d(lot['net_weight']))} / ${_kg(_d(lot['remaining']))}'],
        <String>['مبدأ', t.origins.isEmpty ? '—' : t.origins.map((ChainOrigin o) => '${chainOriginLabel(o.kind)} ${o.name} (${faNum(o.pct, dec: 1)}٪)').join('، ')],
        <String>['فروخته / باقی / ضایعات / برگشتی', '${_kg(t.soldKg)} / ${_kg(t.remainingKg)} / ${_kg(t.wasteKg)} / ${_kg(t.returnedKg)}', 'b'],
      ],
      headers: const <String>['بخش', 'لات / مرحله', 'شرح', 'وزن', 'تاریخ'],
      rows: <List<String>>[
        for (final Map<String, dynamic> o in _list('direct_origin')) <String>['منشأ', chainKindLabel('${o['kind']}'), '${o['label']}', _kg(_d(o['kg'])), _date(o['date'] as String?)],
        for (final Map<String, dynamic> x in _list('sources'))
          <String>['ساخته‌شده از', '${x['code'] ?? '#${x['lot_id']}'}', '${x['via'] ?? ''} — ${_lotLine(x)}', _kg(_d(x['kg'])), _date(x['date'] as String?)],
        for (final ChainStep s in t.before) <String>['مسیر قبل', step(s), chainKindLabel(s.kind), s.kg > 0 ? _kg(s.kg) : '', _date(s.date)],
        for (final ChainStep s in t.after) <String>['مسیر بعد', step(s), chainKindLabel(s.kind), s.kg > 0 ? _kg(s.kg) : '', _date(s.date)],
        for (final Map<String, dynamic> x in _list('products'))
          <String>['تبدیل‌شده به', '${x['code'] ?? '#${x['lot_id']}'}', '${x['via'] ?? ''} — ${_lotLine(x)}', _kg(_d(x['kg'])), _date(x['date'] as String?)],
        for (final ChainStep s in t.sales) <String>['فروش', step(s), '', s.kg > 0 ? _kg(s.kg) : '', _date(s.date)],
        for (final ChainStep s in t.waste) <String>['ضایعات/افت', step(s), '', s.kg > 0 ? _kg(s.kg) : '', _date(s.date)],
      ],
      filePrefix: 'lot_trace',
      pageNumbers: true,
    );
    if (!mounted) return;
    await PdfOutput.show(context, file);
  }

  // ───── اجزای خط زمانی ─────

  Widget _rail({required Widget child, required Color color, bool first = false, bool last = false, bool big = false}) {
    final double d = big ? 16 : 10;
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
        SizedBox(
          width: 28,
          child: Column(children: <Widget>[
            Expanded(child: Container(width: 2, color: first ? Colors.transparent : Colors.grey.shade400)),
            Container(width: d, height: d, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            Expanded(child: Container(width: 2, color: last ? Colors.transparent : Colors.grey.shade400)),
          ]),
        ),
        Expanded(child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: child)),
      ]),
    );
  }

  Widget _stepCard(ChainStep s, {bool self = false}) {
    final bool tappable = s.isLot && !self;
    final String when = _date(s.date);
    final Widget head = s.isLot
        ? CodeChip(code: s.code, isMix: s.isMix, fontSize: self ? 14 : 12)
        : Text('${chainKindLabel(s.kind)} · ${s.label}', style: const TextStyle(fontWeight: FontWeight.w600));
    return Card(
      elevation: self ? 3 : 0,
      color: self ? Theme.of(context).colorScheme.primaryContainer : null,
      shape: self ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: Theme.of(context).colorScheme.primary, width: 1.5)) : null,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: tappable ? () => _open(s) : null,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(children: <Widget>[
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                if (self) const Text('این پسته', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                head,
                Text(
                  <String>[
                    if (s.isLot) (s.label.isNotEmpty ? s.label : chainKindLabel(s.kind)) else chainKindLabel(s.kind),
                    if (when.isNotEmpty) when,
                    if (s.kg > 0) _kg(s.kg),
                  ].join(' · '),
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ]),
            ),
            if (tappable) const Icon(Icons.chevron_left, size: 20),
          ]),
        ),
      ),
    );
  }

  Widget _originsCard(ChainTimeline t) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          const Text('مبدأ', style: TextStyle(fontWeight: FontWeight.bold)),
          if (t.origins.isEmpty) const Text('منشأ ثبت نشده', style: TextStyle(fontSize: 12, color: Colors.grey)),
          for (final ChainOrigin o in t.origins)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(children: <Widget>[
                Expanded(child: Text('${chainOriginLabel(o.kind)} · ${o.name}')),
                Text('${faNum(o.pct, dec: 1)}٪', style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.green)),
              ]),
            ),
        ]),
      ),
    );
  }

  Widget _destCard(ChainTimeline t) {
    Widget row(String title, double kg, List<ChainStep> items) {
      if (kg <= 0 && items.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text('$title: ${_kg(kg)}', style: const TextStyle(fontWeight: FontWeight.w600)),
          for (final ChainStep s in items)
            Text('   ${chainKindLabel(s.kind)} ${s.label}${_date(s.date).isNotEmpty ? ' · ${_date(s.date)}' : ''}${s.kg > 0 ? ' · ${_kg(s.kg)}' : ''}',
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
        ]),
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          const Text('مقصد', style: TextStyle(fontWeight: FontWeight.bold)),
          row('فروخته‌شده', t.soldKg, t.sales),
          row('باقی‌مانده', t.remainingKg, const <ChainStep>[]),
          row('ضایعات/افت', t.wasteKg, t.waste),
          row('برگشتی', t.returnedKg, t.returned),
          if (t.soldKg <= 0 && t.remainingKg <= 0 && t.wasteKg <= 0 && t.returnedKg <= 0)
            const Text('مقصدی ثبت نشده', style: TextStyle(fontSize: 12, color: Colors.grey)),
        ]),
      ),
    );
  }

  Widget _timeline(ChainTimeline t) {
    final List<Widget> rows = <Widget>[];
    final List<(Widget, Color, bool)> items = <(Widget, Color, bool)>[
      (_originsCard(t), Colors.green, false),
      for (final ChainStep s in t.before) (_stepCard(s), Colors.blueGrey, false),
      (_stepCard(t.self, self: true), Theme.of(context).colorScheme.primary, true),
      for (final ChainStep s in t.after) (_stepCard(s), Colors.blueGrey, false),
      (_destCard(t), Colors.deepOrange, false),
    ];
    for (int i = 0; i < items.length; i++) {
      rows.add(_rail(child: items[i].$1, color: items[i].$2, first: i == 0, last: i == items.length - 1, big: items[i].$3));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
      ...rows,
      if (t.truncated)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text('ادامهٔ مسیر نمایش داده نشد (مسیر بسیار بلند است).', style: TextStyle(fontSize: 12, color: Colors.orange)),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final ChainTimeline? t = _t;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('مسیر پسته'), actions: <Widget>[
          IconButton(tooltip: 'چاپ / PDF ردیابی', icon: const Icon(Icons.print_outlined), onPressed: t == null ? null : _print),
        ]),
        body: ListView(padding: const EdgeInsets.all(12), children: <Widget>[
          TextField(
            controller: _c,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _go(),
            decoration: InputDecoration(
              labelText: 'کد یا شمارهٔ لات',
              border: const OutlineInputBorder(),
              prefixIcon: IconButton(tooltip: 'اسکن بارکد', icon: const Icon(Icons.qr_code_scanner), onPressed: _scan),
              suffixIcon: IconButton(tooltip: 'نمایش مسیر', icon: const Icon(Icons.search), onPressed: _go),
            ),
          ),
          if (_loading) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
          if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: const TextStyle(color: Colors.red))),
          if (t != null) ...<Widget>[
            _directCard('ساخته‌شده از (منشأ مستقیم)', _list('sources'), origin: _list('direct_origin')),
            if (_list('products').isNotEmpty) _directCard('تبدیل‌شده به (محصولات مستقیم)', _list('products')),
            const SizedBox(height: 12),
            _timeline(t),
          ],
        ]),
      ),
    );
  }
}
