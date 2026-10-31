import 'package:file_selector/file_selector.dart' show XFile, XTypeGroup, openFile;
import 'package:flutter/material.dart';

import 'edition.dart';
import 'excel_io.dart';
import 'import_engine.dart';
import 'perms.dart';
import 'warehouse_ui.dart' show StockApi;
import 'widgets.dart';

// S13.T13.2a — import wizard (kind → template/file → column mapping → validation preview).
// T13.2b: server check (dry run) + final commit via import.commit (idempotent by import_batch_id) + result report.
class ImportScreen extends StatefulWidget {
  final String? initialKind; // S35.T35.4b: preselect a kind (e.g. 'grade_prices')
  const ImportScreen({super.key, this.initialKind});
  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  late ImpKind _kind = kImportKinds.firstWhere((ImpKind k) => k.id == widget.initialKind, orElse: () => kImportKinds.first);
  ImpSheet? _sheet;
  String _fileName = '';
  Map<String, int> _map = <String, int>{};
  List<ImpRow> _rows = <ImpRow>[];
  String _batchId = _newBatchId();
  bool _allOrNothing = true;
  bool _updateDup = false;
  bool _busy = false;
  Map<String, dynamic>? _result;

  static String _newBatchId() => 'imp_${DateTime.now().microsecondsSinceEpoch}';

  Future<void> _run(bool dry) async {
    if (_busy || _rows.isEmpty) return;
    setState(() => _busy = true);
    try {
      final Map<String, dynamic> p = ImportEngine.payload(_kind, _rows, batchId: _batchId, dryRun: dry, allOrNothing: _allOrNothing);
      p['on_duplicate'] = _updateDup ? 'update' : 'skip';
      final Map<String, dynamic> r = await StockApi.call('import.commit', p);
      if (!mounted) return;
      setState(() => _result = r);
      if (!dry && r['committed'] == true) {
        _batchId = _newBatchId(); // next import (even same file) is a new batch; same-batch retries stay idempotent until then
        snack(context, 'ایمپورت ثبت شد');
      }
    } catch (e) {
      if (mounted) snack(context, '${e}'.replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _report() {
    final Map<String, dynamic> r = _result!;
    final List<dynamic> det = (r['rows'] as List<dynamic>?) ?? <dynamic>[];
    final bool dry = r['dry_run'] == true;
    final bool done = r['committed'] == true;
    final String head = dry ? 'نتیجهٔ بررسی سرور (هنوز چیزی ثبت نشده)' : (done ? (r['replayed'] == true ? 'این دسته قبلاً ثبت شده بود' : 'گزارش ثبت نهایی') : 'ثبت انجام نشد؛ هیچ داده‌ای نوشته نشد');
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text(head, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('جدید: ${r['created'] ?? 0}  |  ویرایش: ${r['updated'] ?? 0}  |  ردشده: ${r['skipped'] ?? 0}  |  خطا: ${r['failed'] ?? 0}'),
          for (final dynamic d in det.where((dynamic d) => d is Map && (d['status'] == 'error' || (d['message'] ?? '').toString().isNotEmpty)).take(100))
            ListTile(
              dense: true,
              leading: Icon(d['status'] == 'error' ? Icons.error_outline : Icons.info_outline, color: d['status'] == 'error' ? Colors.red : Colors.orange),
              title: Text('ردیف ${d['row']}'),
              subtitle: Text('${d['message'] ?? ''}'),
            ),
        ]),
      ),
    );
  }

  Future<void> _template() async {
    try {
      final f = await ImportEngine.template(_kind);
      if (mounted) await ExcelIo.saveOrShare(context, f);
    } catch (e) {
      if (mounted) snack(context, 'خطا در ساخت قالب: $e');
    }
  }

  Future<void> _pick() async {
    try {
      final XFile? x = await openFile(acceptedTypeGroups: <XTypeGroup>[
        const XTypeGroup(label: 'Excel / CSV', extensions: <String>['xlsx', 'csv']),
      ]);
      if (x == null) return;
      final s = ImportEngine.parse(x.name, await x.readAsBytes());
      if (!mounted) return;
      setState(() {
        _sheet = s;
        _fileName = x.name;
        _map = ImportEngine.autoMap(_kind, s.headers);
        _batchId = _newBatchId();
        _result = null;
        _revalidate();
      });
    } catch (e) {
      if (mounted) snack(context, '${e}'.replaceFirst('Exception: ', ''));
    }
  }

  void _revalidate() {
    final ImpSheet? s = _sheet;
    _rows = s == null ? <ImpRow>[] : ImportEngine.validate(_kind, s, _map);
  }

  @override
  Widget build(BuildContext context) {
    if (!StaffPerms.I.can('parties.create')) {
      return Scaffold(
          appBar: AppBar(title: const Text('ورود اطلاعات از اکسل')),
          body: const Center(child: Text('مجوز ورود اطلاعات را ندارید')));
    }
    final int bad = _rows.where((ImpRow r) => !r.ok).length;
    return Scaffold(
      appBar: AppBar(title: const Text('ورود اطلاعات از اکسل')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: <Widget>[
          DropdownButtonFormField<ImpKind>(
            value: _kind,
            decoration: const InputDecoration(labelText: 'نوع اطلاعات', border: OutlineInputBorder()),
            items: <DropdownMenuItem<ImpKind>>[
              for (final ImpKind k in kImportKinds)
                if ((k.id != 'accounts' || EditionService.I.edition.isGold) && (k.id != 'fx_rates' || EditionService.I.edition.isFx)) DropdownMenuItem<ImpKind>(value: k, child: Text(k.label)),
            ],
            onChanged: (ImpKind? k) {
              if (k == null) return;
              setState(() {
                _kind = k;
                _sheet = null;
                _rows = <ImpRow>[];
                _fileName = '';
                _result = null;
                _batchId = _newBatchId();
              });
            },
          ),
          const SizedBox(height: 10),
          Row(children: <Widget>[
            Expanded(
                child: OutlinedButton.icon(
                    onPressed: _template, icon: const Icon(Icons.download), label: const Text('دانلود قالب'))),
            const SizedBox(width: 8),
            Expanded(
                child: FilledButton.icon(
                    onPressed: _pick, icon: const Icon(Icons.upload_file), label: const Text('انتخاب فایل'))),
          ]),
          if (_sheet != null) ...<Widget>[
            const SizedBox(height: 12),
            Text('فایل: $_fileName — ${_rows.length} ردیف'),
            const SizedBox(height: 8),
            const Text('تطبیق ستون‌ها', style: TextStyle(fontWeight: FontWeight.bold)),
            for (final ImpField f in _kind.fields)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: DropdownButtonFormField<int>(
                  value: (_map[f.key] ?? -1) >= 0 && (_map[f.key] ?? -1) < _sheet!.headers.length ? _map[f.key] : -1,
                  decoration: InputDecoration(
                      labelText: f.required ? '${f.label} *' : f.label, border: const OutlineInputBorder(), isDense: true),
                  items: <DropdownMenuItem<int>>[
                    const DropdownMenuItem<int>(value: -1, child: Text('— بدون ستون —')),
                    for (int i = 0; i < _sheet!.headers.length; i++)
                      DropdownMenuItem<int>(value: i, child: Text(_sheet!.headers[i].isEmpty ? 'ستون ${i + 1}' : _sheet!.headers[i])),
                  ],
                  onChanged: (int? v) => setState(() {
                    _map[f.key] = v ?? -1;
                    _revalidate();
                  }),
                ),
              ),
            const SizedBox(height: 12),
            Text('ردیف سالم: ${_rows.length - bad}   |   ردیف خطادار: $bad',
                style: TextStyle(fontWeight: FontWeight.bold, color: bad > 0 ? Colors.red : Colors.green.shade800)),
            const SizedBox(height: 6),
            for (final ImpRow r in _rows.where((ImpRow r) => !r.ok).take(100))
              ListTile(
                dense: true,
                leading: const Icon(Icons.error_outline, color: Colors.red),
                title: Text('ردیف ${r.rowNo}'),
                subtitle: Text(r.errors.join('، ')),
              ),
            if (bad == 0 && _rows.isNotEmpty)
              ..._rows.take(20).map((ImpRow r) => ListTile(
                    dense: true,
                    leading: const Icon(Icons.check_circle_outline, color: Colors.green),
                    title: Text('ردیف ${r.rowNo}: ${r.values.values.take(3).join(' | ')}'),
                  )),
            const SizedBox(height: 12),
            SwitchListTile(
              dense: true,
              title: const Text('همه‌یا‌هیچ (با یک ردیف خطا هیچ‌چیز ثبت نشود)'),
              value: _allOrNothing,
              onChanged: _busy ? null : (bool v) => setState(() => _allOrNothing = v),
            ),
            SwitchListTile(
              dense: true,
              title: const Text('رکوردهای تکراری به‌روزرسانی شوند (پیش‌فرض: رد شوند)'),
              value: _updateDup,
              onChanged: _busy ? null : (bool v) => setState(() => _updateDup = v),
            ),
            Row(children: <Widget>[
              Expanded(
                child: OutlinedButton(
                  onPressed: (_rows.isEmpty || bad > 0 || _busy) ? null : () => _run(true),
                  child: const Text('بررسی روی سرور'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: (_rows.isEmpty || bad > 0 || _busy) ? null : () => _run(false),
                  child: Text(_busy ? 'در حال ارسال…' : 'ثبت نهایی'),
                ),
              ),
            ]),
            if (_result != null) _report(),
          ],
        ],
      ),
    );
  }
}
