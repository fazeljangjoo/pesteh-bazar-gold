import 'package:flutter/material.dart';

import 'db.dart';
import 'license_service.dart';
import 'utils.dart';
import 'warehouse_ui.dart';
import 'widgets.dart';

/// یکسان‌سازی «ي/ك» عربی و «ی/ک» فارسی برای جستجو
String _norm(String s) => s.replaceAll('ي', 'ی').replaceAll('ك', 'ک').trim();

/// سهم هر جنس مبدأ در مخلوط: وزنی که برداشته می‌شود + (اختیاری) تعداد گونیِ مصرف‌شده از آن جنس
class _SourceRow {
  final weight = TextEditingController();
  final small = TextEditingController();
  final large = TextEditingController();
  String? wh; // S01.T01.4b: انبار برداشت (فقط وقتی جنس در چند انبار است)
  void dispose() {
    weight.dispose();
    small.dispose();
    large.dispose();
  }
}

/// صفحه‌ی «ساخت مخلوط (کوت‌ریزی)»: چند بار موجود در انبار را با وزن دلخواه
/// ترکیب می‌کند و یک بار تازه با وزن خالص و تعداد گونیِ واقعیِ اندازه‌گیری‌شده می‌سازد.
/// از این پس در فروش فقط همین یک بار انتخاب می‌شود.
class MixForm extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const MixForm({super.key, this.existing});
  @override
  State<MixForm> createState() => _MixFormState();
}

class _MixFormState extends State<MixForm> with EditGuard<MixForm> {
  final _form = GlobalKey<FormState>();
  List<Map<String, dynamic>> _lots = [];
  final Map<int, bool> _sel = {};
  final Map<int, _SourceRow> _rows = {};
  bool _loading = true;
  bool _saving = false;
  String _query = '';
  String? _warehouseUid; // S01
  String? _ounceUid; // S01

  bool get _isEdit => widget.existing != null;

  List<Map<String, dynamic>> _categories = [];
  int? _categoryId;
  List<Map<String, dynamic>> _baseTypes = []; // انواع پسته‌ی دستهٔ انتخاب‌شده (زیردسته)
  String? _baseType; // نوع زیردسته‌ی انتخاب‌شده (برای دقیق‌تر شدن نمودارها)
  final _typeName = TextEditingController();
  final _netWeight = TextEditingController();
  final _smallSack = TextEditingController();
  final _largeSack = TextEditingController();
  final _ounce = TextEditingController(); // اختیاری
  final _gram = TextEditingController(); // اختیاری
  final _waste = TextEditingController(); // ضایعات/خاک
  final _note = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final lots = _isEdit
        ? await AppDb.I.lotsForMixEdit(widget.existing!['id'] as int)
        : await AppDb.I.lots();
    final cats = await AppDb.I.categories();
    if (!mounted) return;
    setState(() {
      _lots = lots;
      _categories = cats;
      _categoryId = cats.isNotEmpty ? cats.first['id'] as int : null;
      _loading = false;
    });
    await _loadBaseTypes();
    if (_isEdit) {
      final e = widget.existing!;
      final sources = await AppDb.I.mixSourcesOf(e['id'] as int);
      _typeName.text = e['type_name'] as String? ?? '';
      _netWeight.text = plain(e['net_weight'] as num);
      _smallSack.text = plain(e['small_sack_count'] as num);
      _largeSack.text = plain(e['large_sack_count'] as num);
      _ounce.text = e['ounce'] == null ? '' : plain(e['ounce'] as num);
      _gram.text = e['gram'] == null ? '' : plain(e['gram'] as num);
      _warehouseUid = e['warehouse_uid'] as String?;
      _ounceUid = e['ounce_uid'] as String?;
      _note.text = e['note'] as String? ?? '';
      _categoryId = e['category_id'] as int?;
      _baseType = e['base_type'] as String?;
      await _loadBaseTypes();
      var takenOld = 0.0;
      for (final source in sources) {
        final id = source['source_purchase_id'] as int;
        _sel[id] = true;
        final row = _rows.putIfAbsent(id, () => _SourceRow());
        row.weight.text = plain(source['weight'] as num);
        row.small.text = plain(source['small_sacks'] as num? ?? 0);
        row.large.text = plain(source['large_sacks'] as num? ?? 0);
        takenOld += (source['weight'] as num).toDouble();
      }
      // مخلوط‌های قدیمی ضایعات ثبت‌نشده دارند: اختلاف وزن برداشته‌شده و خالص (اگر مثبت باشد) پیشنهاد می‌شود
      if (e['waste'] != null) {
        _waste.text = plain(e['waste'] as num);
      } else {
        final d = takenOld - (e['net_weight'] as num).toDouble();
        _waste.text = d > 0.0005 ? plain(double.parse(d.toStringAsFixed(3))) : '';
      }
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    for (final r in _rows.values) {
      r.dispose();
    }
    _typeName.dispose();
    _netWeight.dispose();
    _smallSack.dispose();
    _largeSack.dispose();
    _ounce.dispose();
    _gram.dispose();
    _waste.dispose();
    _note.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _selected =>
      _lots.where((e) => _sel[e['id'] as int] ?? false).toList();

  double get _takenSum => _selected.fold<double>(
      0, (s, e) => s + (parseNum(_rows[e['id'] as int]?.weight.text) ?? 0));

  /// وزن برداشته‌شده − (وزن خالص + ضایعات)؛ باید صفر باشد (گردشده به ۳ رقم)
  double get _balanceDiff {
    final net = parseNum(_netWeight.text) ?? 0;
    final double waste = parseNum(_waste.text) ?? 0.0;
    return double.parse((_takenSum - net - waste).toStringAsFixed(3));
  }

  Widget _balanceCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final net = parseNum(_netWeight.text) ?? 0;
    final double waste = parseNum(_waste.text) ?? 0.0;
    final diff = _balanceDiff;
    final ok = diff.abs() <= 0.0015;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          infoRow('برداشته‌شده (خالص)', '${faNum(_takenSum)} کیلو'),
          infoRow('وزن (خالص) + ضایعات', '${faNum(net + waste)} کیلو'),
          const SizedBox(height: 4),
          Text(
            ok
                ? '✓ وزن‌ها برابرند'
                : (diff > 0
                    ? '${faNum(diff)} کیلو اختلاف ثبت‌نشده دارید؛ اگر خاک یا ضایعات بوده در «ضایعات» وارد کنید'
                    : 'وزن (خالص) + ضایعات به اندازهٔ ${faNum(-diff)} کیلو از وزن برداشته‌شده بیشتر است'),
            style: TextStyle(color: ok ? Colors.green.shade700 : scheme.error),
          ),
        ]),
      ),
    );
  }

  void _toggle(int id, bool v) {
    setState(() {
      _sel[id] = v;
      _rows.putIfAbsent(id, () => _SourceRow());
    });
  }

  String? _overStock() {
    for (final e in _selected) {
      final id = e['id'] as int;
      final rem = (e['remaining'] as num).toDouble();
      final w = parseNum(_rows[id]?.weight.text) ?? 0;
      if (w > rem + 1e-6) {
        return 'وزن برداشته‌شده از «${e['type_name']}» بیشتر از موجودی آن (${faNum(rem)} کیلو (خالص)) است';
      }
      final sl = (e['small_left'] as num).toDouble();
      final ll = (e['large_left'] as num).toDouble();
      if ((parseNum(_rows[id]?.small.text) ?? 0) > sl + 1e-6) {
        return 'گونی کوچک مصرفی از «${e['type_name']}» بیشتر از موجودی آن (${faNum(sl)}) است';
      }
      if ((parseNum(_rows[id]?.large.text) ?? 0) > ll + 1e-6) {
        return 'گونی بزرگ مصرفی از «${e['type_name']}» بیشتر از موجودی آن (${faNum(ll)}) است';
      }
    }
    return null;
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!_form.currentState!.validate()) return;
    final sel = _selected;
    if (sel.isEmpty) {
      snack(context, 'حداقل یک جنس مبدأ را انتخاب کنید');
      return;
    }
    if (_takenSum <= 0) {
      snack(context, 'وزنی که از انبار برمی‌دارید را وارد کنید');
      return;
    }
    final over = _overStock();
    if (over != null) {
      snack(context, over);
      return;
    }
    if (_categoryId == null) {
      snack(context, 'دسته را انتخاب کنید');
      return;
    }
    if (_baseType == null || _baseType!.isEmpty) {
      snack(context, 'نوع پسته (زیردسته) را انتخاب کنید');
      return;
    }
    if (_typeName.text.trim().isEmpty) {
      snack(context, 'نام/نوع مخلوط را وارد کنید');
      return;
    }
    final net = parseNum(_netWeight.text) ?? 0;
    if (net <= 0) {
      snack(context, 'وزن نهایی مخلوط (بعد از توزین) را وارد کنید');
      return;
    }
    final double waste = parseNum(_waste.text) ?? 0.0;
    final diff = _balanceDiff;
    if (diff.abs() > 0.0015) {
      snack(
          context,
          diff > 0
              ? '${faNum(diff)} کیلو اختلاف ثبت‌نشده دارید؛ اگر خاک یا ضایعات بوده در «ضایعات» وارد کنید'
              : 'وزن (خالص) + ضایعات به اندازهٔ ${faNum(-diff)} کیلو از وزن برداشته‌شده بیشتر است');
      return;
    }
    setState(() => _saving = true);
    try {
      final sources = <Map<String, dynamic>>[];
      for (final e in sel) {
        final id = e['id'] as int;
        final r = _rows[id]!;
        final w = parseNum(r.weight.text) ?? 0;
        if (w <= 0) continue;
        sources.add({
          'purchase_id': id,
          'weight': w,
            'small_sacks': parseNum(r.small.text) ?? 0,
            'large_sacks': parseNum(r.large.text) ?? 0,
          if (r.wh != null) 'warehouse_uid': r.wh,
        });
      }
      final args = {
        'categoryId': _categoryId!,
        'typeName': _typeName.text.trim(),
        'baseType': _baseType,
        'sources': sources,
        'netWeight': net,
        'smallSackCount': parseNum(_smallSack.text) ?? 0.0,
        'largeSackCount': parseNum(_largeSack.text) ?? 0.0,
        'ounce': parseNum(_ounce.text),
        'gram': parseNum(_gram.text),
        'waste': waste,
        'note': _note.text.trim().isEmpty ? null : _note.text.trim(),
      };
      final ok = await saveConfirmed(context, () async {
      if (_isEdit) {
        await AppDb.I.updateMix(
          mixPurchaseId: widget.existing!['id'] as int,
          categoryId: args['categoryId'] as int,
          typeName: args['typeName'] as String,
          baseType: args['baseType'] as String?,
          sources: sources,
          netWeight: net,
          smallSackCount: args['smallSackCount'] as double,
          largeSackCount: args['largeSackCount'] as double,
          ounce: args['ounce'] as double?,
          gram: args['gram'] as double?,
          waste: waste,
          note: args['note'] as String?,
          warehouseUid: _warehouseUid,
          ounceUid: _ounceUid,
          uidsGiven: true,
        );
      } else {
        await AppDb.I.createMix(
          categoryId: args['categoryId'] as int,
          typeName: args['typeName'] as String,
          baseType: args['baseType'] as String?,
          sources: sources,
          netWeight: net,
          smallSackCount: args['smallSackCount'] as double,
          largeSackCount: args['largeSackCount'] as double,
          ounce: args['ounce'] as double?,
          gram: args['gram'] as double?,
          waste: waste,
          note: args['note'] as String?,
          warehouseUid: _warehouseUid,
          ounceUid: _ounceUid,
        );
      }
      }, successMsg: _isEdit ? 'مخلوط/جداسازی با موفقیت ویرایش شد' : 'مخلوط با موفقیت به انبار اضافه شد');
      if (mounted && ok) Navigator.pop(context);
    } catch (e) {
      if (mounted) snack(context, e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  List<Map<String, dynamic>> get _visibleLots {
    final q = _norm(_query);
    if (q.isEmpty) return _lots;
    return _lots.where((e) {
      if (_sel[e['id'] as int] ?? false) return true;
      return _norm('${e['code']} ${e['category_name']} ${e['type_name']}').contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_lots.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(_isEdit ? 'ویرایش مخلوط/جداسازی' : 'مخلوط / جداسازی')),
        body: const Center(child: Text('انبار خالی است')),
      );
    }
    final sel = _selected;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'ویرایش مخلوط/جداسازی' : 'مخلوط / جداسازی')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              color: scheme.primaryContainer,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text('هزینه ضایعات به صورت میانگین از سود همه اجناس جدا/مخلوط شده کم می‌شود.'),
              ),
            ),
            const SizedBox(height: 12),
            sectionTitle(context, '۱) انتخاب اجناس مبدأ'),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                decoration: const InputDecoration(
                  labelText: 'جستجو',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _selectAll,
                icon: const Icon(Icons.select_all),
                label: const Text('انتخاب همه اجناس'),
              ),
            ),
            for (final e in _visibleLots) _lotTile(e),
            const SizedBox(height: 8),
            if (sel.isNotEmpty) ...[
              sectionTitle(context, '۲) چقدر از هرکدام برمی‌دارید'),
              for (final e in sel) _sourceCard(e),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: infoRow('جمع وزن برداشته‌شده (خالص)', '${faNum(_takenSum)} کیلو'),
                ),
              ),
              const SizedBox(height: 8),
              sectionTitle(context, '۳) مشخصات قلم تازه (مخلوط/جداسازی)'),
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    value: _categoryId,
                    decoration:
                        const InputDecoration(labelText: 'دسته', border: OutlineInputBorder()),
                    items: _categories
                        .map((c) =>
                            DropdownMenuItem(value: c['id'] as int, child: Text(c['name'] as String)))
                        .toList(),
                    onChanged: (v) {
                      setState(() {
                        _categoryId = v;
                        _baseType = null;
                      });
                      _loadBaseTypes();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed: _addCategory,
                  icon: const Icon(Icons.add),
                  tooltip: 'افزودن دسته',
                ),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _baseType,
                    isExpanded: true,
                    decoration: const InputDecoration(
                        labelText: 'نوع پسته (زیردسته)',
                        helperText: 'مشخص می‌کند این قلم در نمودارها جزو کدام نوع پسته حساب شود',
                        border: OutlineInputBorder()),
                    items: _baseTypes
                        .map((t) => DropdownMenuItem<String>(value: t['name'] as String, child: Text(t['name'] as String)))
                        .toList(),
                    onChanged: (v) => setState(() => _baseType = v),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed: _addBaseType,
                  icon: const Icon(Icons.add),
                  tooltip: 'افزودن نوع',
                ),
              ]),
              const SizedBox(height: 12),
              textField(_typeName, 'نام قلم تازه (مثلاً «کوت‌ریز» یا «دنبست جداشده»)', required: true),
              numField(_netWeight, 'وزن نهایی (خالص) به کیلو — طبق ترازو',
                  required: true, onChanged: () => setState(() {})),
              numField(_waste, 'ضایعات / خاک (کیلو) — وزنِ کم‌شده هنگام مخلوط/جداسازی',
                  hint: '0', onChanged: () => setState(() {})),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () {
                    final d = double.parse((_takenSum - (parseNum(_netWeight.text) ?? 0)).toStringAsFixed(3));
                    _waste.text = d > 0 ? plain(d) : '0';
                    setState(() {});
                  },
                  icon: const Icon(Icons.balance),
                  label: const Text('ثبت اختلاف به‌عنوان ضایعات'),
                ),
              ),
              _balanceCard(context),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: numField(_smallSack, 'تعداد گونی کوچک (۱۰۰ گرم)', hint: '0')),
                const SizedBox(width: 8),
                Expanded(child: numField(_largeSack, 'تعداد گونی بزرگ (۲۰۰ گرم)', hint: '0')),
              ]),
              Row(children: [
                Expanded(child: numField(_ounce, 'انس (اختیاری)', hint: '0')),
                const SizedBox(width: 8),
                Expanded(child: numField(_gram, 'گرم (اختیاری)', hint: '0')),
              ]),
              WarehousePicker(
                  label: 'انبارِ بار مخلوط', value: _warehouseUid, useLast: !_isEdit, onChanged: (String? v) => _warehouseUid = v),
              OuncePicker(value: _ounceUid, onChanged: (String? v) => _ounceUid = v),
              textField(_note, 'توضیحات (اختیاری)', lines: 2),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check),
                label: Text(_isEdit ? 'ذخیره تغییرات' : 'ثبت در انبار'),
              ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _lotTile(Map<String, dynamic> e) {
    final id = e['id'] as int;
    final rem = (e['remaining'] as num).toDouble();
    return Card(
      key: ValueKey('lot$id'),
      child: CheckboxListTile(
        controlAffinity: ListTileControlAffinity.leading,
        value: _sel[id] ?? false,
        onChanged: (v) => _toggle(id, v ?? false),
        title: Text('${e['category_name']} - ${e['type_name']}'),
        subtitle: Text('کد ${e['code'] ?? '-'}  •  موجودی (خالص) ${faNum(rem)} کیلو  •  فی ${faNum(e['price'] as num, dec: 0)}'
            '${LicenseService.I.isFx.value && e['price_usd'] != null ? ' (${faUsd(e['price_usd'] as num, dec: 3)})' : ''}'),
      ),
    );
  }

  Widget _sourceCard(Map<String, dynamic> e) {
    final id = e['id'] as int;
    final rem = (e['remaining'] as num).toDouble();
    final r = _rows.putIfAbsent(id, () => _SourceRow());
    final w = parseNum(r.weight.text) ?? 0;
    final over = w > rem + 1e-6;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      key: ValueKey('src$id'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${e['category_name']} - ${e['type_name']}',
              style: Theme.of(context).textTheme.titleSmall),
          Text('موجودی (خالص) ${faNum(rem)} کیلو', style: const TextStyle(color: Colors.black54)),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () {
                r.weight.text = plain(rem);
                r.small.text = plain(e['small_left'] as num);
                r.large.text = plain(e['large_left'] as num);
                setState(() {});
              },
              icon: const Icon(Icons.all_inclusive),
              label: const Text('همه موجودی'),
            ),
          ),
          TextFormField(
            controller: r.weight,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'وزنی که از این جنس برمی‌دارید (خالص) به کیلو',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
            validator: (v) {
              final n = parseNum(v);
              if (n == null || n <= 0) return 'وزن را وارد کنید';
              if (n > rem + 1e-6) return 'بیشتر از موجودی';
              return null;
            },
          ),
          const SizedBox(height: 8),
          SaleWarehouseField(key: ValueKey('srcwh$id'), lotId: id, onChanged: (String? v) => r.wh = v),
          if (over)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('بیشتر از موجودی این جنس است', style: TextStyle(color: scheme.error)),
            ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextFormField(
                controller: r.small,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                validator: (v) => _sackCheck(v, (e['small_left'] as num).toDouble()),
                decoration: InputDecoration(
                    labelText: 'گونی کوچک مصرف‌شده (اختیاری)',
                    hintText: '0',
                    helperText: 'حداکثر ${faNum(e['small_left'] as num)}',
                    border: const OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextFormField(
                controller: r.large,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                validator: (v) => _sackCheck(v, (e['large_left'] as num).toDouble()),
                decoration: InputDecoration(
                    labelText: 'گونی بزرگ مصرف‌شده (اختیاری)',
                    hintText: '0',
                    helperText: 'حداکثر ${faNum(e['large_left'] as num)}',
                    border: const OutlineInputBorder()),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  String? _sackCheck(String? v, double cap) {
    if ((v ?? '').trim().isEmpty) return null;
    final n = parseNum(v);
    if (n == null || n < 0) return 'عدد معتبر وارد کنید';
    if (n > cap + 1e-6) return 'بیشتر از موجودی (${faNum(cap)})';
    return null;
  }

  void _selectAll() {
    setState(() {
      for (final e in _lots) {
        final id = e['id'] as int;
        _sel[id] = true;
        final row = _rows.putIfAbsent(id, () => _SourceRow());
        row.weight.text = plain(e['remaining'] as num);
        row.small.text = plain(e['small_left'] as num);
        row.large.text = plain(e['large_left'] as num);
      }
    });
  }

  Future<void> _loadBaseTypes() async {
    final id = _categoryId;
    final list = id == null ? <Map<String, dynamic>>[] : await AppDb.I.typesOf(id);
    if (!mounted) return;
    setState(() {
      _baseTypes = list;
      if (_baseType != null && !list.any((t) => t['name'] == _baseType)) _baseType = null;
    });
  }

  Future<void> _addBaseType() async {
    final cid = _categoryId;
    if (cid == null) {
      snack(context, 'اول دسته را انتخاب کنید');
      return;
    }
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('افزودن نوع پسته جدید'),
        content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(labelText: 'نام نوع (مثلاً دنبست)')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('افزودن')),
        ],
      ),
    );
    c.dispose();
    if (name == null || name.isEmpty) return;
    final ok = await saveConfirmed(context, () => AppDb.I.addType(cid, name), successMsg: 'نوع «$name» اضافه شد');
    if (!ok) return;
    _baseType = name;
    await _loadBaseTypes();
  }

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
    c.dispose();
    if (name == null || name.isEmpty) return;
    final id = await AppDb.I.addCategory(name);
    final cats = await AppDb.I.categories();
    if (mounted) setState(() { _categories = cats; _categoryId = id; _baseType = null; });
    await _loadBaseTypes();
  }
}
