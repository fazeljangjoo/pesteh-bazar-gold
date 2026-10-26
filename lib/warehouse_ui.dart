import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'db.dart';
import 'entity_store.dart';
import 'license_service.dart';
import 'sync_service.dart';
import 'utils.dart';
import 'widgets.dart';

/// S01.T01.4 — انبار / درجه‌بندی اونس: انتخابگرها، دسترسی به API انتقال و صفحهٔ «انتقال بین انبارها».
///
/// * انبارها و اونس‌ها موجودیت‌های عمومی‌اند (جدول entity_rows)؛ آفلاین هم ساخته/ویرایش می‌شوند.
/// * `null` برای انبار یعنی «انبار پیش‌فرض» (سرور آن را می‌سازد و بارهای بدون انبار را به آن می‌سپارد).
/// * انتقال بین انبارها و موجودی هر انبار فقط آنلاین است (دفتر حرکت‌های انبار روی سرور است).

const String kLastWarehouseKey = 'last_warehouse_uid';

class WhOption {
  final String uid;
  final String name;
  final bool isDefault;
  const WhOption(this.uid, this.name, this.isDefault);
}

class StockApiException implements Exception {
  final String message;
  /// true = no connection (the request never reached the server) → offline-capable callers may queue instead of failing.
  final bool network;
  StockApiException(this.message, {this.network = false});
  @override
  String toString() => message;
}

/// فراخوانی ساده و آنلاینِ app.php (فقط برای کارهای انباریِ آنلاین).
class StockApi {
  StockApi._();

  static Future<Map<String, dynamic>> call(String action, [Map<String, dynamic> payload = const <String, dynamic>{}]) async {
    final cred = await LicenseService.I.credentials();
    if (cred == null) throw StockApiException('نیاز به ورود مجدد است');
    final body = <String, dynamic>{'phone': cred.$1, 'token': cred.$2, 'action': action, 'payload': payload};
    http.Response resp;
    try {
      resp = await http
          .post(Uri.parse('${ApiConfig.baseUrl}/app.php'),
              headers: <String, String>{'Content-Type': 'application/json'}, body: jsonEncode(body))
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw StockApiException('اتصال به سرور برقرار نشد. اینترنت را بررسی کنید.', network: true);
    }
    Map<String, dynamic> data = <String, dynamic>{};
    try {
      final j = jsonDecode(utf8.decode(resp.bodyBytes));
      if (j is Map<String, dynamic>) data = j;
    } catch (_) {}
    if (resp.statusCode != 200) {
      throw StockApiException((data['error'] ?? 'خطای سرور (کد ${resp.statusCode})').toString());
    }
    return data;
  }
}

class StockLookup {
  StockLookup._();

  /// انبارهای فعال (پیش‌فرض اول).
  static Future<List<WhOption>> warehouses({bool includeInactive = false}) async {
    final rows = await EntityStore.I.list('warehouses');
    final out = <WhOption>[];
    for (final r in rows) {
      final active = r['active'];
      final isActive = active == null || active == true || active == 1;
      if (!isActive && !includeInactive) continue;
      final def = r['is_default'];
      out.add(WhOption(r['uid'] as String, (r['name'] as String?) ?? '-', def == true || def == 1));
    }
    out.sort((WhOption a, WhOption b) {
      if (a.isDefault != b.isDefault) return a.isDefault ? -1 : 1;
      return a.name.compareTo(b.name);
    });
    return out;
  }

  /// uid → نام (برای نمایش روی کارت‌ها)؛ بارِ بدون انبار = انبار پیش‌فرض.
  static Future<Map<String, String>> warehouseNames() async {
    final m = <String, String>{};
    for (final w in await warehouses(includeInactive: true)) {
      m[w.uid] = w.name;
    }
    return m;
  }

  static Future<String?> defaultWarehouseName() async {
    for (final w in await warehouses(includeInactive: true)) {
      if (w.isDefault) return w.name;
    }
    return null;
  }

  /// uid → کد درجه‌بندی اونس
  static Future<Map<String, String>> ounceCodes() async {
    final rows = await EntityStore.I.list('ounces');
    final m = <String, String>{};
    for (final r in rows) {
      m[r['uid'] as String] = (r['code'] as String?) ?? '-';
    }
    return m;
  }

  /// متن کوتاهِ «انبار / اونس» برای کارت موجودی؛ خالی = چیزی برای نمایش نیست.
  static Future<String> lotLabel(Map<String, dynamic> lot) async {
    final parts = <String>[];
    final wu = lot['warehouse_uid'];
    final names = await warehouseNames();
    if (wu is String && wu.isNotEmpty) {
      parts.add('انبار ${names[wu] ?? '-'}');
    } else {
      final d = await defaultWarehouseName();
      if (d != null) parts.add('انبار $d');
    }
    final ou = lot['ounce_uid'];
    if (ou is String && ou.isNotEmpty) {
      final codes = await ounceCodes();
      if (codes[ou] != null) parts.add('اونس ${codes[ou]}');
    }
    return parts.join('  •  ');
  }

  static Future<String?> lastWarehouse() => AppDb.I.metaGet(kLastWarehouseKey);
  static Future<void> rememberWarehouse(String? uid) async {
    if (uid != null && uid.isNotEmpty) await AppDb.I.metaSet(kLastWarehouseKey, uid);
  }
}

/// انتخاب انبار برای خرید/مخلوط. [value] = null یعنی هنوز انتخاب نشده (انبار پیش‌فرض / آخرین انتخاب).
/// اگر هیچ انباری روی گوشی نیست (هنوز دریافت نشده) چیزی نشان داده نمی‌شود و null = پیش‌فرضِ سرور.
class WarehousePicker extends StatefulWidget {
  final String? value;
  final ValueChanged<String?> onChanged;
  final String label;
  final bool useLast;
  const WarehousePicker({super.key, required this.value, required this.onChanged, this.label = 'انبار', this.useLast = true});

  @override
  State<WarehousePicker> createState() => _WarehousePickerState();
}

class _WarehousePickerState extends State<WarehousePicker> {
  List<WhOption> _opts = <WhOption>[];
  String? _sel;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _sel = widget.value;
    _load();
  }

  Future<void> _load() async {
    final opts = await StockLookup.warehouses();
    String? sel = _sel;
    if (sel == null && widget.useLast) {
      final last = await StockLookup.lastWarehouse();
      if (last != null && opts.any((WhOption o) => o.uid == last)) sel = last;
    }
    if (sel == null && opts.isNotEmpty) {
      for (final o in opts) {
        if (o.isDefault) sel = o.uid;
      }
    }
    if (sel != null && !opts.any((WhOption o) => o.uid == sel)) {
      // انبار غیرفعال/حذف‌شده: همان را نگه می‌داریم تا مقدار قبلی عوض نشود
      sel = opts.isNotEmpty ? sel : null;
    }
    if (!mounted) return;
    setState(() {
      _opts = opts;
      _sel = sel;
      _loaded = true;
    });
    if (sel != widget.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onChanged(sel);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded || _opts.isEmpty) return const SizedBox.shrink();
    final hasSel = _sel != null && _opts.any((WhOption o) => o.uid == _sel);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        value: hasSel ? _sel : null,
        isExpanded: true,
        decoration: InputDecoration(labelText: widget.label, border: const OutlineInputBorder()),
        items: <DropdownMenuItem<String>>[
          for (final o in _opts) DropdownMenuItem<String>(value: o.uid, child: Text(o.name)),
        ],
        onChanged: (String? v) {
          setState(() => _sel = v);
          StockLookup.rememberWarehouse(v);
          widget.onChanged(v);
        },
      ),
    );
  }
}

/// انتخاب درجه‌بندی اونس (اختیاری).
class OuncePicker extends StatefulWidget {
  final String? value;
  final ValueChanged<String?> onChanged;
  const OuncePicker({super.key, required this.value, required this.onChanged});

  @override
  State<OuncePicker> createState() => _OuncePickerState();
}

class _OuncePickerState extends State<OuncePicker> {
  Map<String, String> _codes = <String, String>{};
  String? _sel;

  @override
  void initState() {
    super.initState();
    _sel = widget.value;
    StockLookup.ounceCodes().then((Map<String, String> m) {
      if (mounted) setState(() => _codes = m);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_codes.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String?>(
        value: _codes.containsKey(_sel) ? _sel : null,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'درجه‌بندی اونس (اختیاری)', border: OutlineInputBorder()),
        items: <DropdownMenuItem<String?>>[
          const DropdownMenuItem<String?>(value: null, child: Text('— بدون —')),
          for (final e in _codes.entries) DropdownMenuItem<String?>(value: e.key, child: Text(e.value)),
        ],
        onChanged: (String? v) {
          setState(() => _sel = v);
          widget.onChanged(v);
        },
      ),
    );
  }
}

/// فروش: اگر این قلم در چند انبار موجود باشد (بعد از انتقال)، انتخاب انبار الزامی می‌شود.
/// موجودی هر انبار از سرور (آنلاین) خوانده می‌شود؛ آفلاین یا تک‌انبار = چیزی نشان داده نمی‌شود
/// (سرور خودش تنها انبارِ دارای موجودی را برمی‌دارد).
class SaleWarehouseField extends StatefulWidget {
  final int lotId;
  final ValueChanged<String?> onChanged;
  const SaleWarehouseField({super.key, required this.lotId, required this.onChanged});

  @override
  State<SaleWarehouseField> createState() => _SaleWarehouseFieldState();
}

class _SaleWarehouseFieldState extends State<SaleWarehouseField> {
  List<Map<String, dynamic>> _rows = <Map<String, dynamic>>[];
  Map<String, String> _names = <String, String>{};
  String? _sel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onChanged(null);
    });
    _load();
  }

  Future<void> _load() async {
    if (widget.lotId <= 0) return; // هنوز به سرور نرسیده
    try {
      final r = await StockApi.call('stock.by_warehouse', <String, dynamic>{'lot_id': widget.lotId});
      final items = <Map<String, dynamic>>[];
      final raw = r['items'];
      if (raw is List) {
        for (final x in raw) {
          if (x is Map && ((x['kg'] as num?) ?? 0) > 0.0005) items.add(Map<String, dynamic>.from(x));
        }
      }
      final names = await StockLookup.warehouseNames();
      if (!mounted) return;
      setState(() {
        _rows = items;
        _names = names;
      });
    } catch (_) {
      // آفلاین/خطا: بدون انتخاب ادامه می‌دهیم
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_rows.length < 2) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        value: _sel,
        isExpanded: true,
        decoration: const InputDecoration(
            labelText: 'برداشت از کدام انبار؟ (این قلم در چند انبار است)', border: OutlineInputBorder()),
        items: <DropdownMenuItem<String>>[
          for (final r in _rows)
            DropdownMenuItem<String>(
              value: r['warehouse_uid'] as String,
              child: Text('${_names[r['warehouse_uid']] ?? '-'} — ${faNum(r['kg'] as num)} کیلو'),
            ),
        ],
        validator: (String? v) => v == null ? 'انبار را انتخاب کنید' : null,
        onChanged: (String? v) {
          setState(() => _sel = v);
          widget.onChanged(v);
        },
      ),
    );
  }
}

/// صفحهٔ انتقال بین انبارها (آنلاین).
class StockTransferScreen extends StatefulWidget {
  const StockTransferScreen({super.key});

  @override
  State<StockTransferScreen> createState() => _StockTransferScreenState();
}

class _StockTransferScreenState extends State<StockTransferScreen> {
  final GlobalKey<FormState> _form = GlobalKey<FormState>();
  final TextEditingController _kg = TextEditingController();
  final TextEditingController _small = TextEditingController();
  final TextEditingController _large = TextEditingController();
  final TextEditingController _note = TextEditingController();
  List<Map<String, dynamic>> _lots = <Map<String, dynamic>>[];
  List<WhOption> _whs = <WhOption>[];
  Map<String, String> _names = <String, String>{};
  List<Map<String, dynamic>> _transfers = <Map<String, dynamic>>[];
  int? _lot;
  String? _from;
  String? _to;
  bool _busy = false;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _kg.dispose();
    _small.dispose();
    _large.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final all = await AppDb.I.inventoryAll();
    final lots = all.where((Map<String, dynamic> l) => AppDb.isAvailable(l) && ((l['id'] as int?) ?? 0) > 0).toList();
    final whs = await StockLookup.warehouses();
    final names = await StockLookup.warehouseNames();
    if (!mounted) return;
    setState(() {
      _lots = lots;
      _whs = whs;
      _names = names;
    });
    await _loadTransfers();
  }

  Future<void> _loadTransfers() async {
    try {
      final r = await StockApi.call('stock.transfers', <String, dynamic>{});
      final items = <Map<String, dynamic>>[];
      final raw = r['items'];
      if (raw is List) {
        for (final x in raw) {
          if (x is Map) items.add(Map<String, dynamic>.from(x));
        }
      }
      if (!mounted) return;
      setState(() {
        _transfers = items;
        _err = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _err = e.toString());
    }
  }

  Future<void> _submit() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    if (_lot == null || _from == null || _to == null) {
      snack(context, 'قلم، انبار مبدأ و انبار مقصد را انتخاب کنید');
      return;
    }
    if (_from == _to) {
      snack(context, 'انبار مبدأ و مقصد باید متفاوت باشند');
      return;
    }
    setState(() => _busy = true);
    try {
      await StockApi.call('stock.transfer', <String, dynamic>{
        'uid': EntityStore.newUid(),
        'lot_id': _lot,
        'from_warehouse_uid': _from,
        'to_warehouse_uid': _to,
        'kg': parseNum(_kg.text),
        'small_sacks': parseNum(_small.text) ?? 0,
        'large_sacks': parseNum(_large.text) ?? 0,
        'note': _note.text.trim().isEmpty ? null : _note.text.trim(),
      });
      _kg.clear();
      _small.clear();
      _large.clear();
      _note.clear();
      if (mounted) snack(context, 'انتقال ثبت شد');
      unawaited(SyncService.I.syncNow(pull: true));
      await _loadTransfers();
    } catch (e) {
      if (mounted) snack(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel(Map<String, dynamic> t) async {
    final ok = await confirm(context, 'این انتقال لغو شود؟');
    if (!ok || !mounted) return;
    try {
      await StockApi.call('stock.transfer_cancel', <String, dynamic>{'uid': t['uid']});
      unawaited(SyncService.I.syncNow(pull: true));
      await _loadTransfers();
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
  }

  String _lotTitle(Map<String, dynamic> l) =>
      '${l['category_name'] ?? ''} - ${l['type_name'] ?? ''}  (کد ${l['code'] ?? '-'})  •  ${faNum((l['remaining'] as num?) ?? 0)} کیلو';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('انتقال بین انبارها')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          if (_whs.length < 2)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('برای انتقال حداقل دو انبار لازم است؛ از منوی «انبار» یک انبار تازه بسازید.',
                  style: TextStyle(color: Colors.black54)),
            ),
          Form(
            key: _form,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
              DropdownButtonFormField<int>(
                value: _lot,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'قلم انبار', border: OutlineInputBorder()),
                items: <DropdownMenuItem<int>>[
                  for (final l in _lots)
                    DropdownMenuItem<int>(value: l['id'] as int, child: Text(_lotTitle(l), overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (int? v) => setState(() => _lot = v),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _from,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'از انبار', border: OutlineInputBorder()),
                items: <DropdownMenuItem<String>>[
                  for (final w in _whs) DropdownMenuItem<String>(value: w.uid, child: Text(w.name)),
                ],
                onChanged: (String? v) => setState(() => _from = v),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _to,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'به انبار', border: OutlineInputBorder()),
                items: <DropdownMenuItem<String>>[
                  for (final w in _whs) DropdownMenuItem<String>(value: w.uid, child: Text(w.name)),
                ],
                onChanged: (String? v) => setState(() => _to = v),
              ),
              const SizedBox(height: 12),
              numField(_kg, 'وزن انتقال (کیلو)', required: true),
              Row(children: <Widget>[
                Expanded(child: numField(_small, 'گونی کوچک', hint: '0')),
                const SizedBox(width: 8),
                Expanded(child: numField(_large, 'گونی بزرگ', hint: '0')),
              ]),
              textField(_note, 'توضیحات (اختیاری)'),
              FilledButton.icon(
                onPressed: _busy ? null : _submit,
                icon: const Icon(Icons.swap_horiz),
                label: Text(_busy ? 'در حال ثبت…' : 'ثبت انتقال'),
              ),
            ]),
          ),
          const SizedBox(height: 20),
          sectionTitle(context, 'انتقال‌های اخیر'),
          if (_err != null) Text(_err!, style: const TextStyle(color: Colors.redAccent)),
          if (_err == null && _transfers.isEmpty) const Text('هنوز انتقالی ثبت نشده است.', style: TextStyle(color: Colors.black54)),
          for (final t in _transfers)
            Card(
              child: ListTile(
                dense: true,
                title: Text('${_names[t['from_warehouse_uid']] ?? '-'}  ←  ${_names[t['to_warehouse_uid']] ?? '-'}'),
                subtitle: Text('${faNum((t['kg'] as num?) ?? 0)} کیلو  •  قلم ${t['lot_id']}  •  ${t['date'] ?? ''}'),
                trailing: IconButton(
                  tooltip: 'لغو انتقال',
                  icon: const Icon(Icons.undo),
                  onPressed: () => _cancel(t),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
