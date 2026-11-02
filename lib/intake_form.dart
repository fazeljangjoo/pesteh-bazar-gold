import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'db.dart';
import 'entity_store.dart';
import 'utils.dart' show toEnDigits;

/// S5.T2: فرم پذیرش اتاق انس.
/// این فرم هیچ فیلد قیمتی ندارد؛ قیمت فقط در مرحلهٔ قطعی‌سازی (حسابدار) وارد می‌شود.
/// ذخیره = entity.save (پیش‌نویس، کار آفلاین) و «ثبت نهایی» = intake.submit (سرور کد پسته را می‌دهد).
class IntakeFormScreen extends StatefulWidget {
  const IntakeFormScreen({super.key, this.uid});

  /// شناسهٔ پیش‌نویس موجود برای ویرایش. فقط وضعیت draft قابل ویرایش است.
  final String? uid;

  @override
  State<IntakeFormScreen> createState() => _IntakeFormScreenState();
}

/// درصدهای پویا: هر ردیف یک نوع درصد + مقدار + گرم مغز (اختیاری)
class _PctRow {
  _PctRow({this.uid, this.defKey, String pct = '', String kernel = ''})
      : pctCtrl = TextEditingController(text: pct),
        kernelCtrl = TextEditingController(text: kernel);

  String? uid; // uid ردیف در lot_intake_pcts (null = هنوز ذخیره نشده)
  String? defKey;
  final TextEditingController pctCtrl;
  final TextEditingController kernelCtrl;

  void dispose() {
    pctCtrl.dispose();
    kernelCtrl.dispose();
  }
}

/// فهرست پیش‌فرض اگر pct_defs هنوز از سرور نیامده باشد (همان کلیدهای PB_INTAKE_CORE_DEFS سرور)
const List<Map<String, dynamic>> kFallbackPctDefs = <Map<String, dynamic>>[
  {'key': 'tuchin', 'label': 'توچین'},
  {'key': 'dombest', 'label': 'دهن‌بست'},
  {'key': 'crooked', 'label': 'کج'},
  {'key': 'khandan', 'label': 'خندان'},
];

/// عدد فارسی/انگلیسی را می‌خواند؛ خالی یا نامعتبر = null
double? parseIntakeNum(String? s) {
  if (s == null) return null;
  final t = toEnDigits(s.trim()).replaceAll('٫', '.').replaceAll('،', '').replaceAll(',', '').trim();
  if (t.isEmpty) return null;
  return double.tryParse(t);
}

/// اعتبارسنجی فرم (همان قواعد سرور + چیزهایی که فقط فرم می‌داند). null = بی‌ایراد.
String? validateIntakeForm({
  required int? categoryId,
  required String? typeName,
  required double? grossKg,
  required int small,
  required int large,
  required bool isSample,
  required String owner,
  required List<({String? defKey, double? pct, double? kernel})> pcts,
}) {
  if (categoryId == null) return 'دسته را انتخاب کنید.';
  if (typeName == null || typeName.trim().isEmpty) return 'نوع پسته را انتخاب کنید.';
  if (grossKg == null || grossKg <= 0) return 'وزن کل باید بزرگ‌تر از صفر باشد.';
  if (small < 0 || large < 0) return 'تعداد گونی نمی‌تواند منفی باشد.';
  if (!isSample && owner.trim().isEmpty) return 'نام صاحب پسته را وارد کنید (یا تیک «نمونه» را بزنید).';
  final seen = <String>{};
  double sum = 0;
  for (final r in pcts) {
    if (r.defKey == null) return 'برای هر ردیف درصد، نوع درصد را انتخاب کنید.';
    if (!seen.add(r.defKey!)) return 'هر نوع درصد فقط یک‌بار می‌تواند باشد.';
    final p = r.pct ?? 0;
    if (p < 0 || p > 100) return 'درصد باید بین ۰ و ۱۰۰ باشد.';
    if (r.kernel != null && (r.kernel! <= 0 || r.kernel! > 100)) {
      return 'گرم مغز در ۱۰۰ گرم باید بین ۰ و ۱۰۰ باشد.';
    }
    sum += p;
  }
  if (sum > 100.0001) return 'جمع درصدها از ۱۰۰ بیشتر است.';
  return null;
}

class _IntakeFormScreenState extends State<IntakeFormScreen> {
  final _gross = TextEditingController();
  final _small = TextEditingController(text: '0');
  final _large = TextEditingController(text: '0');
  final _gram = TextEditingController();
  final _ounce = TextEditingController();
  final _owner = TextEditingController();
  final _note = TextEditingController();

  List<Map<String, dynamic>> _categories = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _types = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _defs = <Map<String, dynamic>>[];
  final List<_PctRow> _pcts = <_PctRow>[];
  final List<String> _removedPctUids = <String>[];

  int? _categoryId;
  String? _typeName;
  bool _isSample = false;
  bool _loading = true;
  bool _busy = false;
  bool _readOnly = false;
  String? _uid; // پیش‌نویس فعلی؛ با اولین ذخیره ساخته می‌شود
  String? _error;
  String? _doneCode; // بعد از «ثبت نهایی»: کد موقت تا وقتی سرور کد نهایی را بدهد

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    for (final c in [_gross, _small, _large, _gram, _ounce, _owner, _note]) {
      c.dispose();
    }
    for (final r in _pcts) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _init() async {
    final cats = await AppDb.I.categories();
    final defsRaw = await EntityStore.I.list('pct_defs');
    final defs = defsRaw.where((d) => d['active'] != false).toList();
    Map<String, dynamic>? row;
    List<Map<String, dynamic>> pctRows = <Map<String, dynamic>>[];
    if (widget.uid != null) {
      row = await EntityStore.I.get('lot_intakes', widget.uid!);
      final all = await EntityStore.I.list('lot_intake_pcts');
      pctRows = all.where((p) => p['intake_id']?.toString() == widget.uid).toList();
    }
    if (!mounted) return;
    setState(() {
      _categories = cats;
      _defs = defs.isEmpty ? kFallbackPctDefs : defs;
      _uid = widget.uid;
      if (row != null) {
        _readOnly = (row['status'] ?? 'draft') != 'draft';
        _categoryId = (row['category_id'] as num?)?.toInt();
        _typeName = row['type_name'] as String?;
        _gross.text = row['gross_kg']?.toString() ?? '';
        _small.text = (row['small_sacks'] ?? 0).toString();
        _large.text = (row['large_sacks'] ?? 0).toString();
        _gram.text = row['gram']?.toString() ?? '';
        _ounce.text = row['ounce']?.toString() ?? '';
        _owner.text = row['owner_name'] as String? ?? '';
        _note.text = row['note'] as String? ?? '';
        _isSample = row['is_sample'] == true;
      } else if (cats.isNotEmpty) {
        _categoryId = cats.first['id'] as int?;
      }
      for (final p in pctRows) {
        _pcts.add(_PctRow(
          uid: p['uid'] as String?,
          defKey: p['def_key'] as String?,
          pct: p['pct']?.toString() ?? '',
          kernel: p['kernel_g']?.toString() ?? '',
        ));
      }
      _loading = false;
    });
    if (_categoryId != null) await _loadTypes(_categoryId!, keep: _typeName);
  }

  Future<void> _loadTypes(int categoryId, {String? keep}) async {
    final list = await AppDb.I.typesOf(categoryId);
    if (!mounted) return;
    setState(() {
      _types = list;
      final names = list.map((t) => t['name'] as String).toSet();
      _typeName = (keep != null && names.contains(keep)) ? keep : null;
    });
  }

  void _resetForm() {
    setState(() {
      _uid = null;
      _doneCode = null;
      _error = null;
      _readOnly = false;
      _gross.clear();
      _small.text = '0';
      _large.text = '0';
      _gram.clear();
      _ounce.clear();
      _owner.clear();
      _note.clear();
      _isSample = false;
      _typeName = null;
      for (final r in _pcts) {
        r.dispose();
      }
      _pcts.clear();
      _removedPctUids.clear();
    });
    if (_categoryId != null) _loadTypes(_categoryId!);
  }

  Map<String, dynamic> _intakeData() {
    final owner = _owner.text.trim();
    return <String, dynamic>{
      'category_id': _categoryId,
      'type_name': _typeName,
      'gross_kg': parseIntakeNum(_gross.text),
      'small_sacks': int.tryParse(toEnDigits(_small.text.trim())) ?? 0,
      'large_sacks': int.tryParse(toEnDigits(_large.text.trim())) ?? 0,
      'gram': parseIntakeNum(_gram.text),
      'ounce': parseIntakeNum(_ounce.text),
      'owner_name': _isSample ? null : owner,
      'is_sample': _isSample,
      'note': _note.text.trim(),
    };
  }

  /// ذخیرهٔ پیش‌نویس (پذیرش + درصدها) محلی و در صف. برمی‌گرداند uid.
  Future<String> _persist() async {
    final store = EntityStore.I;
    final uid = _uid ?? EntityStore.newUid();
    await store.save('lot_intakes', _intakeData(), uid: uid);
    _uid = uid;
    for (final u in _removedPctUids) {
      await store.delete('lot_intake_pcts', u);
    }
    _removedPctUids.clear();
    for (final r in _pcts) {
      if (r.defKey == null) continue; // ردیف خالی ذخیره نمی‌شود
      r.uid ??= EntityStore.newUid();
      await store.save(
        'lot_intake_pcts',
        <String, dynamic>{
          'intake_id': uid,
          'def_key': r.defKey,
          'pct': parseIntakeNum(r.pctCtrl.text) ?? 0,
          'kernel_g': parseIntakeNum(r.kernelCtrl.text), // null = پاک‌کردن مقدار قبلی
        },
        uid: r.uid,
      );
    }
    return uid;
  }

  String? _validateAll() {
    return validateIntakeForm(
      categoryId: _categoryId,
      typeName: _typeName,
      grossKg: parseIntakeNum(_gross.text),
      small: int.tryParse(toEnDigits(_small.text.trim())) ?? 0,
      large: int.tryParse(toEnDigits(_large.text.trim())) ?? 0,
      isSample: _isSample,
      owner: _owner.text,
      pcts: [
        for (final r in _pcts) (defKey: r.defKey, pct: parseIntakeNum(r.pctCtrl.text), kernel: parseIntakeNum(r.kernelCtrl.text)),
      ],
    );
  }

  double get _pctSum {
    double s = 0;
    for (final r in _pcts) {
      s += parseIntakeNum(r.pctCtrl.text) ?? 0;
    }
    return s;
  }

  Future<void> _saveDraft() async {
    if (_busy || _readOnly) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _persist();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('پیش‌نویس ذخیره شد'), duration: Duration(seconds: 2)));
    } on ArgumentError catch (e) {
      if (mounted) setState(() => _error = e.message?.toString() ?? 'ذخیره انجام نشد');
    } catch (e) {
      if (mounted) setState(() => _error = 'ذخیره انجام نشد: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    if (_busy || _readOnly) return;
    final err = _validateAll();
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final uid = await _persist();
      await EntityStore.I.submitIntake(uid);
      if (!mounted) return;
      setState(() {
        _readOnly = true;
        _doneCode = uid.substring(0, 6).toUpperCase();
      });
    } on ArgumentError catch (e) {
      if (mounted) setState(() => _error = e.message?.toString() ?? 'ثبت انجام نشد');
    } catch (e) {
      if (mounted) setState(() => _error = 'ثبت انجام نشد: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------------------------------------------------------- UI helpers

  InputDecoration _dec(String label, {String? hint, String? suffix}) => InputDecoration(
        labelText: label,
        hintText: hint,
        suffixText: suffix,
        border: const OutlineInputBorder(),
        isDense: true,
      );

  Widget _num(TextEditingController c, String label,
      {String? suffix, bool integer = false, double width = 220, bool enabled = true}) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: c,
        enabled: enabled && !_readOnly,
        textInputAction: TextInputAction.next,
        onSubmitted: (_) => FocusScope.of(context).nextFocus(),
        keyboardType: TextInputType.numberWithOptions(decimal: !integer),
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.allow(RegExp(integer ? r'[0-9۰-۹]' : r'[0-9۰-۹.٫]')),
        ],
        decoration: _dec(label, suffix: suffix),
      ),
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _pctSection() {
    final sum = _pctSum;
    final over = sum > 100.0001;
    return _section('درصدها', [
      for (final r in _pcts)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 200,
                child: DropdownButtonFormField<String>(
                  // اگر تعریف درصد دیگر فعال نیست، مقدار را نشان نده (وگرنه Flutter خطا می‌دهد)
                  value: _defs.any((d) => d['key'] == r.defKey) ? r.defKey : null,
                  decoration: _dec('نوع درصد'),
                  items: [
                    for (final d in _defs)
                      DropdownMenuItem<String>(
                        value: d['key'] as String?,
                        child: Text(d['label']?.toString() ?? d['key']?.toString() ?? ''),
                      ),
                  ],
                  onChanged: _readOnly ? null : (v) => setState(() => r.defKey = v),
                ),
              ),
              _num(r.pctCtrl, 'درصد', suffix: '٪', width: 130),
              _num(r.kernelCtrl, 'گرم مغز (اختیاری)', suffix: 'g', width: 170),
              if (!_readOnly)
                IconButton(
                  tooltip: 'حذف ردیف',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => setState(() {
                    if (r.uid != null) _removedPctUids.add(r.uid!);
                    _pcts.remove(r);
                    r.dispose();
                  }),
                ),
            ],
          ),
        ),
      Row(
        children: [
          if (!_readOnly)
            OutlinedButton.icon(
              onPressed: () => setState(() => _pcts.add(_PctRow())),
              icon: const Icon(Icons.add),
              label: const Text('افزودن مشخصات'),
            ),
          const Spacer(),
          Text('جمع: ${sum.toStringAsFixed(sum % 1 == 0 ? 0 : 2)}٪',
              style: TextStyle(color: over ? Colors.red : null, fontWeight: FontWeight.w600)),
        ],
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final String title = _uid == null ? 'پذیرش جدید' : (_readOnly ? 'مشاهدهٔ پذیرش' : 'ویرایش پیش‌نویس');
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : CallbackShortcuts(
              bindings: <ShortcutActivator, VoidCallback>{
                const SingleActivator(LogicalKeyboardKey.keyS, control: true): _submit,
                const SingleActivator(LogicalKeyboardKey.keyD, control: true): _saveDraft,
              },
              child: FocusTraversalGroup(
                policy: OrderedTraversalPolicy(),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 820),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_doneCode != null) _doneCard(),
                          if (_readOnly && _doneCode == null)
                            const Padding(
                              padding: EdgeInsets.only(bottom: 12),
                              child: Text('این پذیرش دیگر قابل ویرایش نیست.',
                                  style: TextStyle(color: Colors.orange)),
                            ),
                          AbsorbPointer(
                            absorbing: _readOnly,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _section('مشخصات محموله', [
                                  Wrap(
                                    spacing: 12,
                                    runSpacing: 12,
                                    children: [
                                      SizedBox(
                                        width: 220,
                                        child: DropdownButtonFormField<int>(
                                          value: _categories.any((c) => c['id'] == _categoryId) ? _categoryId : null,
                                          decoration: _dec('دسته'),
                                          items: [
                                            for (final c in _categories)
                                              DropdownMenuItem<int>(
                                                value: c['id'] as int,
                                                child: Text(c['name'] as String),
                                              ),
                                          ],
                                          onChanged: (v) {
                                            setState(() {
                                              _categoryId = v;
                                              _typeName = null;
                                            });
                                            if (v != null) _loadTypes(v);
                                          },
                                        ),
                                      ),
                                      SizedBox(
                                        width: 220,
                                        child: DropdownButtonFormField<String>(
                                          value: _typeName,
                                          decoration: _dec('نوع'),
                                          items: [
                                            for (final t in _types)
                                              DropdownMenuItem<String>(
                                                value: t['name'] as String,
                                                child: Text(t['name'] as String),
                                              ),
                                          ],
                                          onChanged: (v) => setState(() => _typeName = v),
                                        ),
                                      ),
                                      _num(_gross, 'وزن کل', suffix: 'کیلو'),
                                      _num(_small, 'گونی کوچک', integer: true, width: 150),
                                      _num(_large, 'گونی بزرگ', integer: true, width: 150),
                                    ],
                                  ),
                                ]),
                                _section('صاحب پسته', [
                                  CheckboxListTile(
                                    contentPadding: EdgeInsets.zero,
                                    value: _isSample,
                                    title: const Text('نمونه است (بدون صاحب)'),
                                    controlAffinity: ListTileControlAffinity.leading,
                                    onChanged: (v) => setState(() => _isSample = v ?? false),
                                  ),
                                  if (!_isSample)
                                    TextField(
                                      controller: _owner,
                                      textInputAction: TextInputAction.next,
                                      onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                                      decoration: _dec('نام صاحب پسته'),
                                    ),
                                ]),
                                _section('وزن‌های تکمیلی (اختیاری)', [
                                  Wrap(spacing: 12, runSpacing: 12, children: [
                                    _num(_gram, 'گرم', width: 170),
                                    _num(_ounce, 'انس', width: 170),
                                  ]),
                                ]),
                                _pctSection(),
                                _section('یادداشت', [
                                  TextField(
                                    controller: _note,
                                    maxLines: 2,
                                    maxLength: 500,
                                    decoration: _dec('یادداشت'),
                                  ),
                                ]),
                              ],
                            ),
                          ),
                          if (_error != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(_error!, style: const TextStyle(color: Colors.red)),
                            ),
                          if (!_readOnly)
                            Row(
                              children: [
                                OutlinedButton(
                                  onPressed: _busy ? null : _saveDraft,
                                  child: const Text('ذخیرهٔ پیش‌نویس'),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: FilledButton.icon(
                                    onPressed: _busy ? null : _submit,
                                    icon: _busy
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(strokeWidth: 2),
                                          )
                                        : const Icon(Icons.check),
                                    label: const Text('ثبت نهایی (Ctrl+S)'),
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _doneCard() {
    return Card(
      color: const Color(0xFFE8F5E9),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('پذیرش ثبت شد ✔', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            Text('کد موقت: $_doneCode'),
            const Text(
              'کد نهایی پسته پس از همگام‌سازی با سرور در فهرست پذیرش‌ها نمایش داده می‌شود.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _resetForm,
              icon: const Icon(Icons.add),
              label: const Text('پذیرش جدید'),
            ),
          ],
        ),
      ),
    );
  }
}
