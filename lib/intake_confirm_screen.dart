import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'db.dart';
import 'entity_store.dart';
import 'fmt.dart';
import 'intake_form.dart' show parseIntakeNum;
import 'intake_list_screen.dart' show kIntakeStatusLabels;
import 'license_service.dart';
import 'perms.dart';
import 'pricing_engine.dart';
import 'sync_service.dart';
import 'widgets.dart' show confirm;

/// S6.T2: قطعی‌سازی/رد/نمونه‌کردن پذیرش اتاق انس + قیمت‌گذاری درصدی (مدیر/حسابدار).
/// فقط با `intake.confirm` **و** `intake.price`. فقط پذیرشِ «ثبت‌شده» (submitted).
/// - میانگین/مبلغ کل زنده با موتور Dart (pricing_engine.dart) و تأییدِ سرور (`intake.preview_price`).
/// - «قطعی» فقط وقتی فعال است که پیش‌نمایش سرور برای همین ورودی‌ها آمده و با محاسبهٔ محلی یکی باشد.
/// - این اکشن‌ها آنلاین‌اند (صف آفلاین نمی‌شوند)؛ سرور idempotent است (تکرار = `already:true`).

class IntakeApiResult {
  const IntakeApiResult(this.code, this.data, this.message);
  final int code;
  final Map<String, dynamic>? data;
  final String message;
  bool get ok => code == 200 && data != null && data!['error'] == null;
}

/// فراخوانی مستقیم `app.php` با همان phone/token/واحد پول (بدون صف).
class IntakeApi {
  IntakeApi._();

  static Future<IntakeApiResult> call(String action, Map<String, dynamic> payload, {String? idem}) async {
    final cred = await LicenseService.I.credentials();
    if (cred == null) return const IntakeApiResult(401, null, 'نیاز به ورود مجدد است');
    final body = <String, dynamic>{
      'phone': cred.$1,
      'token': cred.$2,
      'action': action,
      'payload': payload,
      'unit': AppDb.I.moneyUnit,
    };
    if (idem != null) body['idem'] = idem;
    http.Response resp;
    try {
      resp = await http
          .post(Uri.parse('${ApiConfig.baseUrl}/app.php'), headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      return const IntakeApiResult(0, null, 'سرور در زمان مناسب پاسخ نداد؛ دوباره تلاش کنید.');
    } on SocketException {
      return const IntakeApiResult(0, null, 'اتصال به اینترنت برقرار نیست؛ قطعی‌سازی فقط آنلاین انجام می‌شود.');
    } on http.ClientException {
      return const IntakeApiResult(0, null, 'اتصال به اینترنت برقرار نیست؛ قطعی‌سازی فقط آنلاین انجام می‌شود.');
    } catch (_) {
      return const IntakeApiResult(0, null, 'خطای غیرمنتظره؛ دوباره تلاش کنید.');
    }
    Map<String, dynamic>? data;
    try {
      final j = jsonDecode(utf8.decode(resp.bodyBytes));
      if (j is Map<String, dynamic>) data = j;
    } catch (_) {}
    String msg = '';
    if (data != null && data['error'] is String) msg = data['error'] as String;
    if (resp.statusCode != 200 && msg.isEmpty) msg = 'خطای سرور (${resp.statusCode})';
    return IntakeApiResult(resp.statusCode, data, msg);
  }
}

class _PctRow {
  _PctRow({required this.defKey, required this.label, required this.pct, required this.kernelG, required this.allowed})
      : q = TextEditingController(),
        g = TextEditingController();
  final String defKey;
  final String label;
  final double pct;
  final double? kernelG;
  final bool allowed;
  bool separate = false; // «قیمت جدا»
  bool gram = false; // «خرید گرمی»
  final TextEditingController q;
  final TextEditingController g;
  void dispose() {
    q.dispose();
    g.dispose();
  }
}

class IntakeConfirmScreen extends StatefulWidget {
  const IntakeConfirmScreen({super.key, required this.uid});
  final String uid;

  @override
  State<IntakeConfirmScreen> createState() => _IntakeConfirmScreenState();
}

class _IntakeConfirmScreenState extends State<IntakeConfirmScreen> {
  final TextEditingController _base = TextEditingController();
  bool _baseGram = false; // «خرید گرمی» برای پسته اصلی
  final TextEditingController _baseG = TextEditingController(); // پیش‌فرض: «گرم» ثبت‌شدهٔ اتاق انس
  final List<_PctRow> _rows = <_PctRow>[];
  Map<String, dynamic>? _intake;
  bool _loading = true;
  bool _submitPending = false;
  bool _busy = false;

  // آخرین پیش‌نمایش سرور
  Timer? _debounce;
  int _seq = 0;
  bool _previewing = false;
  String? _previewErr;
  Map<String, dynamic>? _srv; // پاسخ سرور
  String? _srvKey; // کلید ورودی‌هایی که پاسخ برایشان است

  bool get _allowed => StaffPerms.I.can('intake.confirm') && StaffPerms.I.can('intake.price');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _base.dispose();
    _baseG.dispose();
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final intake = await EntityStore.I.get('lot_intakes', widget.uid);
    final pcts = (await EntityStore.I.list('lot_intake_pcts')).where((p) => p['intake_id'] == widget.uid).toList();
    final defsList = await EntityStore.I.list('pct_defs');
    final defs = <String, Map<String, dynamic>>{for (final d in defsList) (d['key'] ?? '').toString(): d};
    final pending = await EntityStore.I.isSubmitPending(widget.uid);
    for (final p in pcts) {
      final key = (p['def_key'] ?? '').toString();
      final d = defs[key];
      _rows.add(_PctRow(
        defKey: key,
        label: (d?['label'] ?? key).toString(),
        pct: (p['pct'] as num?)?.toDouble() ?? 0,
        kernelG: (p['kernel_g'] as num?)?.toDouble(),
        allowed: true,
      ));
      if (_rows.last.kernelG != null) _rows.last.g.text = _plainNum(_rows.last.kernelG!);
    }
    if (!mounted) return;
    final ig = (intake?['gram'] as num?)?.toDouble();
    if (ig != null) _baseG.text = _plainNum(ig);
    setState(() {
      _intake = intake;
      _submitPending = pending;
      _loading = false;
    });
  }

  static String _plainNum(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  bool get _editable => _intake != null && _intake!['status'] == 'submitted' && !_submitPending && _allowed;

  // ---------- ورودی‌ها ----------

  /// payload سرور؛ null + [_formErr] وقتی ورودی کامل/معتبر نیست.
  String? _formErr;
  Map<String, dynamic>? _payload() {
    _formErr = null;
    final base = MoneyField.stored(_base);
    if (base == null || base <= 0) {
      _formErr = 'قیمت پایه را وارد کنید';
      return null;
    }
    final items = <Map<String, dynamic>>[];
    for (final r in _rows) {
      if (!r.separate) continue;
      final q = MoneyField.stored(r.q);
      if (q == null || q < 0) {
        _formErr = 'قیمت «${r.label}» را وارد کنید';
        return null;
      }
      final it = <String, dynamic>{'def_key': r.defKey, 'q': q};
      if (r.gram) {
        it['gram_mode'] = true;
        final g = parseIntakeNum(r.g.text) ?? r.kernelG;
        if (g == null || g <= 0 || g > 100) {
          _formErr = '«گرم مغز در ۱۰۰ گرم» برای «${r.label}» را (۰ تا ۱۰۰) وارد کنید';
          return null;
        }
        if (parseIntakeNum(r.g.text) != null) it['g'] = g;
      }
      items.add(it);
    }
    final out = <String, dynamic>{'uid': widget.uid, 'base_price': base, 'items': items};
    if (_baseGram) {
      final bg = parseIntakeNum(_baseG.text) ?? (_intake?['gram'] as num?)?.toDouble();
      if (bg == null || bg <= 0 || bg > 100) {
        _formErr = '«گرم مغز در ۱۰۰ گرم» پسته اصلی را (۰ تا ۱۰۰) وارد کنید';
        return null;
      }
      out['base_gram_mode'] = true;
      out['base_g'] = bg;
    }
    return out;
  }

  double? get _srvWeight => (_srv?['weight_kg'] as num?)?.toDouble();
  double? get _srvRef => (_srv?['ref_gram'] as num?)?.toDouble();

  /// محاسبهٔ زندهٔ محلی (نیازمند W و R که از اولین پاسخ سرور می‌آید).
  PriceBlendResult? _local(Map<String, dynamic> payload) {
    final w = _srvWeight;
    final ref = _srvRef;
    if (w == null || ref == null) return null;
    final byKey = <String, Map<String, dynamic>>{for (final i in (payload['items'] as List).cast<Map<String, dynamic>>()) i['def_key'] as String: i};
    final items = <Map<String, dynamic>>[];
    for (final r in _rows) {
      final it = byKey[r.defKey];
      if (it == null) {
        items.add(<String, dynamic>{'pct': r.pct, 'q': null});
      } else {
        items.add(<String, dynamic>{
          'pct': r.pct,
          'q': it['q'],
          'gram_mode': it['gram_mode'] == true,
          'g': it['g'] ?? r.kernelG,
        });
      }
    }
    return priceBlend(<String, dynamic>{
      'base_price': payload['base_price'],
      'weight_kg': w,
      'ref_gram': ref,
      'items': items,
      if (payload['base_gram_mode'] == true) ...<String, dynamic>{'base_gram_mode': true, 'base_g': payload['base_g']},
    });
  }

  void _changed() {
    setState(() {});
    _debounce?.cancel();
    final p = _payload();
    if (p == null) {
      setState(() => _previewErr = null);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 500), () => _fetchPreview(p));
  }

  Future<void> _fetchPreview(Map<String, dynamic> payload) async {
    final seq = ++_seq;
    final key = jsonEncode(payload);
    if (mounted) setState(() => _previewing = true);
    final r = await IntakeApi.call('intake.preview_price', payload);
    if (!mounted || seq != _seq) return; // پاسخ کهنه
    setState(() {
      _previewing = false;
      if (r.ok) {
        _srv = r.data;
        _srvKey = key;
        _previewErr = null;
      } else {
        _srvKey = null;
        _previewErr = r.message.isEmpty ? 'پیش‌نمایش قیمت ناموفق بود' : r.message;
      }
    });
  }

  // ---------- عملیات ----------

  String _idem(String what) => 'ic-$what-${widget.uid}-${DateTime.now().microsecondsSinceEpoch}';

  void _snack(String m) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(m)));

  Future<void> _finish(IntakeApiResult r, String okMsg) async {
    await EntityStore.I.applyServerItem('lot_intakes', r.data?['item']);
    unawaited(SyncService.I.syncNow(pull: true)); // خرید/موجودی تازه شود
    if (!mounted) return;
    _snack(r.data?['already'] == true ? 'این پذیرش قبلاً انجام شده بود.' : okMsg);
    Navigator.of(context).pop(true);
  }

  Future<void> _confirmIntake() async {
    final p = _payload();
    if (p == null || _srv == null || _srvKey != jsonEncode(p) || _busy) return;
    final avg = (_srv!['avg_per_kg'] as num).toInt();
    final total = (_srv!['total'] as num).toInt();
    final code = (_intake!['code'] ?? '').toString();
    final ok = await confirm(
      context,
      'پذیرش $code با میانگین ${Fmt.money(avg)} در هر کیلو و مبلغ کل ${Fmt.money(total)} قطعی می‌شود.\n\n'
      'موجودی اضافه می‌شود: یک خرید جدید با همین کد ثبت می‌گردد و پس از آن این پذیرش قابل ویرایش یا برگشت نیست.\n\nادامه می‌دهید؟',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    final r = await IntakeApi.call('intake.confirm', p, idem: _idem('confirm'));
    if (!mounted) return;
    if (r.ok) {
      await _finish(r, 'پذیرش قطعی و به موجودی اضافه شد.');
      return;
    }
    setState(() => _busy = false);
    _snack(r.message.isEmpty ? 'قطعی‌سازی ناموفق بود' : r.message);
  }

  Future<void> _reject() async {
    if (_busy) return;
    final c = TextEditingController();
    // نتیجه: (دلیل، قطعی؟) — «برگشت برای اصلاح»: اتاق انس ویرایش و دوباره ثبت می‌کند؛ «رد قطعی»: بسته می‌شود
    final res = await showDialog<(String, bool)>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('رد / برگشت پذیرش'),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLength: 250,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'دلیل (اجباری)', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('انصراف')),
          OutlinedButton(
            onPressed: () {
              final t = c.text.trim();
              if (t.isEmpty) return;
              Navigator.pop(ctx, (t, true));
            },
            child: const Text('رد قطعی'),
          ),
          FilledButton(
            onPressed: () {
              final t = c.text.trim();
              if (t.isEmpty) return;
              Navigator.pop(ctx, (t, false));
            },
            child: const Text('برگشت برای اصلاح'),
          ),
        ],
      ),
    );
    c.dispose();
    if (res == null || !mounted) return;
    final reason = res.$1;
    final isFinal = res.$2;
    if (isFinal && !await confirm(context, 'رد قطعی: پذیرش بسته می‌شود و دیگر قابل ویرایش نیست. مطمئنید؟')) return;
    if (!mounted) return;
    setState(() => _busy = true);
    final r = await IntakeApi.call('intake.reject', <String, dynamic>{'uid': widget.uid, 'reason': reason, 'final': isFinal}, idem: _idem('reject'));
    if (!mounted) return;
    if (r.ok) {
      await _finish(r, isFinal ? 'پذیرش رد قطعی شد.' : 'پذیرش برای اصلاح به اتاق انس برگشت.');
      return;
    }
    setState(() => _busy = false);
    _snack(r.message.isEmpty ? 'رد پذیرش ناموفق بود' : r.message);
  }

  Future<void> _markSample() async {
    if (_busy) return;
    final nc = TextEditingController();
    final note = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('نمونه‌کردن پذیرش'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('خرید و موجودی ساخته نمی‌شود و دیگر قابل قطعی‌سازی نیست.'),
          const SizedBox(height: 12),
          TextField(
            controller: nc,
            autofocus: true,
            maxLength: 400,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'توضیح نمونه (الزامی): برای چیست/کیست؟', border: OutlineInputBorder()),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('انصراف')),
          FilledButton(
            onPressed: () {
              final t = nc.text.trim();
              if (t.isEmpty) return;
              Navigator.pop(ctx, t);
            },
            child: const Text('ثبت نمونه'),
          ),
        ],
      ),
    );
    nc.dispose();
    if (note == null || !mounted) return;
    setState(() => _busy = true);
    final r = await IntakeApi.call('intake.mark_sample', <String, dynamic>{'uid': widget.uid, 'note': note}, idem: _idem('sample'));
    if (!mounted) return;
    if (r.ok) {
      await _finish(r, 'پذیرش به‌عنوان نمونه ثبت شد.');
      return;
    }
    setState(() => _busy = false);
    _snack(r.message.isEmpty ? 'ثبت نمونه ناموفق بود' : r.message);
  }

  // ---------- UI ----------

  String _kg(Object? v) => v is num ? Fmt.kg(v) : '-';

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 110, child: Text(k, style: const TextStyle(color: Colors.black54))),
          Expanded(child: Text(v)),
        ]),
      );

  Widget _specCard() {
    final d = _intake!;
    final isSample = d['is_sample'] == true;
    final status = (d['status'] ?? '').toString();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('پذیرش ${(d['code'] ?? '').toString().isEmpty ? '(بدون کد)' : d['code']}',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 6),
          _kv('وضعیت', _submitPending ? 'در انتظار ارسال' : (kIntakeStatusLabels[status] ?? status)),
          _kv('صاحب', isSample ? 'نمونه' : (d['owner_name'] ?? '-').toString()),
          _kv('نوع', (d['type_name'] ?? '-').toString()),
          _kv('وزن کل', _kg(d['gross_kg'])),
          _kv('گونی', 'کوچک ${d['small_sacks'] ?? 0} · بزرگ ${d['large_sacks'] ?? 0}'),
          if (d['gram'] != null) _kv('گرم', Fmt.number(d['gram'] as num, dec: 3)),
          if (d['ounce'] != null) _kv('انس', Fmt.number(d['ounce'] as num, dec: 3)),
          if ((d['created_by_name'] ?? '').toString().isNotEmpty) _kv('ثبت‌کننده', d['created_by_name'].toString()),
          if ((d['note'] ?? '').toString().isNotEmpty) _kv('یادداشت', d['note'].toString()),
          if ((d['reject_reason'] ?? '').toString().isNotEmpty) _kv('دلیل رد', d['reject_reason'].toString()),
          if (_rows.isNotEmpty) ...[
            const Divider(),
            Wrap(spacing: 8, runSpacing: 4, children: [
              for (final r in _rows)
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text('${r.label}: ${Fmt.percent(r.pct)}'),
                ),
            ]),
          ],
        ]),
      ),
    );
  }

  Widget _pctCard(_PctRow r, PriceBlendResult? local) {
    double? eff;
    if (local != null && local.ok) {
      final i = _rows.indexOf(r);
      if (i >= 0 && i < local.lines.length) eff = local.lines[i].effQ;
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${r.label} — ${Fmt.percent(r.pct)}', style: const TextStyle(fontWeight: FontWeight.bold)),
          if (!r.allowed)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('قیمت جدا برای این درصد فعال نیست؛ در قیمت اصلی حساب می‌شود.', style: TextStyle(color: Colors.black54)),
            )
          else ...[
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('قیمت جدا'),
              value: r.separate,
              onChanged: (v) {
                r.separate = v == true;
                if (!r.separate) r.gram = false;
                // گرمِ ثبت‌شده در اتاق انس خودکار اعمال می‌شود؛ نیازی به ورود دوباره نیست
                if (r.separate && r.kernelG != null) {
                  r.gram = true;
                  if (r.g.text.trim().isEmpty) r.g.text = _plainNum(r.kernelG!);
                }
                _changed();
              },
            ),
            if (r.separate) ...[
              const SizedBox(height: 4),
              MoneyField(controller: r.q, label: 'قیمت کیلویی «${r.label}»', onChanged: _changed),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('خرید گرمی'),
                value: r.gram,
                onChanged: (v) {
                  r.gram = v == true;
                  _changed();
                },
              ),
              if (r.gram)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    controller: r.g,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: 'گرم مغز در ۱۰۰ گرم',
                      hintText: r.kernelG == null ? null : 'ثبت اتاق انس: ${Fmt.number(r.kernelG!, dec: 3)}',
                      helperText: 'اگر خالی بماند، مقدار ثبت‌شدهٔ اتاق انس استفاده می‌شود',
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) => _changed(),
                  ),
                ),
              if (eff != null)
                Text('قیمت مؤثر کیلویی: ${Fmt.money(eff.round())}', style: const TextStyle(color: Colors.black54)),
            ],
          ],
        ]),
      ),
    );
  }

  Widget _summary(Map<String, dynamic>? payload, PriceBlendResult? local) {
    final cs = Theme.of(context).colorScheme;
    final fresh = payload != null && _srv != null && _srvKey == jsonEncode(payload);
    int? avg, total;
    if (fresh) {
      avg = (_srv!['avg_per_kg'] as num).toInt();
      total = (_srv!['total'] as num).toInt();
    } else if (local != null && local.ok) {
      avg = local.avgPerKg;
      total = local.total;
    }
    final mismatch = fresh && local != null && local.ok && (local.avgPerKg != avg || local.total != total);
    String state;
    if (_formErr != null && payload == null) {
      state = _formErr!;
    } else if (_previewErr != null) {
      state = _previewErr!;
    } else if (_previewing || (payload != null && !fresh)) {
      state = 'در حال محاسبه با سرور…';
    } else if (fresh) {
      state = mismatch ? 'هشدار: محاسبهٔ برنامه با سرور یکی نیست؛ قطعی‌سازی غیرفعال شد.' : 'تأیید سرور ✔';
    } else {
      state = '';
    }
    return Card(
      color: cs.primaryContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('نتیجهٔ قیمت‌گذاری', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          _kv('وزن خالص', _srvWeight == null ? '—' : Fmt.kg(_srvWeight!)),
          _kv('گرم مرجع (R)', _srvRef == null ? '—' : Fmt.number(_srvRef!, dec: 3)),
          _kv('میانگین هر کیلو', avg == null ? '—' : Fmt.money(avg)),
          _kv('مبلغ کل', total == null ? '—' : Fmt.money(total)),
          if (state.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(state, style: TextStyle(color: (_previewErr != null || mismatch) ? cs.error : Colors.black54)),
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(appBar: AppBar(title: const Text('قطعی‌سازی پذیرش')), body: const Center(child: CircularProgressIndicator()));
    }
    if (!_allowed) {
      return Scaffold(
        appBar: AppBar(title: const Text('قطعی‌سازی پذیرش')),
        body: const Center(child: Text('برای قطعی‌سازی، دسترسی «قطعی‌سازی» و «قیمت‌گذاری» لازم است.')),
      );
    }
    if (_intake == null) {
      return Scaffold(appBar: AppBar(title: const Text('قطعی‌سازی پذیرش')), body: const Center(child: Text('پذیرش پیدا نشد.')));
    }
    final payload = _payload();
    final local = payload == null ? null : _local(payload);
    final fresh = payload != null && _srv != null && _srvKey == jsonEncode(payload);
    final mismatch = fresh && local != null && local.ok && (local.avgPerKg != (_srv!['avg_per_kg'] as num).toInt() || local.total != (_srv!['total'] as num).toInt());
    final canConfirm = _editable && fresh && !mismatch && !_busy && !_previewing;

    return Scaffold(
      appBar: AppBar(title: const Text('قطعی‌سازی پذیرش')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _specCard(),
              if (!_editable)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _submitPending ? 'این پذیرش هنوز در صف ارسال است؛ پس از ارسال می‌توانید قطعی کنید.' : 'فقط پذیرشِ «ثبت‌شده» قابل قطعی‌سازی است.',
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                )
              else ...[
                const SizedBox(height: 12),
                MoneyField(controller: _base, label: 'قیمت پایه (هر کیلو)', onChanged: _changed),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('خرید گرمی (پسته اصلی)'),
                  value: _baseGram,
                  onChanged: (v) {
                    _baseGram = v == true;
                    _changed();
                  },
                ),
                if (_baseGram)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextField(
                      controller: _baseG,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: 'گرم مغز پسته اصلی در ۱۰۰ گرم',
                        helperText: (_intake?['gram'] != null) ? 'ثبت اتاق انس: ${Fmt.number((_intake!['gram'] as num).toDouble(), dec: 3)}' : null,
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (_) => _changed(),
                    ),
                  ),
                for (final r in _rows) _pctCard(r, local),
                _summary(payload, local),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  FilledButton.icon(
                    onPressed: canConfirm ? _confirmIntake : null,
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('قطعی‌سازی و افزودن به موجودی'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _reject,
                    icon: const Icon(Icons.block),
                    label: const Text('رد / برگشت'),
                  ),
                  TextButton.icon(
                    onPressed: _busy ? null : _markSample,
                    icon: const Icon(Icons.science_outlined),
                    label: const Text('نمونه'),
                  ),
                ]),
                if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
