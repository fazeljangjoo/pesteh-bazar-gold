import 'package:flutter/material.dart';

import 'db.dart';
import 'offline_docs.dart';
import 'pdf_output.dart';
import 'pdf_service.dart';
import 'perms.dart';
import 'returns_ui.dart' show ReturnsHelp;
import 'utils.dart';
import 'widgets.dart';

/// S04.T04.4 — pro-forma invoices (پیش‌فاکتور): list, form, convert-to-sale, PDF. Online (server is the source).
const Map<String, String> _kStatusFa = <String, String>{
  'draft': 'پیش‌نویس',
  'sent': 'ارسال‌شده',
  'accepted': 'پذیرفته‌شده',
  'expired': 'منقضی',
  'converted': 'تبدیل‌شده به فروش',
  'cancelled': 'لغوشده',
};

class ProformaListScreen extends StatefulWidget {
  const ProformaListScreen({super.key});
  @override
  State<ProformaListScreen> createState() => _ProformaListScreenState();
}

class _ProformaListScreenState extends State<ProformaListScreen> {
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  bool _loading = true;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await OfflineDocs.call('proformas.list', <String, dynamic>{});
      if (!mounted) return;
      setState(() {
        _items = ReturnsHelp.maps(r['items']);
        _loading = false;
        _err = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _err = e.toString();
      });
    }
  }

  Future<void> _edit(int? id) async {
    final bool? ok = await Navigator.push<bool>(
        context, MaterialPageRoute<bool>(builder: (_) => ProformaFormScreen(editId: id)));
    if (ok == true) await _load();
  }

  Future<void> _pdf(int id) async {
    final Map<String, dynamic> r = await OfflineDocs.call('proformas.get', <String, dynamic>{'id': id});
    final List<Map<String, dynamic>> its = ReturnsHelp.maps(r['items']);
    final file = await PdfService.buildDocument(
      title: 'پیش‌فاکتور فروش',
      fileTag: 'proforma_${r['number']}',
      header: <List<String>>[
        <String>['شماره', faNum(ReturnsHelp.d(r['number']), dec: 0)],
        <String>['تاریخ', jalaliDate('${r['date']}')],
        <String>['مشتری', '${r['party']}'],
        if (r['valid_until'] != null) <String>['اعتبار تا', jalaliDate('${r['valid_until']}')],
        <String>['وضعیت', _kStatusFa['${r['status']}'] ?? '${r['status']}'],
      ],
      columns: <String>['ردیف', 'شرح', 'وزن (کیلو)', 'فی (ریال)', 'تخفیف', 'مبلغ (ریال)'],
      rows: <List<String>>[
        for (int k = 0; k < its.length; k++)
          <String>[
            faNum(k + 1, dec: 0),
            '${its[k]['description'] ?? its[k]['type_name'] ?? '-'}${its[k]['code'] != null ? ' (${its[k]['code']})' : ''}',
            faNum(ReturnsHelp.d(its[k]['kg']), dec: 3),
            faNum(ReturnsHelp.d(its[k]['unit_price']), dec: 0),
            faNum(ReturnsHelp.d(its[k]['discount']), dec: 0),
            faNum(ReturnsHelp.d(its[k]['amount']), dec: 0),
          ],
      ],
      totals: <List<String>>[<String>['جمع کل (ریال)', faNum(ReturnsHelp.d(r['total']), dec: 0)]],
      note: [r['note'], r['terms']].where((x) => x != null && '$x'.trim().isNotEmpty).join('\n'),
    );
    if (!mounted) return;
    await PdfOutput.show(context, file);
  }

  Future<void> _action(Map<String, dynamic> r, String a) async {
    final int id = (r['id'] as num).toInt();
    try {
      if (a == 'edit') {
        await _edit(id);
        return;
      } else if (a == 'pdf') {
        await _pdf(id);
        return;
      } else if (a == 'convert') {
        if (!await confirm(context, 'این پیش‌فاکتور به فروش تبدیل شود؟ موجودی انبار کم می‌شود و بازگشت‌پذیر نیست مگر با حذف فروش.')) return;
        final Map<String, dynamic> res = await OfflineDocs.call('proformas.convert', <String, dynamic>{'id': id, 'date': ReturnsHelp.iso(DateTime.now())});
        if (mounted) snack(context, 'فروش ثبت شد (${faNum(((res['sale_ids'] as List?) ?? <dynamic>[]).length, dec: 0)} مورد). در فروش‌ها دیده می‌شود و خودکار همگام می‌شود.');
      } else if (a == 'del') {
        if (!await confirm(context, 'پیش‌فاکتور حذف شود؟')) return;
        await OfflineDocs.call('proformas.delete', <String, dynamic>{'id': id});
      } else {
        await OfflineDocs.call('proformas.set_status', <String, dynamic>{'id': id, 'status': a});
      }
      await _load();
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool canWrite = StaffPerms.I.can('sales.create');
    return Scaffold(
      appBar: AppBar(title: const Text('پیش‌فاکتورها')),
      floatingActionButton: canWrite
          ? FloatingActionButton.extended(onPressed: () => _edit(null), icon: const Icon(Icons.add), label: const Text('پیش‌فاکتور جدید'))
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _err != null
              ? Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(_err!)))
              : _items.isEmpty
                  ? const Center(child: Text('پیش‌فاکتوری ثبت نشده'))
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(children: <Widget>[
                        for (final Map<String, dynamic> r in _items)
                          ListTile(
                            title: Text('${r['party']} — شمارهٔ ${faNum(ReturnsHelp.d(r['number']), dec: 0)}'),
                            subtitle: Text('${jalaliDate('${r['date']}')} • ${_kStatusFa['${r['status']}'] ?? r['status']}'),
                            trailing: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
                              Text('${faNum(ReturnsHelp.d(r['total']), dec: 0)} ریال'),
                              PopupMenuButton<String>(
                                onSelected: (String v) => _action(r, v),
                                itemBuilder: (_) {
                                  final String st = '${r['status']}';
                                  final bool open = st != 'converted';
                                  return <PopupMenuEntry<String>>[
                                    const PopupMenuItem<String>(value: 'pdf', child: Text('PDF')),
                                    if (canWrite && open) const PopupMenuItem<String>(value: 'edit', child: Text('ویرایش')),
                                    if (canWrite && (st == 'draft' || st == 'sent' || st == 'accepted'))
                                      const PopupMenuItem<String>(value: 'convert', child: Text('تبدیل به فروش')),
                                    if (canWrite && (st == 'draft' || st == 'expired')) const PopupMenuItem<String>(value: 'sent', child: Text('علامت ارسال‌شده')),
                                    if (canWrite && (st == 'draft' || st == 'sent')) const PopupMenuItem<String>(value: 'accepted', child: Text('علامت پذیرفته‌شده')),
                                    if (canWrite && open && st != 'cancelled') const PopupMenuItem<String>(value: 'cancelled', child: Text('لغو')),
                                    if (canWrite && open) const PopupMenuItem<String>(value: 'del', child: Text('حذف')),
                                  ];
                                },
                              ),
                            ]),
                          ),
                      ]),
                    ),
    );
  }
}

class _Line {
  int? lot;
  final TextEditingController kg = TextEditingController();
  final TextEditingController price = TextEditingController();
  final TextEditingController disc = TextEditingController();
  void dispose() {
    kg.dispose();
    price.dispose();
    disc.dispose();
  }
}

class ProformaFormScreen extends StatefulWidget {
  final int? editId;
  const ProformaFormScreen({super.key, this.editId});
  @override
  State<ProformaFormScreen> createState() => _ProformaFormScreenState();
}

class _ProformaFormScreenState extends State<ProformaFormScreen> {
  final GlobalKey<FormState> _form = GlobalKey<FormState>();
  final TextEditingController _party = TextEditingController();
  final TextEditingController _note = TextEditingController();
  final TextEditingController _terms = TextEditingController();
  final List<_Line> _lines = <_Line>[];
  List<Map<String, dynamic>> _lots = <Map<String, dynamic>>[];
  DateTime _date = DateTime.now();
  DateTime? _valid;
  bool _reserve = false;
  bool _busy = false;
  String? _err;
  String? _uid;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _party.dispose();
    _note.dispose();
    _terms.dispose();
    for (final _Line l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  Future<void> _init() async {
    final all = await AppDb.I.inventoryAll();
    // only lots that exist on the server (positive id) and still have stock can be quoted against
    final lots = all.where((Map<String, dynamic> l) => AppDb.isAvailable(l) && ((l['id'] as int?) ?? 0) > 0 && l['is_mix'] != true && '${l['is_mix']}' != '1').toList();
    if (widget.editId != null) {
      try {
        final Map<String, dynamic> r = await OfflineDocs.call('proformas.get', <String, dynamic>{'id': widget.editId});
        _party.text = '${r['party']}';
        _note.text = '${r['note'] ?? ''}';
        _terms.text = '${r['terms'] ?? ''}';
        _reserve = r['reserve'] == true;
        _date = DateTime.tryParse('${r['date']}') ?? _date;
        _valid = r['valid_until'] == null ? null : DateTime.tryParse('${r['valid_until']}');
        for (final Map<String, dynamic> i in ReturnsHelp.maps(r['items'])) {
          final _Line l = _Line();
          l.lot = (i['lot_id'] as num?)?.toInt();
          l.kg.text = faNum(ReturnsHelp.d(i['kg']), dec: 3);
          l.price.text = faNum(ReturnsHelp.d(i['unit_price']), dec: 0);
          l.disc.text = ReturnsHelp.d(i['discount']) > 0 ? faNum(ReturnsHelp.d(i['discount']), dec: 0) : '';
          _lines.add(l);
        }
      } catch (e) {
        _err = e.toString();
      }
    }
    if (_lines.isEmpty) _lines.add(_Line());
    if (!mounted) return;
    setState(() => _lots = lots);
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
    for (final _Line l in _lines) {
      if (l.lot == null) {
        snack(context, 'برای هر قلم، جنس انبار را انتخاب کنید');
        return;
      }
      items.add(<String, dynamic>{
        'lot_id': l.lot,
        'kg': parseNum(l.kg.text) ?? 0,
        'unit_price': parseNum(l.price.text) ?? 0,
        'discount': parseNum(l.disc.text) ?? 0,
      });
    }
    _uid ??= ReturnsHelp.newUid('pf');
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await OfflineDocs.call('proformas.save', <String, dynamic>{
        if (widget.editId != null) 'id': widget.editId else 'uid': _uid,
        'party': _party.text.trim(),
        'date': ReturnsHelp.iso(_date),
        'valid_until': _valid == null ? null : ReturnsHelp.iso(_valid!),
        'reserve': _reserve ? 1 : 0,
        'note': _note.text.trim(),
        'terms': _terms.text.trim(),
        'items': items,
      });
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _err = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.editId == null ? 'پیش‌فاکتور جدید' : 'ویرایش پیش‌فاکتور')),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: <Widget>[
          textField(_party, 'نام مشتری', required: true),
          dateField(context, 'تاریخ', _date, (DateTime d) => setState(() => _date = d)),
          dateField(context, 'اعتبار تا (اختیاری)', _valid, (DateTime d) => setState(() => _valid = d)),
          if (_valid != null)
            Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => setState(() => _valid = null), child: const Text('حذف مهلت اعتبار'))),
          sectionTitle(context, 'اقلام'),
          for (int i = 0; i < _lines.length; i++) _lineCard(i),
          OutlinedButton.icon(
            onPressed: () => setState(() => _lines.add(_Line())),
            icon: const Icon(Icons.add),
            label: const Text('افزودن قلم'),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            value: _reserve,
            onChanged: (bool v) => setState(() => _reserve = v),
            title: const Text('رزرو نرم موجودی'),
            subtitle: const Text('فقط یادآوری است و فروش را مسدود نمی‌کند'),
          ),
          textField(_note, 'یادداشت', lines: 2),
          textField(_terms, 'شرایط', lines: 2),
          if (_err != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_err!, style: const TextStyle(color: Colors.red))),
          FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_outlined),
            label: const Text('ذخیره'),
          ),
        ]),
      ),
    );
  }

  Widget _lineCard(int i) {
    final _Line l = _lines[i];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(children: <Widget>[
          DropdownButtonFormField<int>(
            value: _lots.any((Map<String, dynamic> x) => x['id'] == l.lot) ? l.lot : null,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'جنس انبار', border: OutlineInputBorder()),
            items: <DropdownMenuItem<int>>[
              for (final Map<String, dynamic> x in _lots)
                DropdownMenuItem<int>(
                  value: x['id'] as int,
                  child: Text('${x['code'] ?? '-'} ${x['type_name'] ?? ''} (${faNum(ReturnsHelp.d(x['remaining']), dec: 1)} کیلو)', overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (int? v) => setState(() => l.lot = v),
          ),
          const SizedBox(height: 10),
          numField(l.kg, 'وزن', required: true, suffix: 'کیلو'),
          numField(l.price, 'فی', required: true, suffix: 'ریال', thousands: true),
          numField(l.disc, 'تخفیف این قلم (مبلغ)', suffix: 'ریال', thousands: true),
          if (_lines.length > 1)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => _lines.removeAt(i).dispose()),
                icon: const Icon(Icons.delete_outline),
                label: const Text('حذف قلم'),
              ),
            ),
        ]),
      ),
    );
  }
}
