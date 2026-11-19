import 'package:flutter/material.dart';

import 'db.dart';
import 'fmt.dart' show Fmt;
import 'form_layout.dart';
import 'perms.dart';
import 'processing_ui.dart' show ProcessingStore;
import 'returns_ui.dart' show ReturnsHelp;
import 'utils.dart';
import 'widgets.dart' show JalaliDateField;
import 'warehouse_ui.dart' show StockApi, StockApiException;
import 'workshop_calc.dart';

/// کارگاه داخلی (مرحلهٔ ۱) — فرم ثبت یک عملیات: ورودی از لات‌های انبار، خروجی به تفکیک دسته (سالم، بدشکل و ریز، پوست، مغز، خاک، بدرنگ، چفت، دهنبست).
/// فاز ۱ (مجد): افت وزن = ورودی − Σ خروجی‌ها (فقط‌نمایش، زنده)؛ منفی ⇒ قرمز و دکمهٔ ثبت غیرفعال (سرور هم رد می‌کند).
/// قیمت خرید هر کیلو (V) = میانگین موزون بهای لات‌های ورودی؛ فقط‌نمایش (پیش‌نمایش محلی از قیمت لات؛ مقدار قطعی را سرور حساب می‌کند).
/// سرور: processing.create با direction=internal (api/workshop.php)؛ آفلاین از صف ProcessingStore (uid ایدمپوتنت).
/// بها (مرحلهٔ ۲): بخش «بها» فقط برای دارندهٔ price.view + workshop.cost؛ محاسبه در سرور (pb_ws_cost)، پیش‌نمایش زنده با wsCost (آینه).

String _wsEn(String s) {
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

double _wsNum(String s) => double.tryParse(_wsEn(s).trim()) ?? 0.0;

/// برای فایل‌های دیگر (فرم ویرایش بها در processing_ui).
double wsParseNum(String s) => _wsNum(s);

/// دیدن/ثبت بهای کارگاه: price.view + workshop.cost (مالک همیشه).
bool wsCanCost() => StaffPerms.I.can('price.view') && StaffPerms.I.can('workshop.cost');

/// فیلدهای قابل‌ورود بها. فاز ۱: «قیمت خرید هر کیلو» (V) دیگر وارد نمی‌شود (فقط‌نمایش با [kWsBuyLabel]).
const List<List<String>> kWsCostFields = <List<String>>[
  <String>['wage_per_kg', 'اجرت تولید هر کیلو (X؛ روی وزن ورودی)'],
  <String>['other_cost', 'سایر هزینهٔ تولید — مبلغ کل (Y)'],
];

/// برچسب فیلد فقط‌نمایش V (فرم ثبت و فرم ویرایش بها).
const String kWsBuyLabel = 'قیمت خرید هر کیلو (V) — از بهای لات‌های ورودی';

/// متن هشدار لات ورودی بی‌بها (پاسخ سرور: input_cost_warning = missing_input_cost).
const String kWsMissingInputCost = 'یکی از لات‌های ورودی بها ندارد؛ سهم آن در قیمت خرید صفر حساب شده است.';

/// فیلد فقط‌نمایش (خاکستری) با برچسب و متن.
Widget wsReadOnlyField(String label, String value, {Color? color, String? helper}) => InputDecorator(
      decoration: InputDecoration(labelText: label, helperText: helper, border: const OutlineInputBorder(), filled: true),
      child: Text(value, style: TextStyle(color: color, fontWeight: color == null ? null : FontWeight.bold)),
    );

/// یک ردیف خروجی (مرحلهٔ ۵): ۶ ردیف استاندارد + ردیف‌های «خروجی جدید» (grade=custom با نام آزاد). قیمت هر کیلو جلوی هر ردیف (به‌جز سالم).
class _WsOut {
  _WsOut(this.grade);
  final String grade;
  final TextEditingController nameCtrl = TextEditingController(); // فقط custom
  final TextEditingController kgCtrl = TextEditingController();
  final TextEditingController priceCtrl = TextEditingController(); // سالم: بدون قیمت (محاسبه‌شده)
  bool get isCustom => grade == kWsCustomGrade;
  bool get isSound => grade == 'sound';
  void dispose() {
    nameCtrl.dispose();
    kgCtrl.dispose();
    priceCtrl.dispose();
  }
}

class _WsInput {
  final TextEditingController kg = TextEditingController();
  String? lotLocalId;
  void dispose() => kg.dispose();
}

class WorkshopFormScreen extends StatefulWidget {
  const WorkshopFormScreen({super.key});

  @override
  State<WorkshopFormScreen> createState() => _WorkshopFormScreenState();
}

class _WorkshopFormScreenState extends State<WorkshopFormScreen> {
  DateTime _date = DateTime.now();
  final TextEditingController _owner = TextEditingController();
  final TextEditingController _defect = TextEditingController();
  final TextEditingController _initial = TextEditingController();
  final TextEditingController _bales = TextEditingController();
  final TextEditingController _note = TextEditingController();
  final List<_WsInput> _inputs = <_WsInput>[_WsInput()];
  final List<_WsOut> _outs = <_WsOut>[for (final String g in kWsGrades) _WsOut(g)];
  final Map<String, TextEditingController> _cost = <String, TextEditingController>{
    for (final List<String> f in kWsCostFields) f[0]: TextEditingController(),
  };
  Map<String, String> _lots = <String, String>{};
  /// قیمت هر کیلوی لات (فقط پیش‌نمایش V؛ لات‌های سرور برای اپراتور قیمت ندارند).
  Map<String, double> _lotPrice = <String, double>{};
  String _op = 'dehull';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadLots();
  }

  /// اپراتور کارگاه purchases را همگام نمی‌کند (بدون stock.view) ⇒ لات‌ها از workshop.lots (بدون قیمت) و شناسهٔ سرور مستقیم.
  bool get _serverLots => StaffPerms.I.isWorkshopOperatorOnly;

  Future<void> _loadLots() async {
    if (_serverLots) {
      try {
        final Map<String, dynamic> r = await StockApi.call('workshop.lots');
        final Map<String, String> lots = <String, String>{};
        for (final Map<String, dynamic> l in ReturnsHelp.maps(r['items'])) {
          final double rem = ReturnsHelp.d(l['remaining']);
          if (rem <= 0) continue;
          lots['${l['id']}'] = '${l['code'] ?? ''} · ${l['type_name'] ?? ''} · ${faNum(rem, dec: 3)} کیلو';
        }
        if (mounted) setState(() => _lots = lots);
      } on StockApiException catch (e) {
        _snack(e.message);
      }
      return;
    }
    final List<Map<String, dynamic>> rows = await AppDb.I.inventoryAll();
    final Map<String, String> lots = <String, String>{};
    final Map<String, double> prices = <String, double>{};
    for (final Map<String, dynamic> r in rows) {
      final double rem = ReturnsHelp.d(r['remaining']);
      if (rem <= 0 || ReturnsHelp.d(r['is_mix']) == 3) continue;
      lots['${r['id']}'] = '${r['code'] ?? ''} · ${r['type_name'] ?? ''} · ${faNum(rem, dec: 3)} کیلو';
      prices['${r['id']}'] = ReturnsHelp.d(r['price']);
    }
    if (mounted) {
      setState(() {
        _lots = lots;
        _lotPrice = prices;
      });
    }
  }

  @override
  void dispose() {
    _owner.dispose();
    _defect.dispose();
    _initial.dispose();
    _bales.dispose();
    _note.dispose();
    for (final _WsInput i in _inputs) {
      i.dispose();
    }
    for (final _WsOut o in _outs) {
      o.dispose();
    }
    for (final TextEditingController c in _cost.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  double get _inKg => _inputs.fold<double>(0.0, (double s, _WsInput i) => s + _wsNum(i.kg.text));

  /// Σ کیلوی هر دسته (همهٔ ردیف‌های custom زیر کلید 'custom' جمع می‌شوند).
  Map<String, num> get _outByGrade {
    final Map<String, num> m = <String, num>{};
    for (final _WsOut o in _outs) {
      m[o.grade] = (m[o.grade] ?? 0) + _wsNum(o.kgCtrl.text);
    }
    return m;
  }

  /// فاز ۱: افت خودکار (lossKg = null ⇒ ورودی − Σ خروجی‌ها).
  WsBalance get _balance => wsBalance(
        inputKg: _inKg,
        out: _outByGrade,
        initialKg: _initial.text.trim().isEmpty ? null : _wsNum(_initial.text),
      );

  /// پیش‌نمایش V = میانگین موزون قیمت لات‌های ورودی (آینهٔ wsInputCost). سرور مقدار قطعی را با هزینهٔ دلالی و … حساب می‌کند.
  WsInputCost get _liveV => wsInputCost(<Map<String, Object?>>[
        for (final _WsInput i in _inputs)
          if (i.lotLocalId != null && _wsNum(i.kg.text) > 0)
            <String, Object?>{
              'kg': _wsNum(i.kg.text),
              'unit_cost': _lotPrice[i.lotLocalId],
              'cost': wsR2(_wsNum(i.kg.text) * (_lotPrice[i.lotLocalId] ?? 0)),
            },
      ]);

  Future<void> _submit() async {
    if (_balance.overOutput) {
      _snack('جمع خروجی‌ها از ورودی بیشتر است');
      return;
    }
    setState(() => _saving = true);
    try {
      final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
      for (final _WsInput i in _inputs) {
        final double kg = _wsNum(i.kg.text);
        if (i.lotLocalId == null) {
          _snack('برای هر ورودی لات انبار را انتخاب کنید');
          return;
        }
        if (kg <= 0) {
          _snack('وزن هر ورودی باید بیشتر از صفر باشد');
          return;
        }
        items.add(<String, dynamic>{'purchase_id': _serverLots ? int.parse(i.lotLocalId!) : await ReturnsHelp.serverId('purchase', int.parse(i.lotLocalId!)), 'kg': kg});
      }
      final List<Map<String, dynamic>> outputs = <Map<String, dynamic>>[];
      for (final _WsOut o in _outs) {
        final double kg = _wsNum(o.kgCtrl.text);
        if (kg <= 0) continue;
        final Map<String, dynamic> row = <String, dynamic>{'grade': o.grade, 'kg': kg};
        if (o.isCustom) {
          final String nm = o.nameCtrl.text.trim();
          if (nm.isEmpty) {
            _snack('برای هر «خروجی جدید» نام وارد کنید');
            return;
          }
          row['type_name'] = nm;
        }
        if (wsCanCost() && !o.isSound && o.priceCtrl.text.trim().isNotEmpty) row['price_per_kg'] = _wsNum(o.priceCtrl.text);
        outputs.add(row);
      }
      final Map<String, dynamic> payload = <String, dynamic>{
        'uid': ReturnsHelp.newUid('ws'),
        'direction': 'internal',
        'op_type': _op,
        'date': ReturnsHelp.iso(_date),
        'owner': _owner.text.trim(),
        'defect_note': _defect.text.trim(),
        'loss_kg': _balance.lossKg, // فاز ۱: سرور نادیده می‌گیرد و خودش حساب می‌کند (فقط سازگاری با سرور قدیمی)
        'note': _note.text.trim(),
        'items': items,
        'outputs': outputs,
      };
      if (wsCanCost()) {
        for (final MapEntry<String, TextEditingController> e in _cost.entries) {
          if (e.value.text.trim().isNotEmpty) payload[e.key] = _wsNum(e.value.text); // V ارسال نمی‌شود (سرور از لات‌های ورودی حساب می‌کند)
        }
      }
      if (_initial.text.trim().isNotEmpty) payload['initial_kg'] = _wsNum(_initial.text);
      if (_bales.text.trim().isNotEmpty) payload['bale_count'] = _wsNum(_bales.text);
      final bool queued = await ProcessingStore.write('processing.create', payload, 'کارگاه داخلی: ${kWsOpLabels[_op]}');
      if (!mounted) return;
      _snack(queued ? 'آفلاین ذخیره شد؛ پس از اتصال ارسال می‌شود' : 'ثبت شد');
      Navigator.pop(context, true);
    } on StockApiException catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('خطا: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _numField(TextEditingController c, String label, {bool live = true, bool money = false}) => TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: money ? [ThousandsInputFormatter()] : null,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        onChanged: live ? (_) => setState(() {}) : null,
      );

  bool get _hasV => _liveV.buyPerKg != null;

  /// پیش‌نمایش زندهٔ بها با قیمت هر ردیف (آینهٔ pb_ws_cost).
  WsCost get _liveCost => wsCost(
        inputKg: _inKg,
        out: _outByGrade,
        pr: <String, num>{
          'buy_per_kg': _liveV.buyPerKg ?? 0,
          'wage_per_kg': _wsNum(_cost['wage_per_kg']!.text),
          'other_cost': _wsNum(_cost['other_cost']!.text),
        },
        outs: <Map<String, Object?>>[
          for (final _WsOut o in _outs) <String, Object?>{'grade': o.grade, 'kg': _wsNum(o.kgCtrl.text), 'price': o.isSound ? null : _wsNum(o.priceCtrl.text)},
        ],
      );

  /// یک سطر خروجی: [نام] [وزن] [قیمت هر کیلو] (قیمت فقط با wsCanCost؛ سالم: بهای محاسبه‌شده).
  Widget _outRow(int idx) {
    final _WsOut o = _outs[idx];
    final bool canCost = wsCanCost();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            flex: 3,
            child: o.isCustom
                ? TextField(controller: o.nameCtrl, decoration: const InputDecoration(labelText: 'نام خروجی', border: OutlineInputBorder()))
                : SizedBox(height: 56, child: Align(alignment: AlignmentDirectional.centerStart, child: Text(kWsGradeLabels[o.grade] ?? o.grade))),
          ),
          const SizedBox(width: 8),
          Expanded(flex: 2, child: _numField(o.kgCtrl, 'وزن (کیلو)')),
          if (canCost) ...<Widget>[
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: o.isSound
                  ? SizedBox(
                      height: 56,
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(!_hasV || _liveCost.costPerKgSound == null ? 'بها/کیلو: —' : 'بها/کیلو: ${Fmt.money(_liveCost.costPerKgSound!, label: false)}'),
                      ),
                    )
                  : _numField(o.priceCtrl, 'قیمت هر کیلو', money: true),
            ),
          ],
          if (o.isCustom)
            IconButton(
              tooltip: 'حذف خروجی',
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: () => setState(() => _outs.removeAt(idx).dispose()),
            ),
        ],
      ),
    );
  }

  /// پیش‌نمایش بها. V فقط‌نمایش (از لات‌های ورودی)؛ قیمت خروجی‌ها جلوی هر ردیف است.
  Widget _costCard() {
    final WsCost c = _liveCost;
    final WsInputCost v = _liveV;
    final bool hasV = _hasV;
    String m(double v) => Fmt.money(v, label: false);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('بها (${Fmt.unitLabel()})', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: wsReadOnlyField(
                kWsBuyLabel,
                v.buyPerKg == null ? '—' : m(v.buyPerKg!),
                helper: _serverLots ? 'سرور هنگام ثبت محاسبه می‌کند' : 'پیش‌نمایش؛ مقدار قطعی را سرور حساب می‌کند',
              ),
            ),
            if (v.warning != null && !_serverLots) const Padding(padding: EdgeInsets.only(bottom: 8), child: Text(kWsMissingInputCost, style: TextStyle(color: Colors.orange))),
            for (final List<String> f in kWsCostFields)
              Padding(padding: const EdgeInsets.only(bottom: 8), child: _numField(_cost[f[0]]!, f[1], money: true)),
            if (!hasV) const Text('برای پیش‌نمایش بها لات و وزن ورودی را وارد کنید.')
            else ...<Widget>[
              Text('ارزش ورودی (W): ${m(c.valueIn)} · هزینه تولید (Z): ${m(c.costTotal)}'),
              Text('ارزش محصولات فرعی (AF): ${m(c.recoveryValue)}'),
              Text('بهای تمام‌شدهٔ سالم (AG): ${m(c.costSound)}', style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(c.costPerKgSound == null ? 'بهای هر کیلو سالم: —' : 'بهای هر کیلو سالم (AH): ${m(c.costPerKgSound!)}'),
              if (c.warning != null) const Text('هشدار: ارزش فرعی بیش از هزینه است و بهای سالم منفی شد (ثبت مجاز است).', style: TextStyle(color: Colors.orange)),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final WsBalance b = _balance;
    final Color tone = b.overOutput ? Colors.red : (b.ok ? Colors.green : Colors.orange);
    final bool wide = kWideForm(context);
    final double g = kFormGap;

    final Widget head = FormSection(title: 'مشخصات عملیات', children: <Widget>[
      FormGrid(gap: 12, minColWidth: 260, children: <Widget>[
        Padding(
          padding: EdgeInsets.only(bottom: g),
          child: DropdownButtonFormField<String>(
            value: _op,
            decoration: const InputDecoration(labelText: 'نوع عملیات', border: OutlineInputBorder()),
            items: <DropdownMenuItem<String>>[
              for (final String k in kWsOpTypes) DropdownMenuItem<String>(value: k, child: Text(kWsOpLabels[k] ?? k)),
            ],
            onChanged: (String? v) => setState(() => _op = v ?? 'dehull'),
          ),
        ),
        Padding(
          padding: EdgeInsets.only(bottom: g),
          child: JalaliDateField(label: 'تاریخ', value: _date, onChanged: (DateTime d) => setState(() => _date = d)),
        ),
        Padding(
          padding: EdgeInsets.only(bottom: g),
          child: TextField(controller: _owner, decoration: const InputDecoration(labelText: 'مالک', border: OutlineInputBorder())),
        ),
        Padding(
          padding: EdgeInsets.only(bottom: g),
          child: TextField(controller: _defect, decoration: const InputDecoration(labelText: 'ایراد بار (اختیاری)', border: OutlineInputBorder())),
        ),
        Padding(padding: EdgeInsets.only(bottom: g), child: _numField(_initial, 'وزن خالص اولیه (کیلو)')),
        Padding(padding: EdgeInsets.only(bottom: g), child: _numField(_bales, 'تعداد عدل', live: false)),
      ]),
    ]);

    final Widget inputs = FormSection(title: 'ورودی از انبار', children: <Widget>[
      for (int idx = 0; idx < _inputs.length; idx++)
        Padding(
          padding: EdgeInsets.only(bottom: g),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                flex: 3,
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  value: _inputs[idx].lotLocalId,
                  decoration: const InputDecoration(labelText: 'لات', border: OutlineInputBorder()),
                  items: <DropdownMenuItem<String>>[
                    for (final MapEntry<String, String> e in _lots.entries)
                      DropdownMenuItem<String>(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (String? v) => setState(() => _inputs[idx].lotLocalId = v),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(flex: 2, child: _numField(_inputs[idx].kg, 'وزن (کیلو)')),
              if (_inputs.length > 1)
                IconButton(
                  tooltip: 'حذف ورودی',
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () => setState(() => _inputs.removeAt(idx).dispose()),
                ),
            ],
          ),
        ),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          onPressed: () => setState(() => _inputs.add(_WsInput())),
          icon: const Icon(Icons.add),
          label: const Text('ورودی دیگر'),
        ),
      ),
    ]);

    final Widget outputs = FormSection(title: 'خروجی (به موجودی برمی‌گردد)', children: <Widget>[
      for (int idx = 0; idx < _outs.length; idx++) _outRow(idx),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          onPressed: () => setState(() => _outs.add(_WsOut(kWsCustomGrade))),
          icon: const Icon(Icons.add),
          label: const Text('افزودن خروجی جدید'),
        ),
      ),
      Padding(
        padding: EdgeInsets.only(bottom: g),
        child: wsReadOnlyField(
          'افت وزن (کیلو) — ورودی − جمع خروجی‌ها',
          '${faNum(b.lossKg, dec: 3)}${b.lossPct == null ? '' : '  (${faNum(b.lossPct!, dec: 1)}٪)'}',
          color: b.overOutput ? Colors.red : null,
          helper: b.overOutput ? 'جمع خروجی‌ها از ورودی بیشتر است' : 'خودکار؛ به موجودی برنمی‌گردد',
        ),
      ),
    ]);

    final Widget balance = Card(
      color: tone.withOpacity(0.12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(b.label, style: TextStyle(fontWeight: FontWeight.bold, color: tone)),
            Text('ورودی ${faNum(b.inputKg, dec: 3)} · جمع خروجی ${faNum(b.inputKg - b.lossKg, dec: 3)} · افت ${faNum(b.lossKg, dec: 3)} کیلو'),
            if (b.lossPct != null) Text('درصد افت: ${faNum(b.lossPct!, dec: 1)}٪'),
            if (b.soundPct != null) Text('درصد سالم: ${faNum(b.soundPct!, dec: 1)}٪'),
            if (b.undeliveredKg != null) Text('مانده تحویل‌نشده: ${faNum(b.undeliveredKg!, dec: 3)} کیلو'),
            if (b.overOutput) const Text('ثبت ممکن نیست: وزن خروجی‌ها را اصلاح کنید.', style: TextStyle(color: Colors.red)),
          ],
        ),
      ),
    );

    final Widget note = Padding(
      padding: EdgeInsets.only(bottom: g),
      child: TextField(controller: _note, decoration: const InputDecoration(labelText: 'یادداشت (اختیاری)', border: OutlineInputBorder())),
    );

    final Widget submit = FilledButton.icon(
      onPressed: (_saving || _balance.overOutput) ? null : _submit,
      icon: const Icon(Icons.save_outlined),
      label: Text(_saving ? 'در حال ثبت…' : 'ثبت عملیات'),
    );

    return FormPage(
      title: 'عملیات کارگاه داخلی',
      actions: <Widget>[submit],
      children: <Widget>[
        head,
        if (wide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: inputs),
              const SizedBox(width: 8),
              Expanded(flex: 2, child: outputs),
            ],
          )
        else ...<Widget>[inputs, outputs],
        if (wide && wsCanCost())
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: balance),
              const SizedBox(width: 8),
              Expanded(child: _costCard()),
            ],
          )
        else ...<Widget>[
          balance,
          if (wsCanCost()) ...<Widget>[SizedBox(height: g), _costCard()],
        ],
        SizedBox(height: g),
        note,
      ],
    );
  }
}
