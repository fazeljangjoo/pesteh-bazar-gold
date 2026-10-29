import 'package:flutter/material.dart';
import 'fin_block_view.dart'; // S35.T35.6f
import 'package:flutter/services.dart';

import 'db.dart';
import 'fx_doc_field.dart';
import 'form_settings.dart' show FormSettingsLocal;
import 'grade_lines_ui.dart';
import 'fx_local.dart';
import 'license_service.dart';
import 'party_field.dart';
import 'tax_choice.dart';
import 'price_table_ui.dart' show PriceSuggestionHint;
import 'utils.dart';
import 'warehouse_ui.dart';
import 'widgets.dart';

/// وزن هر گونی (کیلو) — همان مقادیر فرم خرید
const double _kSmallSackKg = 0.1;
const double _kLargeSackKg = 0.2;

/// گرد کردن به ۳ رقم اعشار (جلوگیری از خطای اعشاری مثل 999.3000000000001)
double _r3(double v) => (v * 1000).round() / 1000;

/// یکسان‌سازی «ي/ك» عربی و «ی/ک» فارسی برای جستجو
String _norm(String s) => toEnDigits(s.replaceAll('ي', 'ی').replaceAll('ك', 'ک')).trim().toLowerCase();

/// عددی که کاربر تایپ می‌کند از سقف داده‌شده (گونی باقی‌مانده) بیشتر نمی‌شود:
/// اگر بیشتر شد، خودکار روی همان سقف می‌ایستد.
class _CapFormatter extends TextInputFormatter {
  final double Function() max;
  _CapFormatter(this.max);

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final n = parseNum(newValue.text);
    if (n == null) return newValue;
    final m = max();
    if (n > m + 1e-9) {
      final t = plain(m);
      return TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
    }
    return newValue;
  }
}

/// فرم فروش — هر فروش فقط از «یک قلم انبار» (یک purchase_id) ثبت می‌شود.
/// اگر خریدار چند جنس می‌خرد، برای هر جنس یک فروش جدا ثبت کنید.
///
/// * کاربر همیشه وزن واقعی (کل، با گونی — طبق ترازو) را وارد می‌کند.
/// * گونی کوچک/بزرگِ خالی‌شده اختیاری است و سقفش دقیقاً گونی باقی‌ماندهٔ همان خرید است.
class SaleForm extends StatefulWidget {
  final int? editSaleId;
  const SaleForm({super.key, this.editSaleId});
  @override
  State<SaleForm> createState() => _SaleFormState();
}

class _SaleFormState extends State<SaleForm> with EditGuard<SaleForm> {
  final _form = GlobalKey<FormState>();
  // S35.T35.2b: weighing block (only when the «توزین» switch is on)
  bool _weighOn = false;
  bool _gradesOn = false; // S35.T35.3b
  bool _priceTableOn = false; // S35.T35.4
  final GradeLinesController _gc = GradeLinesController();
  double _sackSmallKg = _kSmallSackKg;
  double _sackLargeKg = _kLargeSackKg;
  bool _deductPct = false;
  final _tareManual = TextEditingController();
  final _deduct = TextEditingController();
  final _ticket = TextEditingController();
  final _plate = TextEditingController();
  final _driver = TextEditingController();
  // S35.T35.6d: بلوک مالی (فقط وقتی form.fin_block روشن است). وضعیت مالیاتی از TaxChoiceField می‌آید.
  bool _finOn = false;
  final _finDisc = TextEditingController();
  final _finWb = TextEditingController();
  String _finPayer = 'us';
  List<Map<String, dynamic>> _lots = [];
  int? _selId;
  bool _loading = true;
  bool _saving = false;
  bool _legacyMulti = false; // فروش قدیمیِ چندقلمی (قابل ویرایش نیست)
  String _query = '';

  final _gross = TextEditingController();
  final _small = TextEditingController();
  final _large = TextEditingController();
  final _price = TextEditingController();
  final FxDocController _fxc = FxDocController(); // S27c: ارز سند (نرخ دستی دلار حذف شد)
  bool _fxEditBlocked = false; // فروش ارزیِ ثبت‌شده فعلاً قابل ویرایش نیست (T27b.7)
  final _buyer = TextEditingController();
  final _note = TextEditingController();
  final _laborCost = TextEditingController(); // هزینه کارگر (اختیاری؛ از سود این فروش کم می‌شود)
  String? _taxStatus; // S17.T17.1b (طلایی): null = طبق سال مالی
  final _taxRate = TextEditingController();
  final _transportCost = TextEditingController(); // هزینه حمل‌ونقل / باسکول (اختیاری)
  String? _saleWh; // S01: انبار برداشت (فقط وقتی قلم در چند انبار است)

  bool get _isEdit => widget.editSaleId != null;

  @override
  void initState() {
    super.initState();
    _load();
    _loadWeighSettings(); // S35.T35.2b
    if (LicenseService.I.isFx.value) _initFx();
  }

  /// ارزهای فعال از کش دستگاه؛ سپس تازه‌سازی بی‌صدای کش (آنلاین) و دوباره‌خوانی نرخ.
  Future<void> _initFx() async {
    await _fxc.load();
    if (mounted) setState(() {});
    if (await FxLocal.refresh()) {
      await _fxc.load();
      await _fxc.resolveRate();
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _gross.dispose();
    _gc.dispose();
    _tareManual.dispose();
    _deduct.dispose();
    _ticket.dispose();
    _plate.dispose();
    _driver.dispose();
    _finDisc.dispose();
    _finWb.dispose();
    _small.dispose();
    _large.dispose();
    _price.dispose();
    _fxc.dispose();
    _buyer.dispose();
    _note.dispose();
    _laborCost.dispose();
    _taxRate.dispose();
    _transportCost.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    List<Map<String, dynamic>> l;
    int? preSel;
    var legacy = false;
    if (_isEdit) {
      final items = await AppDb.I.saleItemsOf(widget.editSaleId!);
      if (items.length != 1) {
        legacy = true;
      } else {
        preSel = (items.first['purchase_id'] as num).toInt();
      }
      l = await AppDb.I.lotsForSaleEdit(widget.editSaleId!);
      final sale = await AppDb.I.saleById(widget.editSaleId!);
      if (sale != null && !legacy) {
        _price.text = plain(sale['price'] as num);
        if (sale['ccy'] != null && (sale['ccy'] as String).isNotEmpty) _fxEditBlocked = true;
        _gross.text = plain(sale['total_weight'] as num);
        if (sale['gross_kg'] != null) { // S35.T35.2b
          _tareManual.text = sale['tare_kg'] == null ? '' : plain(sale['tare_kg'] as num);
          _deduct.text = (sale['quality_deduct_kg'] == null || (sale['quality_deduct_kg'] as num) == 0) ? '' : plain(sale['quality_deduct_kg'] as num);
          _ticket.text = (sale['weigh_ticket_no'] as String?) ?? '';
          _plate.text = (sale['vehicle_plate'] as String?) ?? '';
          _driver.text = (sale['driver_name'] as String?) ?? '';
        }
        // گونی از خودِ قلم فروش خوانده می‌شود (همان مقداری که واقعاً از انبار کم شده بود)
        final small = ((items.first['small_sacks'] as num?) ?? 0).toDouble();
        final large = ((items.first['large_sacks'] as num?) ?? 0).toDouble();
        _small.text = small == 0 ? '' : plain(small);
        _large.text = large == 0 ? '' : plain(large);
        _buyer.text = (sale['buyer'] as String?) ?? '';
        _note.text = (sale['note'] as String?) ?? '';
    _laborCost.text = sale['labor_cost'] == null ? '' : plain(sale['labor_cost'] as num);
    _taxStatus = sale['tax_status'] as String?;
    _taxRate.text = taxRateTextFromMilli(sale['tax_rate_milli']);
    _transportCost.text = sale['transport_cost'] == null ? '' : plain(sale['transport_cost'] as num);
    final Object? fd = sale['discount_amount'] ?? sale['discount']; // S35.T35.6d: prefill
    final Object? fw = sale['weighbridge_cost'];
    if (fd is num && fd > 0) _finDisc.text = plain(fd);
    if (fw is num && fw > 0) _finWb.text = plain(fw);
    _finPayer = sale['side_cost_payer'] == 'party' ? 'party' : 'us';
      }
    } else {
      l = await AppDb.I.lots();
    }
    if (!mounted) return;
    setState(() {
      _lots = l;
      _legacyMulti = legacy;
      if (preSel != null && l.any((e) => e['id'] == preSel)) _selId = preSel;
      _loading = false;
    });
  }

  // ------------------------- محاسبات -------------------------
  Map<String, dynamic>? get _selLot {
    if (_selId == null) return null;
    for (final e in _lots) {
      if (e['id'] == _selId) return e;
    }
    return null;
  }

  double get _rem => ((_selLot?['remaining'] as num?) ?? 0).toDouble();
  double get _smallCap => ((_selLot?['small_left'] as num?) ?? 0).toDouble();
  double get _largeCap => ((_selLot?['large_left'] as num?) ?? 0).toDouble();

  double get _grossKg => parseNum(_gross.text) ?? 0;
  double get _smallN => parseNum(_small.text) ?? 0;
  double get _largeN => parseNum(_large.text) ?? 0;
  double get _sackTare => _smallN * (_weighOn ? _sackSmallKg : _kSmallSackKg) + _largeN * (_weighOn ? _sackLargeKg : _kLargeSackKg);
  double get _tare => (_weighOn && _tareManual.text.trim().isNotEmpty) ? (parseNum(_tareManual.text) ?? 0) : _sackTare;
  double get _deductKg {
    if (!_weighOn) return 0;
    final double v = parseNum(_deduct.text) ?? 0;
    if (!_deductPct) return v;
    final double base = _grossKg - _tare;
    return base <= 0 ? 0 : _r3(base * v / 100);
  }
  double get _net => _r3(_grossKg - _tare - _deductKg);

  Future<void> _loadWeighSettings() async {
    final bool on = await FormSettingsLocal.isOn('weigh');
    final bool gOn = await FormSettingsLocal.isOn('grades');
    final bool ptOn = await FormSettingsLocal.isOn('price_table'); // S35.T35.4
    final bool fin = await FormSettingsLocal.isOn('fin_block'); // S35.T35.6d
    List<Map<String, dynamic>> gl = <Map<String, dynamic>>[];
    if (gOn && widget.editSaleId != null) gl = await GradeLinesLocal.load('sale', widget.editSaleId!);
    final List<double> k = await FormSettingsLocal.sackKg();
    if (!mounted) return;
    setState(() {
      _gradesOn = gOn;
      _priceTableOn = ptOn;
      if (gl.isNotEmpty) _gc.loadFrom(gl);
      _weighOn = on;
      _sackSmallKg = k[0];
      _sackLargeKg = k[1];
      _finOn = fin;
    });
  }
  /// فی فروش (واحد ذخیره، تومان تا S29): در سند ارزی = فی ارزی × نرخ ÷ ۱۰
  bool get _useGrades => _gradesOn && _gc.hasRows && !_fxc.active; // S35.T35.3b: price = weighted average of the grade lines
  double get _priceVal => _fxc.active ? (_fxc.priceStored ?? 0) : (_useGrades ? _gc.weightedPrice : (parseNum(_price.text) ?? 0));
  double get _revenue => _net * _priceVal;

  bool get _fx => LicenseService.I.isFx.value;

  /// فی دلاریِ خریدِ پستهٔ انتخاب‌شده (null = ثبت نشده، مثلاً خرید قبل از ارتقای پلن)
  double? get _costPerKgUsd => (_selLot?['price_usd'] as num?)?.toDouble();

  void _changed() {
    if (mounted) setState(() {});
  }

  void _select(int id) {
    setState(() {
      if (_selId != id) {
        _selId = id;
        // سقف گونی هر خرید فرق دارد؛ مقدارهای قبلی پاک می‌شوند
        _small.clear();
        _large.clear();
      }
    });
  }

  void _fillAll() {
    final lot = _selLot;
    if (lot == null) return;
    final small = _smallCap;
    final large = _largeCap;
    _small.text = small == 0 ? '' : plain(small);
    _large.text = large == 0 ? '' : plain(large);
    _gross.text = plain(_rem + small * (_weighOn ? _sackSmallKg : _kSmallSackKg) + large * (_weighOn ? _sackLargeKg : _kLargeSackKg));
    _changed();
  }

  // ------------------------- ذخیره -------------------------
  Future<void> _save() async {
    if (_saving) return;
    if (!_form.currentState!.validate()) return;
    final lot = _selLot;
    if (lot == null) {
      snack(context, 'یک پسته از انبار انتخاب کنید');
      return;
    }
    final fxErr = _fxc.validate();
    if (fxErr != null) {
      snack(context, fxErr);
      return;
    }
    final price = _priceVal;
    if (price <= 0) {
      snack(context, 'فی فروش را وارد کنید');
      return;
    }
    final net = _net;
    if (net <= 0) {
      snack(context, 'وزن (خالص) باید بیشتر از صفر باشد (وزن گونی‌ها از وزن کل (ناخالص) بیشتر است؟)');
      return;
    }
    if (net > _rem + 1e-6) {
      snack(context, 'وزن (خالص) «${lot['type_name']}» از موجودی آن (${faNum(_rem)} کیلو) بیشتر است');
      return;
    }
    if (_gradesOn) {
      final String? ge = _gc.validate(net); // S35.T35.3b
      if (ge != null) {
        snack(context, ge);
        return;
      }
    }
    final smallN = _smallN;
    final largeN = _largeN;
    if (smallN > _smallCap + 1e-6) {
      snack(context, 'گونی کوچک از گونی کوچک باقی‌ماندهٔ این خرید (${faNum(_smallCap)}) بیشتر است');
      return;
    }
    if (largeN > _largeCap + 1e-6) {
      snack(context, 'گونی بزرگ از گونی بزرگ باقی‌ماندهٔ این خرید (${faNum(_largeCap)}) بیشتر است');
      return;
    }

    final sacksEntered = (smallN + largeN) > 0;
    // اگر این خرید اصلاً گونی‌ای ندارد، هشدار معنی ندارد
    final lotHasSacks = (_smallCap + _largeCap) > 0;
    if (!sacksEntered && lotHasSacks) {
      final ok = await confirm(context,
          'شما تعداد گونی خالی‌شده را وارد نکردید؛ گونیِ انبار برای این خرید کم نخواهد شد. مطمئنید؟');
      if (!ok || !mounted) return;
    }

    final id = lot['id'] as int;
    final items = <Map<String, dynamic>>[
      {
        'purchase_id': id,
        'weight': net,
        'item_price': price,
        'small_sacks': sacksEntered ? smallN : null,
        'large_sacks': sacksEntered ? largeN : null,
      }
    ];
    final saleData = <String, dynamic>{
      ..._fxc.fields(),
      'price': price,
      'total_weight': _grossKg,
      'small_sack_count': smallN,
      'large_sack_count': largeN,
      'net_weight': net,
      if (_gradesOn) 'grade_lines': _gc.toPayload(), // S35.T35.3b (empty list = single-price document)
      // S35.T35.2b: weighing block (null when the switch is off)
      'gross_kg': _weighOn ? _grossKg : null,
      'tare_kg': _weighOn ? _tare : null,
      'quality_deduct_kg': _weighOn ? _deductKg : null,
      'weigh_ticket_no': _weighOn && _ticket.text.trim().isNotEmpty ? _ticket.text.trim() : null,
      'vehicle_plate': _weighOn && _plate.text.trim().isNotEmpty ? _plate.text.trim() : null,
      'driver_name': _weighOn && _driver.text.trim().isNotEmpty ? _driver.text.trim() : null,
      'buyer': _buyer.text.trim().isEmpty ? null : _buyer.text.trim(),
      'note': _note.text.trim().isEmpty ? null : _note.text.trim(),
      'labor_cost': parseNum(_laborCost.text),
      'transport_cost': parseNum(_transportCost.text),
      if (_finOn) ...<String, dynamic>{ // S35.T35.6d: server applies only when form.fin_block is on
        'discount_amount': parseNum(_finDisc.text) ?? 0,
        'weighbridge_cost': parseNum(_finWb.text) ?? 0,
        'side_cost_payer': _finPayer,
      },
      if (taxChoiceAvailable()) 'tax_status': _taxStatus,
      if (taxChoiceAvailable()) 'tax_rate_milli': _taxStatus == 'taxable' ? taxRateMilliFromText(_taxRate.text) : null,
      if (_saleWh != null) 'warehouse_uid': _saleWh,
    };

    setState(() => _saving = true);
    if (!_isEdit) saleData['date'] = DateTime.now().toIso8601String();
    final ok = await saveConfirmed(
      context,
      () async {
        if (_isEdit) {
          await AppDb.I.updateSale(widget.editSaleId!, saleData, items);
        } else {
          await AppDb.I.insertSale(saleData, items);
        }
      },
      successMsg: _isEdit ? 'ویرایش فروش با موفقیت ثبت شد' : 'فروش با موفقیت ثبت شد',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.pop(context);
  }

  // ------------------------- رابط کاربری -------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'ویرایش فروش' : 'فروش جدید')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _legacyMulti
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'این فروش قدیمی و چندقلمی است و دیگر قابل ویرایش نیست.\n'
                      'هر فروش فقط از یک قلم انبار ثبت می‌شود؛ می‌توانید آن را حذف کنید '
                      'و برای هر جنس یک فروش جدا ثبت کنید.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : _fxEditBlocked
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'این فروش به ارز ثبت شده و نرخ آن ثابت است؛ ویرایش مستقیم ممکن نیست.\n'
                          'برای اصلاح نرخ از «سند تعدیل نرخ» استفاده کنید، یا فروش را حذف و دوباره ثبت کنید.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
              : _lots.isEmpty
                  ? const Center(child: Text('انبار خالی است؛ ابتدا خرید ثبت کنید'))
                  : Form(
                      key: _form,
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        children: _children(context),
                      ),
                    ),
    );
  }

  List<Map<String, dynamic>> get _visibleLots {
    final q = _norm(_query);
    if (q.isEmpty) return _lots;
    return _lots.where((e) {
      if (e['id'] == _selId) return true; // مورد انتخاب‌شده همیشه دیده می‌شود
      return _norm('${e['code']} ${e['category_name']} ${e['type_name']}').contains(q);
    }).toList();
  }

  List<Widget> _children(BuildContext context) {
    final w = <Widget>[];
    final lot = _selLot;

    w.add(sectionTitle(context, '۱) پستهٔ فروخته‌شده را از انبار انتخاب کنید (هر فروش فقط یک قلم)'));
    w.add(Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        decoration: const InputDecoration(
          labelText: 'جستجو با کد پسته، دسته یا نوع',
          prefixIcon: Icon(Icons.search),
          border: OutlineInputBorder(),
        ),
        onChanged: (v) => setState(() => _query = v),
      ),
    ));
    final visible = _visibleLots;
    if (visible.isEmpty) {
      w.add(const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text('نتیجه‌ای پیدا نشد', style: TextStyle(color: Colors.black54)),
      ));
    }
    w.add(Column(children: [for (final e in visible) _lotTile(e)]));

    if (lot == null) {
      w.add(const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text('بعد از انتخاب پسته، وزن فروش را وارد کنید.', style: TextStyle(color: Colors.black54)),
      ));
    } else {
      w.add(sectionTitle(context, '۲) وزن واقعی فروش (طبق ترازو)'));
      w.add(KeyedSubtree(key: ValueKey('weigh${lot['id']}'), child: _weighFields(lot)));
      w.add(KeyedSubtree(
          key: ValueKey('swh${lot['id']}'),
          child: SaleWarehouseField(lotId: lot['id'] as int, onChanged: (String? v) => _saleWh = v)));
      w.add(_summaryCard(context));
      w.add(sectionTitle(context, '۳) فی فروش'));
      if (_fx) w.add(FxDocFields(c: _fxc, priceLabel: 'فی فروش ارزی (هر کیلو)', onChanged: _changed));
      if (!_fxc.active && !_useGrades) {
        w.add(numField(_price, 'فی فروش (ریال به ازای هر کیلو)',
            required: true, thousands: true, onChanged: _changed));
      }
      if (_priceTableOn && !_fxc.active && !_useGrades && _selLot != null) {
        w.add(PriceSuggestionHint(
            typeName: '${_selLot!['type_name']}', ounceUid: _selLot!['ounce_uid'] as String?, onAccept: (num v) { _price.text = plain(v); _changed(); })); // S35.T35.4
      }
      if (_gradesOn && !_fxc.active) w.add(GradeLinesEditor(c: _gc, netKg: _net, onChanged: _changed)); // S35.T35.3b
      if (!_fx) w.add(fxLockedField('فروش به ارز'));
    }

    w.add(const SizedBox(height: 12));
    w.add(KeyedSubtree(
        key: const ValueKey('buyer'), child: PartyField(controller: _buyer, label: 'خریدار (اختیاری)')));
    w.add(KeyedSubtree(key: const ValueKey('note'), child: textField(_note, 'توضیحات (اختیاری)', lines: 2)));
    w.add(KeyedSubtree(
        key: const ValueKey('laborCost'),
        child: numField(_laborCost, 'هزینه کارگر (ریال) — اختیاری', thousands: true, hint: 'اگر وارد شود از سود این فروش کم می‌شود')));
    w.add(KeyedSubtree(
        key: const ValueKey('transportCost'),
        child: numField(_transportCost, 'هزینه حمل‌ونقل / باسکول (ریال) — اختیاری', thousands: true, hint: 'اگر وارد شود از سود این فروش کم می‌شود')));
    if (_finOn)
      w.addAll(<Widget>[
        sectionTitle(context, 'بلوک مالی'),
        numField(_finDisc, 'تخفیف (ریال) — اختیاری', thousands: true),
        numField(_finWb, 'هزینهٔ باسکول (ریال) — اختیاری', thousands: true),
        DropdownButtonFormField<String>(
          value: _finPayer,
          decoration: const InputDecoration(labelText: 'هزینه‌های جانبی بر عهدهٔ'),
          items: const <DropdownMenuItem<String>>[
            DropdownMenuItem<String>(value: 'us', child: Text('ما')),
            DropdownMenuItem<String>(value: 'party', child: Text('طرف حساب')),
          ],
          onChanged: (String? v) => setState(() => _finPayer = v ?? 'us'),
        ),
      ]);
    if (_finOn && widget.editSaleId != null) w.add(FinBlockCard(docType: 'sale', docId: widget.editSaleId));
    w.add(KeyedSubtree(
        key: const ValueKey('taxChoice'),
        child: TaxChoiceField(status: _taxStatus, rate: _taxRate, onChanged: (String? v) => setState(() => _taxStatus = v))));
    w.add(FilledButton.icon(
      onPressed: _saving ? null : _save,
      icon: _saving
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.check),
      label: Text(_isEdit ? 'ذخیره تغییرات' : 'ثبت فروش'),
    ));
    w.add(const SizedBox(height: 24));
    return w;
  }

  Widget _lotTile(Map<String, dynamic> e) {
    final id = e['id'] as int;
    final rem = (e['remaining'] as num).toDouble();
    final selected = _selId == id;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      key: ValueKey('lot$id'),
      color: selected ? scheme.primaryContainer : null,
      child: ListTile(
        onTap: () => _select(id),
        leading: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
            color: selected ? scheme.primary : null),
        title: Text('${e['category_name']} - ${e['type_name']}'),
        subtitle: Text(
          'کد پسته: ${e['code'] ?? '-'}  •  خرید ${jalaliDate(e['date'] as String)}  •  فی ${faNum(e['price'] as num, dec: 0)}'
          '${_fx && e['price_usd'] != null ? ' (${faUsd(e['price_usd'] as num, dec: 4)})' : ''}\n'
          'موجودی (خالص) ${faNum(rem)} کیلو  •  گونی مانده: کوچک ${faNum(e['small_left'] as num)} / بزرگ ${faNum(e['large_left'] as num)}',
        ),
        isThreeLine: true,
      ),
    );
  }

  Widget _sackField(TextEditingController c, String label, double cap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [_CapFormatter(() => cap)],
        decoration: InputDecoration(
          labelText: label,
          hintText: '0',
          helperText: 'حداکثر ${faNum(cap)} (گونی باقی‌مانده)',
          border: const OutlineInputBorder(),
        ),
        onChanged: (_) => _changed(),
        validator: (v) {
          if ((v ?? '').trim().isEmpty) return null;
          final n = parseNum(v);
          if (n == null || n < 0) return 'عدد معتبر وارد کنید';
          if (n > cap + 1e-6) return 'حداکثر ${faNum(cap)}';
          return null;
        },
      ),
    );
  }

  /// وزن واقعی (کل، با گونی) + گونی‌های خالی‌شده (اختیاری)
  Widget _weighFields(Map<String, dynamic> lot) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      numField(_gross, 'وزن کل (ناخالص - با گونی) — طبق ترازو', required: true, onChanged: _changed),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _fillAll,
          icon: const Icon(Icons.all_inclusive),
          label: const Text('همه موجودی'),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          'تعداد گونی خالی‌شده اختیاری است و از گونیِ باقی‌ماندهٔ همین خرید کم می‌شود؛ '
          'اگر وارد نکنید فقط وزن از انبار کم می‌شود.',
          style: TextStyle(color: Colors.black54, fontSize: 12),
        ),
      ),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
            child: _sackField(_small, 'گونی کوچک برداشته‌شده (${faNum(_kSmallSackKg * 1000, dec: 0)} گرم)', _smallCap)),
        const SizedBox(width: 8),
        Expanded(
            child: _sackField(_large, 'گونی بزرگ برداشته‌شده (${faNum(_kLargeSackKg * 1000, dec: 0)} گرم)', _largeCap)),
      ]),
      if (_weighOn) ...[
        sectionTitle(context, 'توزین'),
        const Padding(
          padding: EdgeInsets.only(bottom: 4),
          child: Text('تارا یعنی وزن گونی یا ظرف خالی که از وزن کل کم می‌شود', style: TextStyle(fontSize: 12, color: Colors.black54)),
        ),
        numField(_tareManual, 'تارا (کیلو) — خالی = از تعداد گونی', hint: faNum(_sackTare), onChanged: _changed),
        Row(children: [
          Expanded(child: numField(_deduct, _deductPct ? 'کسر کیفیت (درصد)' : 'کسر کیفیت (کیلو)', onChanged: _changed)),
          const SizedBox(width: 8),
          DropdownButton<bool>(
            value: _deductPct,
            items: const <DropdownMenuItem<bool>>[
              DropdownMenuItem<bool>(value: false, child: Text('کیلو')),
              DropdownMenuItem<bool>(value: true, child: Text('درصد')),
            ],
            onChanged: (bool? v) {
              setState(() => _deductPct = v ?? false);
              _changed();
            },
          ),
        ]),
        textField(_ticket, 'شمارهٔ قبض باسکول'),
        Row(children: [
          Expanded(child: textField(_plate, 'پلاک')),
          const SizedBox(width: 8),
          Expanded(child: textField(_driver, 'راننده')),
        ]),
      ],
    ]);
  }

  Widget _summaryCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final over = _net > _rem + 1e-6;
    final tooHeavy = _grossKg > 0 && _net <= 0;
    return Card(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          infoRow('موجودی این خرید (خالص)', '${faNum(_rem)} کیلو'),
          infoRow('وزن کل (ناخالص - با گونی)', '${faNum(_grossKg)} کیلو'),
          infoRow(_weighOn ? 'تارا' : 'وزن گونی‌ها', '${faNum(_tare)} کیلو'),
          if (_weighOn && _deductKg > 0) infoRow('کسر کیفیت', '${faNum(_deductKg)} کیلو'),
          infoRow('وزن پسته (خالص)', '${faNum(_net)} کیلو', valueColor: over ? scheme.error : null),
          infoRow('مبلغ فروش تقریبی', '${faNum(_revenue, dec: 0)} ریال'),
          if (_fxc.active && _fxc.priceCcyNum != null) ...[
            infoRow('فی فروش ارزی (هر کیلو)', faCcy(_fxc.ccy!, _fxc.priceCcyNum!, dec: _fxc.decimals)),
            infoRow('مبلغ فروش ارزی', faCcy(_fxc.ccy!, _net * _fxc.priceCcyNum!, dec: _fxc.decimals)),
          ],
          if (tooHeavy)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('وزن گونی‌ها از وزن کل (ناخالص) بیشتر یا مساوی آن است', style: TextStyle(color: scheme.error)),
            ),
          if (over)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('وزن (خالص) «${_selLot?['type_name']}» از موجودی آن (${faNum(_rem)} کیلو) بیشتر است',
                  style: TextStyle(color: scheme.error)),
            ),
        ]),
      ),
    );
  }
}
