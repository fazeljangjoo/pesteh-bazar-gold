import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'entity_store.dart' show EntityStore;
import 'pdf_output.dart';
import 'pdf_service.dart';
import 'perms.dart';
import 'vouchers_links.dart';
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi;
import 'widgets.dart';

/// S11.T11.4 — payroll screens (حقوق و دستمزد).
/// Server: payroll.* (api/payroll.php). Permissions: payroll.view (read) / payroll.manage (write).
/// Offline: employees / pay items / run list are cached; a NEW run can be prepared as a LOCAL draft
/// (SharedPreferences `payroll_drafts_v1`, preview only, statutory deductions and advances are computed by the server).
/// Sending a draft to the server, editing server lines, pay-lines, advances and APPROVE require being online.

bool _can(String key) => StaffPerms.I.can(key);

String _m(num v) => faNum(v, dec: v == v.roundToDouble() ? 0 : 2);

double _r2(double v) => (v * 100).round() / 100;

double _d(dynamic v) => v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0.0);

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String _period(int y, int m) => '${kJalaliMonthNames[(m - 1).clamp(0, 11)]} ${toFaDigits('$y')}';

List<Map<String, dynamic>> _maps(dynamic v) {
  final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
  if (v is List) {
    for (final dynamic x in v) {
      if (x is Map) out.add(Map<String, dynamic>.from(x));
    }
  }
  return out;
}

/// Online call with a SharedPreferences cache fallback for read lists.
class _PayCache {
  static Future<(List<Map<String, dynamic>>, bool)> list(String action, String cacheKey) async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    try {
      final Map<String, dynamic> r = await StockApi.call(action);
      final List<Map<String, dynamic>> items = _maps(r['items']);
      await sp.setString(cacheKey, jsonEncode(items));
      return (items, false);
    } catch (_) {
      final String? raw = sp.getString(cacheKey);
      if (raw == null) rethrow;
      return (_maps(jsonDecode(raw)), true);
    }
  }

  static Future<List<Map<String, dynamic>>> drafts() async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    final String? raw = sp.getString('payroll_drafts_v1');
    if (raw == null) return <Map<String, dynamic>>[];
    try {
      return _maps(jsonDecode(raw));
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<void> saveDraft(Map<String, dynamic> d) async {
    final List<Map<String, dynamic>> all = await drafts();
    all.removeWhere((Map<String, dynamic> x) => x['uid'] == d['uid']);
    all.add(d);
    final SharedPreferences sp = await SharedPreferences.getInstance();
    await sp.setString('payroll_drafts_v1', jsonEncode(all));
  }

  static Future<void> removeDraft(String uid) async {
    final List<Map<String, dynamic>> all = await drafts();
    all.removeWhere((Map<String, dynamic> x) => x['uid'] == uid);
    final SharedPreferences sp = await SharedPreferences.getInstance();
    await sp.setString('payroll_drafts_v1', jsonEncode(all));
  }
}

Widget _banner(String t) => Container(
      width: double.infinity,
      color: Colors.amber.shade100,
      padding: const EdgeInsets.all(8),
      child: Text(t, style: const TextStyle(fontSize: 12)),
    );

// ───────────────────────────── home ─────────────────────────────

class PayrollHomeScreen extends StatefulWidget {
  const PayrollHomeScreen({super.key});

  @override
  State<PayrollHomeScreen> createState() => _PayrollHomeState();
}

class _PayrollHomeState extends State<PayrollHomeScreen> {
  List<Map<String, dynamic>> _runs = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _drafts = <Map<String, dynamic>>[];
  bool _loading = true;
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    _drafts = await _PayCache.drafts();
    try {
      final (List<Map<String, dynamic>> r, bool off) = await _PayCache.list('payroll.runs', 'payroll_runs_cache');
      _runs = r;
      _offline = off;
    } catch (_) {
      _runs = <Map<String, dynamic>>[];
      _offline = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _go(Widget w) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => w)).then((_) => _load());

  @override
  Widget build(BuildContext context) {
    final bool manage = _can('payroll.manage');
    return Scaffold(
      appBar: AppBar(
        title: const Text('حقوق و دستمزد'),
        actions: <Widget>[IconButton(onPressed: _load, icon: const Icon(Icons.refresh))],
      ),
      floatingActionButton: manage
          ? FloatingActionButton.extended(
              onPressed: () => _go(const PayrollWizardScreen()),
              icon: const Icon(Icons.add),
              label: const Text('دورهٔ جدید'),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 90),
              children: <Widget>[
                if (_offline) _banner('آفلاین: آخرین داده‌های ذخیره‌شده نمایش داده می‌شود.'),
                ListTile(
                  leading: const Icon(Icons.badge_outlined),
                  title: const Text('کارکنان و مساعده'),
                  trailing: const Icon(Icons.chevron_left),
                  onTap: () => _go(const PayrollEmployeesScreen()),
                ),
                ListTile(
                  leading: const Icon(Icons.tune),
                  title: const Text('اقلام حقوقی (مزایا و کسورات)'),
                  trailing: const Icon(Icons.chevron_left),
                  onTap: () => _go(const PayItemsScreen()),
                ),
                ListTile(
                  leading: const Icon(Icons.event_busy_outlined),
                  title: const Text('پرداخت‌های سررسیدنشده / پرداخت‌نشده'),
                  trailing: const Icon(Icons.chevron_left),
                  onTap: () => _go(const PayrollUnpaidScreen()),
                ),
                const Divider(),
                if (_drafts.isNotEmpty) sectionTitle(context, 'پیش‌نویس‌های محلی (هنوز به سرور نرفته)'),
                for (final Map<String, dynamic> d in _drafts)
                  ListTile(
                    leading: const Icon(Icons.edit_note, color: Colors.orange),
                    title: Text(_period(_d(d['year']).toInt(), _d(d['month']).toInt())),
                    subtitle: Text('ارز: ${d['ccy']} · پیش‌نویس محلی'),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        if (!await confirm(context, 'پیش‌نویس محلی حذف شود؟')) return;
                        await _PayCache.removeDraft('${d['uid']}');
                        _load();
                      },
                    ),
                    onTap: () => _go(PayrollWizardScreen(draft: d)),
                  ),
                sectionTitle(context, 'دوره‌های حقوق'),
                if (_runs.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('دوره‌ای ثبت نشده است.')),
                for (final Map<String, dynamic> r in _runs)
                  ListTile(
                    leading: Icon(r['status'] == 'approved' ? Icons.verified_outlined : Icons.pending_outlined,
                        color: r['status'] == 'approved' ? Colors.green : Colors.orange),
                    title: Text(_period(_d(r['year']).toInt(), _d(r['month']).toInt())),
                    subtitle: Text(
                        '${r['ccy']} · ${toFaDigits('${r['employees']}')} نفر · ${r['status'] == 'approved' ? 'تأییدشده' : 'پیش‌نویس'}'),
                    trailing: const Icon(Icons.chevron_left),
                    onTap: () => _go(PayrollRunScreen(runId: _d(r['id']).toInt())),
                  ),
              ],
            ),
    );
  }
}

// ───────────────────────────── employees ─────────────────────────────

class PayrollEmployeesScreen extends StatefulWidget {
  const PayrollEmployeesScreen({super.key});

  @override
  State<PayrollEmployeesScreen> createState() => _PayrollEmployeesState();
}

class _PayrollEmployeesState extends State<PayrollEmployeesScreen> {
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  bool _loading = true;
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final (List<Map<String, dynamic>> r, bool off) = await _PayCache.list('payroll.employees', 'payroll_emp_cache');
      _items = r;
      _offline = off;
    } catch (e) {
      if (mounted) snack(context, friendlyError(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _edit(Map<String, dynamic>? e) async {
    final TextEditingController name = TextEditingController(text: '${e?['name'] ?? ''}');
    final TextEditingController pos = TextEditingController(text: '${e?['position'] ?? ''}');
    final TextEditingController base =
        TextEditingController(text: e == null ? '' : plain(_d(e['base_salary'])));
    final TextEditingController ccy = TextEditingController(text: '${e?['ccy'] ?? 'IRR'}');
    final TextEditingController bank = TextEditingController(text: '${e?['bank_account'] ?? ''}');
    final TextEditingController ins = TextEditingController(text: '${e?['insurance_no'] ?? ''}');
    bool active = e == null ? true : _d(e['active']) != 0;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter set) => AlertDialog(
          title: Text(e == null ? 'کارمند جدید' : 'ویرایش کارمند'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
              textField(name, 'نام'),
              textField(pos, 'سمت'),
              numField(base, 'حقوق پایه', thousands: true),
              textField(ccy, 'ارز حقوق (مثلاً IRR)'),
              textField(bank, 'شماره حساب / شبا'),
              textField(ins, 'شمارهٔ بیمه'),
              SwitchListTile(title: const Text('فعال'), value: active, onChanged: (bool v) => set(() => active = v)),
            ]),
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ذخیره')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (name.text.trim().isEmpty) {
      if (mounted) snack(context, 'نام الزامی است');
      return;
    }
    try {
      await StockApi.call('payroll.employee_save', <String, dynamic>{
        if (e != null) 'id': e['id'] else 'uid': EntityStore.newUid(),
        'name': name.text.trim(),
        'position': pos.text.trim(),
        'base_salary': parseNum(base.text) ?? 0,
        'ccy': ccy.text.trim().isEmpty ? 'IRR' : ccy.text.trim().toUpperCase(),
        'bank_account': bank.text.trim(),
        'insurance_no': ins.text.trim(),
        'active': active ? 1 : 0,
      });
      _load();
    } catch (err) {
      if (mounted) snack(context, friendlyError(err));
    }
  }

  Future<void> _advance(Map<String, dynamic> e) async {
    final TextEditingController amt = TextEditingController();
    final TextEditingController note = TextEditingController();
    DateTime date = DateTime.now();
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter set) => AlertDialog(
          title: Text('مساعده برای ${e['name']}'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
              numField(amt, 'مبلغ (${e['ccy']})', required: true, thousands: true),
              dateField(ctx, 'تاریخ', date, (DateTime d) => set(() => date = d)),
              textField(note, 'توضیح'),
            ]),
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ثبت')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final double a = parseNum(amt.text) ?? 0;
    if (a <= 0) {
      if (mounted) snack(context, 'مبلغ نامعتبر است');
      return;
    }
    try {
      await StockApi.call('payroll.advance_add', <String, dynamic>{
        'uid': EntityStore.newUid(),
        'employee_id': e['id'],
        'amount': a,
        'date': _iso(date),
        'note': note.text.trim(),
      });
      if (mounted) snack(context, 'مساعده ثبت شد؛ در تأیید دورهٔ حقوق کسر می‌شود.');
    } catch (err) {
      if (mounted) snack(context, friendlyError(err));
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool manage = _can('payroll.manage');
    return Scaffold(
      appBar: AppBar(title: const Text('کارکنان')),
      floatingActionButton:
          manage ? FloatingActionButton(onPressed: () => _edit(null), child: const Icon(Icons.person_add_alt)) : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.only(bottom: 90), children: <Widget>[
              if (_offline) _banner('آفلاین: فهرست ذخیره‌شده؛ ویرایش نیاز به اینترنت دارد.'),
              if (_items.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('کارمندی ثبت نشده است.')),
              for (final Map<String, dynamic> e in _items)
                ListTile(
                  leading: Icon(_d(e['active']) != 0 ? Icons.person : Icons.person_off_outlined),
                  title: Text('${e['name']}'),
                  subtitle: Text(
                      '${e['position'] ?? ''} · پایه: ${_m(_d(e['base_salary']))} ${e['ccy']}'),
                  trailing: manage
                      ? PopupMenuButton<String>(
                          onSelected: (String v) => v == 'adv' ? _advance(e) : _edit(e),
                          itemBuilder: (BuildContext c) => const <PopupMenuEntry<String>>[
                            PopupMenuItem<String>(value: 'edit', child: Text('ویرایش')),
                            PopupMenuItem<String>(value: 'adv', child: Text('ثبت مساعده')),
                          ],
                        )
                      : null,
                ),
            ]),
    );
  }
}

// ───────────────────────────── pay items ─────────────────────────────

class PayItemsScreen extends StatefulWidget {
  const PayItemsScreen({super.key});

  @override
  State<PayItemsScreen> createState() => _PayItemsState();
}

class _PayItemsState extends State<PayItemsScreen> {
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  bool _loading = true;
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final (List<Map<String, dynamic>> r, bool off) = await _PayCache.list('payroll.items', 'payroll_item_cache');
      _items = r;
      _offline = off;
    } catch (e) {
      if (mounted) snack(context, friendlyError(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _edit(Map<String, dynamic>? it) async {
    final TextEditingController name = TextEditingController(text: '${it?['name'] ?? ''}');
    final TextEditingController val = TextEditingController(text: it == null ? '' : plain(_d(it['default_value'])));
    String kind = '${it?['kind'] ?? 'earning'}';
    String formula = '${it?['formula'] ?? 'fixed'}';
    bool taxable = it != null && _d(it['taxable']) != 0;
    bool insurable = it != null && _d(it['insurable']) != 0;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter set) => AlertDialog(
          title: Text(it == null ? 'قلم جدید' : 'ویرایش قلم'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
              textField(name, 'عنوان (مثلاً حق مسکن)'),
              DropdownButtonFormField<String>(
                value: kind,
                decoration: const InputDecoration(labelText: 'نوع', border: OutlineInputBorder()),
                items: const <DropdownMenuItem<String>>[
                  DropdownMenuItem<String>(value: 'earning', child: Text('مزایا')),
                  DropdownMenuItem<String>(value: 'deduction', child: Text('کسورات')),
                ],
                onChanged: (String? v) => set(() => kind = v ?? 'earning'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: formula,
                decoration: const InputDecoration(labelText: 'روش محاسبه', border: OutlineInputBorder()),
                items: const <DropdownMenuItem<String>>[
                  DropdownMenuItem<String>(value: 'fixed', child: Text('مبلغ ثابت')),
                  DropdownMenuItem<String>(value: 'percent', child: Text('درصد از حقوق پایه')),
                ],
                onChanged: (String? v) => set(() => formula = v ?? 'fixed'),
              ),
              const SizedBox(height: 12),
              numField(val, formula == 'percent' ? 'درصد' : 'مبلغ', thousands: formula != 'percent'),
              if (kind == 'earning') ...<Widget>[
                CheckboxListTile(
                    title: const Text('مشمول مالیات'), value: taxable, onChanged: (bool? v) => set(() => taxable = v ?? false)),
                CheckboxListTile(
                    title: const Text('مشمول بیمه'), value: insurable, onChanged: (bool? v) => set(() => insurable = v ?? false)),
              ],
            ]),
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ذخیره')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (name.text.trim().isEmpty) {
      if (mounted) snack(context, 'عنوان الزامی است');
      return;
    }
    try {
      await StockApi.call('payroll.item_save', <String, dynamic>{
        if (it != null) 'id': it['id'] else 'uid': EntityStore.newUid(),
        'name': name.text.trim(),
        'kind': kind,
        'formula': formula,
        'default_value': parseNum(val.text) ?? 0,
        'taxable': kind == 'earning' && taxable ? 1 : 0,
        'insurable': kind == 'earning' && insurable ? 1 : 0,
      });
      _load();
    } catch (err) {
      if (mounted) snack(context, friendlyError(err));
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool manage = _can('payroll.manage');
    return Scaffold(
      appBar: AppBar(title: const Text('اقلام حقوقی')),
      floatingActionButton: manage ? FloatingActionButton(onPressed: () => _edit(null), child: const Icon(Icons.add)) : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.only(bottom: 90), children: <Widget>[
              if (_offline) _banner('آفلاین: فهرست ذخیره‌شده؛ ویرایش نیاز به اینترنت دارد.'),
              if (_items.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('قلمی تعریف نشده است.')),
              for (final Map<String, dynamic> it in _items)
                ListTile(
                  leading: Icon(it['kind'] == 'earning' ? Icons.add_circle_outline : Icons.remove_circle_outline,
                      color: it['kind'] == 'earning' ? Colors.green : Colors.red),
                  title: Text('${it['name']}'),
                  subtitle: Text(it['formula'] == 'percent'
                      ? '${_m(_d(it['default_value']))}٪ از حقوق پایه'
                      : _m(_d(it['default_value']))),
                  onTap: manage ? () => _edit(it) : null,
                ),
            ]),
    );
  }
}

// ───────────────────────────── run wizard ─────────────────────────────

/// Step 1 month → step 2 lines (overtime / other deductions) → step 3 review → local draft or send to server.
class PayrollWizardScreen extends StatefulWidget {
  final Map<String, dynamic>? draft;
  const PayrollWizardScreen({super.key, this.draft});

  @override
  State<PayrollWizardScreen> createState() => _PayrollWizardState();
}

class _PayrollWizardState extends State<PayrollWizardScreen> {
  int _step = 0;
  late int _year;
  late int _month;
  String _ccy = 'IRR';
  late String _uid;
  List<Map<String, dynamic>> _emps = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  final Map<int, TextEditingController> _ot = <int, TextEditingController>{};
  final Map<int, TextEditingController> _od = <int, TextEditingController>{};
  final TextEditingController _yearCtl = TextEditingController();
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final DateTime n = DateTime.now();
    final List<int> j = gregorianToJalali(n.year, n.month, n.day);
    final Map<String, dynamic>? d = widget.draft;
    _year = d == null ? j[0] : _d(d['year']).toInt();
    _month = d == null ? j[1] : _d(d['month']).toInt();
    _ccy = d == null ? 'IRR' : '${d['ccy']}';
    _uid = d == null ? EntityStore.newUid() : '${d['uid']}';
    _yearCtl.text = '$_year';
    _load();
  }

  Future<void> _load() async {
    try {
      final (List<Map<String, dynamic>> e, bool _) = await _PayCache.list('payroll.employees', 'payroll_emp_cache');
      final (List<Map<String, dynamic>> i, bool _) = await _PayCache.list('payroll.items', 'payroll_item_cache');
      _emps = e;
      _items = i;
    } catch (err) {
      if (mounted) snack(context, 'ابتدا یک‌بار آنلاین کارکنان را بارگیری کنید.');
    }
    final Map<String, dynamic>? d = widget.draft;
    for (final Map<String, dynamic> e in _emps) {
      final int id = _d(e['id']).toInt();
      final Map<String, dynamic> ot = d?['ot'] is Map ? Map<String, dynamic>.from(d!['ot'] as Map) : <String, dynamic>{};
      final Map<String, dynamic> od = d?['od'] is Map ? Map<String, dynamic>.from(d!['od'] as Map) : <String, dynamic>{};
      _ot[id] = TextEditingController(text: '${ot['$id'] ?? ''}');
      _od[id] = TextEditingController(text: '${od['$id'] ?? ''}');
    }
    if (mounted) setState(() => _loading = false);
  }

  List<Map<String, dynamic>> get _active => _emps
      .where((Map<String, dynamic> e) => _d(e['active']) != 0 && '${e['ccy']}' == _ccy)
      .toList();

  List<String> get _ccys {
    final Set<String> s = <String>{'IRR'};
    for (final Map<String, dynamic> e in _emps) {
      s.add('${e['ccy']}');
    }
    return s.toList()..sort();
  }

  /// Local preview of one line (server recomputes; statutory + advances are NOT included offline).
  Map<String, double> _calc(Map<String, dynamic> e) {
    final int id = _d(e['id']).toInt();
    final double base = _r2(_d(e['base_salary']));
    final double ot = parseNum(_ot[id]?.text) ?? 0;
    final double od = parseNum(_od[id]?.text) ?? 0;
    double allow = 0, ded = 0;
    for (final Map<String, dynamic> it in _items) {
      final double v = _d(it['default_value']);
      final double amt = it['formula'] == 'percent' ? _r2(base * v / 100) : _r2(v);
      if (it['kind'] == 'earning') {
        allow += amt;
      } else {
        ded += amt;
      }
    }
    final double earn = _r2(base + ot + allow);
    final double totalDed = _r2(ded + od);
    return <String, double>{'earnings': earn, 'deductions': totalDed, 'net': _r2(earn - totalDed), 'ot': ot, 'od': od};
  }

  Map<String, dynamic> _draftMap() => <String, dynamic>{
        'uid': _uid,
        'year': _year,
        'month': _month,
        'ccy': _ccy,
        'ot': <String, dynamic>{
          for (final Map<String, dynamic> e in _active)
            if ((parseNum(_ot[_d(e['id']).toInt()]?.text) ?? 0) > 0) '${_d(e['id']).toInt()}': _ot[_d(e['id']).toInt()]!.text,
        },
        'od': <String, dynamic>{
          for (final Map<String, dynamic> e in _active)
            if ((parseNum(_od[_d(e['id']).toInt()]?.text) ?? 0) > 0) '${_d(e['id']).toInt()}': _od[_d(e['id']).toInt()]!.text,
        },
      };

  Future<void> _saveLocal() async {
    await _PayCache.saveDraft(_draftMap());
    if (!mounted) return;
    snack(context, 'پیش‌نویس روی همین دستگاه ذخیره شد.');
    Navigator.pop(context);
  }

  Future<void> _send() async {
    setState(() => _busy = true);
    try {
      int runId = 0;
      Map<String, dynamic> run = <String, dynamic>{};
      try {
        run = await StockApi.call('payroll.run_create',
            <String, dynamic>{'uid': _uid, 'year': _year, 'month': _month, 'ccy': _ccy});
        runId = _d(run['id']).toInt();
      } catch (e) {
        // the same period may already exist on the server (e.g. a retry after a dropped connection)
        final Map<String, dynamic> list = await StockApi.call('payroll.runs');
        for (final Map<String, dynamic> r in _maps(list['items'])) {
          if (_d(r['year']).toInt() == _year && _d(r['month']).toInt() == _month && '${r['ccy']}' == _ccy && r['status'] == 'draft') {
            runId = _d(r['id']).toInt();
          }
        }
        if (runId == 0) rethrow;
        run = await StockApi.call('payroll.run_get', <String, dynamic>{'id': runId});
      }
      for (final Map<String, dynamic> l in _maps(run['lines'])) {
        final int emp = _d(l['employee_id']).toInt();
        final double ot = parseNum(_ot[emp]?.text) ?? 0;
        final double od = parseNum(_od[emp]?.text) ?? 0;
        if (ot > 0 || od > 0) {
          await StockApi.call('payroll.line_update',
              <String, dynamic>{'line_id': l['id'], 'overtime': ot, 'other_deductions': od});
        }
      }
      await _PayCache.removeDraft(_uid);
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute<void>(builder: (_) => PayrollRunScreen(runId: runId)));
    } catch (e) {
      if (mounted) snack(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('دورهٔ جدید حقوق')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Stepper(
              currentStep: _step,
              controlsBuilder: (BuildContext c, ControlsDetails d) => Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(children: <Widget>[
                  if (_step < 2) FilledButton(onPressed: d.onStepContinue, child: const Text('بعدی')),
                  const SizedBox(width: 8),
                  if (_step > 0) TextButton(onPressed: d.onStepCancel, child: const Text('قبلی')),
                ]),
              ),
              onStepContinue: () {
                if (_step == 0) {
                  final int? y = int.tryParse(toEnDigits(_yearCtl.text.trim()));
                  if (y == null || y < 1300 || y > 1600) {
                    snack(context, 'سال نامعتبر است');
                    return;
                  }
                  _year = y;
                }
                if (_step < 2) setState(() => _step++);
              },
              onStepCancel: () => setState(() => _step--),
              steps: <Step>[
                Step(
                  title: const Text('ماه و ارز'),
                  isActive: _step >= 0,
                  content: Column(children: <Widget>[
                    DropdownButtonFormField<int>(
                      value: _month,
                      decoration: const InputDecoration(labelText: 'ماه', border: OutlineInputBorder()),
                      items: <DropdownMenuItem<int>>[
                        for (int i = 1; i <= 12; i++) DropdownMenuItem<int>(value: i, child: Text(kJalaliMonthNames[i - 1])),
                      ],
                      onChanged: (int? v) => setState(() => _month = v ?? _month),
                    ),
                    const SizedBox(height: 12),
                    textField(_yearCtl, 'سال شمسی'),
                    DropdownButtonFormField<String>(
                      value: _ccys.contains(_ccy) ? _ccy : _ccys.first,
                      decoration: const InputDecoration(labelText: 'ارز دوره', border: OutlineInputBorder()),
                      items: <DropdownMenuItem<String>>[
                        for (final String c in _ccys) DropdownMenuItem<String>(value: c, child: Text(c)),
                      ],
                      onChanged: (String? v) => setState(() => _ccy = v ?? _ccy),
                    ),
                  ]),
                ),
                Step(
                  title: const Text('ردیف‌ها'),
                  isActive: _step >= 1,
                  content: Column(children: <Widget>[
                    if (_active.isEmpty) const Text('کارمند فعالی با این ارز وجود ندارد.'),
                    for (final Map<String, dynamic> e in _active)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                            Text('${e['name']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                            Text('پایه: ${_m(_d(e['base_salary']))}', style: const TextStyle(fontSize: 12)),
                            const SizedBox(height: 8),
                            numField(_ot[_d(e['id']).toInt()]!, 'اضافه‌کاری', thousands: true, onChanged: () => setState(() {})),
                            numField(_od[_d(e['id']).toInt()]!, 'سایر کسورات', thousands: true, onChanged: () => setState(() {})),
                            Text('خالص (پیش‌نمایش): ${_m(_calc(e)['net'] ?? 0)}'),
                          ]),
                        ),
                      ),
                  ]),
                ),
                Step(
                  title: const Text('مرور و ارسال'),
                  isActive: _step >= 2,
                  content: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                    Text('${_period(_year, _month)} · $_ccy'),
                    const SizedBox(height: 6),
                    for (final Map<String, dynamic> e in _active)
                      infoRow('${e['name']}', _m(_calc(e)['net'] ?? 0)),
                    const Divider(),
                    infoRow('جمع خالص (پیش‌نمایش)',
                        _m(_active.fold<double>(0, (double s, Map<String, dynamic> e) => s + (_calc(e)['net'] ?? 0)))),
                    const SizedBox(height: 6),
                    const Text(
                        'مبلغ نهایی (کسر مساعده و بیمه/مالیات) پس از ارسال توسط سرور محاسبه می‌شود. تأیید نهایی فقط آنلاین انجام می‌شود.',
                        style: TextStyle(fontSize: 12)),
                    const SizedBox(height: 10),
                    Wrap(spacing: 8, children: <Widget>[
                      OutlinedButton.icon(
                          onPressed: _busy ? null : _saveLocal,
                          icon: const Icon(Icons.save_outlined),
                          label: const Text('ذخیرهٔ پیش‌نویس محلی')),
                      FilledButton.icon(
                          onPressed: _busy || _active.isEmpty ? null : _send,
                          icon: const Icon(Icons.cloud_upload_outlined),
                          label: Text(_busy ? 'در حال ارسال…' : 'ارسال به سرور')),
                    ]),
                  ]),
                ),
              ],
            ),
    );
  }
}

// ───────────────────────────── run view / approve ─────────────────────────────

class PayrollRunScreen extends StatefulWidget {
  final int runId;
  const PayrollRunScreen({super.key, required this.runId});

  @override
  State<PayrollRunScreen> createState() => _PayrollRunState();
}

class _PayrollRunState extends State<PayrollRunScreen> {
  Map<String, dynamic>? _run;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _run = await StockApi.call('payroll.run_get', <String, dynamic>{'id': widget.runId});
    } catch (e) {
      if (mounted) snack(context, friendlyError(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _editLine(Map<String, dynamic> l) async {
    final TextEditingController ot = TextEditingController(text: plain(_d(l['overtime'])));
    final TextEditingController od = TextEditingController(text: plain(_d(l['other_deductions'])));
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('${l['employee']}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          numField(ot, 'اضافه‌کاری', thousands: true),
          numField(od, 'سایر کسورات', thousands: true),
        ]),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ذخیره')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      _run = await StockApi.call('payroll.line_update', <String, dynamic>{
        'line_id': l['id'],
        'overtime': parseNum(ot.text) ?? 0,
        'other_deductions': parseNum(od.text) ?? 0,
      });
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) snack(context, friendlyError(e));
    }
  }

  Future<void> _approve() async {
    if (!await confirm(context, 'دوره تأیید شود؟ پس از تأیید، ردیف‌ها و مساعده‌های کسرشده غیرقابل ویرایش‌اند.')) return;
    try {
      _run = await StockApi.call('payroll.approve', <String, dynamic>{'run_id': widget.runId});
      if (mounted) {
        setState(() {});
        snack(context, 'دوره تأیید شد.');
      }
    } catch (e) {
      if (mounted) snack(context, friendlyError(e));
    }
  }

  Future<void> _delete() async {
    if (!await confirm(context, 'پیش‌نویس دوره حذف شود؟')) return;
    try {
      await StockApi.call('payroll.run_delete', <String, dynamic>{'run_id': widget.runId});
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) snack(context, friendlyError(e));
    }
  }

  Future<void> _payslip(Map<String, dynamic> l) async {
    try {
      final Map<String, dynamic> p = await StockApi.call('payroll.payslip', <String, dynamic>{'line_id': l['id']});
      final List<List<String>> rows = <List<String>>[];
      for (final Map<String, dynamic> x in _maps(p['earnings'])) {
        rows.add(<String>['${x['name']}', 'مزایا', _m(_d(x['amount']))]);
      }
      for (final Map<String, dynamic> x in _maps(p['deductions'])) {
        rows.add(<String>['${x['name']}', 'کسورات', _m(_d(x['amount']))]);
      }
      final Map<String, dynamic>? st = p['statutory'] is Map ? Map<String, dynamic>.from(p['statutory'] as Map) : null;
      final String ccy = '${p['ccy']}';
      final file = await PdfService.buildDocument(
        title: 'فیش حقوقی',
        fileTag: 'payslip_${p['line_id']}',
        header: <List<String>>[
          <String>['کارمند', '${p['employee']}'],
          <String>['سمت', '${p['position'] ?? '-'}'],
          <String>['دوره', _period(_d(p['year']).toInt(), _d(p['month']).toInt())],
          <String>['شمارهٔ بیمه', '${p['insurance_no'] ?? '-'}'],
        ],
        columns: const <String>['شرح', 'نوع', 'مبلغ'],
        rows: rows,
        totals: <List<String>>[
          <String>['جمع مزایا', '${_m(_d(p['total_earnings']))} $ccy'],
          <String>['جمع کسورات', '${_m(_d(p['total_deductions']))} $ccy'],
          <String>['خالص پرداختی', '${_m(_d(p['net']))} $ccy'],
          if (st != null) <String>['بیمه سهم کارفرما', '${_m(_d(st['ins_employer']))} $ccy'],
        ],
      );
      if (!mounted) return;
      await PdfOutput.show(context, file);
    } catch (e) {
      if (mounted) snack(context, friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic>? r = _run;
    final bool manage = _can('payroll.manage');
    final bool editable = r != null && r['editable'] == true;
    return Scaffold(
      appBar: AppBar(
        title: Text(r == null ? 'دورهٔ حقوق' : _period(_d(r['year']).toInt(), _d(r['month']).toInt())),
        actions: <Widget>[
          if (r != null && !editable)
            IconButton(
              tooltip: 'برنامهٔ پرداخت (سررسیدها)',
              icon: const Icon(Icons.payments_outlined),
              onPressed: () => Navigator.push(
                  context, MaterialPageRoute<void>(builder: (_) => PayLinesScreen(runId: widget.runId))),
            ),
          if (editable && manage) IconButton(onPressed: _delete, icon: const Icon(Icons.delete_outline)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : r == null
              ? Center(child: TextButton(onPressed: _load, child: const Text('تلاش دوباره (نیاز به اینترنت)')))
              : ListView(padding: const EdgeInsets.all(12), children: <Widget>[
                  Text('ارز: ${r['ccy']} · ${editable ? 'پیش‌نویس' : 'تأییدشده'}'),
                  if (!editable) Wrap(spacing: 8, children: <Widget>[
                    VoucherStatusChip(sourceType: 'payroll', sourceId: '${widget.runId}'),
                    VoucherLinkButton(sourceType: 'payroll', sourceId: '${widget.runId}'),
                  ]),
                  const SizedBox(height: 8),
                  for (final Map<String, dynamic> l in _maps(r['lines']))
                    Card(
                      child: ExpansionTile(
                        title: Text('${l['employee']}'),
                        subtitle: Text('خالص: ${_m(_d(l['net']))}'),
                        children: <Widget>[
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Column(children: <Widget>[
                              infoRow('حقوق پایه', _m(_d(l['base']))),
                              infoRow('اضافه‌کاری', _m(_d(l['overtime']))),
                              for (final Map<String, dynamic> x in _maps(l['items']))
                                infoRow('${x['name']}', '${x['kind'] == 'earning' ? '+' : '-'}${_m(_d(x['amount']))}'),
                              infoRow('سایر کسورات', _m(_d(l['other_deductions']))),
                              infoRow('کسر مساعده', _m(_d(l['advances_deducted']))),
                              infoRow('جمع مزایا', _m(_d(l['earnings']))),
                              infoRow('جمع کسورات', _m(_d(l['deductions']))),
                            ]),
                          ),
                          OverflowBar(children: <Widget>[
                            if (editable && manage)
                              TextButton.icon(
                                  onPressed: () => _editLine(l), icon: const Icon(Icons.edit_outlined), label: const Text('ویرایش')),
                            if (!editable)
                              TextButton.icon(
                                  onPressed: () => _payslip(l),
                                  icon: const Icon(Icons.picture_as_pdf_outlined),
                                  label: const Text('فیش حقوقی')),
                          ]),
                        ],
                      ),
                    ),
                  const Divider(),
                  if (r['totals'] is Map) ...<Widget>[
                    infoRow('جمع مزایا', _m(_d((r['totals'] as Map)['earnings']))),
                    infoRow('جمع کسورات', _m(_d((r['totals'] as Map)['deductions']))),
                    infoRow('جمع مساعده کسرشده', _m(_d((r['totals'] as Map)['advances_deducted']))),
                    infoRow('جمع خالص', _m(_d((r['totals'] as Map)['net']))),
                  ],
                  if (editable && manage) ...<Widget>[
                    const SizedBox(height: 12),
                    FilledButton.icon(
                        onPressed: _approve, icon: const Icon(Icons.verified_outlined), label: const Text('تأیید دوره (آنلاین)')),
                  ],
                ]),
    );
  }
}

// ───────────────────────────── pay lines (multi-currency, multi-due) ─────────────────────────────

class PayLinesScreen extends StatefulWidget {
  final int runId;
  const PayLinesScreen({super.key, required this.runId});

  @override
  State<PayLinesScreen> createState() => _PayLinesState();
}

class _PayLinesState extends State<PayLinesScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _data = await StockApi.call('payroll.pay_lines', <String, dynamic>{'run_id': widget.runId});
    } catch (e) {
      if (mounted) snack(context, friendlyError(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _add(Map<String, dynamic> item, String runCcy) async {
    final double remaining = _d(item['remaining']);
    final TextEditingController ccy = TextEditingController(text: runCcy);
    final TextEditingController amount = TextEditingController(text: remaining > 0 ? plain(remaining) : '');
    final TextEditingController netPart = TextEditingController(text: remaining > 0 ? plain(remaining) : '');
    final TextEditingController chq = TextEditingController();
    DateTime due = DateTime.now();
    String method = 'transfer';
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter set) => AlertDialog(
          title: Text('پرداخت برای ${item['employee']}'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
              Text('مانده برنامه‌ریزی‌نشده: ${_m(remaining)} $runCcy', style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 8),
              textField(ccy, 'ارز پرداخت'),
              numField(amount, 'مبلغ به ارز پرداخت', required: true, thousands: true),
              numField(netPart, 'معادل به ارز دوره ($runCcy)', required: true, thousands: true),
              dateField(ctx, 'سررسید', due, (DateTime d) => set(() => due = d)),
              DropdownButtonFormField<String>(
                value: method,
                decoration: const InputDecoration(labelText: 'روش', border: OutlineInputBorder()),
                items: const <DropdownMenuItem<String>>[
                  DropdownMenuItem<String>(value: 'transfer', child: Text('انتقال بانکی')),
                  DropdownMenuItem<String>(value: 'cash', child: Text('نقد')),
                  DropdownMenuItem<String>(value: 'cheque', child: Text('چک')),
                ],
                onChanged: (String? v) => set(() => method = v ?? 'transfer'),
              ),
              if (method == 'cheque') ...<Widget>[const SizedBox(height: 12), textField(chq, 'شمارهٔ چک')],
            ]),
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('افزودن')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final String c = ccy.text.trim().isEmpty ? runCcy : ccy.text.trim().toUpperCase();
    final double a = parseNum(amount.text) ?? 0;
    final double n = parseNum(netPart.text) ?? 0;
    if (a <= 0 || n <= 0) {
      if (mounted) snack(context, 'مبالغ نامعتبر است');
      return;
    }
    try {
      await StockApi.call('payroll.pay_line_add', <String, dynamic>{
        'uid': EntityStore.newUid(),
        'line_id': item['line_id'],
        'ccy': c,
        'amount': a,
        'net_part': c == runCcy ? a : n,
        'due_date': _iso(due),
        'method': method,
        if (method == 'cheque') 'cheque_ref': chq.text.trim(),
      });
      _load();
    } catch (e) {
      if (mounted) snack(context, friendlyError(e));
    }
  }

  Future<void> _del(Map<String, dynamic> row) async {
    if (!await confirm(context, 'این ردیف پرداخت حذف شود؟')) return;
    try {
      await StockApi.call('payroll.pay_line_delete', <String, dynamic>{'id': row['id']});
      _load();
    } catch (e) {
      if (mounted) snack(context, friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic>? d = _data;
    final bool manage = _can('payroll.manage');
    final String runCcy = '${d?['ccy'] ?? ''}';
    return Scaffold(
      appBar: AppBar(title: const Text('برنامهٔ پرداخت حقوق')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : d == null
              ? Center(child: TextButton(onPressed: _load, child: const Text('تلاش دوباره')))
              : ListView(padding: const EdgeInsets.all(12), children: <Widget>[
                  for (final Map<String, dynamic> it in _maps(d['items']))
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                          Text('${it['employee']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                          Text(
                              'خالص ${_m(_d(it['net']))} · برنامه‌ریزی‌شده ${_m(_d(it['scheduled']))} · پرداخت‌شده ${_m(_d(it['paid']))} · مانده ${_m(_d(it['remaining']))} $runCcy',
                              style: const TextStyle(fontSize: 12)),
                          for (final Map<String, dynamic> row in _maps(it['rows']))
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(_d(row['paid']) != 0 ? Icons.check_circle : Icons.schedule,
                                  color: _d(row['paid']) != 0 ? Colors.green : Colors.orange),
                              title: Text('${_m(_d(row['amount']))} ${row['ccy']}'
                                  '${row['ccy'] != runCcy ? ' (≈ ${_m(_d(row['net_part']))} $runCcy)' : ''}'),
                              subtitle: Text(
                                  '${row['due_date'] == null ? '-' : jalaliDate('${row['due_date']}')} · ${row['method']}${row['cheque_ref'] == null ? '' : ' · ${row['cheque_ref']}'}'),
                              trailing: manage && _d(row['paid']) == 0
                                  ? IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _del(row))
                                  : null,
                            ),
                          if (manage)
                            TextButton.icon(
                                onPressed: () => _add(it, runCcy), icon: const Icon(Icons.add), label: const Text('افزودن پرداخت')),
                        ]),
                      ),
                    ),
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('علامت‌گذاری «پرداخت‌شد» از صفحهٔ سررسیدها انجام می‌شود.', style: TextStyle(fontSize: 12)),
                  ),
                ]),
    );
  }
}

// ───────────────────────────── unpaid report ─────────────────────────────

class PayrollUnpaidScreen extends StatefulWidget {
  const PayrollUnpaidScreen({super.key});

  @override
  State<PayrollUnpaidScreen> createState() => _PayrollUnpaidState();
}

class _PayrollUnpaidState extends State<PayrollUnpaidScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _data = await StockApi.call('payroll.pay_unpaid');
    } catch (e) {
      if (mounted) snack(context, friendlyError(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic>? d = _data;
    return Scaffold(
      appBar: AppBar(title: const Text('پرداخت‌های حقوق باز')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : d == null
              ? const Center(child: Text('نیاز به اتصال اینترنت است.'))
              : ListView(children: <Widget>[
                  if (d['totals_by_run_ccy'] is Map)
                    for (final MapEntry<dynamic, dynamic> e in (d['totals_by_run_ccy'] as Map).entries)
                      infoRow('جمع ${e.key}', _m(_d(e.value))),
                  const Divider(),
                  if (_maps(d['items']).isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('پرداخت بازی وجود ندارد.')),
                  for (final Map<String, dynamic> r in _maps(d['items']))
                    ListTile(
                      leading: const Icon(Icons.schedule, color: Colors.orange),
                      title: Text('${r['employee']} · ${_m(_d(r['amount']))} ${r['ccy']}'),
                      subtitle: Text(
                          '${_period(_d(r['year']).toInt(), _d(r['month']).toInt())} · سررسید ${r['due_date'] == null ? '-' : jalaliDate('${r['due_date']}')}'),
                    ),
                ]),
    );
  }
}
