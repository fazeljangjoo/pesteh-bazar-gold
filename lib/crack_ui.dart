import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'processing_ui.dart' show ProcessingStore;
import 'returns_ui.dart' show ReturnsHelp;
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;
import 'widgets.dart' show pickDate;
import 'workshop_calc.dart';

/// کارگاه — مرحلهٔ ۳-ب: «گزارش خط شکست» (فرم نوبت کار دستگاه شکست؛ برگهٔ اکسل A..AP).
/// سرور: workshop.crack_create/update/list (api/workshop_crack.php). هیچ فیلد قیمتی نیست و موجودی انبار اصلی را تغییر نمی‌دهد.
/// آفلاین: صف ProcessingStore (create با uid ایدمپوتنت). ستون‌های محاسباتی فقط‌خواندنی از crackCalc (آینهٔ pb_cr_calc).
/// AO حذف شده و AP (معنی تأییدنشده) عمداً در UI نشان داده نمی‌شود.
/// تاریخ: شمسی در UI، میلادی (yyyy-mm-dd) در API.

String _crEn(String s) {
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

/// خالی ⇒ null؛ نامعتبر ⇒ null.
double? _crNum(String s) {
  final String t = _crEn(s).trim();
  return t.isEmpty ? null : double.tryParse(t);
}

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
  final List<_StopRow> _stops = <_StopRow>[];
  late final String _uid;
  DateTime _runDate = DateTime.now();
  DateTime? _endDate;
  TimeOfDay? _start;
  TimeOfDay? _end;
  bool _saving = false;

  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    _uid = ReturnsHelp.newUid('cr');
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
    for (final _StopRow r in _stops) {
      r.dispose();
    }
    super.dispose();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

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

  Map<String, dynamic>? _buildPayload() {
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
      if (raw.isNotEmpty && v == null) {
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
    return p;
  }

  Future<void> _submit() async {
    final Map<String, dynamic>? p = _buildPayload();
    if (p == null) return;
    setState(() => _saving = true);
    try {
      bool queued;
      if (_editing) {
        p['id'] = widget.existing!['id'];
        queued = await ProcessingStore.write('workshop.crack_update', p, 'خط شکست: ویرایش');
      } else {
        p['uid'] = _uid; // ایدمپوتنت: تکرار ارسال/صف آفلاین ردیف دوم نمی‌سازد
        queued = await ProcessingStore.write('workshop.crack_create', p, 'خط شکست: ${jalaliDateFromDt(_runDate)}');
      }
      if (!mounted) return;
      _snack(queued ? 'آفلاین ذخیره شد؛ پس از اتصال ارسال می‌شود' : (_editing ? 'ویرایش شد' : 'ثبت شد'));
      if (widget.onSaved != null) {
        widget.onSaved!();
      } else {
        Navigator.pop(context, true);
      }
    } on StockApiException catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('خطا: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // --- ویجت‌های کمکی ---

  Widget _numField(String key, {bool live = true}) {
    final String label = _kNumFields.firstWhere((List<String> f) => f[0] == key)[1];
    return TextField(
      controller: _n[key],
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      onChanged: live ? (_) => setState(() {}) : null,
    );
  }

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
              _row2(_numField('kernel_kg'), _numField('hull_kg', live: false)),
              _gap(),
              _row2(_numField('soil_kg', live: false), _numField('hull_left_kg', live: false)),
              _gap(),
              _readOnly('ظرفیت واقعی (X)', c.capacityKgh == null ? '' : '${faNum(c.capacityKgh!, dec: 3)} کیلو/ساعت'),
              _gap(),
              _textField('machine_setting'),
            ]),
            _stopsCard(c),
            _group('وزن بار خروجی دستگاه (AA..AI)', <Widget>[
              _row2(_numField('sound_kg', live: false), _numField('wheat_kg', live: false)),
              _gap(),
              _row2(_numField('super_fine_kg', live: false), _numField('flower_kg', live: false)),
              _gap(),
              _row2(_numField('split_kg', live: false), _numField('unbreakable_kg', live: false)),
              _gap(),
              _row2(_numField('pink_kg', live: false), _numField('waste_kernel_kg', live: false)),
              _gap(),
              _textField('analyst'),
            ]),
            _group('محاسبات (AJ..AN)', <Widget>[
              _readOnly('وزن ورودی (AJ)', kg(c.inputKg)),
              _gap(),
              _numField('initial_kernel_kg'),
              _gap(),
              _row2(_readOnly('افت کیلویی (AL)', kg(c.lossKg)), _readOnly('افت درصدی', c.lossPct == null ? '' : '${faNum(c.lossPct!, dec: 2)}٪')),
              _gap(),
              _numField('power_kwh', live: false),
              _gap(),
              _readOnly('تعداد توقفات (AN)', faNum(c.stopCount, dec: 0)),
            ]),
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
      if (calc['loss_pct'] != null) 'افت ${faNum(ReturnsHelp.d(calc['loss_pct']), dec: 2)}٪',
      'توقف ${faNum(ReturnsHelp.d(calc['stop_count']), dec: 0)}',
    ];
    return ListTile(
      title: Text(head.join(' · ')),
      subtitle: Text(sub.join(' · ')),
      trailing: const Icon(Icons.edit_outlined),
      onTap: () => _open(it),
    );
  }
}
