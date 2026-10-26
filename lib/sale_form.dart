import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'db.dart';
import 'license_service.dart';
import 'party_field.dart';
import 'tax_choice.dart';
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
  final _usdRate = TextEditingController(); // قیمت دلار هنگام فروش (فقط پلن ارزی)
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
  }

  @override
  void dispose() {
    _gross.dispose();
    _small.dispose();
    _large.dispose();
    _price.dispose();
    _usdRate.dispose();
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
        _usdRate.text = sale['usd_rate'] == null ? '' : plain(sale['usd_rate'] as num);
        _gross.text = plain(sale['total_weight'] as num);
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
  double get _tare => _smallN * _kSmallSackKg + _largeN * _kLargeSackKg;
  double get _net => _r3(_grossKg - _tare);
  double get _revenue => _net * (parseNum(_price.text) ?? 0);

  bool get _fx => LicenseService.I.isFx.value;
  double? get _rate {
    final r = parseNum(_usdRate.text);
    return (r == null || r <= 0) ? null : r;
  }

  /// فی فروش به دلار (هر کیلو)
  double? get _salePerKgUsd {
    final p = parseNum(_price.text);
    final r = _rate;
    return (p == null || r == null) ? null : p / r;
  }

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
    _gross.text = plain(_rem + small * _kSmallSackKg + large * _kLargeSackKg);
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
    final price = parseNum(_price.text) ?? 0;
    if (price <= 0) {
      snack(context, 'فی فروش را وارد کنید');
      return;
    }
    if (_fx && _rate == null) {
      snack(context, 'قیمت دلار روز فروش را وارد کنید');
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
      if (_fx) 'usd_rate': _rate,
      'price': price,
      'total_weight': _grossKg,
      'small_sack_count': smallN,
      'large_sack_count': largeN,
      'net_weight': net,
      'buyer': _buyer.text.trim().isEmpty ? null : _buyer.text.trim(),
      'note': _note.text.trim().isEmpty ? null : _note.text.trim(),
      'labor_cost': parseNum(_laborCost.text),
      'transport_cost': parseNum(_transportCost.text),
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
      w.add(numField(_price, 'فی فروش (تومان به ازای هر کیلو)',
          required: true, thousands: true, onChanged: _changed));
      if (_fx)
        w.add(numField(_usdRate, 'قیمت دلار در زمان فروش (تومان)',
            required: true, thousands: true, onChanged: _changed));
      else
        w.add(fxLockedField('قیمت دلار در زمان فروش (تومان)'));
    }

    w.add(const SizedBox(height: 12));
    w.add(KeyedSubtree(
        key: const ValueKey('buyer'), child: PartyField(controller: _buyer, label: 'خریدار (اختیاری)')));
    w.add(KeyedSubtree(key: const ValueKey('note'), child: textField(_note, 'توضیحات (اختیاری)', lines: 2)));
    w.add(KeyedSubtree(
        key: const ValueKey('laborCost'),
        child: numField(_laborCost, 'هزینه کارگر (تومان) — اختیاری', thousands: true, hint: 'اگر وارد شود از سود این فروش کم می‌شود')));
    w.add(KeyedSubtree(
        key: const ValueKey('transportCost'),
        child: numField(_transportCost, 'هزینه حمل‌ونقل / باسکول (تومان) — اختیاری', thousands: true, hint: 'اگر وارد شود از سود این فروش کم می‌شود')));
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
          infoRow('وزن گونی‌ها', '${faNum(_tare)} کیلو'),
          infoRow('وزن پسته (خالص)', '${faNum(_net)} کیلو', valueColor: over ? scheme.error : null),
          infoRow('مبلغ فروش تقریبی', '${faNum(_revenue, dec: 0)} تومان'),
          if (_fx && _salePerKgUsd != null) ...[
            infoRow('فی فروش به دلار (هر کیلو)', faUsd(_salePerKgUsd!, dec: 4)),
            infoRow('مبلغ فروش به دلار', faUsd(_net * _salePerKgUsd!)),
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
