import 'package:flutter/material.dart';

import 'export_docs_pdf.dart';
import 'utils.dart';
import 'widgets.dart' show snack;
import 'warehouse_ui.dart' show StockApi, StockApiException;

/// S31.T31.10b/11b — export info form on an FX sale (sale_export.get|save) + packing list / origin certificate PDF buttons.
/// Online only; [saleId] must be the SERVER id (callers resolve it via AppDb.serverIdOf('sale', localId)).

class SaleExportScreen extends StatefulWidget {
  final int saleId;
  const SaleExportScreen({super.key, required this.saleId});

  @override
  State<SaleExportScreen> createState() => _SaleExportScreenState();
}

class _SaleExportScreenState extends State<SaleExportScreen> {
  static const List<String> _textKeys = <String>[
    'port_loading', 'port_destination', 'ccy_code', 'remit_no', 'lc_bank', 'lc_no',
    'pkg_count', 'pkg_type', 'gross_kg', 'marks', 'origin_country', 'hs_code', 'cert_no',
  ];
  static const Map<String, String> _labels = <String, String>{
    'port_loading': 'بندر بارگیری',
    'port_destination': 'بندر مقصد',
    'ccy_code': 'کد ارز (مثلاً USD)',
    'remit_no': 'شمارهٔ حواله',
    'lc_bank': 'بانک گشایش‌کننده',
    'lc_no': 'شمارهٔ اعتبار اسنادی',
    'pkg_count': 'تعداد بسته',
    'pkg_type': 'نوع بسته',
    'gross_kg': 'وزن ناخالص (کیلو)',
    'marks': 'علائم و شماره‌ها',
    'origin_country': 'کشور مبدأ',
    'hs_code': 'کد تعرفه (HS)',
    'cert_no': 'شمارهٔ گواهی مبدأ',
  };
  static const Set<String> _numeric = <String>{'pkg_count', 'gross_kg'};

  final Map<String, TextEditingController> _c = <String, TextEditingController>{for (final String k in _textKeys) k: TextEditingController()};
  List<String> _incoterms = <String>[];
  List<String> _ships = <String>[];
  String? _incoterm;
  String? _ship;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final TextEditingController c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> _strs(dynamic v) => v is List ? <String>[for (final dynamic e in v) '$e'] : <String>[];

  Future<void> _load() async {
    try {
      final Map<String, dynamic> r = await StockApi.call('sale_export.get', <String, dynamic>{'sale_id': widget.saleId});
      if (!mounted) return;
      final Map<String, dynamic> f = r['fields'] is Map ? Map<String, dynamic>.from(r['fields'] as Map) : <String, dynamic>{};
      final Map<String, dynamic> d = r['defaults'] is Map ? Map<String, dynamic>.from(r['defaults'] as Map) : <String, dynamic>{};
      setState(() {
        _incoterms = _strs(r['incoterms']);
        _ships = _strs(r['ship_methods']);
        for (final String k in _textKeys) {
          final dynamic v = f[k] ?? (k == 'ccy_code' ? d['ccy_code'] : null);
          _c[k]!.text = v == null ? '' : '$v';
        }
        final String? inc = f['incoterm'] == null ? null : '${f['incoterm']}';
        final String? sh = f['ship_method'] == null ? null : '${f['ship_method']}';
        _incoterm = (inc != null && _incoterms.contains(inc)) ? inc : null;
        _ship = (sh != null && _ships.contains(sh)) ? sh : null;
        _loading = false;
      });
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<bool> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final Map<String, dynamic> p = <String, dynamic>{
      'sale_id': widget.saleId,
      'incoterm': _incoterm ?? '',
      'ship_method': _ship ?? '',
      for (final String k in _textKeys) k: _numeric.contains(k) ? _c[k]!.text.trim().replaceAll(RegExp(r'[^0-9.]'), '') : _c[k]!.text.trim(),
    };
    try {
      await StockApi.call('sale_export.save', p);
      if (!mounted) return true;
      setState(() => _busy = false);
      return true;
    } on StockApiException catch (e) {
      if (!mounted) return false;
      setState(() {
        _error = e.message;
        _busy = false;
      });
      return false;
    }
  }

  Future<void> _pdf(String kind) async {
    if (!await _save()) return; // PDFs are built from the saved fields
    if (!mounted) return;
    await ExportDocsPdf.open(context, widget.saleId, kind);
  }

  Widget _dd(String label, String? value, List<String> items, ValueChanged<String?> onChanged) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: DropdownButtonFormField<String>(
          value: value,
          isExpanded: true,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
          items: <DropdownMenuItem<String>>[for (final String s in items) DropdownMenuItem<String>(value: s, child: Text(s))],
          onChanged: onChanged,
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('اطلاعات صادراتی فروش')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(padding: const EdgeInsets.all(12), children: <Widget>[
                if (_busy) const LinearProgressIndicator(),
                if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_error!, style: const TextStyle(color: Colors.red))),
                _dd('اینکوترمز', _incoterm, _incoterms, (String? v) => setState(() => _incoterm = v)),
                _dd('روش حمل', _ship, _ships, (String? v) => setState(() => _ship = v)),
                for (final String k in _textKeys)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: TextField(
                      controller: _c[k],
                      keyboardType: _numeric.contains(k) ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
                      textCapitalization: k == 'ccy_code' ? TextCapitalization.characters : TextCapitalization.none,
                      decoration: InputDecoration(labelText: _labels[k], border: const OutlineInputBorder()),
                    ),
                  ),
                FilledButton.icon(
                  onPressed: _busy ? null : () async {
                    if (await _save() && mounted) snack(context, 'ذخیره شد');
                  },
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('ذخیره'),
                ),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: <Widget>[
                  OutlinedButton.icon(onPressed: _busy ? null : () => _pdf('packing'), icon: const Icon(Icons.inventory_2_outlined), label: const Text('لیست بسته‌بندی')),
                  OutlinedButton.icon(onPressed: _busy ? null : () => _pdf('origin'), icon: const Icon(Icons.verified_outlined), label: const Text('گواهی مبدأ')),
                ]),
              ]),
      ),
    );
  }
}
