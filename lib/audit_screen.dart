import 'package:flutter/material.dart';

import 'excel_io.dart';
import 'utils.dart';
import 'warehouse_ui.dart';
import 'widgets.dart' show snack;

/// T02.3 — گزارش ممیزی (audit log). فقط برای مالک یا کارکنی که audit.view دارد.
/// آنلاین از طریق StockApi (app.php → audit.list). فیلتر: کاربر، نوع رکورد، بازهٔ تاریخ، جستجوی متن.

const Map<String, String> _kEntityFa = <String, String>{
  'purchase': 'خرید',
  'sale': 'فروش',
  'mix': 'مخلوط',
  'payment': 'پرداخت',
  'receipt': 'دریافت',
  'due': 'سررسید',
  'party': 'طرف حساب',
  'loan': 'قرض/وام',
  'stock_transfer': 'انتقال انبار',
  'staff': 'کاربر',
  'role': 'نقش',
  'account': 'حساب',
  'backup': 'پشتیبان',
  'category': 'دسته‌بندی',
  'type': 'نوع',
  'intake': 'پذیرش اتاق انس', // S6.T3 (entity='intake' در audit_log)
  'intake_price_settings': 'تنظیم گرم مرجع قیمت',
};

const Map<String, String> _kVerbFa = <String, String>{
  'create': 'ایجاد',
  'update': 'ویرایش',
  'delete': 'حذف',
};

String _entityFa(String e) {
  if (e.startsWith('entity.')) return e.substring(7);
  return _kEntityFa[e] ?? e;
}

class AuditLogScreen extends StatefulWidget {
  const AuditLogScreen({super.key});

  @override
  State<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends State<AuditLogScreen> {
  final List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _staff = <Map<String, dynamic>>[];
  bool _loading = false;
  bool _hasMore = false;
  String? _error;
  int? _staffId; // null = همه، 0 = مالک
  String _entity = '';
  String _action = '';
  String _from = '';
  String _to = '';
  final TextEditingController _q = TextEditingController();
  final TextEditingController _code = TextEditingController(); // S6.T3: کد پسته
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _loadStaff();
    _load(reset: true);
  }

  @override
  void dispose() {
    _q.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _loadStaff() async {
    try {
      final r = await StockApi.call('staff.list');
      final raw = r['items'];
      final list = <Map<String, dynamic>>[];
      if (raw is List) {
        for (final x in raw) {
          if (x is Map) list.add(Map<String, dynamic>.from(x));
        }
      }
      if (mounted) setState(() => _staff = list);
    } catch (_) {
      // بدون مجوز users.manage فهرست کاربران در دسترس نیست؛ فیلتر کاربر فقط «همه/مالک» می‌ماند.
    }
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) _items.clear();
    });
    try {
      final Map<String, dynamic> p = _params(limit: 50);
      if (!reset && _items.isNotEmpty) p['before_id'] = _items.last['id'];
      final r = await StockApi.call('audit.list', p);
      final raw = r['items'];
      if (raw is List) {
        for (final x in raw) {
          if (x is Map) _items.add(Map<String, dynamic>.from(x));
        }
      }
      _hasMore = r['has_more'] == true;
      if (_items.isNotEmpty) _learnStaff(_items);
    } catch (e) {
      _error = e.toString().replaceFirst('Exception: ', '');
    }
    if (mounted) setState(() => _loading = false);
  }

  /// S6.T3: پارامترهای فیلتر. «کد پسته» در شرح ممیزی پذیرش می‌آید (مثلاً «… (KH-…)») و سرور فقط یک `q` می‌شناسد؛
  /// اگر هم کد و هم متن آزاد داده شود، کد به سرور می‌رود و متن آزاد سمت کلاینت اعمال می‌شود ([_textOk]).
  Map<String, dynamic> _params({required int limit}) {
    final Map<String, dynamic> p = <String, dynamic>{'limit': limit};
    if (_staffId != null) p['staff_id'] = _staffId;
    if (_entity.isNotEmpty) p['entity'] = _entity;
    if (_action.isNotEmpty) p['action'] = _action;
    if (_from.isNotEmpty) p['from'] = _from;
    if (_to.isNotEmpty) p['to'] = _to;
    final String code = _code.text.trim();
    final String text = _q.text.trim();
    if (code.isNotEmpty) {
      p['q'] = code;
    } else if (text.isNotEmpty) {
      p['q'] = text;
    }
    return p;
  }

  bool _textOk(Map<String, dynamic> it) {
    final String code = _code.text.trim();
    final String text = _q.text.trim().toLowerCase();
    if (code.isEmpty || text.isEmpty) return true; // فقط یکی داده شده؛ سرور فیلتر کرده
    return '${it['summary'] ?? ''} ${it['entity_id'] ?? ''} ${it['staff_name'] ?? ''}'.toLowerCase().contains(text);
  }

  /// بدون مجوز users.manage فهرست کاربران نیست؛ نام پرسنل را از خود ردیف‌های ممیزی می‌سازیم تا فیلتر پرسنل کار کند.
  void _learnStaff(List<Map<String, dynamic>> rows) {
    final Set<int> have = <int>{for (final s in _staff) int.tryParse('${s['id']}') ?? -1};
    bool added = false;
    for (final it in rows) {
      final int id = int.tryParse('${it['staff_id']}') ?? 0;
      final String name = (it['staff_name'] ?? '').toString();
      if (id <= 0 || name.isEmpty || have.contains(id)) continue;
      have.add(id);
      _staff.add(<String, dynamic>{'id': id, 'name': name});
      added = true;
    }
    if (added && mounted) setState(() {});
  }

  /// S6.T3: خروجی Excel از «همهٔ» نتایجِ فیلتر فعلی (صفحه‌به‌صفحه تا سقف ۵۰۰۰ ردیف)، نه فقط ردیف‌های بارگذاری‌شده.
  Future<void> _export() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      const int cap = 5000;
      final List<Map<String, dynamic>> all = <Map<String, dynamic>>[];
      int? beforeId;
      bool more = true;
      while (more && all.length < cap) {
        final Map<String, dynamic> p = _params(limit: 200);
        if (beforeId != null) p['before_id'] = beforeId;
        final Map<String, dynamic> r = await StockApi.call('audit.list', p);
        final Object? raw = r['items'];
        if (raw is! List || raw.isEmpty) break;
        for (final x in raw) {
          if (x is Map) {
            final Map<String, dynamic> m = Map<String, dynamic>.from(x);
            if (_textOk(m)) all.add(m);
          }
        }
        beforeId = int.tryParse('${(raw.last as Map)['id']}');
        more = r['has_more'] == true && beforeId != null;
      }
      if (all.isEmpty) {
        if (mounted) snack(context, 'موردی برای خروجی نیست');
        return;
      }
      final List<List<String>> rows = <List<String>>[
        for (final it in all)
          <String>[
            '${it['id'] ?? ''}',
            _when((it['created_at'] ?? '').toString()),
            (it['staff_name'] ?? '').toString().isEmpty ? 'مالک' : it['staff_name'].toString(),
            _kVerbFa[(it['action'] ?? '').toString()] ?? (it['action'] ?? '').toString(),
            _entityFa((it['entity'] ?? '').toString()),
            '${it['entity_id'] ?? ''}',
            '${it['summary'] ?? ''}',
            '${it['ip'] ?? ''}',
          ],
      ];
      final f = await ExcelIo.exportTable(
        columns: const <String>['ردیف', 'زمان', 'کاربر', 'عملیات', 'رکورد', 'شناسه', 'شرح', 'IP'],
        rows: rows,
        sheetName: 'ممیزی',
        filePrefix: 'audit',
      );
      if (!mounted) return;
      if (all.length >= cap) snack(context, 'فقط ۵۰۰۰ ردیف اول خروجی گرفته شد؛ بازه را کوچک‌تر کنید.');
      await ExcelIo.saveOrShare(context, f);
    } catch (e) {
      if (mounted) snack(context, 'خطا در خروجی: ${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// S31.T31.5b — audit.verify: recompute the sha1 hash chain server-side and show the result.
  Future<void> _verifyChain() async {
    showDialog<void>(context: context, barrierDismissible: false, builder: (BuildContext c) => const Center(child: CircularProgressIndicator()));
    Map<String, dynamic>? r;
    String? err;
    try {
      r = await StockApi.call('audit.verify');
    } catch (e) {
      err = e.toString().replaceFirst('Exception: ', '');
    }
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    final bool ok = r != null && r['ok'] == true;
    final String reason = r == null ? '' : '${r['reason'] ?? ''}';
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          icon: Icon(err != null || !ok ? Icons.error_outline : Icons.verified_outlined, color: err != null || !ok ? Colors.red : Colors.green),
          title: Text(err != null ? 'خطا در بررسی' : (ok ? 'زنجیرهٔ ممیزی سالم است' : 'زنجیرهٔ ممیزی دستکاری شده است')),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            if (err != null) Text(err, style: const TextStyle(color: Colors.red)),
            if (r != null) ...<Widget>[
              Text('ردیف‌های مهرشده: ${toFaDigits('${r['sealed_rows'] ?? 0}')}'),
              Text('ردیف‌های قدیمی (بدون مهر): ${toFaDigits('${r['legacy_rows'] ?? 0}')}'),
              Text(r['db_triggers'] == true ? 'قفل سطح پایگاه‌داده: فعال' : 'قفل سطح پایگاه‌داده: غیرفعال'),
              if (!ok && r['broken_at_id'] != null) Text('اولین ردیف مشکوک: ${toFaDigits('${r['broken_at_id']}')}', style: const TextStyle(color: Colors.red)),
              if (reason.isNotEmpty) Text(reason, style: const TextStyle(fontSize: 12)),
            ],
          ]),
          actions: <Widget>[TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('بستن'))],
        ),
      ),
    );
  }

  Future<void> _pickDate(bool isFrom) async {
    final DateTime now = DateTime.now();
    final DateTime? d = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
    );
    if (d == null) return;
    final String iso = '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    setState(() {
      if (isFrom) {
        _from = iso;
      } else {
        _to = iso;
      }
    });
    _load(reset: true);
  }

  Widget _filters() {
    final List<DropdownMenuItem<int?>> staffItems = <DropdownMenuItem<int?>>[
      const DropdownMenuItem<int?>(value: null, child: Text('همهٔ کاربران')),
      const DropdownMenuItem<int?>(value: 0, child: Text('مالک')),
      for (final s in _staff)
        DropdownMenuItem<int?>(value: int.tryParse('${s['id']}') ?? 0, child: Text('${s['name'] ?? s['username'] ?? ''}')),
    ];
    final List<DropdownMenuItem<String>> entItems = <DropdownMenuItem<String>>[
      const DropdownMenuItem<String>(value: '', child: Text('همهٔ رکوردها')),
      for (final e in _kEntityFa.entries) DropdownMenuItem<String>(value: e.key, child: Text(e.value)),
    ];
    final List<DropdownMenuItem<String>> actItems = <DropdownMenuItem<String>>[
      const DropdownMenuItem<String>(value: '', child: Text('همهٔ عملیات')),
      for (final e in _kVerbFa.entries) DropdownMenuItem<String>(value: e.key, child: Text(e.value)),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: DropdownButtonFormField<int?>(
                  value: _staffId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'کاربر', isDense: true),
                  items: staffItems,
                  onChanged: (int? v) {
                    setState(() => _staffId = v);
                    _load(reset: true);
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _entity,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'رکورد', isDense: true),
                  items: entItems,
                  onChanged: (String? v) {
                    setState(() => _entity = v ?? '');
                    _load(reset: true);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _action,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'عملیات', isDense: true),
                  items: actItems,
                  onChanged: (String? v) {
                    setState(() => _action = v ?? '');
                    _load(reset: true);
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _pickDate(true),
                  child: Text(_from.isEmpty ? 'از تاریخ' : 'از ${jalaliDate(_from)}'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _pickDate(false),
                  child: Text(_to.isEmpty ? 'تا تاریخ' : 'تا ${jalaliDate(_to)}'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _code,
                  decoration: InputDecoration(
                    labelText: 'کد پسته',
                    isDense: true,
                    suffixIcon: IconButton(icon: const Icon(Icons.search), onPressed: () => _load(reset: true)),
                  ),
                  onSubmitted: (_) => _load(reset: true),
                ),
              ),
              const SizedBox(width: 8),
              FilterChip(
                label: const Text('پذیرش‌های اتاق انس'),
                selected: _entity == 'intake',
                onSelected: (bool v) {
                  setState(() => _entity = v ? 'intake' : '');
                  _load(reset: true);
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _q,
            decoration: InputDecoration(
              labelText: 'جستجو (شرح، شناسه، نام کاربر)',
              isDense: true,
              suffixIcon: IconButton(icon: const Icon(Icons.search), onPressed: () => _load(reset: true)),
            ),
            onSubmitted: (_) => _load(reset: true),
          ),
          if (_from.isNotEmpty || _to.isNotEmpty)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: () {
                  setState(() {
                    _from = '';
                    _to = '';
                  });
                  _load(reset: true);
                },
                child: const Text('پاک‌کردن تاریخ'),
              ),
            ),
        ],
      ),
    );
  }

  List<Map<String, dynamic>> get _visible => _items.where(_textOk).toList();

  String _when(String ts) {
    if (ts.length < 16) return ts;
    return '${jalaliDate(ts.substring(0, 10))}  ${ts.substring(11, 16)}';
  }

  void _details(Map<String, dynamic> it) {
    final String before = (it['before'] ?? '').toString();
    final String after = (it['after'] ?? '').toString();
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('${it['summary'] ?? ''}'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('کاربر: ${(it['staff_name'] ?? '').toString().isEmpty ? 'مالک' : it['staff_name']}'),
              Text('زمان: ${_when((it['created_at'] ?? '').toString())}'),
              Text('شناسه: ${it['entity_id'] ?? ''}'),
              Text('IP: ${it['ip'] ?? ''}'),
              if (before.isNotEmpty) ...<Widget>[const SizedBox(height: 8), const Text('قبل:'), SelectableText(before)],
              if (after.isNotEmpty) ...<Widget>[const SizedBox(height: 8), const Text('بعد:'), SelectableText(after)],
            ],
          ),
        ),
        actions: <Widget>[TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('بستن'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('گزارش ممیزی'), actions: <Widget>[
        IconButton(
          icon: _exporting ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.table_view_outlined),
          tooltip: 'خروجی Excel (طبق فیلترهای فعلی)',
          onPressed: _exporting ? null : _export,
        ), // S6.T3
        IconButton(icon: const Icon(Icons.verified_user_outlined), tooltip: 'بررسی صحت زنجیرهٔ ممیزی', onPressed: _verifyChain), // S31.T31.5b
      ]),
      body: Column(
        children: <Widget>[
          _filters(),
          if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: const TextStyle(color: Colors.red))),
          Expanded(
            child: _visible.isEmpty && !_loading
                ? const Center(child: Text('موردی ثبت نشده است'))
                : ListView.separated(
                    itemCount: _visible.length + 1,
                    separatorBuilder: (BuildContext c, int i) => const Divider(height: 1),
                    itemBuilder: (BuildContext c, int i) {
                      if (i == _visible.length) {
                        if (_loading) return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
                        if (_hasMore) return TextButton(onPressed: () => _load(), child: const Text('بیشتر'));
                        return const SizedBox.shrink();
                      }
                      final Map<String, dynamic> it = _visible[i];
                      final String who = (it['staff_name'] ?? '').toString().isEmpty ? 'مالک' : it['staff_name'].toString();
                      final String verb = _kVerbFa[(it['action'] ?? '').toString()] ?? (it['action'] ?? '').toString();
                      return ListTile(
                        dense: true,
                        title: Text('${it['summary'] ?? ''}'),
                        subtitle: Text('$who · $verb ${_entityFa((it['entity'] ?? '').toString())} · ${_when((it['created_at'] ?? '').toString())}'),
                        onTap: () => _details(it),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
