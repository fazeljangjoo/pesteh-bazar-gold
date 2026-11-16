// مرحلهٔ ۱۱ — «کارتکس لات» (زیرتب «کارتکس» در تب انبار). غیر از «کارتکس مالک» (reports_ui.dart). بدون هیچ قیمت/مبلغ.
// داده: StockApi 'stock.lot_cartex' (مجوز stock.view)؛ سرور در دسترس نبود ⇒ محاسبهٔ محلی (lotCartexBuild) از SQLite، بدون فراوری.
import 'package:flutter/material.dart';

import 'code_kind.dart' show groupColor;
import 'db.dart';
import 'form_layout.dart' show FormGrid;
import 'lot_cartex_calc.dart';
import 'processing_ui.dart' show ProcessingScreen;
import 'returns_ui.dart' show ReturnsHelp;
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;

const List<String> _kJMonths = [
  'فروردین', 'اردیبهشت', 'خرداد', 'تیر', 'مرداد', 'شهریور', 'مهر', 'آبان', 'آذر', 'دی', 'بهمن', 'اسفند',
];

String _jd(String? iso) {
  if (iso == null || iso.length < 10) return '—';
  try {
    return jalaliDate(iso.substring(0, 10));
  } catch (_) {
    return '—';
  }
}

String _kgTxt(double v) => '${faNum(v, dec: 3)} کیلو';

class LotCartexView extends StatefulWidget {
  const LotCartexView({super.key});
  @override
  State<LotCartexView> createState() => _LotCartexViewState();
}

class _LotCartexViewState extends State<LotCartexView> with SingleTickerProviderStateMixin {
  static int _lastMonth = 7, _lastDay = 1; // آخرین تنظیم دیده‌شده از سرور (برای حالت آفلاین)

  late final TabController _tc;
  LotCartexReport? _r;
  bool _loading = true;
  String? _err;
  int? _yearStart; // null = سال پسته‌ای جاری (پیش‌فرض سرور)
  String _q = '';

  @override
  void initState() {
    super.initState();
    _tc = TabController(length: 3, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    LotCartexReport? r;
    String? err;
    try {
      final j = await StockApi.call('stock.lot_cartex', <String, dynamic>{if (_yearStart != null) 'year_start': _yearStart});
      r = LotCartexReport.fromJson(j);
      _lastMonth = r.month;
      _lastDay = r.day;
    } on StockApiException catch (e) {
      if (e.network) {
        try {
          r = await _offline();
        } catch (e2) {
          err = 'خواندن اطلاعات محلی ممکن نشد: $e2';
        }
      } else {
        err = e.message;
      }
    } catch (e) {
      err = '$e';
    }
    if (!mounted) return;
    setState(() {
      _r = r ?? _r;
      _err = err;
      _loading = false;
    });
  }

  /// آفلاین: فقط خرید/فروش/کوت از آینهٔ SQLite؛ فراوری/شکست فقط روی سرور است.
  Future<LotCartexReport> _offline() async {
    final d = await AppDb.I.db;
    String day(Object? v) {
      final s = '${v ?? ''}';
      return s.length >= 10 ? s.substring(0, 10) : s;
    }

    final lots = <Map<String, dynamic>>[
      for (final x in await d.rawQuery('SELECT id, code, type_name, seller, net_weight, remaining, date, is_mix FROM purchases WHERE is_mix IN (0,1,2)'))
        {...Map<String, dynamic>.from(x), 'date': day(x['date'])}
    ];
    final ms = <Map<String, dynamic>>[
      for (final x in await d.rawQuery('SELECT mix_purchase_id, source_purchase_id, weight FROM mix_sources')) Map<String, dynamic>.from(x)
    ];
    final si = <Map<String, dynamic>>[
      for (final x in await d.rawQuery('SELECT si.purchase_id AS purchase_id, si.weight AS weight, s.date AS date FROM sale_items si JOIN sales s ON s.id = si.sale_id'))
        {...Map<String, dynamic>.from(x), 'date': day(x['date'])}
    ];
    final today = ReturnsHelp.iso(DateTime.now());
    final years = lotCartexYears([for (final l in lots) '${l['date']}'], today, _lastMonth, _lastDay);
    final yr = _yearStart ?? lotCartexStartYearOf(today, _lastMonth, _lastDay);
    final rg = lotCartexRange(yr, _lastMonth, _lastDay);
    final base = lotCartexBuild(lots, ms, const <Map<String, dynamic>>[], si, from: rg.from, to: rg.to, label: rg.label, offline: true);
    return LotCartexReport(
        from: base.from, to: base.to, label: base.label, types: base.types, years: years, month: _lastMonth, day: _lastDay, offline: true);
  }

  // ---------------- فیلتر جست‌وجو (نام طرف) ----------------
  bool _hit(String party) => _q.isEmpty || persianSortKey(party).contains(persianSortKey(_q));

  // ---------------- ساخت ----------------
  @override
  Widget build(BuildContext context) {
    final r = _r;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _topBar(context, r),
      if (r != null && r.offline)
        Container(
          color: Colors.amber.withAlpha(40),
          padding: const EdgeInsetsDirectional.symmetric(horizontal: 12, vertical: 6),
          child: const Text('اتصال به سرور برقرار نیست؛ داده از اطلاعات محلی محاسبه شد (فراوری و شکست نمایش داده نمی‌شود).',
              style: TextStyle(fontSize: 12)),
        ),
      TabBar(controller: _tc, tabs: const [
        Tab(text: 'پسته‌های عادی'),
        Tab(text: 'کوت‌ریزی‌شده'),
        Tab(text: 'فراوری‌شده'),
      ]),
      Expanded(child: _body(context, r)),
    ]);
  }

  Widget _topBar(BuildContext context, LotCartexReport? r) {
    int? cur;
    if (r != null && r.from.length >= 10) cur = lotCartexStartYearOf(r.from, r.month, r.day);
    final years = r?.years ?? const <LotCartexYear>[];
    final hasCur = cur != null && years.any((y) => y.yearStart == cur);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 12, 4),
      child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (years.isNotEmpty)
          DropdownButton<int>(
            value: hasCur ? cur : null,
            hint: Text(r?.label ?? 'سال پسته‌ای'),
            isDense: true,
            items: [for (final y in years) DropdownMenuItem<int>(value: y.yearStart, child: Text(y.label))],
            onChanged: (v) {
              if (v == null) return;
              _yearStart = v;
              _load();
            },
          ),
        OutlinedButton.icon(
          onPressed: _loading ? null : () => _settingsDialog(context),
          icon: const Icon(Icons.tune, size: 18),
          label: const Text('تنظیم بازه'),
        ),
        IconButton(tooltip: 'تازه‌سازی', onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh)),
        SizedBox(
          width: 240,
          child: TextField(
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 20),
              hintText: 'جست‌وجو بر اساس نام طرف',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _q = v.trim()),
          ),
        ),
        if (r != null && r.from.isNotEmpty)
          Text('${r.label.isNotEmpty ? '${r.label}  ·  ' : ''}از ${_jd(r.from)} تا ${_jd(r.to)}',
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
      ]),
    );
  }

  Widget _body(BuildContext context, LotCartexReport? r) {
    if (_loading && r == null) return const Center(child: CircularProgressIndicator());
    if (r == null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_err ?? 'اطلاعاتی دریافت نشد', textAlign: TextAlign.center),
          const SizedBox(height: 8),
          FilledButton.icon(onPressed: _load, icon: const Icon(Icons.refresh), label: const Text('تلاش دوباره')),
        ]),
      );
    }
    return Stack(children: [
      TabBarView(controller: _tc, children: [
        _refreshable(_tabNormal(r)),
        _refreshable(_tabKot(context, r)),
        _refreshable(_tabProcessed(context, r)),
      ]),
      if (_loading) const Align(alignment: Alignment.topCenter, child: LinearProgressIndicator()),
      if (_err != null)
        Align(
          alignment: Alignment.bottomCenter,
          child: Material(
            color: Colors.red.shade50,
            child: Padding(padding: const EdgeInsets.all(8), child: Text(_err!, style: const TextStyle(color: Colors.red))),
          ),
        ),
    ]);
  }

  Widget _refreshable(Widget child) => RefreshIndicator(onRefresh: _load, child: child);

  Widget _empty(String msg) => ListView(children: [
        const SizedBox(height: 80),
        Center(child: Text(msg, style: const TextStyle(color: Colors.black54))),
      ]);

  // ---------------- زبانهٔ ۱ ----------------
  Widget _tabNormal(LotCartexReport r) {
    final tiles = <Widget>[];
    for (final t in r.types) {
      final rows = t.normal.where((x) => _hit(x.party)).toList();
      if (rows.isEmpty) continue;
      tiles.add(_typeTile('n', t, rows.length, _table(rows, showKotColor: true)));
    }
    return tiles.isEmpty ? _empty(_q.isEmpty ? 'در این بازه ورودی عادی ثبت نشده' : 'موردی پیدا نشد') : _list(tiles);
  }

  // ---------------- زبانهٔ ۲ ----------------
  Widget _tabKot(BuildContext context, LotCartexReport r) {
    final tiles = <Widget>[];
    for (final t in r.types) {
      final groups = <Widget>[];
      var n = 0;
      for (final k in t.kot) {
        final items = k.items.where((x) => _hit(x.party)).toList();
        if (items.isEmpty) continue;
        n += items.length;
        final c = groupColor(k.colorKey);
        groups.add(Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(border: Border.all(color: c.withAlpha(150)), borderRadius: BorderRadius.circular(8)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            InkWell(
              onTap: () => _showKot(context, k),
              child: Container(
                color: c.withAlpha(45),
                padding: const EdgeInsetsDirectional.symmetric(horizontal: 10, vertical: 8),
                child: Row(children: [
                  CircleAvatar(radius: 6, backgroundColor: c),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('کوت ${k.title}  ·  ساخت ${_jd(k.date)}  ·  جمع ${_kgTxt(k.totalKg)}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  const Icon(Icons.info_outline, size: 18),
                ]),
              ),
            ),
            _table(items, fixedColor: c),
          ]),
        ));
      }
      if (groups.isEmpty) continue;
      tiles.add(_typeTile('k', t, n, Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: groups)));
    }
    return tiles.isEmpty ? _empty(_q.isEmpty ? 'در این بازه لاتی کوت نشده' : 'موردی پیدا نشد') : _list(tiles);
  }

  // ---------------- زبانهٔ ۳ ----------------
  Widget _tabProcessed(BuildContext context, LotCartexReport r) {
    if (r.offline) return _empty('برای نمایش فراوری آنلاین شوید');
    final tiles = <Widget>[];
    for (final t in r.types) {
      final rows = t.processed.where((x) => _hit(x.party)).toList();
      if (rows.isEmpty) continue;
      tiles.add(_typeTile('p', t, rows.length, _table(rows, orderLink: true, ctx: context)));
    }
    return tiles.isEmpty ? _empty(_q.isEmpty ? 'در این بازه لاتی به فراوری/شکست نرفته' : 'موردی پیدا نشد') : _list(tiles);
  }

  Widget _list(List<Widget> tiles) => ListView(padding: const EdgeInsets.all(12), physics: const AlwaysScrollableScrollPhysics(), children: tiles);

  Widget _typeTile(String tab, LotCartexType t, int count, Widget child) {
    final name = t.typeName.isEmpty ? '(بدون نوع)' : t.typeName;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ExpansionTile(
        key: PageStorageKey<String>('lotcartex-$tab-${t.typeName}'),
        initiallyExpanded: true,
        title: Text('$name  ·  ${_kgTxt(t.totalKg)}', style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text('${faNum(count, dec: 0)} ردیف', style: const TextStyle(fontSize: 12)),
        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [child],
      ),
    );
  }

  // ---------------- جدول فشرده ----------------
  Widget _table(List<LotCartexRow> rows, {bool showKotColor = false, Color? fixedColor, bool orderLink = false, BuildContext? ctx}) {
    DataRow rowOf(LotCartexRow x) {
      Color? c = fixedColor;
      if (c == null && showKotColor && x.colorKey != null) c = groupColor(x.colorKey!);
      var weight = faNum(x.weightKg, dec: 3);
      final exit = StringBuffer(x.exitLabel);
      if (x.exitType == 'in_stock') {
        if (x.partial && x.remainingKg != null) exit.write(' · مانده ${faNum(x.remainingKg!, dec: 3)} کیلو');
        if ((x.soldKg ?? 0) > 0) exit.write(' · فروخته ${faNum(x.soldKg!, dec: 3)} کیلو');
      }
      Widget exitCell = Text(exit.toString());
      if (orderLink && ctx != null && x.exitType == 'proc') {
        exitCell = InkWell(
          onTap: () => Navigator.push(ctx, MaterialPageRoute<void>(builder: (_) => const ProcessingScreen())),
          child: Text(exit.toString(), style: const TextStyle(color: Colors.blue, decoration: TextDecoration.underline)),
        );
      }
      return DataRow(
        color: c == null ? null : WidgetStatePropertyAll<Color>(c.withAlpha(32)),
        cells: [
          DataCell(Text(x.party.isEmpty ? '—' : x.party)),
          DataCell(Text(weight)),
          DataCell(Text(_jd(x.entryDate))),
          DataCell(Text(_jd(x.exitDate))),
          DataCell(exitCell),
        ],
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 640),
        child: DataTable(
          columnSpacing: 20,
          headingRowHeight: 34,
          dataRowMinHeight: 30,
          dataRowMaxHeight: 40,
          columns: const [
            DataColumn(label: Text('نام طرف')),
            DataColumn(label: Text('وزن خالص (کیلو)'), numeric: true),
            DataColumn(label: Text('تاریخ ورود')),
            DataColumn(label: Text('تاریخ خروج')),
            DataColumn(label: Text('نوع خروج')),
          ],
          rows: [for (final x in rows) rowOf(x)],
        ),
      ),
    );
  }

  // ---------------- جزئیات کوت ----------------
  void _showKot(BuildContext context, LotCartexKot k) {
    final c = groupColor(k.colorKey);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [CircleAvatar(radius: 7, backgroundColor: c), const SizedBox(width: 8), Text('کوت ${k.title}')]),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('کد/نام کوت: ${k.title}'),
              Text('تاریخ ساخت: ${_jd(k.date)}'),
              Text('جمع وزن: ${_kgTxt(k.totalKg)}'),
              const SizedBox(height: 8),
              const Text('لات‌های درون کوت:', style: TextStyle(fontWeight: FontWeight.bold)),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columnSpacing: 18,
                  headingRowHeight: 32,
                  dataRowMinHeight: 30,
                  dataRowMaxHeight: 38,
                  columns: const [
                    DataColumn(label: Text('نام طرف')),
                    DataColumn(label: Text('نوع')),
                    DataColumn(label: Text('وزن سهم (کیلو)'), numeric: true),
                    DataColumn(label: Text('تاریخ ورود')),
                  ],
                  rows: [
                    for (final x in k.allItems)
                      DataRow(cells: [
                        DataCell(Text(x.party.isEmpty ? '—' : x.party)),
                        DataCell(Text(x.typeName.isEmpty ? '—' : x.typeName)),
                        DataCell(Text(faNum(x.weightKg, dec: 3))),
                        DataCell(Text(_jd(x.entryDate))),
                      ]),
                  ],
                ),
              ),
            ]),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('بستن'))],
      ),
    );
  }

  // ---------------- تنظیم بازه ----------------
  Future<void> _settingsDialog(BuildContext context) async {
    var m = _r?.month ?? _lastMonth;
    var d = _r?.day ?? _lastDay;
    final res = await showDialog<(int, int)>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final maxDay = lotCartexDaysInJMonth(m);
        if (d > maxDay) d = maxDay;
        return AlertDialog(
          title: const Text('تنظیم بازهٔ سال پسته‌ای'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('روز و ماه شروع سال پسته‌ای (پیش‌فرض: ۱ مهر تا ۳۱ شهریور).', style: TextStyle(fontSize: 12, color: Colors.black54)),
              const SizedBox(height: 10),
              FormGrid(minColWidth: 170, children: [
                DropdownButtonFormField<int>(
                  value: m,
                  decoration: const InputDecoration(labelText: 'ماه شروع'),
                  items: [for (var i = 1; i <= 12; i++) DropdownMenuItem<int>(value: i, child: Text(_kJMonths[i - 1]))],
                  onChanged: (v) => setD(() => m = v ?? m),
                ),
                DropdownButtonFormField<int>(
                  key: ValueKey<int>(m),
                  value: d,
                  decoration: const InputDecoration(labelText: 'روز شروع'),
                  items: [for (var i = 1; i <= maxDay; i++) DropdownMenuItem<int>(value: i, child: Text(faNum(i, dec: 0)))],
                  onChanged: (v) => setD(() => d = v ?? d),
                ),
              ]),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('انصراف')),
            FilledButton(onPressed: () => Navigator.pop(ctx, (m, d)), child: const Text('ذخیره')),
          ],
        );
      }),
    );
    if (res == null || !mounted) return;
    try {
      await StockApi.call('stock.lot_cartex_settings', <String, dynamic>{'save': true, 'month': res.$1, 'day': res.$2});
      _yearStart = null;
      await _load();
    } on StockApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.network ? 'برای ذخیرهٔ تنظیم باید آنلاین باشید' : e.message)));
    }
  }
}
