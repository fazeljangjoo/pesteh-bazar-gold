import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import 'db.dart';
import 'license_service.dart';
import 'party_field.dart';
import 'tax_choice.dart';
import 'utils.dart';
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
  final _usdRate = TextEditingController(); // قیمت دلار هنگام خرید (فقط پلن ارزی)
  final _total = TextEditingController();
  final _smallSack = TextEditingController();
  final _largeSack = TextEditingController();

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

  /// فی دلاری هر کیلو = فی تومانی ÷ قیمت دلار
  double? get _usdPerKg {
    final p = parseNum(_price.text);
    final r = parseNum(_usdRate.text);
    if (p == null || r == null || r <= 0) return null;
    return p / r;
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
    final e = widget.existing;
    if (e != null) {
      _loadExistingPhoto(e['id'] as int?);
      _ounce.text = e['ounce'] == null ? '' : plain(e['ounce'] as num);
      _warehouseUid = e['warehouse_uid'] as String?;
      _ounceUid = e['ounce_uid'] as String?;
      _price.text = plain(e['price'] as num);
      _usdRate.text = e['usd_rate'] == null ? '' : plain(e['usd_rate'] as num);
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
    _laborCost.text = e['labor_cost'] == null ? '' : plain(e['labor_cost'] as num);
    _taxStatus = e['tax_status'] as String?;
    _taxRate.text = taxRateTextFromMilli(e['tax_rate_milli']);
    _transportCost.text = e['transport_cost'] == null ? '' : plain(e['transport_cost'] as num);
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

  double get _tare =>
      (parseNum(_smallSack.text) ?? 0) * 0.1 + (parseNum(_largeSack.text) ?? 0) * 0.2;
  double get _net => (parseNum(_total.text) ?? 0) - _tare;

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

  Future<void> _save() async {
    if (_saving) return;
    if (!_form.currentState!.validate()) return;

    if (_locked) {
      // فقط فی، فروشنده، عکس و توضیحات قابل ویرایش است (چون بخشی از این خرید فروخته شده)
      setState(() => _saving = true);
      final lockedData = <String, dynamic>{
        if (_photoChanged) 'photo': _photo,
        'price': parseNum(_price.text),
        if (_fx) 'usd_rate': parseNum(_usdRate.text),
        'seller': _seller.text.trim().isEmpty ? null : _seller.text.trim(),
        'note': _note.text.trim().isEmpty ? null : _note.text.trim(),
        'labor_cost': parseNum(_laborCost.text),
        'transport_cost': parseNum(_transportCost.text),
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
    if ((parseNum(_price.text) ?? 0) <= 0) {
      snack(context, 'فی خرید را وارد کنید');
      return;
    }
    if (_fx && (parseNum(_usdRate.text) ?? 0) <= 0) {
      snack(context, 'قیمت دلار روز خرید را وارد کنید');
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

    final data = {
      'category_id': _categoryId,
      'type_name': typeName,
      'photo': _photo,
      'ounce': parseNum(_ounce.text),
      'warehouse_uid': _warehouseUid,
      'ounce_uid': _ounceUid,
      'price': parseNum(_price.text),
      if (_fx) 'usd_rate': parseNum(_usdRate.text),
      'total_weight': parseNum(_total.text),
      'small_sack_count': parseNum(_smallSack.text) ?? 0,
      'large_sack_count': parseNum(_largeSack.text) ?? 0,
      'net_weight': _net,
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
        'labor_cost': parseNum(_laborCost.text),
        'transport_cost': parseNum(_transportCost.text),
      if (taxChoiceAvailable()) 'tax_status': _taxStatus,
      if (taxChoiceAvailable()) 'tax_rate_milli': _taxStatus == 'taxable' ? taxRateMilliFromText(_taxRate.text) : null,
    };

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
                  numField(_price, 'فی خرید (تومان به ازای هر کیلو)',
                      required: true, thousands: true, onChanged: () => setState(() {})),
                  if (_fx)
                    numField(_usdRate, 'قیمت دلار در زمان خرید (تومان)',
                        required: !_locked, thousands: true, onChanged: () => setState(() {}))
                  else
                    fxLockedField('قیمت دلار در زمان خرید (تومان)'),
                  numField(_total, 'وزن کل (ناخالص) به کیلو', required: true, onChanged: () => setState(() {})),
                  Row(children: [
                    Expanded(
                        child: numField(_smallSack, 'تعداد گونی کوچک (۱۰۰ گرم)', hint: '0', onChanged: () => setState(() {}))),
                    const SizedBox(width: 8),
                    Expanded(
                        child: numField(_largeSack, 'تعداد گونی بزرگ (۲۰۰ گرم)', hint: '0', onChanged: () => setState(() {}))),
                  ]),
                  Card(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(children: [
                        infoRow('وزن گونی‌ها', '${faNum(_tare)} کیلو'),
                        infoRow('وزن پسته (خالص)', '${faNum(_net)} کیلو'),
                        infoRow('ارزش کل', '${faNum(_net * (parseNum(_price.text) ?? 0), dec: 0)} تومان'),
                        if (_fx && _usdPerKg != null) ...[
                          infoRow('فی خرید به دلار (هر کیلو)', faUsd(_usdPerKg!, dec: 4)),
                          infoRow('ارزش کل به دلار', faUsd(_net * _usdPerKg!)),
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
            numField(_laborCost, 'هزینه کارگر (تومان) — اختیاری', thousands: true, hint: 'اگر وارد شود از سود این پسته کم می‌شود'),
            numField(_transportCost, 'هزینه حمل‌ونقل / باسکول (تومان) — اختیاری', thousands: true, hint: 'اگر وارد شود از سود این پسته کم می‌شود'),
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
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
