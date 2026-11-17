import 'package:flutter/material.dart';

import 'edition.dart';
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi;
import 'widgets.dart';

/// S15.T15.1b — fiscal years (gold only). Online calls via StockApi (server is source of truth).
class FiscalYear {
  final int id;
  final String name;
  final String start;
  final String end;
  final String status; // open | closed | locked
  final bool vatEnabled;
  final double? vatRate;
  final double? vatLevyRate;
  final String vatNote;
  final String vatSource;
  final bool isCurrent;

  const FiscalYear({
    required this.id,
    required this.name,
    required this.start,
    required this.end,
    required this.status,
    required this.vatEnabled,
    required this.vatRate,
    required this.vatLevyRate,
    required this.vatNote,
    required this.vatSource,
    required this.isCurrent,
  });

  factory FiscalYear.fromJson(Map<String, dynamic> j) {
    double? d(dynamic v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
    return FiscalYear(
      id: (j['id'] as num).toInt(),
      name: (j['name'] ?? '').toString(),
      start: (j['start_date'] ?? '').toString(),
      end: (j['end_date'] ?? '').toString(),
      status: (j['status'] ?? 'open').toString(),
      vatEnabled: j['vat_enabled'] == true || j['vat_enabled'] == 1,
      vatRate: d(j['vat_rate']),
      vatLevyRate: d(j['vat_levy_rate']),
      vatNote: (j['vat_note'] ?? '').toString(),
      vatSource: (j['vat_source'] ?? '').toString(),
      isCurrent: j['is_current'] == true || j['is_current'] == 1,
    );
  }

  String get statusFa => status == 'open' ? 'باز' : (status == 'closed' ? 'بسته' : 'قفل‌شده');
}

class FiscalService {
  FiscalService._();
  static final FiscalService I = FiscalService._();

  final ValueNotifier<List<FiscalYear>> years = ValueNotifier<List<FiscalYear>>(<FiscalYear>[]);

  FiscalYear? get current {
    for (final FiscalYear y in years.value) {
      if (y.isCurrent) return y;
    }
    return years.value.isEmpty ? null : years.value.last;
  }

  List<FiscalYear> _parse(Map<String, dynamic> r) {
    final dynamic items = r['items'];
    final List<FiscalYear> out = <FiscalYear>[];
    if (items is List) {
      for (final dynamic x in items) {
        if (x is Map) out.add(FiscalYear.fromJson(Map<String, dynamic>.from(x)));
      }
    }
    return out;
  }

  Future<void> refresh() async {
    if (!EditionService.I.edition.isGold) return;
    try {
      years.value = _parse(await StockApi.call('fiscal_years.list'));
    } catch (_) {}
  }

  Future<void> setCurrent(int id) async {
    years.value = _parse(await StockApi.call('fiscal_years.set_current', <String, dynamic>{'id': id}));
  }

  Future<void> save(Map<String, dynamic> payload) async {
    years.value = _parse(await StockApi.call('fiscal_years.save', payload));
  }

  Future<void> createNext({bool copyVat = true}) async {
    years.value = _parse(await StockApi.call('fiscal_years.create', <String, dynamic>{'copy_vat': copyVat}));
  }
}

/// FY switcher for the app bar: nothing is shown for green editions.
class FiscalSwitcher extends StatefulWidget {
  const FiscalSwitcher({super.key});

  @override
  State<FiscalSwitcher> createState() => _FiscalSwitcherState();
}

class _FiscalSwitcherState extends State<FiscalSwitcher> {
  @override
  void initState() {
    super.initState();
    FiscalService.I.refresh();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Edition>(
      valueListenable: EditionService.I.current,
      builder: (BuildContext context, Edition e, Widget? _) {
        if (!e.isGold) return const SizedBox.shrink();
        return ValueListenableBuilder<List<FiscalYear>>(
          valueListenable: FiscalService.I.years,
          builder: (BuildContext context, List<FiscalYear> ys, Widget? __) {
            final FiscalYear? cur = FiscalService.I.current;
            return PopupMenuButton<int>(
              tooltip: 'سال مالی',
              onOpened: () => FiscalService.I.refresh(),
              onSelected: (int id) async {
                try {
                  await FiscalService.I.setCurrent(id);
                } catch (err) {
                  if (context.mounted) snack(context, err.toString());
                }
              },
              itemBuilder: (BuildContext c) => <PopupMenuEntry<int>>[
                for (final FiscalYear y in ys)
                  CheckedPopupMenuItem<int>(
                    value: y.id,
                    checked: y.isCurrent,
                    child: Text('${y.name} (${y.statusFa})'),
                  ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
                  Icon(cur != null && cur.status != 'open' ? Icons.lock_outline : Icons.calendar_month,
                      size: 18, color: cur != null && cur.status != 'open' ? Colors.red : null),
                  const SizedBox(width: 4),
                  Text(
                      cur == null
                          ? 'سال مالی'
                          : (cur.status != 'open' ? '${cur.name} (فقط خواندنی)' : cur.name),
                      style: TextStyle(fontSize: 13, color: cur != null && cur.status != 'open' ? Colors.red : null)),
                ]),
              ),
            );
          },
        );
      },
    );
  }
}

/// FY + VAT settings screen (gold).
class FiscalSettingsScreen extends StatefulWidget {
  const FiscalSettingsScreen({super.key});

  @override
  State<FiscalSettingsScreen> createState() => _FiscalSettingsScreenState();
}

class _FiscalSettingsScreenState extends State<FiscalSettingsScreen> {
  bool _loading = true;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final r = await StockApi.call('fiscal_years.list');
      final dynamic items = r['items'];
      final List<FiscalYear> out = <FiscalYear>[];
      if (items is List) {
        for (final dynamic x in items) {
          if (x is Map) out.add(FiscalYear.fromJson(Map<String, dynamic>.from(x)));
        }
      }
      FiscalService.I.years.value = out;
    } catch (e) {
      _err = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _run(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
  }

  Future<void> _edit(FiscalYear y) async {
    final TextEditingController name = TextEditingController(text: y.name);
    final TextEditingController rate = TextEditingController(text: y.vatRate == null ? '' : y.vatRate.toString());
    final TextEditingController levy = TextEditingController(text: y.vatLevyRate == null ? '' : y.vatLevyRate.toString());
    final TextEditingController note = TextEditingController(text: y.vatNote);
    final TextEditingController source = TextEditingController(text: y.vatSource);
    bool vat = y.vatEnabled;
    String status = y.status;
    final bool locked = y.status == 'locked';
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter set) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: Text('سال مالی ${y.name}'),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
                TextField(controller: name, decoration: const InputDecoration(labelText: 'نام')),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: status,
                  decoration: const InputDecoration(labelText: 'وضعیت'),
                  items: <DropdownMenuItem<String>>[
                    const DropdownMenuItem<String>(value: 'open', child: Text('باز')),
                    const DropdownMenuItem<String>(value: 'closed', child: Text('بسته')),
                    if (locked) const DropdownMenuItem<String>(value: 'locked', child: Text('قفل‌شده')),
                  ],
                  onChanged: locked ? null : (String? v) => set(() => status = v ?? status),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('مالیات بر ارزش افزوده فعال'),
                  value: vat,
                  onChanged: (bool v) => set(() => vat = v),
                ),
                TextField(
                  controller: rate,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'نرخ مالیات (٪)', helperText: 'طبق اعلام سازمان امور مالیاتی؛ توسط حسابدار تأیید شود'),
                ),
                TextField(
                  controller: levy,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'نرخ عوارض (٪)'),
                ),
                TextField(controller: source, decoration: const InputDecoration(labelText: 'منبع نرخ')),
                TextField(controller: note, maxLines: 2, decoration: const InputDecoration(labelText: 'توضیح')),
              ]),
            ),
            actions: <Widget>[
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ذخیره')),
            ],
          ),
        ),
      ),
    );
    if (ok != true) return;
    String? numOrNull(TextEditingController c) {
      final String t = c.text.trim().replaceAll('٫', '.');
      return t.isEmpty ? null : t;
    }

    await _run(() => FiscalService.I.save(<String, dynamic>{
          'id': y.id,
          'name': name.text.trim(),
          if (!locked) 'status': status,
          'vat_enabled': vat,
          'vat_rate': numOrNull(rate),
          'vat_levy_rate': numOrNull(levy),
          'vat_source': source.text.trim(),
          'vat_note': note.text.trim(),
        }));
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('سال مالی و مالیات')),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _run(() => FiscalService.I.createNext()),
          icon: const Icon(Icons.add),
          label: const Text('سال مالی بعدی'),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _err != null
                ? Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
                      Text(_err!),
                      const SizedBox(height: 8),
                      OutlinedButton(onPressed: _load, child: const Text('تلاش دوباره')),
                    ]),
                  )
                : ValueListenableBuilder<List<FiscalYear>>(
                    valueListenable: FiscalService.I.years,
                    builder: (BuildContext context, List<FiscalYear> ys, Widget? _) {
                      return ListView(
                        padding: const EdgeInsets.only(bottom: 88),
                        children: <Widget>[
                          for (final FiscalYear y in ys.reversed)
                            ListTile(
                              leading: Icon(y.isCurrent ? Icons.star : Icons.calendar_month, color: y.isCurrent ? Colors.amber : null),
                              title: Text('${y.name} — ${y.statusFa}'),
                              subtitle: Text('${jalaliDate(y.start)} تا ${jalaliDate(y.end)}\n'
                                  '${y.vatEnabled ? 'مالیات: ${y.vatRate == null ? 'نرخ ثبت نشده' : '${faNum(y.vatRate!, dec: 1)}٪'}' : 'مالیات غیرفعال'}'),
                              isThreeLine: true,
                              trailing: y.isCurrent
                                  ? null
                                  : TextButton(
                                      onPressed: () => _run(() => FiscalService.I.setCurrent(y.id)),
                                      child: const Text('سال جاری'),
                                    ),
                              onTap: () => _edit(y),
                            ),
                        ],
                      );
                    },
                  ),
      ),
    );
  }
}
