import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'crack_lots.dart';
import 'db.dart' show AppDb;
import 'perms.dart' show StaffPerms;
import 'processing_ui.dart' show ProcessingStore, ProcWriteResult;
import 'returns_ui.dart' show ReturnsHelp;
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException, StockLookup, WhOption;
import 'widgets.dart' show pickDate;
import 'workshop_calc.dart';

/// کارگاه — مرحلهٔ ۳-ب: «گزارش خط شکست» (فرم نوبت کار دستگاه شکست؛ برگهٔ اکسل A..AP).
/// سرور: workshop.crack_create/update/list (api/workshop_crack.php). هیچ فیلد قیمتی نیست و موجودی انبار اصلی را تغییر نمی‌دهد.
/// آفلاین: صف ProcessingStore (create با uid ایدمپوتنت). ستون‌های محاسباتی فقط‌خواندنی از crackCalc (آینهٔ pb_cr_calc).
/// AO حذف شده و AP (معنی تأییدنشده) عمداً در UI نشان داده نمی‌شود.
/// تاریخ: شمسی در UI، میلادی (yyyy-mm-dd) در API.

/// S1: خالی یا «-» ⇒ null؛ `عدد(عدد)` ⇒ عدد اول؛ نامعتبر ⇒ null (با crIsBlank از خالی تشخیص داده می‌شود). منطق در workshop_calc.dart.
double? _crNum(String s) => crParseNum(s);

String _crFmt(num? v) {
  if (v == null) return '';
  final double d = v.toDouble();
  return d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toString();
}

String _crTime(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

TimeOfDay? _crParseTime(String? s) {
  if (s == null || !RegExp(r'^\d{2}:\d{2}').hasMatch(s)) return null;
  return TimeOfDay(hour: int.parse(s.substring(0, 2)), minute: int.parse(s.substring(3, 5)));
}

DateTime? _crParseDate(dynamic s) {
  if (s == null) return null;
  final RegExpMatch? m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch('$s');
  if (m == null) return null;
  return DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
}

const String _kCrackListCache = 'crack_list_v1';
/// S4: انتخاب کاربر برای «ورود به‌صورت درصد»؛ روی دستگاه ماندگار (پیش‌فرض خاموش).
const String _kCrackPctPref = 'crack_pct_mode_v1';

class _StopRow {
  final TextEditingController reason = TextEditingController();
  final TextEditingController minutes = TextEditingController();
  void dispose() {
    reason.dispose();
    minutes.dispose();
  }
}

/// فیلدهای متنی (کلید JSON ⇒ برچسب) و عددی؛ ترتیب = ترتیب ستون‌های اکسل.
const List<List<String>> _kTextFields = <List<String>>[
  <String>['shift', 'شیفت (D)'],
  <String>['operator_name', 'نام اپراتور (E)'],
  <String>['customer_name', 'نام مشتری (F)'],
  <String>['line_code', 'کد خط (G)'],
  <String>['pistachio_type', 'کد/نوع پسته (H)'],
  <String>['customer_code', 'کد مشتری (J)'],
  <String>['shipment_code', 'کد محموله (K)'],
  <String>['ounce_by', 'اونس‌کننده (Q)'],
  <String>['machine_setting', 'تنظیم/سرعت دستگاه (Y)'],
  <String>['analyst', 'آنالیزکننده (AI)'],
  <String>['note', 'یادداشت (اختیاری)'],
];

const List<List<String>> _kNumFields = <List<String>>[
  <String>['bale_count', 'تعداد عدل (I)'],
  <String>['input_kg', 'وزن کل ورودی — کیلو (L)'],
  <String>['gram_pct', 'درصد گرم مغز (M)'],
  <String>['moisture_pct', 'رطوبت ٪ (O)'],
  <String>['fines_pct', 'درصد ریز (P)'],
  <String>['run_minutes', 'زمان واقعی کارکرد — دقیقه (T)'],
  <String>['kernel_kg', 'وزن مغز خروجی — کیلو (U)'],
  <String>['hull_kg', 'وزن پوست (V)'],
  <String>['soil_kg', 'وزن خاک (W)'],
  <String>['hull_left_kg', 'وزن پوست باقی‌مانده (Z)'],
  <String>['sound_kg', 'وزن مغز سالم (AA)'],
  <String>['wheat_kg', 'گندمی و موشو (AB)'],
  <String>['super_fine_kg', 'سوپر خیلی ریز (AC)'],
  <String>['flower_kg', 'گلدار (AD)'],
  <String>['split_kg', 'لپه و شکسته (AE)'],
  <String>['unbreakable_kg', 'ناشکن (AF)'],
  <String>['pink_kg', 'کال سوپر و صورتی (AG)'],
  <String>['waste_kernel_kg', 'مغز ضایعاتی (AH)'],
  <String>['initial_kernel_kg', 'مغز اولیه — کیلو (AK)'],
  <String>['power_kwh', 'مصرف برق — kWh (AM)'],
];

// ---------------------------------------------------------------------------
// فرم
// ---------------------------------------------------------------------------

class CrackFormScreen extends StatefulWidget {
  /// null = ثبت جدید؛ وگرنه ردیف خروجی crack_list/crack_get (ویرایش).
  final Map<String, dynamic>? existing;

  /// بعد از ثبت موفق (یا صف‌شدن) در حالت تب؛ اگر null صفحه با true بسته می‌شود.
  final VoidCallback? onSaved;
  const CrackFormScreen({super.key, this.existing, this.onSaved});

  @override
  State<CrackFormScreen> createState() => _CrackFormScreenState();
}

class _CrackFormScreenState extends State<CrackFormScreen> {
  final Map<String, TextEditingController> _t = <String, TextEditingController>{
    for (final List<String> f in _kTextFields) f[0]: TextEditingController(),
  };
  final Map<String, TextEditingController> _n = <String, TextEditingController>{
    for (final List<String> f in _kNumFields) f[0]: TextEditingController(),
  };
  /// S4: متن درصدی هر فیلد مجاز (فقط برای نمایش/ورود؛ حقیقتِ ذخیره همیشه کیلو در [_n] است).
  final Map<String, TextEditingController> _p = <String, TextEditingController>{
    for (final String k in kCrPctKeys) k: TextEditingController(),
  };
  final Set<String> _pctTouched = <String>{}; // فیلدهایی که کاربر درصدشان را دست زده؛ بقیه از kg/L مشتق‌اند
  bool _pctPref = false;
  final List<_StopRow> _stops = <_StopRow>[];
  late final String _uid;
  DateTime _runDate = DateTime.now();
  DateTime? _endDate;
  TimeOfDay? _start;
  TimeOfDay? _end;
  bool _saving = false;

  // --- S6: ثبت خروجی‌ها به‌عنوان لات جدید (فقط workshop.manage؛ پیش‌فرض خاموش؛ سرور مرجع نهایی است) ---
  bool _lotsOn = false;
  bool _removeLots = false;
  final Set<String> _lotFields = <String>{};
  String? _lotSource; // شناسهٔ سرورِ لات مبدأ
  int? _lotCat; // شناسهٔ سرورِ دسته؛ null = هم‌دستهٔ لات مبدأ
  String? _lotWh; // uid انبار؛ null = انبار اصلی
  bool _lotsLoading = false;
  bool _lotOptsLoaded = false;
  String? _lotsLoadError;
  List<_LotSrc> _lotSources = <_LotSrc>[];
  List<_LotCat> _lotCats = <_LotCat>[];
  List<WhOption> _lotWhs = <WhOption>[];

  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    _uid = ReturnsHelp.newUid('cr');
    _loadPctPref();
    final Map<String, dynamic>? e = widget.existing;
    if (e == null) return;
    _runDate = _crParseDate(e['run_date']) ?? DateTime.now();
    _endDate = _crParseDate(e['end_date']);
    _start = _crParseTime('${e['start_time'] ?? ''}');
    _end = _crParseTime('${e['end_time'] ?? ''}');
    _t.forEach((String k, TextEditingController c) => c.text = '${e[k] ?? ''}');
    _n.forEach((String k, TextEditingController c) => c.text = e[k] is num ? _crFmt(e[k] as num) : '');
    final dynamic st = e['stops'];
    if (st is List) {
      for (final dynamic s in st) {
        if (s is! Map) continue;
        final _StopRow r = _StopRow();
        r.reason.text = '${s['reason'] ?? ''}';
        r.minutes.text = s['minutes'] is num ? _crFmt(s['minutes'] as num) : '';
        _stops.add(r);
      }
    }
  }

  @override
  void dispose() {
    for (final TextEditingController c in _t.values) {
      c.dispose();
    }
    for (final TextEditingController c in _n.values) {
      c.dispose();
    }
    for (final TextEditingController c in _p.values) {
      c.dispose();
    }
    for (final _StopRow r in _stops) {
      r.dispose();
    }
    super.dispose();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  // --- S4: ورود درصدی (کیلو همیشه حقیقت است؛ ذخیره/سرور/محاسبات بدون تغییر) ---

  double? get _inputKg => _crNum(_n['input_kg']!.text);

  /// L>۰ (روی گرم صحیح).
  bool get _pctAvailable => wsGrams(_inputKg) > 0;

  /// حالت درصدی فقط وقتی فعال است که کاربر روشن کرده باشد و L>۰ باشد.
  bool get _pctActive => _pctPref && _pctAvailable;

  Future<void> _loadPctPref() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      final bool v = sp.getBool(_kCrackPctPref) ?? false;
      if (!mounted || v == _pctPref) return;
      setState(() {
        _pctPref = v;
        _pctRefresh();
      });
    } catch (_) {
      // ذخیره‌سازی در دسترس نیست ⇒ پیش‌فرض (خاموش)
    }
  }

  Future<void> _setPctPref(bool v) async {
    setState(() {
      _pctPref = v;
      _pctTouched.clear(); // همهٔ درصدها از kg فعلی مشتق می‌شوند
      _pctRefresh();
    });
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      await sp.setBool(_kCrackPctPref, v);
    } catch (_) {}
  }

  /// درصدِ نمایشیِ مشتق از kg/L (برای فیلد دست‌نخورده)؛ بدون اثر بر مقدار ذخیره.
  void _pctSyncFromKg(String key) {
    final double? pct = crKgToPct(_inputKg, _crNum(_n[key]!.text));
    _p[key]!.text = pct == null ? '' : _crFmt(pct);
  }

  /// کاربر درصد را نوشته ⇒ kg = round(L×pct/100, 3). خالی/«-» ⇒ خالی؛ نامعتبر ⇒ kg خالی (ثبت با پیام رد می‌شود).
  void _pctApply(String key) {
    final String raw = _p[key]!.text;
    final double? kg = crPctToKg(_inputKg, _crNum(raw));
    _n[key]!.text = (crIsBlank(raw) || kg == null) ? '' : _crFmt(kg);
  }

  /// با تغییر L یا تغییر حالت: فیلد دست‌خورده از درصدش kg تازه می‌گیرد؛ بقیه درصدشان از kg مشتق می‌شود.
  void _pctRefresh() {
    if (!_pctActive) return;
    for (final String k in kCrPctKeys) {
      if (_pctTouched.contains(k)) {
        _pctApply(k);
      } else {
        _pctSyncFromKg(k);
      }
    }
  }

  /// null = معتبر. فقط فیلد دست‌خورده بررسی می‌شود (ردیف قدیمی با kg>L نباید بی‌دلیل رد شود).
  String? _pctError(String key) {
    if (!_pctActive || !_pctTouched.contains(key)) return null;
    final String raw = _p[key]!.text;
    if (crIsBlank(raw)) return null;
    final double? v = _crNum(raw);
    if (v == null) return 'مقدار عددی نامعتبر';
    if (!crPctOk(v)) return 'درصد باید بین ۰ و ۱۰۰ باشد';
    return null;
  }

  double? _pctValue(String key) {
    if (_pctTouched.contains(key)) {
      final double? v = _crNum(_p[key]!.text);
      return crPctOk(v) ? v : null;
    }
    return crKgToPct(_inputKg, _crNum(_n[key]!.text));
  }

  /// جمع درصد U+V+W (برای هشدار غیرمسدود)؛ هیچ‌کدام مقدار نداشت ⇒ null.
  double? _pctSumUvw() {
    double sum = 0;
    bool any = false;
    for (final String k in const <String>['kernel_kg', 'hull_kg', 'soil_kg']) {
      final double? v = _pctValue(k);
      if (v == null) continue;
      sum += v;
      any = true;
    }
    return any ? sum : null;
  }

  List<double> get _stopMinutes => <double>[
        for (final _StopRow r in _stops) if ((_crNum(r.minutes.text) ?? 0) > 0) _crNum(r.minutes.text)!,
      ];

  CrackCalc get _calc => crackCalc(
        inputKg: _crNum(_n['input_kg']!.text),
        gramPct: _crNum(_n['gram_pct']!.text),
        kernelKg: _crNum(_n['kernel_kg']!.text),
        runMinutes: _crNum(_n['run_minutes']!.text),
        initialKernelKg: _crNum(_n['initial_kernel_kg']!.text),
        stopMinutes: _stopMinutes,
        hullKg: _crNum(_n['hull_kg']!.text),
        soilKg: _crNum(_n['soil_kg']!.text),
        soundKg: _crNum(_n['sound_kg']!.text),
        wheatKg: _crNum(_n['wheat_kg']!.text),
        superFineKg: _crNum(_n['super_fine_kg']!.text),
        flowerKg: _crNum(_n['flower_kg']!.text),
        splitKg: _crNum(_n['split_kg']!.text),
        unbreakableKg: _crNum(_n['unbreakable_kg']!.text),
        pinkKg: _crNum(_n['pink_kg']!.text),
        wasteKernelKg: _crNum(_n['waste_kernel_kg']!.text),
      );

  Future<void> _pickRun(bool isEnd) async {
    final DateTime? d = await pickDate(context, initial: isEnd ? (_endDate ?? _runDate) : _runDate);
    if (d == null) return;
    setState(() => isEnd ? _endDate = d : _runDate = d);
  }

  Future<void> _pickTime(bool isEnd) async {
    final TimeOfDay? t = await showTimePicker(
      context: context,
      initialTime: (isEnd ? _end : _start) ?? TimeOfDay.now(),
      builder: (BuildContext c, Widget? w) => MediaQuery(data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true), child: w ?? const SizedBox()),
    );
    if (t == null) return;
    setState(() => isEnd ? _end = t : _start = t);
  }

  /// پیشنهاد (قابل‌ویرایش): T = (پایان − شروع) − مجموع توقف؛ عبور از نیمه‌شب و تاریخ پایان در نظر گرفته می‌شود.
  double? _suggestedRunMinutes() {
    if (_start == null || _end == null) return null;
    final int days = _endDate == null ? 0 : DateTime(_endDate!.year, _endDate!.month, _endDate!.day).difference(DateTime(_runDate.year, _runDate.month, _runDate.day)).inDays;
    int span = days * 1440 + (_end!.hour * 60 + _end!.minute) - (_start!.hour * 60 + _start!.minute);
    if (span < 0) span += 1440; // شیفت شب
    final double v = span - _calc.stopTotalMin;
    return v < 0 ? 0 : v;
  }

  void _applySuggestion() {
    final double? v = _suggestedRunMinutes();
    if (v == null) return _snack('ساعت شروع و پایان را وارد کنید');
    setState(() => _n['run_minutes']!.text = _crFmt(double.parse(v.toStringAsFixed(2))));
  }

  /// S2: پر کردن «مغز خروجی (U)» از جمع تفکیک AA..AH — فقط با کلیک کاربر و با اعلام صریح (بی‌صدا نیست).
  void _fillKernelFromSub() {
    final double? sub = _calc.subSumKg;
    if (sub == null || sub <= 0 || !crIsBlank(_n['kernel_kg']!.text)) return;
    setState(() {
      _n['kernel_kg']!.text = _crFmt(double.parse(sub.toStringAsFixed(3)));
      _pctTouched.remove('kernel_kg');
      if (_pctActive) _pctSyncFromKg('kernel_kg');
    });
    _snack('مغز خروجی با جمع تفکیک پر شد: ${faNum(sub, dec: 3)} کیلو');
  }

  Widget _warnLine(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 20),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold))),
        ]),
      );

  /// S2: هشدارهای غیرمسدودکننده (ثبت همیشه ممکن است).
  Widget _warnings(CrackCalc c) {
    final List<Widget> w = <Widget>[
      if (c.subMismatch == true) _warnLine('مغز خروجی با جمع تفکیک نمی‌خواند (جمع تفکیک: ${faNum(c.subSumKg ?? 0, dec: 3)} کیلو)'),
      if (c.overOutput) _warnLine('جمع خروجی‌ها از ورودی بیشتر است'),
      if (_pctActive && (_pctSumUvw() ?? 0) > 100 + 1e-9) _warnLine('جمع درصدهای مغز + پوست + خاک (U+V+W) برابر ${faNum(_pctSumUvw()!, dec: 2)}٪ است و از ۱۰۰٪ بیشتر است'),
    ];
    if (w.isEmpty) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      color: Colors.orange.withOpacity(0.10),
      child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: w)),
    );
  }

  /// S2: کارت «تراز واقعی» (فقط‌خواندنی؛ آینهٔ pb_cr_calc).
  Widget _realBalanceCard(CrackCalc c) {
    String kgPct(double? kg, double? pct) {
      if (kg == null) return '';
      return '${faNum(kg, dec: 3)} کیلو${pct == null ? '' : ' (${faNum(pct, dec: 2)}٪)'}';
    }

    String pct(double? v) => v == null ? '' : '${faNum(v, dec: 2)}٪';
    return _group('تراز واقعی', <Widget>[
      _readOnly('افت واقعی = L−(U+V+W)', kgPct(c.realLossKg, c.realLossPct)),
      _gap(),
      _readOnly('کسری مغز نسبت به برآورد (N−U)', kgPct(c.shortfallKg, c.shortfallPct)),
      _gap(),
      _row2(_readOnly('سالم از ورودی (AA÷L)', pct(c.soundPctInput)), _readOnly('سالم از مغز (AA÷U)', pct(c.soundPctKernel))),
    ]);
  }

  Map<String, dynamic>? _buildPayload() {
    if (_pctActive) {
      // S4: درصدِ دست‌خورده باید ۰..۱۰۰ و عددی باشد؛ پس از آن فقط kg ذخیره می‌شود.
      for (final String k in kCrPctKeys) {
        final String? err = _pctError(k);
        if (err != null) {
          final String label = _kNumFields.firstWhere((List<String> f) => f[0] == k)[1];
          _snack('$err: $label');
          return null;
        }
      }
    }
    final Map<String, dynamic> p = <String, dynamic>{
      'run_date': ReturnsHelp.iso(_runDate),
      'end_date': _endDate == null ? '' : ReturnsHelp.iso(_endDate!),
      'start_time': _start == null ? '' : _crTime(_start!),
      'end_time': _end == null ? '' : _crTime(_end!),
    };
    for (final MapEntry<String, TextEditingController> e in _t.entries) {
      p[e.key] = e.value.text.trim();
    }
    for (final List<String> f in _kNumFields) {
      final String raw = _n[f[0]]!.text.trim();
      final double? v = _crNum(raw);
      if (!crIsBlank(raw) && v == null) {
        _snack('مقدار عددی نامعتبر: ${f[1]}');
        return null;
      }
      if (v != null && v < 0) {
        _snack('مقدار منفی مجاز نیست: ${f[1]}');
        return null;
      }
      if ((f[0] == 'gram_pct' || f[0] == 'moisture_pct' || f[0] == 'fines_pct') && v != null && v > 100) {
        _snack('درصد نمی‌تواند بیشتر از ۱۰۰ باشد: ${f[1]}');
        return null;
      }
      p[f[0]] = v; // null = خالی
    }
    p['input_kg'] ??= 0.0;
    final List<Map<String, dynamic>> stops = <Map<String, dynamic>>[];
    for (final _StopRow r in _stops) {
      final String reason = r.reason.text.trim();
      final String mRaw = r.minutes.text.trim();
      if (reason.isEmpty && mRaw.isEmpty) continue; // ردیف خالی
      final double? m = _crNum(mRaw);
      if (reason.isEmpty || m == null || m <= 0) {
        _snack('هر توقف باید علت و دقیقهٔ بیشتر از صفر داشته باشد');
        return null;
      }
      stops.add(<String, dynamic>{'reason': reason, 'minutes': m});
    }
    p['stops'] = stops;
    final String? lotsErr = _addLotsPayload(p); // S6
    if (lotsErr != null) {
      _snack(lotsErr);
      return null;
    }
    return p;
  }

  Future<void> _submit() async {
    final Map<String, dynamic>? p = _buildPayload();
    if (p == null) return;
    final bool lotsAsked = p['lots'] is Map; // S6
    setState(() => _saving = true);
    try {
      ProcWriteResult r;
      if (_editing) {
        p['id'] = widget.existing!['id'];
        r = await ProcessingStore.writeWithResult('workshop.crack_update', p, 'خط شکست: ویرایش');
      } else {
        p['uid'] = _uid; // ایدمپوتنت: تکرار ارسال/صف آفلاین ردیف دوم نمی‌سازد
        r = await ProcessingStore.writeWithResult('workshop.crack_create', p, 'خط شکست: ${jalaliDateFromDt(_runDate)}');
      }
      if (!mounted) return;
      if (lotsAsked && r.queued) {
        // ساخت/حذف لات سمت سرور است؛ تا همگام‌سازی نه کدی هست نه لاتی
        await _msgDialog('در انتظار همگام‌سازی', 'گزارش آفلاین ذخیره شد. لات‌ها فقط پس از اتصال و همگام‌سازی در سرور ساخته (یا حذف) می‌شوند و کدشان آن‌جا مشخص می‌شود؛ بعد از آن در جزئیات همین گزارش می‌بینید. اگر سرور آن را رد کند، پیامش در فهرست گزارش‌ها می‌آید.');
      } else if (lotsAsked) {
        await _msgDialog('ثبت شد', _lotsResultText(p['lots'] as Map<String, dynamic>, r.data));
      } else {
        _snack(r.queued ? 'آفلاین ذخیره شد؛ پس از اتصال ارسال می‌شود' : (_editing ? 'ویرایش شد' : 'ثبت شد'));
      }
      if (!mounted) return;
      if (widget.onSaved != null) {
        widget.onSaved!();
      } else {
        Navigator.pop(context, true);
      }
    } on StockApiException catch (e) {
      if (!mounted) return;
      if (lotsAsked || _hasExistingLots) {
        // پیام‌های رد S5 (لات فروخته‌شده، موجودی ناکافی، مجوز، …) طولانی‌اند؛ در دیالوگ می‌آیند
        await _msgDialog('ثبت نشد', '${e.message}\n\nهیچ تغییری ذخیره نشد.');
      } else {
        _snack(e.message);
      }
    } catch (e) {
      _snack('خطا: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // --- S6: لات‌های خروجی ---

  bool get _canLots => StaffPerms.I.can('workshop.manage');

  List<Map<String, dynamic>> get _existingLots => widget.existing?['lots'] is List ? ReturnsHelp.maps(widget.existing!['lots']) : <Map<String, dynamic>>[];

  bool get _hasExistingLots => _existingLots.isNotEmpty;

  Map<String, double?> get _kgByField => <String, double?>{for (final String k in kCrLotLabels.keys) k: _crNum(_n[k]!.text)};

  CrLotsPlan get _lotsPlanNow => crLotsPlan(_kgByField, _lotFields);

  _LotSrc? get _selectedSource {
    for (final _LotSrc s in _lotSources) {
      if (s.id == _lotSource) return s;
    }
    return null;
  }

  void _setLotsOn(bool v) {
    setState(() => _lotsOn = v);
    if (v) _loadLotOptions();
  }

  /// لات‌های مبدأ از workshop.lots (مانده از سرور)؛ اگر مجوز/اتصال نبود ⇒ فهرست محلی با شناسهٔ سرور. دسته و انبار از دادهٔ محلی.
  Future<void> _loadLotOptions() async {
    if (_lotOptsLoaded || _lotsLoading) return;
    setState(() {
      _lotsLoading = true;
      _lotsLoadError = null;
    });
    final List<_LotSrc> srcs = <_LotSrc>[];
    String? err;
    try {
      final Map<String, dynamic> r = await StockApi.call('workshop.lots');
      for (final Map<String, dynamic> l in ReturnsHelp.maps(r['items'])) {
        final double rem = ReturnsHelp.d(l['remaining']);
        if (rem <= 0) continue;
        srcs.add(_LotSrc('${l['id']}', '${l['code'] ?? ''} · ${l['type_name'] ?? ''} · ${faNum(rem, dec: 3)} کیلو', rem));
      }
    } on StockApiException catch (e) {
      try {
        for (final Map<String, dynamic> r in await AppDb.I.inventoryAll()) {
          final double rem = ReturnsHelp.d(r['remaining']);
          if (rem <= 0 || ReturnsHelp.d(r['is_mix']) == 3) continue;
          final int lid = (r['id'] as num).toInt();
          final int? sid = await AppDb.I.serverIdOf('pur', lid) ?? await AppDb.I.aliasOf('pur', lid);
          if (sid == null || sid <= 0) continue; // هنوز به سرور نرسیده
          srcs.add(_LotSrc('$sid', '${r['code'] ?? ''} · ${r['type_name'] ?? ''} · ${faNum(rem, dec: 3)} کیلو', rem));
        }
      } catch (_) {}
      if (srcs.isEmpty) err = e.message;
    }
    final List<_LotCat> cats = <_LotCat>[];
    try {
      for (final Map<String, dynamic> c in await AppDb.I.categories()) {
        final int lid = (c['id'] as num).toInt();
        final int? sid = await AppDb.I.serverIdOf('cat', lid) ?? await AppDb.I.aliasOf('cat', lid);
        if (sid == null || sid <= 0) continue;
        cats.add(_LotCat(sid, '${c['name'] ?? ''}'));
      }
    } catch (_) {}
    List<WhOption> whs = <WhOption>[];
    try {
      whs = await StockLookup.warehouses();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _lotSources = srcs;
      _lotCats = cats;
      _lotWhs = whs;
      _lotsLoadError = err;
      _lotOptsLoaded = err == null;
      _lotsLoading = false;
      if (_lotSource != null && _selectedSource == null) _lotSource = null;
    });
  }

  Widget _lotsRedLine(String t) => Padding(padding: const EdgeInsets.only(top: 6), child: Text(t, style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)));

  /// بخش «لات‌های ساخته‌شده» (ردیف دارای لات) یا سوییچ ساخت لات (ردیف بدون لات؛ فقط مجاز به workshop.manage).
  Widget _lotsCard() {
    final List<Map<String, dynamic>> made = _existingLots;
    if (made.isNotEmpty) {
      return _group('لات‌های ساخته‌شده', <Widget>[
        for (final Map<String, dynamic> l in made)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: <Widget>[
              Expanded(child: Text('${l['code'] ?? ''} · ${kCrLotLabels['${l['field_key']}'] ?? '${l['field_key']}'}', style: const TextStyle(fontWeight: FontWeight.bold))),
              Text('${faNum(ReturnsHelp.d(l['kg']), dec: 3)} کیلو'),
            ]),
          ),
        if (_canLots) ...<Widget>[
          const Text('ویرایش مقدار خروجی‌های لات‌شده، لات‌ها را به‌روز می‌کند (اگر دست‌نخورده باشند؛ کد لات ممکن است عوض شود).'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('حذف لات‌های ساخته‌شده هنگام ذخیره'),
            subtitle: const Text('فقط اگر فروخته/منتقل/مصرف نشده باشند؛ وزن به لات مبدأ برمی‌گردد. در غیر این صورت سرور رد می‌کند.'),
            value: _removeLots,
            onChanged: (bool v) => setState(() => _removeLots = v),
          ),
        ] else
          const Text('ویرایش مقدار خروجی‌های لات‌شده فقط با مجوز مدیریت کارگاه ممکن است.'),
      ]);
    }
    if (!_canLots) return const SizedBox.shrink();
    final CrLotsPlan plan = _lotsPlanNow;
    final _LotSrc? src = _selectedSource;
    final List<Widget> boxes = <Widget>[];
    for (final MapEntry<String, String> e in kCrLotLabels.entries) {
      final double? kg = _crNum(_n[e.key]!.text);
      if (wsGrams(kg) <= 0) continue;
      final bool checked = _lotFields.contains(e.key);
      final bool conflict = !checked && crLotsConflict(_lotFields, e.key);
      boxes.add(CheckboxListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: checked,
        onChanged: conflict
            ? null
            : (bool? v) => setState(() {
                  if (v == true) {
                    _lotFields.add(e.key);
                  } else {
                    _lotFields.remove(e.key);
                  }
                }),
        title: Text('${e.value} — ${faNum(kg!, dec: 3)} کیلو'),
        subtitle: conflict ? Text(e.key == 'kernel_kg' ? 'همراه تفکیک مغز (AA..AH) لات نمی‌شود' : 'همراه مغز خروجی (U) لات نمی‌شود') : null,
      ));
    }
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('ثبت خروجی‌ها به‌عنوان لات جدید'),
            subtitle: const Text('هر خروجی انتخاب‌شده یک لات با کد جدید می‌شود؛ وزنش از «لات مبدأ» کم می‌شود'),
            value: _lotsOn,
            onChanged: _saving ? null : _setLotsOn,
          ),
          if (_lotsOn) ...<Widget>[
            const Divider(),
            const Text('خروجی‌هایی که لات می‌شوند', style: TextStyle(fontWeight: FontWeight.bold)),
            if (boxes.isEmpty) const Padding(padding: EdgeInsets.only(top: 6), child: Text('اول وزن خروجی‌ها را وارد کنید')) else ...boxes,
            const SizedBox(height: 10),
            if (_lotsLoading) const LinearProgressIndicator(),
            if (_lotsLoadError != null) ...<Widget>[
              _lotsRedLine(_lotsLoadError!),
              TextButton.icon(onPressed: _loadLotOptions, icon: const Icon(Icons.refresh), label: const Text('تلاش دوباره')),
            ],
            DropdownButtonFormField<String>(
              value: _lotSource,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'لات مبدأ (الزامی)', border: OutlineInputBorder()),
              items: <DropdownMenuItem<String>>[for (final _LotSrc s in _lotSources) DropdownMenuItem<String>(value: s.id, child: Text(s.label, overflow: TextOverflow.ellipsis))],
              onChanged: (String? v) => setState(() => _lotSource = v),
            ),
            if (src != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text('موجودی لات مبدأ: ${faNum(src.remaining, dec: 3)} کیلو')),
            _gap(),
            DropdownButtonFormField<int?>(
              value: _lotCat,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'دستهٔ لات‌ها', border: OutlineInputBorder()),
              items: <DropdownMenuItem<int?>>[
                const DropdownMenuItem<int?>(value: null, child: Text('هم‌دستهٔ لات مبدأ (پیش‌فرض)')),
                for (final _LotCat c in _lotCats) DropdownMenuItem<int?>(value: c.id, child: Text(c.name)),
              ],
              onChanged: (int? v) => setState(() => _lotCat = v),
            ),
            _gap(),
            DropdownButtonFormField<String?>(
              value: _lotWh,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'انبار لات‌ها', border: OutlineInputBorder()),
              items: <DropdownMenuItem<String?>>[
                const DropdownMenuItem<String?>(value: null, child: Text('انبار اصلی (پیش‌فرض)')),
                for (final WhOption w in _lotWhs) DropdownMenuItem<String?>(value: w.uid, child: Text(w.name)),
              ],
              onChanged: (String? v) => setState(() => _lotWh = v),
            ),
            const SizedBox(height: 10),
            if (_lotFields.isEmpty)
              const Text('خروجی‌ای انتخاب نشده است')
            else if (!plan.ok)
              _lotsRedLine(plan.error!)
            else ...<Widget>[
              Text('از لات مبدأ ${faNum(plan.totalKg, dec: 3)} کیلو کم می‌شود', style: const TextStyle(fontWeight: FontWeight.bold)),
              if (src != null && plan.totalKg > src.remaining + 1e-9) _lotsRedLine('این مقدار از موجودی لات مبدأ (${faNum(src.remaining, dec: 3)} کیلو) بیشتر است؛ سرور رد می‌کند'),
            ],
            const SizedBox(height: 6),
            const Text('کد لات‌ها را سرور تعیین می‌کند و پس از ثبتِ موفق نشان داده می‌شود. بهای لات‌ها ۰ است.', style: TextStyle(color: Colors.grey)),
          ],
        ]),
      ),
    );
  }

  /// null = معتبر (و p['lots'] در صورت لزوم پر می‌شود)؛ وگرنه پیام خطا.
  String? _addLotsPayload(Map<String, dynamic> p) {
    if (!_canLots) return null;
    if (_hasExistingLots) {
      if (_removeLots) p['lots'] = <String, dynamic>{'enabled': false};
      return null; // بدون کلید lots ⇒ سرور همان انتخاب را با وزن‌های جدید به‌روز می‌کند
    }
    if (!_lotsOn) return null;
    final CrLotsPlan plan = _lotsPlanNow;
    if (!plan.ok) return plan.error;
    if (_lotSource == null) return '«لات مبدأ» را انتخاب کنید';
    p['lots'] = <String, dynamic>{
      'enabled': true,
      'source_lot_id': int.tryParse(_lotSource!) ?? _lotSource,
      'fields': <String>[for (final CrLotItem i in plan.items) i.field],
      if (_lotCat != null) 'category_id': _lotCat,
      if (_lotWh != null) 'warehouse_uid': _lotWh,
    };
    return null;
  }

  Future<void> _msgDialog(String title, String body) => showDialog<void>(
        context: context,
        builder: (BuildContext c) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: Text(title),
            content: SingleChildScrollView(child: Text(body)),
            actions: <Widget>[TextButton(onPressed: () => Navigator.pop(c), child: const Text('باشه'))],
          ),
        ),
      );

  /// فقط پس از تأیید واقعی سرور: کدها از پاسخ می‌آیند، نه از حدس کلاینت.
  String _lotsResultText(Map<String, dynamic> lotsReq, Map<String, dynamic> data) {
    final List<Map<String, dynamic>> got = data['lots'] is List ? ReturnsHelp.maps(data['lots']) : <Map<String, dynamic>>[];
    if (lotsReq['enabled'] != true) {
      return got.isEmpty ? 'لات‌های ساخته‌شده حذف شد و وزن آن‌ها به لات مبدأ برگشت.' : 'درخواست حذف لات ارسال شد اما سرور هنوز ${faNum(got.length, dec: 0)} لات برای این گزارش گزارش می‌کند؛ جزئیات گزارش را بررسی کنید.';
    }
    final List<String> want = (lotsReq['fields'] as List<dynamic>).cast<String>();
    final Set<String> have = <String>{for (final Map<String, dynamic> l in got) '${l['field_key']}'};
    final List<String> lines = <String>[
      for (final Map<String, dynamic> l in got) '${l['code'] ?? ''} — ${kCrLotLabels['${l['field_key']}'] ?? '${l['field_key']}'} — ${faNum(ReturnsHelp.d(l['kg']), dec: 3)} کیلو',
    ];
    if (got.isEmpty) return 'گزارش ثبت شد اما سرور لاتی در پاسخ برنگرداند؛ لات‌ها را در جزئیات گزارش/انبار بررسی کنید.';
    final String miss = want.any((String f) => !have.contains(f)) ? '\n\nتوجه: همهٔ خروجی‌های انتخابی در پاسخ سرور نبود؛ جزئیات گزارش را بررسی کنید.' : '';
    return 'لات‌های جدید ساخته شد:\n${lines.join('\n')}$miss';
  }

  // --- ویجت‌های کمکی ---

  Widget _numField(String key, {bool live = true}) {
    final String label = _kNumFields.firstWhere((List<String> f) => f[0] == key)[1];
    if (_pctActive && kCrPctKeys.contains(key)) return _pctField(key, label);
    return TextField(
      controller: _n[key],
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      onChanged: (live || key == 'input_kg')
          ? (_) => setState(() {
                if (key == 'input_kg') _pctRefresh(); // S4: تغییر L ⇒ معادل‌ها دوباره
              })
          : null,
    );
  }

  /// S4: فیلد درصدی با معادل کیلویی زنده (kg = round(L×٪/۱۰۰، ۳)).
  Widget _pctField(String key, String label) {
    final String? err = _pctError(key);
    final double? kg = _crNum(_n[key]!.text);
    final bool blank = crIsBlank(_p[key]!.text);
    return TextField(
      controller: _p[key],
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: '${label.replaceAll(' — کیلو', '')} — ٪ از ورودی',
        border: const OutlineInputBorder(),
        suffixText: '٪',
        errorText: err,
        helperText: err != null || blank || kg == null ? null : '= ${faNum(kg, dec: 3)} کیلو',
      ),
      onChanged: (_) => setState(() {
        _pctTouched.add(key);
        _pctApply(key);
      }),
    );
  }

  /// S4: سوییچ «ورود به‌صورت درصد (از وزن ورودی)»؛ فقط با L>۰ فعال.
  Widget _pctSwitch() => Card(
        margin: const EdgeInsets.only(bottom: 14),
        child: SwitchListTile(
          title: const Text('ورود به‌صورت درصد (از وزن ورودی)'),
          subtitle: Text(_pctAvailable ? 'فیلدهای U, V, W, Z, AA..AH به‌صورت ٪ وارد می‌شوند؛ فقط کیلو ذخیره می‌شود' : 'اول وزن ورودی را وارد کنید'),
          value: _pctActive,
          onChanged: _pctAvailable ? _setPctPref : null,
        ),
      );

  Widget _textField(String key) {
    final String label = _kTextFields.firstWhere((List<String> f) => f[0] == key)[1];
    return TextField(controller: _t[key], decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()));
  }

  Widget _gap([double h = 10]) => SizedBox(height: h);

  Widget _readOnly(String label, String value) => InputDecorator(
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), filled: true),
        child: Text(value.isEmpty ? '—' : value),
      );

  Widget _group(String title, List<Widget> children) => Card(
        margin: const EdgeInsets.only(bottom: 14),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 10),
              ...children,
            ],
          ),
        ),
      );

  Widget _row2(Widget a, Widget b) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[Expanded(child: a), const SizedBox(width: 10), Expanded(child: b)]);

  Widget _dateBtn(String label, DateTime? d, bool isEnd) => OutlinedButton(
        onPressed: () => _pickRun(isEnd),
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: Text(d == null ? label : '$label: ${jalaliDateFromDt(d)}'),
      );

  Widget _timeBtn(String label, TimeOfDay? t, bool isEnd) => OutlinedButton(
        onPressed: () => _pickTime(isEnd),
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: Text(t == null ? label : '$label: ${toFaDigits(_crTime(t))}'),
      );

  Widget _stopsCard(CrackCalc c) => Card(
        margin: const EdgeInsets.only(bottom: 14),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('توقف‌ها', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              for (int i = 0; i < _stops.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        flex: 3,
                        child: TextField(controller: _stops[i].reason, decoration: const InputDecoration(labelText: 'علت توقف', border: OutlineInputBorder())),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: _stops[i].minutes,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(labelText: 'دقیقه', border: OutlineInputBorder()),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      IconButton(
                        tooltip: 'حذف توقف',
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: () => setState(() => _stops.removeAt(i).dispose()),
                      ),
                    ],
                  ),
                ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () => setState(() => _stops.add(_StopRow())),
                  icon: const Icon(Icons.add),
                  label: const Text('افزودن توقف'),
                ),
              ),
              Text('تعداد توقفات (AN): ${faNum(c.stopCount, dec: 0)} · مجموع: ${faNum(c.stopTotalMin, dec: 2)} دقیقه', style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final CrackCalc c = _calc;
    final double? sug = _suggestedRunMinutes();
    String kg(double? v) => v == null ? '' : '${faNum(v, dec: 3)} کیلو';
    return Scaffold(
      appBar: AppBar(title: Text(_editing ? 'ویرایش گزارش خط شکست' : 'گزارش خط شکست'), automaticallyImplyLeading: widget.onSaved == null),
      body: Directionality(
        textDirection: TextDirection.rtl,
        child: ListView(
          padding: const EdgeInsets.all(14),
          children: <Widget>[
            _group('اطلاعات کلی بار (C..K)', <Widget>[
              _row2(_dateBtn('تاریخ شروع (A)', _runDate, false), _dateBtn('تاریخ پایان (B)', _endDate, true)),
              _gap(),
              _readOnly('تاریخ میلادی (C)', ReturnsHelp.iso(_runDate)),
              _gap(),
              _row2(_textField('shift'), _textField('operator_name')),
              _gap(),
              _row2(_textField('customer_name'), _textField('line_code')),
              _gap(),
              _row2(_textField('pistachio_type'), _numField('bale_count', live: false)),
              _gap(),
              _row2(_textField('customer_code'), _textField('shipment_code')),
            ]),
            _group('اطلاعات بار ورودی به دستگاه (L..Q)', <Widget>[
              _row2(_numField('input_kg'), _numField('gram_pct')),
              _gap(),
              _readOnly('برآورد مغز خروجی (N)', kg(c.estimatedKernelKg)),
              _gap(),
              _row2(_numField('moisture_pct', live: false), _numField('fines_pct', live: false)),
              _gap(),
              _textField('ounce_by'),
            ]),
            _pctSwitch(),
            _group('اطلاعات دستگاه (R..Z)', <Widget>[
              _row2(_timeBtn('ساعت شروع (R)', _start, false), _timeBtn('ساعت پایان (S)', _end, true)),
              _gap(),
              _numField('run_minutes'),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: sug == null ? null : _applySuggestion,
                  icon: const Icon(Icons.auto_fix_high),
                  label: Text(sug == null ? 'پیشنهاد: (پایان − شروع) − توقف' : 'پیشنهاد: ${faNum(sug, dec: 2)} دقیقه = (پایان − شروع) − توقف'),
                ),
              ),
              _gap(4),
              _row2(_numField('kernel_kg'), _numField('hull_kg')),
              if (crIsBlank(_n['kernel_kg']!.text) && (c.subSumKg ?? 0) > 0)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: _fillKernelFromSub,
                    icon: const Icon(Icons.playlist_add_check),
                    label: Text('پر کردن مغز خروجی از جمع تفکیک (${faNum(c.subSumKg!, dec: 3)} کیلو)'),
                  ),
                ),
              _gap(),
              _row2(_numField('soil_kg'), _numField('hull_left_kg', live: false)),
              _gap(),
              _readOnly('ظرفیت واقعی (X)', c.capacityKgh == null ? '' : '${faNum(c.capacityKgh!, dec: 3)} کیلو/ساعت'),
              _gap(),
              _textField('machine_setting'),
            ]),
            _stopsCard(c),
            _group('وزن بار خروجی دستگاه (AA..AI)', <Widget>[
              _row2(_numField('sound_kg'), _numField('wheat_kg')),
              _gap(),
              _row2(_numField('super_fine_kg'), _numField('flower_kg')),
              _gap(),
              _row2(_numField('split_kg'), _numField('unbreakable_kg')),
              _gap(),
              _row2(_numField('pink_kg'), _numField('waste_kernel_kg')),
              _gap(),
              _textField('analyst'),
            ]),
            _group('محاسبات (AJ..AN)', <Widget>[
              _readOnly('وزن ورودی (AJ)', kg(c.inputKg)),
              _gap(),
              _numField('initial_kernel_kg'),
              _gap(),
              _readOnly('مغزِ نشده = افت + پوست + خاک (L−U)', kg(c.nonKernelKg)),
              _gap(),
              _readOnly('مغزِ نشده ٪ (از ورودی)', c.lossPct == null ? '' : '${faNum(c.lossPct!, dec: 2)}٪'),
              _gap(),
              _numField('power_kwh', live: false),
              _gap(),
              _readOnly('تعداد توقفات (AN)', faNum(c.stopCount, dec: 0)),
            ]),
            _lotsCard(), // S6
            _warnings(c),
            _realBalanceCard(c),
            _textField('note'),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _saving ? null : _submit,
              icon: const Icon(Icons.save_outlined),
              label: Text(_saving ? 'در حال ثبت…' : (_editing ? 'ذخیرهٔ ویرایش' : 'ثبت گزارش')),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// فهرست رکوردهای خود اپراتور (سرور فقط ردیف‌های خودش را برمی‌گرداند؛ مدیر همه را)
// ---------------------------------------------------------------------------

class CrackListScreen extends StatefulWidget {
  /// تغییر این عدد ⇒ بارگذاری مجدد (برای حالت تب بعد از ثبت جدید).
  final int refreshToken;
  const CrackListScreen({super.key, this.refreshToken = 0});

  @override
  State<CrackListScreen> createState() => _CrackListScreenState();
}

class _CrackListScreenState extends State<CrackListScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  int _queued = 0;
  DateTime? _from;
  DateTime? _to;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant CrackListScreen old) {
    super.didUpdateWidget(old);
    if (old.refreshToken != widget.refreshToken) _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final List<String> flushErrors = await ProcessingStore.flush();
    final int queued = (await ProcessingStore.pendingOps()).length;
    String? error;
    List<Map<String, dynamic>> items;
    try {
      final Map<String, dynamic> payload = <String, dynamic>{
        if (_from != null) 'from': ReturnsHelp.iso(_from!),
        if (_to != null) 'to': ReturnsHelp.iso(_to!),
      };
      final Map<String, dynamic> r = await StockApi.call('workshop.crack_list', payload);
      items = ReturnsHelp.maps(r['items']);
      if (_from == null && _to == null) {
        final SharedPreferences sp = await SharedPreferences.getInstance();
        await sp.setString(_kCrackListCache, jsonEncode(items));
      }
    } on StockApiException catch (e) {
      error = e.message;
      items = await _cached();
    }
    if (flushErrors.isNotEmpty && error == null) error = flushErrors.join('\n');
    if (!mounted) return;
    setState(() {
      _items = items;
      _queued = queued;
      _error = error;
      _loading = false;
    });
  }

  Future<List<Map<String, dynamic>>> _cached() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      final String? raw = sp.getString(_kCrackListCache);
      return raw == null ? <Map<String, dynamic>>[] : ReturnsHelp.maps(jsonDecode(raw));
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<void> _pick(bool from) async {
    final DateTime? d = await pickDate(context, initial: (from ? _from : _to) ?? DateTime.now());
    if (d == null) return;
    setState(() => from ? _from = d : _to = d);
    _load();
  }

  Future<void> _open(Map<String, dynamic> it) async {
    final bool? ok = await Navigator.of(context).push<bool>(MaterialPageRoute<bool>(builder: (_) => CrackFormScreen(existing: it)));
    if (ok == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('گزارش‌های خط شکست من'),
        automaticallyImplyLeading: false,
        actions: <Widget>[IconButton(tooltip: 'بازخوانی', icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      body: Directionality(
        textDirection: TextDirection.rtl,
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Row(children: <Widget>[
                Expanded(child: OutlinedButton(onPressed: () => _pick(true), child: Text(_from == null ? 'از تاریخ' : jalaliDateFromDt(_from!)))),
                const SizedBox(width: 8),
                Expanded(child: OutlinedButton(onPressed: () => _pick(false), child: Text(_to == null ? 'تا تاریخ' : jalaliDateFromDt(_to!)))),
                if (_from != null || _to != null)
                  IconButton(
                    tooltip: 'پاک‌کردن فیلتر',
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      setState(() {
                        _from = null;
                        _to = null;
                      });
                      _load();
                    },
                  ),
              ]),
            ),
            if (_queued > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Text('${faNum(_queued, dec: 0)} مورد در صف ارسال (آفلاین) است', style: const TextStyle(color: Colors.orange)),
              ),
            if (_error != null)
              Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: Text(_error!, style: const TextStyle(color: Colors.red))),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _items.isEmpty
                      ? const Center(child: Text('گزارشی ثبت نشده است'))
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.separated(
                            itemCount: _items.length,
                            separatorBuilder: (_, __) => const Divider(height: 1),
                            itemBuilder: (BuildContext c, int i) => _tile(_items[i]),
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(Map<String, dynamic> it) {
    final Map<String, dynamic> calc = it['calc'] is Map ? Map<String, dynamic>.from(it['calc'] as Map) : <String, dynamic>{};
    final List<String> head = <String>[
      jalaliDate('${it['run_date']}'),
      if ('${it['line_code'] ?? ''}'.isNotEmpty) 'خط ${it['line_code']}',
      if ('${it['pistachio_type'] ?? ''}'.isNotEmpty) '${it['pistachio_type']}',
    ];
    final List<String> sub = <String>[
      'ورودی ${faNum(ReturnsHelp.d(calc['input_kg']), dec: 3)} کیلو',
      if (it['kernel_kg'] != null) 'مغز ${faNum(ReturnsHelp.d(it['kernel_kg']), dec: 3)}',
      if (calc['capacity_kgh'] != null) 'ظرفیت ${faNum(ReturnsHelp.d(calc['capacity_kgh']), dec: 1)} کیلو/ساعت',
      if (calc['loss_pct'] != null) 'مغزِ نشده ${faNum(ReturnsHelp.d(calc['loss_pct']), dec: 2)}٪',
      'توقف ${faNum(ReturnsHelp.d(calc['stop_count']), dec: 0)}',
      if (it['lots'] is List && (it['lots'] as List).isNotEmpty) 'لات: ${ReturnsHelp.maps(it['lots']).map((Map<String, dynamic> l) => '${l['code'] ?? ''}').join('، ')}',
    ];
    return ListTile(
      title: Text(head.join(' · ')),
      subtitle: Text(sub.join(' · ')),
      trailing: const Icon(Icons.edit_outlined),
      onTap: () => _open(it),
    );
  }
}

/// S6: گزینهٔ لات مبدأ (شناسهٔ سرور + برچسب + مانده).
class _LotSrc {
  final String id;
  final String label;
  final double remaining;
  const _LotSrc(this.id, this.label, this.remaining);
}

/// S6: دستهٔ کالا (شناسهٔ سرور).
class _LotCat {
  final int id;
  final String name;
  const _LotCat(this.id, this.name);
}
