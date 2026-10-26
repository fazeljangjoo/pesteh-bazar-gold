import 'dart:io';

import 'package:flutter/material.dart';

import 'perms.dart';
import 'vouchers_links.dart';
import 'pdf_output.dart';
import 'pdf_service.dart';
import 'returns_ui.dart' show ReturnsHelp;
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException, StockLookup, WhOption;

/// S10.T10.2 — orchards (باغ): list, form, detail (costs, harvests, allocation), performance report, PDF.
/// Server: orchards.* / orchard_costs.* / harvests.* (api/orchards.php), reports.orchard_performance.
/// Online only (the stage does not require offline). Profit / revenue columns appear only when the server says can_profit.
/// Permissions: view → orchards.view, edit → orchards.manage.

const Map<String, String> _catLabels = <String, String>{
  'water': 'آبیاری',
  'labor': 'کارگر',
  'fertilizer': 'کود',
  'pesticide': 'سم',
  'rent': 'اجاره',
  'machinery': 'ماشین‌آلات',
  'other': 'سایر',
};

String _en(String s) {
  const String fa = '۰۱۲۳۴۵۶۷۸۹';
  const String ar = '٠١٢٣٤٥٦٧٨٩';
  final StringBuffer b = StringBuffer();
  for (final int c in s.runes) {
    final String ch = String.fromCharCode(c);
    final int fi = fa.indexOf(ch);
    final int ai = ar.indexOf(ch);
    if (fi >= 0) {
      b.write(fi);
    } else if (ai >= 0) {
      b.write(ai);
    } else if (ch == '٫') {
      b.write('.');
    } else if (ch == '٬' || ch == ',') {
      // thousands separator
    } else {
      b.write(ch);
    }
  }
  return b.toString();
}

double _numText(String s) => double.tryParse(_en(s).trim()) ?? 0.0;
double _n(dynamic v) => ReturnsHelp.d(v);
String _kg(dynamic v) => faNum(_n(v), dec: 3);
String _money(dynamic v) => faNum(_n(v), dec: 0);
bool _can(String key) => StaffPerms.I.can(key);

void _snackOf(BuildContext context, String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

/// Runs a StockApi call and shows the server message on failure. Returns the response or null.
Future<Map<String, dynamic>?> _call(BuildContext context, String action, [Map<String, dynamic> payload = const <String, dynamic>{}]) async {
  try {
    return await StockApi.call(action, payload);
  } on StockApiException catch (e) {
    _snackOf(context, e.message);
    return null;
  }
}

class _F {
  final String key;
  final String label;
  final String initial;
  final bool numeric;
  final Map<String, String>? options;
  const _F(this.key, this.label, {this.initial = '', this.numeric = false, this.options});
}

Future<Map<String, String>?> _form(BuildContext context, String title, List<_F> fields) async {
  final Map<String, TextEditingController> ctrls = <String, TextEditingController>{};
  final Map<String, String?> sel = <String, String?>{};
  for (final _F f in fields) {
    if (f.options != null) {
      final bool ok = f.options!.containsKey(f.initial);
      sel[f.key] = ok ? f.initial : (f.options!.isEmpty ? null : f.options!.keys.first);
    } else {
      ctrls[f.key] = TextEditingController(text: f.initial);
    }
  }
  final Map<String, String>? out = await showDialog<Map<String, String>>(
    context: context,
    builder: (BuildContext ctx) => StatefulBuilder(
      builder: (BuildContext ctx2, StateSetter set) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final _F f in fields)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: f.options != null
                      ? DropdownButtonFormField<String>(
                          value: sel[f.key],
                          decoration: InputDecoration(labelText: f.label, border: const OutlineInputBorder()),
                          items: <DropdownMenuItem<String>>[
                            for (final MapEntry<String, String> e in f.options!.entries)
                              DropdownMenuItem<String>(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
                          ],
                          onChanged: (String? v) => set(() => sel[f.key] = v),
                        )
                      : TextField(
                          controller: ctrls[f.key],
                          keyboardType: f.numeric ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
                          decoration: InputDecoration(labelText: f.label, border: const OutlineInputBorder()),
                        ),
                ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('انصراف')),
          FilledButton(
            onPressed: () {
              final Map<String, String> res = <String, String>{};
              for (final _F f in fields) {
                res[f.key] = f.options != null ? (sel[f.key] ?? '') : (ctrls[f.key]?.text.trim() ?? '');
              }
              Navigator.pop(ctx, res);
            },
            child: const Text('ثبت'),
          ),
        ],
      ),
    ),
  );
  for (final TextEditingController c in ctrls.values) {
    c.dispose();
  }
  return out;
}

// ---------------------------------------------------------------------------
// List
// ---------------------------------------------------------------------------

class OrchardsScreen extends StatefulWidget {
  const OrchardsScreen({super.key});

  @override
  State<OrchardsScreen> createState() => _OrchardsScreenState();
}

class _OrchardsScreenState extends State<OrchardsScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final Map<String, dynamic> r = await StockApi.call('orchards.list');
      if (!mounted) return;
      setState(() {
        _items = ReturnsHelp.maps(r['items']);
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

  Future<void> _open(Widget page) async {
    final Object? changed = await Navigator.push(context, MaterialPageRoute<Object>(builder: (_) => page));
    if (changed != null) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('باغ‌ها'),
        actions: <Widget>[
          if (_can('orchards.view'))
            IconButton(
              tooltip: 'گزارش عملکرد باغ‌ها',
              icon: const Icon(Icons.assessment_outlined),
              onPressed: () => _open(const OrchardReportScreen()),
            ),
          IconButton(tooltip: 'به‌روزرسانی', icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      floatingActionButton: _can('orchards.manage')
          ? FloatingActionButton.extended(
              onPressed: () => _open(const OrchardFormScreen()),
              icon: const Icon(Icons.add),
              label: const Text('باغ جدید'),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
          children: <Widget>[
            if (_error != null)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(padding: const EdgeInsets.all(10), child: Text(_error!)),
              ),
            if (_loading) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
            if (!_loading && _items.isEmpty)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('باغی ثبت نشده است'))),
            for (final Map<String, dynamic> o in _items)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.park_outlined),
                  title: Text('${o['name']}'),
                  subtitle: Text(
                    '${o['location'] ?? ''}  •  ${faNum(_n(o['area_ha']), dec: 2)} هکتار  •  ${o['tree_count'] ?? 0} درخت\n'
                    'فصل‌ها: ${o['seasons'] ?? 0}  •  کل خشک: ${_kg(o['dry_kg'])} کیلو',
                  ),
                  isThreeLine: true,
                  onTap: () => _open(OrchardDetailScreen(id: _n(o['id']).toInt())),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Form (create / edit)
// ---------------------------------------------------------------------------

class OrchardFormScreen extends StatefulWidget {
  final Map<String, dynamic>? orchard;
  const OrchardFormScreen({super.key, this.orchard});

  @override
  State<OrchardFormScreen> createState() => _OrchardFormScreenState();
}

class _OrchardFormScreenState extends State<OrchardFormScreen> {
  late final TextEditingController _name = TextEditingController(text: '${widget.orchard?['name'] ?? ''}');
  late final TextEditingController _loc = TextEditingController(text: '${widget.orchard?['location'] ?? ''}');
  late final TextEditingController _area = TextEditingController(text: '${widget.orchard?['area_ha'] ?? ''}');
  late final TextEditingController _trees = TextEditingController(text: '${widget.orchard?['tree_count'] ?? ''}');
  late final TextEditingController _variety = TextEditingController(text: '${widget.orchard?['variety'] ?? ''}');
  late final TextEditingController _note = TextEditingController(text: '${widget.orchard?['note'] ?? ''}');
  late String _own = '${widget.orchard?['ownership'] ?? 'own'}';
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _loc.dispose();
    _area.dispose();
    _trees.dispose();
    _variety.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) return _snackOf(context, 'نام باغ را وارد کنید');
    setState(() => _saving = true);
    final Map<String, dynamic>? r = await _call(context, 'orchards.save', <String, dynamic>{
      if (widget.orchard != null) 'id': widget.orchard!['id'],
      if (widget.orchard == null) 'uid': ReturnsHelp.newUid('orch'),
      'name': _name.text.trim(),
      'location': _loc.text.trim(),
      'area_ha': _numText(_area.text),
      'tree_count': _numText(_trees.text).toInt(),
      'variety': _variety.text.trim(),
      'ownership': _own,
      'note': _note.text.trim(),
    });
    if (mounted) setState(() => _saving = false);
    if (r != null && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.orchard == null ? 'باغ جدید' : 'ویرایش باغ')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: <Widget>[
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'نام باغ', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          TextField(controller: _loc, decoration: const InputDecoration(labelText: 'موقعیت', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _area,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'مساحت (هکتار)', border: OutlineInputBorder()),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _trees,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'تعداد درخت', border: OutlineInputBorder()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(controller: _variety, decoration: const InputDecoration(labelText: 'رقم / گونه', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            value: _own,
            decoration: const InputDecoration(labelText: 'مالکیت', border: OutlineInputBorder()),
            items: const <DropdownMenuItem<String>>[
              DropdownMenuItem(value: 'own', child: Text('ملکی')),
              DropdownMenuItem(value: 'lease', child: Text('اجاره‌ای')),
            ],
            onChanged: (String? v) => setState(() => _own = v ?? 'own'),
          ),
          const SizedBox(height: 10),
          TextField(controller: _note, decoration: const InputDecoration(labelText: 'یادداشت', border: OutlineInputBorder())),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: const Text('ذخیره'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Detail: seasons with costs, harvests, allocation; actions
// ---------------------------------------------------------------------------

class OrchardDetailScreen extends StatefulWidget {
  final int id;
  const OrchardDetailScreen({super.key, required this.id});

  @override
  State<OrchardDetailScreen> createState() => _OrchardDetailScreenState();
}

class _OrchardDetailScreenState extends State<OrchardDetailScreen> {
  bool _loading = true;
  String? _error;
  bool _changed = false;
  Map<String, dynamic> _d = <String, dynamic>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final Map<String, dynamic> r = await StockApi.call('orchards.get', <String, dynamic>{'id': widget.id});
      if (!mounted) return;
      setState(() {
        _d = r;
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

  List<Map<String, dynamic>> get _seasons => ReturnsHelp.maps(_d['seasons']);

  Future<void> _addCost() async {
    final Map<String, String>? r = await _form(context, 'ثبت هزینهٔ فصلی', <_F>[
      _F('season', 'سال زراعی', initial: '${DateTime.now().year}', numeric: true),
      _F('cat', 'دسته', initial: 'water', options: _catLabels),
      _F('amount', 'مبلغ', numeric: true),
      _F('date', 'تاریخ (yyyy-mm-dd)', initial: ReturnsHelp.iso(DateTime.now())),
      _F('party', 'طرف حساب'),
      _F('note', 'یادداشت'),
    ]);
    if (r == null) return;
    final double amt = _numText(r['amount'] ?? '');
    if (amt <= 0) return _snackOf(context, 'مبلغ را وارد کنید');
    final Map<String, dynamic>? res = await _call(context, 'orchard_costs.add', <String, dynamic>{
      'uid': ReturnsHelp.newUid('ocost'),
      'orchard_id': widget.id,
      'season_year': _numText(r['season'] ?? '').toInt(),
      'category': r['cat'],
      'amount': amt,
      'date': _en(r['date'] ?? ''),
      'party': r['party'] ?? '',
      'note': r['note'] ?? '',
    });
    if (res != null) {
      _changed = true;
      _load();
    }
  }

  Future<void> _addHarvest() async {
    final List<WhOption> whs = await StockLookup.warehouses();
    if (!mounted) return;
    final Map<String, String> whOpts = <String, String>{for (final WhOption w in whs) w.uid: w.name};
    final Map<String, String>? r = await _form(context, 'ثبت برداشت', <_F>[
      _F('season', 'سال زراعی', initial: '${DateTime.now().year}', numeric: true),
      _F('date', 'تاریخ (yyyy-mm-dd)', initial: ReturnsHelp.iso(DateTime.now())),
      _F('wet', 'وزن تر (کیلو)', numeric: true),
      _F('dry', 'وزن خشک (کیلو)', numeric: true),
      if (whOpts.isNotEmpty) _F('wh', 'انبار', initial: whs.where((WhOption w) => w.isDefault).isNotEmpty ? whs.firstWhere((WhOption w) => w.isDefault).uid : whs.first.uid, options: whOpts),
      _F('note', 'یادداشت'),
    ]);
    if (r == null) return;
    final double dry = _numText(r['dry'] ?? '');
    final double wet = _numText(r['wet'] ?? '');
    if (dry <= 0) return _snackOf(context, 'وزن خشک را وارد کنید');
    if (wet < dry) return _snackOf(context, 'وزن تر باید از وزن خشک بیشتر یا برابر باشد');
    if ((r['wh'] ?? '').isEmpty) return _snackOf(context, 'انبار را انتخاب کنید');
    final Map<String, dynamic>? res = await _call(context, 'harvests.create', <String, dynamic>{
      'uid': ReturnsHelp.newUid('harv'),
      'orchard_id': widget.id,
      'season_year': _numText(r['season'] ?? '').toInt(),
      'date': _en(r['date'] ?? ''),
      'wet_kg': wet,
      'dry_kg': dry,
      'warehouse_uid': r['wh'],
      'note': r['note'] ?? '',
    });
    if (res != null) {
      _changed = true;
      _load();
    }
  }

  Future<void> _allocate(int season) async {
    final Map<String, String>? r = await _form(context, 'تسهیم هزینه‌های فصل $season', <_F>[
      _F('basis', 'روش تسهیم', initial: 'weight', options: const <String, String>{
        'weight': 'بر اساس وزن خشک (جمع هزینه‌ها)',
        'market': 'بر اساس قیمت بازار (وزن × قیمت)',
      }),
      _F('market', 'قیمت بازار هر کیلو (فقط برای بازار)', numeric: true),
    ]);
    if (r == null) return;
    final Map<String, dynamic>? res = await _call(context, 'orchards.allocate', <String, dynamic>{
      'orchard_id': widget.id,
      'season_year': season,
      'basis': r['basis'] ?? 'weight',
      'market_per_kg': _numText(r['market'] ?? ''),
    });
    if (res != null) {
      _changed = true;
      _load();
    }
  }

  Future<void> _print(Map<String, dynamic> s) async {
    final Map<String, dynamic> costs = (s['costs'] is Map) ? Map<String, dynamic>.from(s['costs'] as Map) : <String, dynamic>{};
    final List<Map<String, dynamic>> hs = ReturnsHelp.maps(s['harvests']);
    final File file = await PdfService.buildTableReport(
      title: 'گزارش فصل ${s['season_year']} باغ ${_d['name'] ?? ''}',
      subtitle: 'تسهیم: ${s['allocated'] == true ? 'انجام شده' : 'انجام نشده'}',
      kv: <List<String>>[
        <String>['وزن تر (کیلو)', _kg(s['wet_kg'])],
        <String>['وزن خشک (کیلو)', _kg(s['dry_kg'])],
        <String>['کل هزینه', _money(s['cost_total'])],
        <String>['بهای هر کیلو خشک', _money(s['cost_per_kg'])],
        <String>['بازدهی در هکتار (کیلو)', s['yield_per_ha'] == null ? '—' : _kg(s['yield_per_ha'])],
      ],
      headers: const <String>['برداشت', 'تاریخ', 'تر (کیلو)', 'خشک (کیلو)', 'بهای تمام‌شده'],
      rows: <List<String>>[
        for (final Map<String, dynamic> h in hs)
          <String>['${h['code'] ?? ''}', jalaliDate('${h['date']}'), _kg(h['wet_kg']), _kg(h['dry_kg']), _money(h['cost'])],
        for (final MapEntry<String, dynamic> e in costs.entries)
          <String>['هزینه: ${_catLabels[e.key] ?? e.key}', '', '', '', _money(e.value)],
      ],
      filePrefix: 'orchard_season',
    );
    if (!mounted) return;
    await PdfOutput.show(context, file);
  }

  @override
  Widget build(BuildContext context) {
    final bool canManage = _can('orchards.manage');
    return WillPopScope(
      onWillPop: () async {
        Navigator.pop(context, _changed ? true : null);
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_d['name'] == null ? 'باغ' : '${_d['name']}'),
          actions: <Widget>[
            if (canManage && _d.isNotEmpty)
              IconButton(
                tooltip: 'ویرایش باغ',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () async {
                  final Object? ok = await Navigator.push(context, MaterialPageRoute<Object>(builder: (_) => OrchardFormScreen(orchard: _d)));
                  if (ok != null) {
                    _changed = true;
                    _load();
                  }
                },
              ),
          ],
        ),
        body: _loading && _d.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.all(14),
                  children: <Widget>[
                    if (_error != null)
                      Card(
                        color: Theme.of(context).colorScheme.errorContainer,
                        child: Padding(padding: const EdgeInsets.all(10), child: Text(_error!)),
                      ),
                    if (_d.isNotEmpty) ...<Widget>[
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text('موقعیت: ${_d['location'] ?? '—'}'),
                              Text('مساحت: ${faNum(_n(_d['area_ha']), dec: 2)} هکتار  •  درخت: ${_d['tree_count'] ?? 0}'),
                              Text('رقم: ${_d['variety'] ?? '—'}  •  مالکیت: ${_d['ownership'] == 'lease' ? 'اجاره‌ای' : 'ملکی'}'),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <Widget>[
                          if (canManage)
                            OutlinedButton.icon(onPressed: _addCost, icon: const Icon(Icons.payments_outlined), label: const Text('هزینهٔ فصلی')),
                          if (canManage)
                            FilledButton.icon(onPressed: _addHarvest, icon: const Icon(Icons.grass), label: const Text('ثبت برداشت')),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_seasons.isEmpty)
                        const Padding(padding: EdgeInsets.all(16), child: Center(child: Text('هنوز هزینه یا برداشتی ثبت نشده است'))),
                      for (final Map<String, dynamic> s in _seasons) _seasonCard(s, canManage),
                    ],
                  ],
                ),
              ),
      ),
    );
  }

  Widget _seasonCard(Map<String, dynamic> s, bool canManage) {
    final Map<String, dynamic> costs = (s['costs'] is Map) ? Map<String, dynamic>.from(s['costs'] as Map) : <String, dynamic>{};
    final bool allocated = s['allocated'] == true;
    final int season = _n(s['season_year']).toInt();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(child: Text('فصل $season', style: Theme.of(context).textTheme.titleMedium)),
                Chip(label: Text(allocated ? 'تسهیم شده' : 'تسهیم نشده')),
                IconButton(tooltip: 'چاپ فصل', icon: const Icon(Icons.print_outlined), onPressed: () => _print(s)),
              ],
            ),
            Text('وزن تر ${_kg(s['wet_kg'])} • خشک ${_kg(s['dry_kg'])} کیلو • نسبت خشک/تر ${s['dry_wet_ratio'] == null ? '—' : faNum(_n(s['dry_wet_ratio']), dec: 3)}'),
            Text('بازدهی در هکتار: ${s['yield_per_ha'] == null ? '—' : _kg(s['yield_per_ha'])} • در درخت: ${s['yield_per_tree'] == null ? '—' : _kg(s['yield_per_tree'])}'),
            Text('کل هزینه: ${_money(s['cost_total'])} • بهای هر کیلو خشک: ${s['cost_per_kg'] == null ? '—' : _money(s['cost_per_kg'])}'),
            if (costs.isNotEmpty)
              Wrap(
                spacing: 6,
                children: <Widget>[
                  for (final MapEntry<String, dynamic> e in costs.entries) Chip(label: Text('${_catLabels[e.key] ?? e.key}: ${_money(e.value)}')),
                ],
              ),
            if (s['cost_ids'] is List && (s['cost_ids'] as List).isNotEmpty)
              Wrap(spacing: 6, children: <Widget>[
                for (final dynamic cid in (s['cost_ids'] as List))
                  VoucherLinkButton(sourceType: 'orch_cost', sourceId: '$cid', label: 'سند هزینه ${faNum(_n(cid), dec: 0)}'),
              ]),
            if (s['allocation'] is Map && (s['allocation'] as Map)['id'] != null)
              VoucherLinkButton(sourceType: 'orch_alloc', sourceId: '${(s['allocation'] as Map)['id']}', label: 'سند تسهیم'),
            const Divider(),
            for (final Map<String, dynamic> h in ReturnsHelp.maps(s['harvests']))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('${h['code'] ?? ''}  •  ${jalaliDate('${h['date']}')}'),
                subtitle: Text('تر ${_kg(h['wet_kg'])} • خشک ${_kg(h['dry_kg'])} کیلو'
                    '${h['cost'] != null ? ' • بهای ${_money(h['cost'])}' : ''}'),
              ),
            if (canManage && !allocated)
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FilledButton.tonalIcon(
                  onPressed: () => _allocate(season),
                  icon: const Icon(Icons.call_split),
                  label: const Text('تسهیم هزینه‌ها'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Performance report (reports.orchard_performance)
// ---------------------------------------------------------------------------

class OrchardReportScreen extends StatefulWidget {
  const OrchardReportScreen({super.key});

  @override
  State<OrchardReportScreen> createState() => _OrchardReportScreenState();
}

class _OrchardReportScreenState extends State<OrchardReportScreen> {
  final TextEditingController _season = TextEditingController();
  bool _busy = false;
  bool _canProfit = false;
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _season.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() => _busy = true);
    final Map<String, dynamic>? r = await _call(context, 'reports.orchard_performance', <String, dynamic>{
      if (_season.text.trim().isNotEmpty) 'season_year': _numText(_season.text).toInt(),
    });
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r != null) {
        _items = ReturnsHelp.maps(r['items']);
        _canProfit = r['can_profit'] == true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('گزارش عملکرد باغ‌ها')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _season,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'سال زراعی (خالی = همه)', border: OutlineInputBorder()),
                  onSubmitted: (_) => _run(),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(onPressed: _busy ? null : _run, child: const Text('نمایش')),
            ],
          ),
          const SizedBox(height: 12),
          if (_busy) const Center(child: CircularProgressIndicator()),
          if (!_busy && _items.isEmpty) const Center(child: Text('داده‌ای برای نمایش نیست')),
          for (final Map<String, dynamic> it in _items)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('${it['orchard']}  •  فصل ${it['season_year']}', style: Theme.of(context).textTheme.titleMedium),
                    Text('خشک ${_kg(it['dry_kg'])} کیلو • فروخته‌شده ${_kg(it['sold_kg'])} • باقی ${_kg(it['unsold_kg'])}'),
                    Text('بازدهی/هکتار: ${it['yield_per_ha'] == null ? '—' : _kg(it['yield_per_ha'])}'
                        '${it['yield_change_pct'] == null ? '' : '  (تغییر ${faNum(_n(it['yield_change_pct']), dec: 1)}٪)'}'),
                    Text('هزینه: ${_money(it['costs'])} • بهای هر کیلو: ${it['cost_per_kg'] == null ? '—' : _money(it['cost_per_kg'])}'),
                    if (_canProfit) ...<Widget>[
                      const Divider(),
                      Text('فروش: ${_money(it['revenue'])} • هزینهٔ فروش: ${_money(it['selling_expense'])}'),
                      Text('سود: ${_money(it['profit'])}${it['margin_pct'] == null ? '' : '  (حاشیه ${faNum(_n(it['margin_pct']), dec: 1)}٪)'}'),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
