import 'package:flutter/material.dart';

import 'perms.dart';
import 'reports_excel.dart';
import 'returns_ui.dart' show ReturnsHelp;
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;
import 'widgets.dart' show pickDate;

/// مرحلهٔ ۶-۳ کارگاه — گزارش‌های مالک/مدیریتی (فقط‌خواندنی، بدون هیچ قیمت):
///  • «کارتکس مالک» ← `reports.cartex` (مجوز workshop.feed)
///  • «خلاصهٔ مدیریتی» ← `reports.workshop_summary` (مجوز stock.view؛ اپراتور کارگاه ندارد)
///  • «مقایسهٔ کارگاه‌ها/اپراتورها» ← `reports.workshop_compare` (مجوز workshop.feed)
/// همهٔ اعداد از سرور می‌آیند (منطق: `workshop_calc.dart` → cartexBuild / wsumInternal / wsumCrack / wcmpBuild)؛ در UI محاسبهٔ تازه‌ای نیست.
/// تاریخ در API میلادی و در UI شمسی. خروجی اکسل: reports_excel.dart (۶-۴).

double _rd(dynamic v) => ReturnsHelp.d(v);
String _rkg(dynamic v) => faNum(_rd(v), dec: 3);
String _rnum(dynamic v) => v == null || '$v'.isEmpty ? '—' : faNum(_rd(v), dec: 3);
String _rowner(dynamic v) => v == null || '$v'.trim().isEmpty ? 'بدون مالک' : '$v';
String _rtxt(dynamic v) => v == null || '$v'.isEmpty ? '—' : '$v';
InputDecoration _rdec(String label) => InputDecoration(labelText: label, border: const OutlineInputBorder());

DataCell _rcell(String s, {bool bold = false}) => DataCell(Text(s, style: bold ? const TextStyle(fontWeight: FontWeight.bold) : null));

Widget _rerr(BuildContext c, String m) => Card(
      color: Theme.of(c).colorScheme.errorContainer,
      child: Padding(padding: const EdgeInsets.all(10), child: Text(m)),
    );

Widget _rstat(String label, dynamic v, {bool strong = false}) => Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          child: Column(children: <Widget>[
            Text(label, style: const TextStyle(fontSize: 12), textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(_rkg(v), style: TextStyle(fontWeight: strong ? FontWeight.bold : FontWeight.normal, fontSize: strong ? 16 : 14)),
          ]),
        ),
      ),
    );

Widget _rkv(String label, String value, {bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Flexible(child: Text(label)),
          const SizedBox(width: 8),
          Text(value, style: TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        ],
      ),
    );

Widget _rtable(List<String> heads, List<DataRow> rows) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(columns: <DataColumn>[for (final String h in heads) DataColumn(label: Text(h))], rows: rows),
    );

/// نوار بازهٔ تاریخ (از/تا شمسی) + ویجت‌های اضافهٔ هر گزارش.
class _DateFilter extends StatelessWidget {
  const _DateFilter({required this.from, required this.to, required this.onChanged, this.extra = const <Widget>[]});
  final DateTime? from;
  final DateTime? to;
  final void Function(DateTime? from, DateTime? to) onChanged;
  final List<Widget> extra;

  Future<void> _pick(BuildContext context, bool isFrom) async {
    final DateTime? d = await pickDate(context, initial: (isFrom ? from : to) ?? DateTime.now());
    if (d == null) return;
    onChanged(isFrom ? d : from, isFrom ? to : d);
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        OutlinedButton.icon(onPressed: () => _pick(context, true), icon: const Icon(Icons.event), label: Text(from == null ? 'از تاریخ' : jalaliDateFromDt(from!))),
        OutlinedButton.icon(onPressed: () => _pick(context, false), icon: const Icon(Icons.event), label: Text(to == null ? 'تا تاریخ' : jalaliDateFromDt(to!))),
        if (from != null || to != null) TextButton(onPressed: () => onChanged(null, null), child: const Text('پاک‌کردن تاریخ')),
        ...extra,
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// صفحهٔ گزارش‌ها (تب‌ها بر اساس مجوز)
// ---------------------------------------------------------------------------

class WorkshopReportsScreen extends StatelessWidget {
  /// embedded=true: داخل تب پوستهٔ اپراتور (بدون دکمهٔ بازگشت).
  final bool embedded;
  const WorkshopReportsScreen({super.key, this.embedded = false});

  @override
  Widget build(BuildContext context) {
    final bool feed = StaffPerms.I.can('workshop.feed');
    final bool summary = StaffPerms.I.can('stock.view');
    final List<Tab> tabs = <Tab>[
      if (feed) const Tab(text: 'کارتکس مالک'),
      if (summary) const Tab(text: 'خلاصهٔ مدیریتی'),
      if (feed) const Tab(text: 'مقایسه'),
    ];
    final List<Widget> views = <Widget>[
      if (feed) const _CartexBody(),
      if (summary) const _SummaryBody(),
      if (feed) const _CompareBody(),
    ];
    if (tabs.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('گزارش‌های کارگاه'), automaticallyImplyLeading: !embedded),
        body: const Center(child: Text('دسترسی به این گزارش‌ها ندارید')),
      );
    }
    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('گزارش‌های کارگاه'),
          automaticallyImplyLeading: !embedded,
          bottom: TabBar(tabs: tabs, isScrollable: true),
        ),
        body: TabBarView(children: views),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ۱) کارتکس مالک — reports.cartex
// ---------------------------------------------------------------------------

const Map<String, String> kCartexEventLabels = <String, String>{'send': 'ارسال', 'receive': 'دریافت'};

class _CartexBody extends StatefulWidget {
  const _CartexBody();

  @override
  State<_CartexBody> createState() => _CartexBodyState();
}

class _CartexBodyState extends State<_CartexBody> with AutomaticKeepAliveClientMixin<_CartexBody> {
  final TextEditingController _owner = TextEditingController();
  final TextEditingController _party = TextEditingController();
  DateTime? _from;
  DateTime? _to;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _rows = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _owners = <Map<String, dynamic>>[];
  Map<String, dynamic> _tot = <String, dynamic>{};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _owner.dispose();
    _party.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final Map<String, dynamic> q = <String, dynamic>{};
      if (_owner.text.trim().isNotEmpty) q['owner'] = _owner.text.trim();
      if (_party.text.trim().isNotEmpty) q['party'] = _party.text.trim();
      if (_from != null) q['from'] = ReturnsHelp.iso(_from!);
      if (_to != null) q['to'] = ReturnsHelp.iso(_to!);
      final Map<String, dynamic> r = await StockApi.call('reports.cartex', q);
      if (!mounted) return;
      setState(() {
        _rows = ReturnsHelp.maps(r['rows']);
        _owners = ReturnsHelp.maps(r['owners']);
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

  @override
  Widget build(BuildContext context) {
    super.build(context);
    const List<String> heads = <String>['تاریخ', 'رویداد', 'مالک', 'عدل', 'ورود (کیلو)', 'خروج (کیلو)', 'انس', 'گرم', 'دهنبست', 'مانده مالک (کیلو)', 'توضیحات'];
    final List<DataRow> rows = <DataRow>[
      for (final Map<String, dynamic> r in _rows)
        DataRow(cells: <DataCell>[
          _rcell(r['date'] == null ? '—' : jalaliDate('${r['date']}')),
          _rcell(kCartexEventLabels['${r['event']}'] ?? _rtxt(r['event'])),
          _rcell(_rowner(r['owner'])),
          _rcell(_rnum(r['bale_count'])),
          _rcell(_rkg(r['in_kg'])),
          _rcell(_rkg(r['out_kg'])),
          _rcell(_rnum(r['ounce'])),
          _rcell(_rnum(r['gram_pct'])),
          _rcell(_rnum(r['dahanbast'])),
          _rcell(_rkg(r['balance_kg']), bold: true),
          _rcell(_rtxt(r['note'])),
        ]),
    ];
    if (_rows.isNotEmpty) {
      rows.add(DataRow(cells: <DataCell>[
        _rcell('جمع', bold: true),
        _rcell(''),
        _rcell(''),
        _rcell(''),
        _rcell(_rkg(_tot['in_kg']), bold: true),
        _rcell(_rkg(_tot['out_kg']), bold: true),
        _rcell(''),
        _rcell(''),
        _rcell(''),
        _rcell(_rkg(_tot['balance_kg']), bold: true),
        _rcell(''),
      ]));
    }
    final List<DataRow> ownerRows = <DataRow>[
      for (final Map<String, dynamic> o in _owners)
        DataRow(cells: <DataCell>[
          _rcell(_rowner(o['owner'])),
          _rcell(_rkg(o['opening_kg'])),
          _rcell(_rkg(o['in_kg'])),
          _rcell(_rkg(o['out_kg'])),
          _rcell(_rkg(o['balance_kg']), bold: true),
        ]),
    ];
    return ListView(
      padding: const EdgeInsets.all(12),
      children: <Widget>[
        Row(children: <Widget>[
          Expanded(child: TextField(controller: _owner, onSubmitted: (_) => _load(), decoration: _rdec('فیلتر مالک'))),
          const SizedBox(width: 8),
          Expanded(child: TextField(controller: _party, onSubmitted: (_) => _load(), decoration: _rdec('فیلتر کارگاه'))),
        ]),
        const SizedBox(height: 8),
        _DateFilter(
          from: _from,
          to: _to,
          onChanged: (DateTime? f, DateTime? t) {
            setState(() {
              _from = f;
              _to = t;
            });
            _load();
          },
          extra: <Widget>[
            FilledButton(onPressed: _load, child: const Text('اعمال')),
            IconButton(tooltip: 'خروجی اکسل', icon: const Icon(Icons.table_view), onPressed: _rows.isEmpty ? null : () => ReportsExcel.export(context, ReportsExcel.cartex(_rows, _tot))),
            IconButton(tooltip: 'به‌روزرسانی', icon: const Icon(Icons.refresh), onPressed: _load),
          ],
        ),
        const SizedBox(height: 10),
        if (_error != null) _rerr(context, _error!),
        if (_loading) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
        if (!_loading && _error == null) ...<Widget>[
          Row(children: <Widget>[
            _rstat('مانده افتتاحیه', _tot['opening_kg']),
            _rstat('ورود', _tot['in_kg']),
            _rstat('خروج', _tot['out_kg']),
            _rstat('مانده', _tot['balance_kg'], strong: true),
          ]),
          if (_owners.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            const Text('مانده به‌تفکیک مالک', style: TextStyle(fontWeight: FontWeight.bold)),
            _rtable(const <String>['مالک', 'افتتاحیه', 'ورود', 'خروج', 'مانده'], ownerRows),
          ],
          const SizedBox(height: 8),
          if (_rows.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('رویدادی در این بازه نیست'))),
          if (_rows.isNotEmpty) _rtable(heads, rows),
        ],
        const SizedBox(height: 8),
        const Text(
          'فقط کارگاه بیرونی با قبض: ارسال = خروج در تاریخ سفارش، دریافت = ورود در تاریخ دریافت. مانده هر مالک جدا و تجمعی است و مانده منفی یعنی پسته‌ای که هنوز بیرون است. '
          'ضایعات برنمی‌گردد و فقط در توضیحات ردیف دریافت می‌آید. ستون‌های انس و دهنبست در این نسخه خالی‌اند. این گزارش هیچ قیمتی ندارد.',
          style: TextStyle(fontSize: 12),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// ۲) خلاصهٔ مدیریتی — reports.workshop_summary (stock.view)
// ---------------------------------------------------------------------------

class _SummaryBody extends StatefulWidget {
  const _SummaryBody();

  @override
  State<_SummaryBody> createState() => _SummaryBodyState();
}

class _SummaryBodyState extends State<_SummaryBody> with AutomaticKeepAliveClientMixin<_SummaryBody> {
  final TextEditingController _owner = TextEditingController();
  DateTime? _from;
  DateTime? _to;
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _internal = <String, dynamic>{};
  Map<String, dynamic> _crack = <String, dynamic>{};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _owner.dispose();
    super.dispose();
  }

  Map<String, dynamic> _map(dynamic v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final Map<String, dynamic> q = <String, dynamic>{};
      if (_owner.text.trim().isNotEmpty) q['owner'] = _owner.text.trim();
      if (_from != null) q['from'] = ReturnsHelp.iso(_from!);
      if (_to != null) q['to'] = ReturnsHelp.iso(_to!);
      final Map<String, dynamic> r = await StockApi.call('reports.workshop_summary', q);
      if (!mounted) return;
      setState(() {
        _internal = _map(r['internal']);
        _crack = _map(r['crack']);
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

  Widget _card(String title, List<Widget> children) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const Divider(),
            ...children,
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final Map<String, dynamic> i = _internal;
    final Map<String, dynamic> k = _crack;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: <Widget>[
        TextField(controller: _owner, onSubmitted: (_) => _load(), decoration: _rdec('فیلتر مالک')),
        const SizedBox(height: 8),
        _DateFilter(
          from: _from,
          to: _to,
          onChanged: (DateTime? f, DateTime? t) {
            setState(() {
              _from = f;
              _to = t;
            });
            _load();
          },
          extra: <Widget>[
            FilledButton(onPressed: _load, child: const Text('اعمال')),
            IconButton(tooltip: 'خروجی اکسل', icon: const Icon(Icons.table_view), onPressed: _loading || _error != null ? null : () => ReportsExcel.export(context, ReportsExcel.summary(_internal, _crack))),
            IconButton(tooltip: 'به‌روزرسانی', icon: const Icon(Icons.refresh), onPressed: _load),
          ],
        ),
        const SizedBox(height: 10),
        if (_error != null) _rerr(context, _error!),
        if (_loading) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
        if (!_loading && _error == null) ...<Widget>[
          _card('کارگاه داخلی (کنترل ورود و خروج تولید)', <Widget>[
            _rkv('تعداد عملیات', _rnum(i['orders_count'])),
            _rkv('وزن تحویلی (کیلو)', _rkg(i['delivered_kg'])),
            _rkv('وزن ورودی (کیلو)', _rkg(i['input_kg']), bold: true),
            _rkv('سالم', _rkg(i['sound_kg'])),
            _rkv('بدشکل و ریز', _rkg(i['deformed_fine_kg'])),
            _rkv('پوست', _rkg(i['hull_kg'])),
            _rkv('مغز', _rkg(i['kernel_kg'])),
            _rkv('خاک', _rkg(i['soil_kg'])),
            _rkv('بدرنگ', _rkg(i['discolored_kg'])),
            _rkv('افت وزن', _rkg(i['loss_kg'])),
            _rkv('مجموع ضایعات', _rkg(i['waste_total_kg'])),
            _rkv('اختلاف تراز', _rkg(i['diff_kg'])),
            _rkv('تحویل‌نشده', _rkg(i['undelivered_kg'])),
            _rkv('درصد سالم از ورودی', i['sound_pct'] == null ? '—' : '${_rnum(i['sound_pct'])}٪', bold: true),
            _rkv('عملیات نیازمند بررسی تراز', _rnum(i['check_count'])),
          ]),
          _card('خط شکست', <Widget>[
            _rkv('تعداد نوبت کار', _rnum(k['runs_count'])),
            _rkv('وزن ورودی (کیلو)', _rkg(k['input_kg']), bold: true),
            _rkv('مغز خروجی', _rkg(k['kernel_kg'])),
            _rkv('پوست', _rkg(k['hull_kg'])),
            _rkv('خاک', _rkg(k['soil_kg'])),
            _rkv('مجموع زیرمجموعه‌های مغز (سالم، گندمی، گلدار، لپه و …)', _rkg(k['sub_kernel_kg'])),
            _rkv('برگشتی همهٔ خروجی‌ها', _rkg(k['returned_all_kg']), bold: true),
            _rkv('افت (کیلو)', _rkg(k['loss_kg'])),
            _rkv('افت (٪)', k['loss_pct'] == null ? '—' : '${_rnum(k['loss_pct'])}٪'),
            _rkv('مغز از ورودی (٪)', k['kernel_pct'] == null ? '—' : '${_rnum(k['kernel_pct'])}٪'),
            _rkv('ظرفیت واقعی (کیلو/ساعت)', _rnum(k['capacity_kgh'])),
            _rkv('زمان کارکرد (دقیقه)', _rnum(k['run_minutes'])),
            _rkv('مجموع توقف (دقیقه)', _rnum(k['stop_minutes'])),
            const SizedBox(height: 6),
            const Text(
              '⚠️ «برگشتی همهٔ خروجی‌ها» = مغز + پوست + خاک + زیرمجموعه‌های مغز است. اگر زیرمجموعه‌ها بخشی از وزن مغز باشند، این عدد دوبار می‌شمارد؛ '
              'برای همین اجزا جدا هم آمده‌اند تا قضاوت کنید.',
              style: TextStyle(fontSize: 12),
            ),
          ]),
        ],
        const SizedBox(height: 4),
        const Text('این گزارش هیچ قیمتی ندارد. نام ستون‌ها مطابق برگهٔ «کنترل ورود و خروج تولید» است و «سایر ضایعات» حذف شده است.', style: TextStyle(fontSize: 12)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// ۳) مقایسهٔ کارگاه‌ها / اپراتورها — reports.workshop_compare
// ---------------------------------------------------------------------------

const Map<String, String> kCompareSourceLabels = <String, String>{'internal': 'کارگاه داخلی', 'outside': 'کارگاه بیرونی', 'crack': 'خط شکست'};
const List<List<String>> kCompareBy = <List<String>>[
  <String>['workshop', 'کارگاه'],
  <String>['operator', 'اپراتور'],
  <String>['registrar', 'ثبت‌کننده'],
];

class _CompareBody extends StatefulWidget {
  const _CompareBody();

  @override
  State<_CompareBody> createState() => _CompareBodyState();
}

class _CompareBodyState extends State<_CompareBody> with AutomaticKeepAliveClientMixin<_CompareBody> {
  String _by = 'workshop';
  DateTime? _from;
  DateTime? _to;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _rows = <Map<String, dynamic>>[];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final Map<String, dynamic> q = <String, dynamic>{'by': _by};
      if (_from != null) q['from'] = ReturnsHelp.iso(_from!);
      if (_to != null) q['to'] = ReturnsHelp.iso(_to!);
      final Map<String, dynamic> r = await StockApi.call('reports.workshop_compare', q);
      if (!mounted) return;
      setState(() {
        _rows = ReturnsHelp.maps(r['rows']);
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

  @override
  Widget build(BuildContext context) {
    super.build(context);
    const List<String> heads = <String>['منبع', 'نام', 'تعداد', 'ورودی (کیلو)', 'خروجی خوب (کیلو)', 'افت (کیلو)', 'بازده ٪', 'افت ٪', 'ظرفیت (کیلو/ساعت)', 'میانگین افت گرم'];
    final List<DataRow> rows = <DataRow>[
      for (final Map<String, dynamic> r in _rows)
        DataRow(cells: <DataCell>[
          _rcell(kCompareSourceLabels['${r['source']}'] ?? _rtxt(r['source'])),
          _rcell(_rtxt(r['name'])),
          _rcell(_rnum(r['count'])),
          _rcell(_rkg(r['input_kg'])),
          _rcell(_rkg(r['good_kg'])),
          _rcell(_rkg(r['loss_kg'])),
          _rcell(_rnum(r['yield_pct']), bold: true),
          _rcell(_rnum(r['loss_pct'])),
          _rcell(_rnum(r['capacity_kgh'])),
          _rcell(_rnum(r['avg_gram_loss'])),
        ]),
    ];
    return ListView(
      padding: const EdgeInsets.all(12),
      children: <Widget>[
        Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: <Widget>[
          const Text('مقایسه بر اساس:'),
          for (final List<String> b in kCompareBy)
            ChoiceChip(
              label: Text(b[1]),
              selected: _by == b[0],
              onSelected: (bool v) {
                if (!v) return;
                setState(() => _by = b[0]);
                _load();
              },
            ),
        ]),
        const SizedBox(height: 8),
        _DateFilter(
          from: _from,
          to: _to,
          onChanged: (DateTime? f, DateTime? t) {
            setState(() {
              _from = f;
              _to = t;
            });
            _load();
          },
          extra: <Widget>[
            IconButton(tooltip: 'خروجی اکسل', icon: const Icon(Icons.table_view), onPressed: _rows.isEmpty ? null : () => ReportsExcel.export(context, ReportsExcel.compare(_rows, kCompareBy.firstWhere((List<String> b) => b[0] == _by)[1]))),
            IconButton(tooltip: 'به‌روزرسانی', icon: const Icon(Icons.refresh), onPressed: _load),
          ],
        ),
        const SizedBox(height: 10),
        if (_error != null) _rerr(context, _error!),
        if (_loading) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
        if (!_loading && _error == null) ...<Widget>[
          if (_rows.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('موردی برای مقایسه نیست'))),
          if (_rows.isNotEmpty) _rtable(heads, rows),
        ],
        const SizedBox(height: 8),
        Text(
          _by == 'workshop'
              ? 'ردیف‌ها بر اساس بازده (نزولی) مرتب‌اند. خط شکست به‌ازای کد خط، کارگاه داخلی و بیرونی به‌ازای نام کارگاه گروه می‌شوند. کارگاه بیرونی فقط سفارش‌های دریافت‌شده را می‌شمارد.'
              : 'کارگاه داخلی و بیرونی نام اپراتور ندارند؛ مقایسهٔ اپراتورها و ثبت‌کنندگان فقط از گزارش‌های خط شکست است (نام خالی = «نامشخص»).',
          style: const TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 4),
        const Text(
          'بازده = خروجی خوب ÷ ورودی (سالم در داخلی، خروجی برگشتی در بیرونی، مغز در خط شکست). ظرفیت فقط برای خط شکست و میانگین افت گرم فقط برای کارگاه بیرونی است. بدون قیمت.',
          style: TextStyle(fontSize: 12),
        ),
      ],
    );
  }
}
