import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'edition.dart';
import 'upgrade_buy.dart';
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;
import 'widgets.dart';

/// S20.T20.3 — Green → Gold upgrade wizard (owner only).
/// Server (source of truth, resumable): `tier.upgrade_status|preview|apply|rollback`. Killing the app mid-way is safe:
/// opening this screen reads `tier.upgrade_status` and offers to resume (apply is idempotent). A local "pending" flag keeps the menu entry
/// visible after the tier already flipped to gold (until the user dismisses the final report).

const String kUpgradePendingKey = 'pb_upgrade_pending';

Future<bool> upgradePending() async {
  try {
    return (await SharedPreferences.getInstance()).getBool(kUpgradePendingKey) ?? false;
  } catch (_) {
    return false;
  }
}

Future<void> _setPending(bool v) async {
  try {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    if (v) {
      await sp.setBool(kUpgradePendingKey, true);
    } else {
      await sp.remove(kUpgradePendingKey);
    }
  } catch (_) {}
}

String _ymd(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

Map<String, dynamic> _m(dynamic v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _l(dynamic v) => <Map<String, dynamic>>[for (final dynamic e in (v as List<dynamic>? ?? <dynamic>[])) _m(e)];

const Map<String, String> _stepFa = <String, String>{
  'snapshot': 'نسخهٔ پشتیبان سرور',
  'tier': 'فعال‌سازی نسخهٔ طلایی',
  'setup': 'سال مالی، سرفصل‌ها و تفصیلی‌ها',
  'opening': 'سند افتتاحیه',
  'backfill': 'ثبت اسناد حسابداری',
  'reconcile': 'کنترل و تطبیق نهایی',
};
const List<String> _stepOrder = <String>['snapshot', 'tier', 'setup', 'opening', 'backfill', 'reconcile'];

class UpgradeScreen extends StatefulWidget {
  const UpgradeScreen({super.key});

  @override
  State<UpgradeScreen> createState() => _UpgradeScreenState();
}

class _UpgradeScreenState extends State<UpgradeScreen> {
  bool _busy = true;
  bool _running = false;
  String? _error;
  Map<String, dynamic>? _run; // latest server run
  Map<String, dynamic>? _pv; // preview
  // form
  DateTime _fyStart = DateTime.now();
  DateTime? _openDate;
  bool _vat = false;
  final TextEditingController _vatRate = TextEditingController();
  final TextEditingController _vatSource = TextEditingController();
  bool _ackBackup = false;
  bool? _entitled; // S22.T22.3c: paid/manual upgrade right (tier.upgrade_status.entitled); null = unknown
  bool _stop = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _stop = true;
    _vatRate.dispose();
    _vatSource.dispose();
    super.dispose();
  }

  String get _runStatus => '${_run?['status'] ?? ''}';
  bool get _unfinished => _runStatus == 'running' || _runStatus == 'failed';

  Map<String, dynamic> _params() => <String, dynamic>{
        'first_fy_start': _ymd(_fyStart),
        if (_openDate != null) 'opening_date': _ymd(_openDate!),
        'vat_enabled': _vat,
        if (_vat && parseNum(_vatRate.text) != null) 'vat_rate': parseNum(_vatRate.text),
        'vat_source': _vatSource.text.trim(),
      };

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> r = await StockApi.call('tier.upgrade_status');
      _run = r['run'] == null ? null : _m(r['run']);
      _entitled = r['entitled'] is bool ? r['entitled'] as bool : null;
      if (_run != null && _runStatus == 'done') {
        await _setPending(true);
      }
      if (!mounted) return;
      setState(() => _busy = false);
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  Future<void> _preview() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _pv = await StockApi.call('tier.upgrade_preview', _params());
    } on StockApiException catch (e) {
      _error = e.message;
    }
    if (!mounted) return;
    setState(() => _busy = false);
  }

  /// Payment gate (S22.T22.3c): a NEW run needs the upgrade right bought (or granted by admin). Server enforces it too (402 tier_not_entitled).
  Future<bool> _licenceStub() async {
    if (_entitled == false) {
      if (mounted) snack(context, 'ابتدا «ارتقا به طلایی» را خریداری کنید.');
      return false;
    }
    return true;
  }

  Future<void> _start() async {
    if (!await _licenceStub()) return;
    if (!mounted) return;
    if (!await confirm(context, 'ارتقا به نسخهٔ طلایی آغاز می‌شود. اسناد عملیاتی شما تغییر نمی‌کند و تا ۷ روز امکان بازگشت وجود دارد. ادامه می‌دهید؟')) return;
    await _setPending(true);
    await _applyLoop();
  }

  Future<void> _applyLoop() async {
    setState(() {
      _running = true;
      _error = null;
    });
    int busyRetries = 0;
    while (mounted && !_stop) {
      try {
        final Map<String, dynamic> r = await StockApi.call('tier.upgrade_apply', <String, dynamic>{'confirm': 1, ..._params()});
        if (r['busy'] == true) {
          if (++busyRetries > 20) break;
          await Future<void>.delayed(const Duration(seconds: 3));
          continue;
        }
        _run = r;
        if (mounted) setState(() {});
        final String st = '${r['status']}';
        if (st == 'done') {
          await _refreshEdition();
          break;
        }
        if (st == 'failed') {
          _error = '${r['error'] ?? 'یک مرحله با خطا روبه‌رو شد'}';
          break;
        }
        // running: server stopped on its time budget -> call again (resume)
      } on StockApiException catch (e) {
        _error = e.message;
        break;
      }
    }
    if (!mounted) return;
    setState(() => _running = false);
  }

  /// Green → gold edition refresh: the server flipped the tier; pull it into the local EditionService.
  Future<void> _refreshEdition() async {
    try {
      final Map<String, dynamic> r = await StockApi.call('account.status');
      await EditionService.I.apply(r['edition'], r['plan']);
    } catch (_) {}
  }

  Future<void> _rollback() async {
    try {
      final Map<String, dynamic> dry = await StockApi.call('tier.upgrade_rollback', <String, dynamic>{'dry': 1});
      if (!mounted) return;
      final Map<String, dynamic> w = _m(dry['would_remove']);
      final bool ok = await confirm(context, 'بازگشت به نسخهٔ سبز، سندهای حسابداری (${faNum((w['vouchers'] as num?) ?? 0, dec: 0)} سند)، سرفصل‌ها و سال‌های مالی را حذف می‌کند. اسناد خرید و فروش دست‌نخورده می‌ماند. ادامه؟');
      if (!ok) return;
      await StockApi.call('tier.upgrade_rollback');
      await _setPending(false);
      await _refreshEdition();
      if (!mounted) return;
      snack(context, 'به نسخهٔ سبز بازگشتید');
      Navigator.pop(context);
    } on StockApiException catch (e) {
      if (!mounted) return;
      snack(context, e.message);
    }
  }

  Future<void> _dismissReport() async {
    await _setPending(false);
    if (mounted) Navigator.pop(context);
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('ارتقا به نسخهٔ طلایی')),
        body: _busy
            ? const Center(child: CircularProgressIndicator())
            : ListView(padding: const EdgeInsets.all(16), children: <Widget>[
                if (_error != null) _errorCard(),
                if (_running || _unfinished) _progressCard()
                else if (_runStatus == 'done') ..._reportView()
                else if (_pv != null) ..._previewView()
                else ..._formView(),
              ]),
      ),
    );
  }

  Widget _errorCard() => Card(
        color: Colors.red.shade50,
        child: Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: TextStyle(color: Colors.red.shade900))),
      );

  List<Widget> _formView() => <Widget>[
        if (_entitled == false) TierUpgradeBuyCard(onRefresh: _load),
        sectionTitle(context, 'مزایای نسخهٔ طلایی'),
        const Text('• دفتر حسابداری دوطرفه: سند، کل، معین و تفصیلی\n• سندزنی خودکار از خرید، فروش، چک، حقوق و انبار\n• مالیات بر ارزش افزوده و صورت‌حساب رسمی\n• تراز آزمایشی، دفتر روزنامه، بستن و افتتاح سال مالی'),
        sectionTitle(context, 'پیش‌نیازها'),
        const Text('• فقط مالک حساب می‌تواند ارتقا دهد.\n• اینترنت پایدار تا پایان کار (در صورت قطع، ادامه از همان‌جا انجام می‌شود).\n• طرف‌حساب‌ها، قیمت خرید محموله‌ها و حساب خزانهٔ پرداخت‌ها کامل باشد (در پیش‌نمایش بررسی می‌شود).'),
        Card(
          color: Colors.amber.shade50,
          child: CheckboxListTile(
            value: _ackBackup,
            onChanged: (bool? v) => setState(() => _ackBackup = v ?? false),
            title: const Text('پیش از ارتقا یک نسخهٔ پشتیبان روی سرور ساخته می‌شود؛ پیشنهاد می‌کنم از «پشتیبان‌گیری» هم یک نسخه روی گوشی نگه دارم.'),
          ),
        ),
        sectionTitle(context, 'تنظیمات'),
        dateField(context, 'شروع اولین سال مالی (سال شمسی همان تاریخ)', _fyStart, (DateTime d) => setState(() => _fyStart = d)),
        dateField(context, 'تاریخ سند افتتاحیه (خالی = اول سال مالی)', _openDate, (DateTime d) => setState(() => _openDate = d)),
        SwitchListTile(title: const Text('مالیات بر ارزش افزوده فعال باشد'), value: _vat, onChanged: (bool v) => setState(() => _vat = v)),
        if (_vat) ...<Widget>[
          textField(_vatRate, 'نرخ مالیات (درصد) — طبق تأیید حسابدار'),
          textField(_vatSource, 'منبع/یادداشت نرخ (مثلاً شمارهٔ ابلاغیه)'),
        ],
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _ackBackup ? _preview : null,
          icon: const Icon(Icons.fact_check_outlined),
          label: const Text('پیش‌نمایش ارتقا'),
        ),
      ];

  List<Widget> _previewView() {
    final Map<String, dynamic> pv = _pv!;
    final Map<String, dynamic> st = _m(pv['stats']);
    final List<Map<String, dynamic>> issues = _l(pv['issues']);
    final bool ok = pv['ok'] == true;
    return <Widget>[
      sectionTitle(context, 'نتیجهٔ پیش‌نمایش'),
      infoRow('سال مالی اول', '${pv['fy_start']} تا ${pv['fy_end']}'),
      infoRow('تاریخ سند افتتاحیه', '${pv['opening_date']}'),
      infoRow('اسناد حسابداری‌شدنی', faNum((st['documents'] as num?) ?? 0, dec: 0)),
      infoRow('پیش از سال مالی (خلاصه در افتتاحیه)', faNum((st['before_fy'] as num?) ?? 0, dec: 0)),
      infoRow('داخل سال مالی (تک‌تک ثبت می‌شود)', faNum((st['in_fy'] as num?) ?? 0, dec: 0)),
      infoRow('زمان تقریبی', '${faNum((pv['estimate_seconds'] as num?) ?? 0, dec: 0)} ثانیه'),
      sectionTitle(context, 'نکات و مشکلات'),
      for (final Map<String, dynamic> i in issues)
        ListTile(
          dense: true,
          leading: Icon(i['level'] == 'error' ? Icons.error : (i['level'] == 'warning' ? Icons.warning_amber : Icons.info_outline),
              color: i['level'] == 'error' ? Colors.red : (i['level'] == 'warning' ? Colors.orange : Colors.blueGrey)),
          title: Text('${i['detail']}'),
          trailing: (i['count'] as num? ?? 0) > 0 ? Text(faNum(i['count'] as num, dec: 0)) : null,
        ),
      const SizedBox(height: 12),
      Row(children: <Widget>[
        OutlinedButton(onPressed: () => setState(() => _pv = null), child: const Text('ویرایش تنظیمات')),
        const SizedBox(width: 12),
        Expanded(child: FilledButton.icon(onPressed: ok ? _start : null, icon: const Icon(Icons.workspace_premium_outlined), label: const Text('شروع ارتقا'))),
      ]),
    ];
  }

  Widget _progressCard() {
    final Map<String, dynamic> steps = _m(_run?['steps']);
    final String cur = '${_run?['step'] ?? ''}';
    final Map<String, dynamic> bf = _m(steps['backfill']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      sectionTitle(context, _running ? 'در حال ارتقا… برنامه را نبندید' : 'ارتقا نیمه‌کاره مانده است'),
      for (final String s in _stepOrder)
        ListTile(
          dense: true,
          leading: _m(steps[s])['done'] == true
              ? const Icon(Icons.check_circle, color: Colors.green)
              : (_running && s == cur ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.radio_button_unchecked)),
          title: Text(_stepFa[s] ?? s),
          subtitle: s == 'backfill' && bf.isNotEmpty ? Text('ثبت‌شده: ${faNum((bf['posted'] as num?) ?? 0, dec: 0)} — باقی‌مانده: ${faNum((bf['remaining'] as num?) ?? 0, dec: 0)}') : null,
        ),
      if (!_running) ...<Widget>[
        const SizedBox(height: 8),
        const Text('داده‌ها در سرور ذخیره شده است؛ با «ادامه» از همان مرحله پیش می‌رود.'),
        const SizedBox(height: 8),
        FilledButton.icon(onPressed: () => _applyLoop(), icon: const Icon(Icons.play_arrow), label: const Text('ادامهٔ ارتقا')),
        TextButton(onPressed: _rollback, child: const Text('انصراف و بازگشت')),
      ],
    ]);
  }

  List<Widget> _reportView() {
    final Map<String, dynamic> rep = _m(_run?['report']);
    final List<Map<String, dynamic>> diffs = _l(rep['differences']);
    final bool ok = rep['ok'] == true;
    final Map<String, dynamic> inv = _m(rep['inventory']);
    final Map<String, dynamic> tb = _m(rep['trial_balance']);
    return <Widget>[
      Card(
        color: ok ? Colors.green.shade50 : Colors.orange.shade50,
        child: ListTile(
          leading: Icon(ok ? Icons.verified : Icons.rule, color: ok ? Colors.green : Colors.orange),
          title: Text(ok ? 'ارتقا کامل شد و تطبیق بدون مغایرت است' : 'ارتقا کامل شد؛ مغایرت‌های زیر را با حسابدار بررسی کنید'),
        ),
      ),
      sectionTitle(context, 'گزارش تطبیق'),
      infoRow('موجودی دفتری', faNum((inv['book'] as num?) ?? 0, dec: 0)),
      infoRow('ارزش انبار', faNum((inv['valuation'] as num?) ?? 0, dec: 0)),
      infoRow('جمع بدهکار', faNum((tb['debit'] as num?) ?? 0, dec: 0)),
      infoRow('جمع بستانکار', faNum((tb['credit'] as num?) ?? 0, dec: 0)),
      infoRow('طرف‌حساب‌های کنترل‌شده', faNum((rep['parties_checked'] as num?) ?? 0, dec: 0)),
      if (diffs.isNotEmpty) sectionTitle(context, 'مغایرت‌ها (ریال)'),
      for (final Map<String, dynamic> d in diffs)
        ListTile(
          dense: true,
          leading: Icon(d['level'] == 'error' ? Icons.error : Icons.warning_amber, color: d['level'] == 'error' ? Colors.red : Colors.orange),
          title: Text('${d['item']}'),
          subtitle: d['diff'] == null ? null : Text('دفتر ${faNum((d['book'] as num?) ?? 0, dec: 0)} — مورد انتظار ${faNum((d['expected'] as num?) ?? 0, dec: 0)} — اختلاف ${faNum((d['diff'] as num?) ?? 0, dec: 0)}'),
        ),
      sectionTitle(context, 'چه چیزی تغییر کرد؟'),
      const Text('• اسناد خرید/فروش/چک شما دست‌نخورده است؛ برای هر کدام یک سند حسابداری خودکار (موقت) ساخته شد.\n'
          '• اسناد پیش از سال مالی در «سند افتتاحیه» خلاصه شد؛ سود/زیان قبل و مانده‌های اول دورهٔ طرف‌حساب‌ها به «سود انباشته» رفته است.\n'
          '• مانده نقد و بانک اول دوره ثبت نمی‌شود؛ حسابدار با یک سند دستی آن را وارد کند.\n'
          '• از این پس ثبت سند در سال مالی بسته یا خارج از سال‌های مالی ممکن نیست.\n'
          '• تا ۷ روز و پیش از ثبت سند دستی یا بستن سال، می‌توانید به نسخهٔ سبز برگردید.'),
      const SizedBox(height: 12),
      FilledButton(onPressed: _dismissReport, child: const Text('متوجه شدم')),
      TextButton(onPressed: _rollback, child: const Text('بازگشت به نسخهٔ سبز')),
    ];
  }
}
