import 'package:flutter/material.dart';

import 'code_kind.dart';
import 'lot_chain_calc.dart';
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
        appBar: AppBar(title: const Text('مسیر پسته')),
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
          if (t != null) ...<Widget>[const SizedBox(height: 12), _timeline(t)],
        ]),
      ),
    );
  }
}
