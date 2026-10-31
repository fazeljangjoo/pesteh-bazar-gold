import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'fin_block_view.dart'; // S35.T35.6f
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import 'db.dart';
import 'fx_doc_field.dart';
import 'doc_drafts.dart' show DocDraftsLocal;
import 'form_settings.dart' show FormSettingsLocal;
import 'grade_lines_ui.dart';
import 'fx_local.dart';
import 'license_service.dart';
import 'party_field.dart';
import 'price_table_ui.dart' show PriceSuggestionHint;
import 'tax_choice.dart';
import 'fmt.dart' show Fmt, MoneyField;
import 'utils.dart';
import 'voucher_preview_ui.dart' show confirmVoucherPreview;
import 'doc_summary_ui.dart' show confirmDocSummary; // S35.T35.13
import 'warehouse_ui.dart';
import 'widgets.dart';

class PurchaseForm extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const PurchaseForm({super.key, this.existing});
  @override
  State<PurchaseForm> createState() => _PurchaseFormState();
}

class _CustomSpecRow {
  final TextEditingController label = TextEditingController();
  final TextEditingController value = TextEditingController();
}

class _PurchaseFormState extends State<PurchaseForm> with EditGuard<PurchaseForm> {
  final _form = GlobalKey<FormState>();

  List<Map<String, dynamic>> _categories = [];
  int? _categoryId;
  bool _loadingCats = true;
  bool _saving = false;

  List<Map<String, dynamic>> _types = [];
  int? _typeId;
  final _customTypeCtrl = TextEditingController();

  String? _photo; // data-URL (base64) مثل سرور/وب
  String? _warehouseUid; // S01: انبار (null = پیش‌فرض)
  String? _ounceUid; // S01: درجه‌بندی اونس
  bool _photoChanged = false;

  final _ounce = TextEditingController();
  final _price = TextEditingController();
  final FxDocController _fxc = FxDocController(); // S27c: ارز سند (نرخ دستی دلار حذف شد)
  bool _fxEditBlocked = false; // خرید ارزیِ ثبت‌شده فعلاً قابل ویرایش نیست (T27b.6)
  final _total = TextEditingController();
  final _smallSack = TextEditingController();
  final _largeSack = TextEditingController();
  // S35.T35.2: weighing block (only when the «توزین» switch is on)
  bool _weighOn = false;
  bool _gradesOn = false; // S35.T35.3b
  bool _priceTableOn = false; // S35.T35.4
  final GradeLinesController _gc = GradeLinesController();
  double _sackSmallKg = 0.1;
  double _sackLargeKg = 0.2;
  bool _deductPct = false; // quality deduction entered as percent of (gross - tare)
  final _tareManual = TextEditingController();
  final _deduct = TextEditingController();
  final _ticket = TextEditingController();
  final _plate = TextEditingController();
  final _driver = TextEditingController();
  // S35.T35.6c: بلوک مالی (فقط وقتی form.fin_block روشن است). وضعیت مالیاتی از TaxChoiceField می‌آید.
  bool _finOn = false;
  bool _draftOn = false; // S35.T35.9b form.draft
  final _finDisc = TextEditingController();
  final _finWb = TextEditingController();
  String _finPayer = 'us';

  final _gram = TextEditingController();
  final _pctKhandan = TextEditingController(); // درصد خندان در دنبست
  final _pctDombest = TextEditingController(); // درصد دنبست در خندان
  final _pctTuchin = TextEditingController();
  final _pctCrooked = TextEditingController();

  final List<_CustomSpecRow> _customSpecs = [];

  final _seller = TextEditingController();
  final _note = TextEditingController();
  final _laborCost = TextEditingController(); // هزینه کارگر (اختیاری؛ از سود این پسته کم می‌شود)
  String? _taxStatus; // S17.T17.1b (طلایی): null = طبق سال مالی
  final _taxRate = TextEditingController();
  final _transportCost = TextEditingController(); // هزینه حمل‌ونقل / باسکول (اختیاری)

  bool get _isEdit => widget.existing != null;

  bool get _fx => LicenseService.I.isFx.value;

  /// فی خرید (واحد ذخیره، تومان تا S29): در سند ارزی = فی ارزی × نرخ ÷ ۱۰
  String get _suggestTypeName {
    if (_isPreset) {
      for (final Map<String, dynamic> t in _types) {
        if (t['id'] == _typeId) return '${t['name']}';
      }
      return '';
    }
    return _customTypeCtrl.text.trim();
  }

  bool get _useGrades => _gradesOn && _gc.hasRows && !_fxc.active; // S35.T35.3b: price = weighted average of the grade lines
  double get _priceVal => _fxc.active ? (_fxc.priceStored ?? 0) : (_useGrades ? _gc.weightedPrice : (MoneyField.stored(_price) ?? 0).toDouble());

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
    _fxc.dispose();
    _finDisc.dispose();
    _finWb.dispose();
    _gc.dispose();
    _tareManual.dispose();
    _deduct.dispose();
    _ticket.dispose();
    _plate.dispose();
    _driver.dispose();
    super.dispose();
  }

  /// اگر بخشی از این خرید قبلاً فروخته شده باشد، دسته/نوع/وزن قابل ویرایش نیست
  bool get _locked {
    final e = widget.existing;
    if (e == null) return false;
    final rem = (e['remaining'] as num).toDouble();
    final net = (e['net_weight'] as num).toDouble();
    return rem < net - 1e-6;
  }

  @override
  void initState() {
    super.initState();
    if (LicenseService.I.isFx.value) _initFx();
    _loadWeighSettings();
    final e = widget.existing;
    if (e != null) {
      if (e['gross_kg'] != null) { // S35.T35.2
        _tareManual.text = e['tare_kg'] == null ? '' : plain(e['tare_kg'] as num);
        _deduct.text = (e['quality_deduct_kg'] == null || (e['quality_deduct_kg'] as num) == 0) ? '' : plain(e['quality_deduct_kg'] as num);
        _ticket.text = (e['weigh_ticket_no'] as String?) ?? '';
        _plate.text = (e['vehicle_plate'] as String?) ?? '';
        _driver.text = (e['driver_name'] as String?) ?? '';
      }
      _loadExistingPhoto(e['id'] as int?);
      _ounce.text = e['ounce'] == null ? '' : plain(e['ounce'] as num);
      _warehouseUid = e['warehouse_uid'] as String?;
      _ounceUid = e['ounce_uid'] as String?;
      MoneyField.setStored(_price, e['price'] as num);
      if (e['ccy'] != null && (e['ccy'] as String).isNotEmpty) _fxEditBlocked = true;
      _total.text = plain(e['total_weight'] as num);
      final smallVal = (e['small_sack_count'] as num).toDouble();
      final largeVal = (e['large_sack_count'] as num).toDouble();
      _smallSack.text = smallVal == 0 ? '' : plain(smallVal);
      _largeSack.text = largeVal == 0 ? '' : plain(largeVal);
      _gram.text = e['gram'] == null ? '' : plain(e['gram'] as num);
      _pctKhandan.text = e['pct_khandan'] == null ? '' : plain(e['pct_khandan'] as num);
      _pctDombest.text = e['pct_dombest'] == null ? '' : plain(e['pct_dombest'] as num);
      _pctTuchin.text = e['pct_tuchin'] == null ? '' : plain(e['pct_tuchin'] as num);
      _pctCrooked.text = e['pct_crooked'] == null ? '' : plain(e['pct_crooked'] as num);
      _seller.text = (e['seller'] as String?) ?? '';
      _note.text = (e['note'] as String?) ?? '';
    MoneyField.setStored(_laborCost, e['labor_cost'] as num?);
    _taxStatus = e['tax_status'] as String?;
    _taxRate.text = taxRateTextFromMilli(e['tax_rate_milli']);
    MoneyField.setStored(_transportCost, e['transport_cost'] as num?);
      final specs = AppDb.decodeCustomSpecs(e['custom_specs'] as String?);
      for (final s in specs) {
        final row = _CustomSpecRow();
        row.label.text = s['label'] ?? '';
        row.value.text = s['value'] ?? '';
        _customSpecs.add(row);
      }
      _customTypeCtrl.text = e['type_name'] as String? ?? '';
    }
    _loadCategories(select: e?['category_id'] as int?);
  }

  Map<String, dynamic>? get _selectedCategory {
    if (_categoryId == null) return null;
    try {
      return _categories.firstWhere((c) => c['id'] == _categoryId);
    } catch (_) {
      return null;
    }
  }

  String? get _presetKey => _selectedCategory?['preset_key'] as String?;
  bool get _isPreset => _presetKey != null;

  Future<void> _loadCategories({int? select}) async {
    final list = await AppDb.I.categories();
    if (!mounted) return;
    setState(() {
      _categories = list;
      _categoryId = select ?? (list.isNotEmpty ? list.first['id'] as int : null);
      _loadingCats = false;
    });
    if (_categoryId != null) await _loadTypes();
  }

  Future<void> _loadTypes({int? select}) async {
    if (_categoryId == null || !_isPreset) {
      setState(() {
        _types = [];
        _typeId = null;
      });
      return;
    }
    final list = await AppDb.I.typesOf(_categoryId!);
    if (!mounted) return;
    int? resolved = select;
    if (resolved == null && widget.existing != null) {
      final wantName = widget.existing!['type_name'] as String?;
      for (final t in list) {
        if (t['name'] == wantName) {
          resolved = t['id'] as int;
          break;
        }
      }
    }
    setState(() {
      _types = list;
      _typeId = resolved ?? (list.isNotEmpty ? list.first['id'] as int : null);
    });
  }

  Future<void> _loadWeighSettings() async {
    final bool on = await FormSettingsLocal.isOn('weigh');
    final bool gOn = await FormSettingsLocal.isOn('grades');
    final bool ptOn = await FormSettingsLocal.isOn('price_table'); // S35.T35.4
    final bool fin = await FormSettingsLocal.isOn('fin_block'); // S35.T35.6c
    final bool draftOn = await FormSettingsLocal.isOn('draft'); // S35.T35.9b
    List<Map<String, dynamic>> gl = <Map<String, dynamic>>[];
    final Map<String, dynamic>? ex = widget.existing;
    if (gOn && ex != null && ex['id'] is int) gl = await GradeLinesLocal.load('purchase', ex['id'] as int);
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
      _draftOn = draftOn;
      if (ex != null) {
        final Object? d = ex['discount_amount'] ?? ex['discount']; // S35.T35.6c: prefill
        final Object? w = ex['weighbridge_cost'];
        if (d is num && d > 0) MoneyField.setStored(_finDisc, d);
        if (w is num && w > 0) MoneyField.setStored(_finWb, w);
        _finPayer = ex['side_cost_payer'] == 'party' ? 'party' : 'us';
      }
    });
  }

  double get _sackTare =>
      (parseNum(_smallSack.text) ?? 0) * (_weighOn ? _sackSmallKg : 0.1) + (parseNum(_largeSack.text) ?? 0) * (_weighOn ? _sackLargeKg : 0.2);
  /// tare = manual value when typed, else from sack counts (S35.T35.2)
  double get _tare => (_weighOn && _tareManual.text.trim().isNotEmpty) ? (parseNum(_tareManual.text) ?? 0) : _sackTare;
  double get _deductKg {
    if (!_weighOn) return 0;
    final double v = parseNum(_deduct.text) ?? 0;
    if (!_deductPct) return v;
    final double base = (parseNum(_total.text) ?? 0) - _tare;
    return base <= 0 ? 0 : (base * v / 100 * 1000).round() / 1000;
  }
  double get _net => (parseNum(_total.text) ?? 0) - _tare - _deductKg;

  Future<void> _addCategory() async {
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('افزودن دسته جدید'),
        content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(labelText: 'نام دسته')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('افزودن')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final id = await AppDb.I.addCategory(name);
    await _loadCategories(select: id);
  }

  Future<void> _addType() async {
    if (_categoryId == null) return;
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('افزودن نوع جدید به «${_selectedCategory?['name']}»'),
        content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(labelText: 'نام نوع')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('افزودن')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final id = await AppDb.I.addType(_categoryId!, name);
    await _loadTypes(select: id);
  }

  void _addCustomSpec() {
    if (_customSpecs.length >= kMaxCustomSpecs) return;
    setState(() => _customSpecs.add(_CustomSpecRow()));
  }

  void _removeCustomSpec(int i) {
    setState(() => _customSpecs.removeAt(i));
  }

  /// عکس در لیست‌ها بارگذاری نمی‌شود (سنگین است)؛ فقط هنگام ویرایش از دیتابیس خوانده می‌شود
  Future<void> _loadExistingPhoto(int? id) async {
    if (id == null) return;
    final ph = await AppDb.I.localPhoto(id);
    if (mounted && !_photoChanged && ph != null) setState(() => _photo = ph);
  }

  Uint8List _downscale(Uint8List src) {
    try {
      final im = img.decodeImage(src);
      if (im == null) return src;
      final r = im.width > 1100 ? img.copyResize(im, width: 1100) : im;
      return Uint8List.fromList(img.encodeJpg(r, quality: 72));
    } catch (_) {
      return src;
    }
  }

  Future<void> _pick(ImageSource src) async {
    // مثل وب: حداکثر ~۱۱۰۰ پیکسل و کیفیت ۷۲٪ تا حجم دیتابیس/سرور زیاد نشود
    final x = await ImagePicker().pickImage(source: src, maxWidth: 1100, imageQuality: 72);
    if (x == null) return;
    var bytes = await x.readAsBytes();
    // دسکتاپ، maxWidth/imageQuality را اعمال نمی‌کند؛ خودمان کوچک می‌کنیم
    if (Platform.isWindows) bytes = _downscale(bytes);
    if (bytes.length > 6 * 1024 * 1024) {
      if (mounted) snack(context, 'حجم عکس زیاد است');
      return;
    }
    final dataUrl = 'data:image/jpeg;base64,${base64Encode(bytes)}';
    if (mounted) {
      setState(() {
        _photo = dataUrl;
        _photoChanged = true;
      });
    }
  }

  void _photoSheet() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          if (!Platform.isWindows)
            ListTile(
            leading: const Icon(Icons.photo_camera),
            title: const Text('گرفتن عکس'),
            onTap: () {
              Navigator.pop(ctx);
              _pick(ImageSource.camera);
            },
          ),
          ListTile(
            leading: const Icon(Icons.photo_library),
            title: Text(Platform.isWindows ? 'انتخاب عکس از کامپیوتر' : 'انتخاب از گالری'),
            onTap: () {
              Navigator.pop(ctx);
              _pick(ImageSource.gallery);
            },
          ),
          if (_photo != null)
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('حذف عکس'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _photo = null;
                  _photoChanged = true;
                });
              },
            ),
        ]),
      ),
    );
  }

  Future<void> _save({bool draft = false}) async {
    if (_saving) return;
    if (!_form.currentState!.validate()) return;

    if (_locked) {
      // فقط فی، فروشنده، عکس و توضیحات قابل ویرایش است (چون بخشی از این خرید فروخته شده)
      setState(() => _saving = true);
      final lockedData = <String, dynamic>{
        if (_photoChanged) 'photo': _photo,
        'price': MoneyField.stored(_price),
        'seller': _seller.text.trim().isEmpty ? null : _seller.text.trim(),
        'note': _note.text.trim().isEmpty ? null : _note.text.trim(),
        'labor_cost': MoneyField.stored(_laborCost),
        'transport_cost': MoneyField.stored(_transportCost),
      };
      final okLocked = await saveConfirmed(
        context,
        () => AppDb.I.updatePurchase(widget.existing!['id'] as int, lockedData),
        successMsg: 'ویرایش خرید با موفقیت ثبت شد',
      );
      if (!mounted) return;
      setState(() => _saving = false);
      if (okLocked) Navigator.pop(context);
      return;
    }

    if (_categoryId == null) {
      snack(context, 'دسته را انتخاب کنید');
      return;
    }
    String typeName;
    if (_isPreset) {
      if (_typeId == null) {
        snack(context, 'نوع پسته را انتخاب کنید');
        return;
      }
      typeName = (_types.firstWhere((t) => t['id'] == _typeId)['name']) as String;
    } else {
      typeName = _customTypeCtrl.text.trim();
      if (typeName.isEmpty) {
        snack(context, 'نوع پسته را وارد کنید');
        return;
      }
    }
    if (_net <= 0) {
      snack(context, 'وزن (خالص) باید بیشتر از صفر باشد');
      return;
    }
    final String? fxErr = _fxc.validate();
    if (fxErr != null) {
      snack(context, fxErr);
      return;
    }
    if (_gradesOn) {
      final String? ge = _gc.validate(_net);
      if (ge != null) {
        snack(context, ge);
        return;
      }
    }
    if (_priceVal <= 0) {
      snack(context, 'فی خرید را وارد کنید');
      return;
    }

    // اگر تعداد گونی وارد نشده باشد، قبل از ثبت تأیید می‌گیریم
    if (((parseNum(_smallSack.text) ?? 0) + (parseNum(_largeSack.text) ?? 0)) <= 0) {
      final ok = await confirm(context,
          'شما تعداد را وارد نکردید؛ گونیِ انبار برای این خرید اضافه نخواهد شد و فقط وزن (خالص) به انبار اضافه می‌شود. مطمئنید؟');
      if (!ok || !mounted) return;
    }

    final preset = _presetKey;
    List<Map<String, String>>? customSpecs;
    if (preset != 'dombest' && preset != 'khandan') {
      customSpecs = _customSpecs
          .where((r) => r.label.text.trim().isNotEmpty)
          .map((r) => {'label': r.label.text.trim(), 'value': r.value.text.trim()})
          .toList();
    }

    final Map<String, dynamic> data = <String, dynamic>{
      'category_id': _categoryId,
      'type_name': typeName,
      'photo': _photo,
      'ounce': parseNum(_ounce.text),
      'warehouse_uid': _warehouseUid,
      'ounce_uid': _ounceUid,
      'price': _priceVal,
      ..._fxc.fields(),
      'total_weight': parseNum(_total.text),
      'small_sack_count': parseNum(_smallSack.text) ?? 0,
      'large_sack_count': parseNum(_largeSack.text) ?? 0,
      'net_weight': _net,
      if (_gradesOn) 'grade_lines': _gc.toPayload(), // S35.T35.3b (empty list = single-price document)
      // S35.T35.2: weighing block (null when the switch is off so an edit never keeps stale values)
      'gross_kg': _weighOn ? parseNum(_total.text) : null,
      'tare_kg': _weighOn ? _tare : null,
      'quality_deduct_kg': _weighOn ? _deductKg : null,
      'weigh_ticket_no': _weighOn && _ticket.text.trim().isNotEmpty ? _ticket.text.trim() : null,
      'vehicle_plate': _weighOn && _plate.text.trim().isNotEmpty ? _plate.text.trim() : null,
      'driver_name': _weighOn && _driver.text.trim().isNotEmpty ? _driver.text.trim() : null,
      if (_finOn) ...<String, dynamic>{ // S35.T35.6c: server applies only when form.fin_block is on
        'discount_amount': MoneyField.stored(_finDisc) ?? 0,
        'weighbridge_cost': MoneyField.stored(_finWb) ?? 0,
        'side_cost_payer': _finPayer,
      },
      'gram': preset == 'dombest' ? parseNum(_gram.text) : null,
      'pct_khandan': preset == 'dombest' ? parseNum(_pctKhandan.text) : null,
      'pct_dombest': preset == 'khandan' ? parseNum(_pctDombest.text) : null,
      'pct_tuchin': preset == 'khandan' ? parseNum(_pctTuchin.text) : null,
      'pct_crooked': (preset == 'dombest' || preset == 'khandan') ? parseNum(_pctCrooked.text) : null,
      'custom_specs': customSpecs != null && customSpecs.isNotEmpty
          ? AppDb.encodeCustomSpecs(customSpecs)
          : null,
      'seller': _seller.text.trim().isEmpty ? null : _seller.text.trim(),
      'note': _note.text.trim().isEmpty ? null : _note.text.trim(),
        'labor_cost': MoneyField.stored(_laborCost),
        'transport_cost': MoneyField.stored(_transportCost),
      if (taxChoiceAvailable()) 'tax_status': _taxStatus,
      if (taxChoiceAvailable()) 'tax_rate_milli': _taxStatus == 'taxable' ? taxRateMilliFromText(_taxRate.text) : null,
    };

    if (draft) {
      // S35.T35.9b: پیش‌نویس فقط محلی ذخیره می‌شود؛ هیچ اثری روی انبار/حساب ندارد
      data['date'] = DateTime.now().toIso8601String();
      await DocDraftsLocal.save('purchase', '${data['type_name'] ?? ''} — ${faNum(_net)} کیلو', data);
      if (!mounted) return;
      snack(context, 'پیش‌نویس ذخیره شد (بدون اثر روی انبار و حساب‌ها)');
      Navigator.pop(context);
      return;
    }
    if (!_isEdit) {
      // S35.T35.9d: gold dry-run preview of the voucher (display-only; never blocks when offline)
      final bool go = await confirmVoucherPreview(context, docType: 'purchase', doc: <String, dynamic>{...data, 'date': DateTime.now().toIso8601String()});
      if (!go || !mounted) return;
    }
    if (await FormSettingsLocal.isOn('confirm_summary')) { // S35.T35.13
      if (!mounted) return;
      final bool okSum = await confirmDocSummary(context, title: 'تأیید خرید', rows: <MapEntry<String, String>>[
        MapEntry<String, String>('طرف حساب', '${data['seller'] ?? '—'}'),
        MapEntry<String, String>('وزن ناخالص', Fmt.kg((data['total_weight'] as num?) ?? 0)),
        MapEntry<String, String>('فی خرید', Fmt.money((data['price'] as num?) ?? 0)),
        if (data['discount_amount'] != null) MapEntry<String, String>('تخفیف', Fmt.money(data['discount_amount'] as num)),
        if (data['weighbridge_cost'] != null) MapEntry<String, String>('هزینه باسکول', Fmt.money(data['weighbridge_cost'] as num)),
        if (data['labor_cost'] != null) MapEntry<String, String>('هزینه کارگر', Fmt.money(data['labor_cost'] as num)),
        if (data['transport_cost'] != null) MapEntry<String, String>('حمل‌ونقل', Fmt.money(data['transport_cost'] as num)),
        MapEntry<String, String>('وضعیت مالیاتی', '${data['tax_status'] ?? 'بدون مالیات'}'),
      ]);
      if (!okSum || !mounted) return;
    }
    setState(() => _saving = true);
    if (_isEdit) {
      if (!_photoChanged) data.remove('photo');
    } else {
      data['date'] = DateTime.now().toIso8601String();
    }
    final ok = await saveConfirmed(
      context,
      () async {
        if (_isEdit) {
          await AppDb.I.updatePurchase(widget.existing!['id'] as int, data);
        } else {
          await AppDb.I.insertPurchase(data);
        }
      },
      successMsg: _isEdit ? 'ویرایش خرید با موفقیت ثبت شد' : 'خرید با موفقیت ثبت شد',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingCats) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_fxEditBlocked) {
      return Scaffold(
        appBar: AppBar(title: const Text('ویرایش خرید')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'این خرید به ارز ثبت شده و نرخ آن ثابت است؛ ویرایش مستقیم ممکن نیست.\n'
              'برای اصلاح نرخ از «سند تعدیل نرخ» استفاده کنید، یا خرید را حذف و دوباره ثبت کنید.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    final preset = _presetKey;
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'ویرایش خرید' : 'خرید جدید')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_locked)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'چون بخشی از این خرید فروخته شده، دسته/نوع/وزن و مشخصات کیفی قابل ویرایش نیست. '
                    'فقط فی خرید، فروشنده، عکس و توضیحات قابل تغییرند.',
                  ),
                ),
              ),
            if (_locked) const SizedBox(height: 12),
            IgnorePointer(
              ignoring: _locked,
              child: Opacity(
                opacity: _locked ? 0.5 : 1,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  sectionTitle(context, 'دسته و نوع پسته'),
                  Row(children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        value: _categoryId,
                        decoration: const InputDecoration(labelText: 'دسته', border: OutlineInputBorder()),
                        items: _categories
                            .map((c) => DropdownMenuItem(value: c['id'] as int, child: Text(c['name'] as String)))
                            .toList(),
                        onChanged: (v) async {
                          if (v == null) return;
                          setState(() => _categoryId = v);
                          await _loadTypes();
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(onPressed: _addCategory, icon: const Icon(Icons.add), tooltip: 'افزودن دسته'),
                  ]),
                  const SizedBox(height: 12),
                  if (_isPreset)
                    Row(children: [
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          key: ValueKey('$_categoryId-$_typeId'),
                          value: _typeId,
                          decoration: const InputDecoration(labelText: 'نوع', border: OutlineInputBorder()),
                          items: _types
                              .map((t) => DropdownMenuItem(value: t['id'] as int, child: Text(t['name'] as String)))
                              .toList(),
                          onChanged: (v) => setState(() => _typeId = v),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(onPressed: _addType, icon: const Icon(Icons.add), tooltip: 'افزودن نوع'),
                    ])
                  else
                    textField(_customTypeCtrl, 'نوع پسته', required: true),
                ]),
              ),
            ),
            const SizedBox(height: 16),
            sectionTitle(context, 'عکس نمونه (اختیاری)'),
            InkWell(
              onTap: _photoSheet,
              child: Container(
                height: 140,
                decoration: BoxDecoration(border: Border.all(color: Colors.black26), borderRadius: BorderRadius.circular(8)),
                clipBehavior: Clip.antiAlias,
                child: _photo == null
                    ? const Center(child: Icon(Icons.add_a_photo_outlined, size: 36))
                    : Image.memory(photoBytes(_photo!), fit: BoxFit.cover, width: double.infinity),
              ),
            ),
            const SizedBox(height: 16),
            IgnorePointer(
              ignoring: _locked,
              child: Opacity(
                opacity: _locked ? 0.5 : 1,
                child: WarehousePicker(
                    value: _warehouseUid, useLast: !_isEdit, onChanged: (String? v) => _warehouseUid = v),
              ),
            ),
            OuncePicker(value: _ounceUid, onChanged: (String? v) => _ounceUid = v),
            IgnorePointer(
              ignoring: _locked,
              child: Opacity(
                opacity: _locked ? 0.5 : 1,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  sectionTitle(context, 'قیمت و وزن'),
                  numField(_ounce, 'انس پسته (اختیاری)'),
                  if (_fx && !_isEdit)
                    FxDocFields(c: _fxc, priceLabel: 'فی خرید ارزی (هر کیلو)', onChanged: () => setState(() {})),
                  if (!_fxc.active && !_useGrades)
                    MoneyField(controller: _price, label: 'فی خرید (به ازای هر کیلو)', required: true, onChanged: () => setState(() {})),
                  if (_priceTableOn && !_fxc.active && !_useGrades)
                    PriceSuggestionHint(
                        typeName: _suggestTypeName, ounceUid: _ounceUid, onAccept: (num v) => setState(() => MoneyField.setStored(_price, v))), // S35.T35.4
                  if (_gradesOn && !_fxc.active) GradeLinesEditor(c: _gc, netKg: _net, onChanged: () => setState(() {})),
                  if (!_fx) fxLockedField('خرید به ارز'),
                  numField(_total, 'وزن کل (ناخالص) به کیلو', required: true, onChanged: () => setState(() {})),
                  Row(children: [
                    Expanded(
                        child: numField(_smallSack, 'تعداد گونی کوچک (۱۰۰ گرم)', hint: '0', onChanged: () => setState(() {}))),
                    const SizedBox(width: 8),
                    Expanded(
                        child: numField(_largeSack, 'تعداد گونی بزرگ (۲۰۰ گرم)', hint: '0', onChanged: () => setState(() {}))),
                  ]),
                  if (_weighOn) ...[
                    sectionTitle(context, 'توزین'),
                    const Padding(
                      padding: EdgeInsets.only(bottom: 4),
                      child: Text('تارا یعنی وزن گونی یا ظرف خالی که از وزن کل کم می‌شود', style: TextStyle(fontSize: 12, color: Colors.black54)),
                    ),
                    numField(_tareManual, 'تارا (کیلو) — خالی = از تعداد گونی', hint: faNum(_sackTare), onChanged: () => setState(() {})),
                    Row(children: [
                      Expanded(child: numField(_deduct, _deductPct ? 'کسر کیفیت (درصد)' : 'کسر کیفیت (کیلو)', onChanged: () => setState(() {}))),
                      const SizedBox(width: 8),
                      DropdownButton<bool>(
                        value: _deductPct,
                        items: const <DropdownMenuItem<bool>>[
                          DropdownMenuItem<bool>(value: false, child: Text('کیلو')),
                          DropdownMenuItem<bool>(value: true, child: Text('درصد')),
                        ],
                        onChanged: (bool? v) => setState(() => _deductPct = v ?? false),
                      ),
                    ]),
                    textField(_ticket, 'شمارهٔ قبض باسکول'),
                    Row(children: [
                      Expanded(child: textField(_plate, 'پلاک')),
                      const SizedBox(width: 8),
                      Expanded(child: textField(_driver, 'راننده')),
                    ]),
                  ],
                  Card(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(children: [
                        infoRow(_weighOn ? 'تارا' : 'وزن گونی‌ها', '${faNum(_tare)} کیلو'),
                        if (_weighOn && _deductKg > 0) infoRow('کسر کیفیت', '${faNum(_deductKg)} کیلو'),
                        infoRow('وزن پسته (خالص)', '${faNum(_net)} کیلو'),
                        infoRow('ارزش کل', Fmt.money(_net * _priceVal)),
                        if (_fxc.active && _fxc.priceCcyNum != null) ...[
                          infoRow('فی خرید ارزی (هر کیلو)', faCcy(_fxc.ccy!, _fxc.priceCcyNum!, dec: _fxc.decimals)),
                          infoRow('ارزش کل ارزی', faCcy(_fxc.ccy!, _net * _fxc.priceCcyNum!, dec: _fxc.decimals)),
                        ],
                      ]),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (preset == 'dombest') ...[
                    sectionTitle(context, 'مشخصات پسته دنبست'),
                    numField(_gram, 'گرم'),
                    numField(_pctKhandan, 'درصد پسته خندان در دنبست', suffix: '٪', max: 100),
                    numField(_pctCrooked, 'درصد پسته کج / ناخالص', suffix: '٪', max: 100),
                  ] else if (preset == 'khandan') ...[
                    sectionTitle(context, 'مشخصات پسته خندان'),
                    numField(_pctDombest, 'درصد دنبست در پسته خندان', suffix: '٪', max: 100),
                    numField(_pctTuchin, 'درصد توچین', suffix: '٪', max: 100),
                    numField(_pctCrooked, 'درصد پسته کج / ناخالص', suffix: '٪', max: 100),
                  ] else ...[
                    Row(children: [
                      Expanded(child: sectionTitle(context, 'مشخصات (حداکثر ۴ مورد دلخواه)')),
                      if (_customSpecs.length < kMaxCustomSpecs)
                        IconButton(onPressed: _addCustomSpec, icon: const Icon(Icons.add_circle_outline)),
                    ]),
                    for (var i = 0; i < _customSpecs.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(children: [
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: _customSpecs[i].label,
                              decoration: const InputDecoration(labelText: 'عنوان', border: OutlineInputBorder()),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            flex: 3,
                            child: TextField(
                              controller: _customSpecs[i].value,
                              decoration: const InputDecoration(labelText: 'مقدار', border: OutlineInputBorder()),
                            ),
                          ),
                          IconButton(
                            onPressed: () => _removeCustomSpec(i),
                            icon: const Icon(Icons.close, size: 20),
                          ),
                        ]),
                      ),
                    if (_customSpecs.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: OutlinedButton.icon(
                          onPressed: _addCustomSpec,
                          icon: const Icon(Icons.add),
                          label: const Text('افزودن مشخصه'),
                        ),
                      ),
                  ],
                ]),
              ),
            ),
            sectionTitle(context, 'سایر'),
            PartyField(controller: _seller, label: 'فروشنده (اختیاری)'),
            textField(_note, 'توضیحات (اختیاری)', lines: 2),
            MoneyField(controller: _laborCost, label: 'هزینه کارگر — اختیاری', hint: 'اگر وارد شود از سود این پسته کم می‌شود'),
            if (_finOn) ...[
              sectionTitle(context, 'بلوک مالی'),
              MoneyField(controller: _finDisc, label: 'تخفیف — اختیاری'),
              MoneyField(controller: _finWb, label: 'هزینهٔ باسکول — اختیاری'),
              DropdownButtonFormField<String>(
                value: _finPayer,
                decoration: const InputDecoration(labelText: 'هزینه‌های جانبی بر عهدهٔ'),
                items: const <DropdownMenuItem<String>>[
                  DropdownMenuItem<String>(value: 'us', child: Text('ما')),
                  DropdownMenuItem<String>(value: 'party', child: Text('طرف حساب')),
                ],
                onChanged: (String? v) => setState(() => _finPayer = v ?? 'us'),
              ),
            ],
            if (_finOn && widget.existing != null) FinBlockCard(docType: 'purchase', docId: (widget.existing!['id'] as num?)?.toInt()), // S35.T35.6f
            MoneyField(controller: _transportCost, label: 'هزینه حمل‌ونقل / باسکول — اختیاری', hint: 'اگر وارد شود از سود این پسته کم می‌شود'),
            TaxChoiceField(status: _taxStatus, rate: _taxRate, onChanged: (String? v) => setState(() => _taxStatus = v)),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.check),
              label: Text(_isEdit ? 'ذخیره تغییرات' : 'ثبت خرید'),
            ),
            if (_draftOn && !_isEdit) ...<Widget>[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _saving ? null : () => _save(draft: true),
                icon: const Icon(Icons.edit_note),
                label: const Text('ذخیره به‌عنوان پیش‌نویس'),
              ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
