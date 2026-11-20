import 'package:flutter/material.dart';

import 'db.dart';
import 'entity_store.dart' show EntityStore;
import 'fmt.dart' show Fmt;
import 'perms.dart';
import 'processing_ui.dart' show ProcessingStore;
import 'returns_ui.dart' show ReturnsHelp;
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException, StockLookup, WhOption;
import 'widgets.dart' show JalaliDateField, confirm;
import 'workshop_calc.dart';
import 'workshop_ui.dart' show kWsBuyLabel, kWsCostFields, kWsMissingInputCost, wsCanCost, wsParseNum, wsReadOnlyField;

/// فاز ۲ مجد — «کارگاه مرحله‌ای» (فایل مشترک اندروید و ویندوز؛ بدون واژهٔ مخصوص پلتفرم).
///   [WorkshopOpenFormScreen]  شروع عملیات: سربرگ + ورودی‌ها ⇒ workshop.open (ورودی‌ها همان لحظه از موجودی کم می‌شوند).
///   [WorkshopOpsScreen]       فهرست عملیات کارگاه با فیلتر «عملیات باز» و جمع «در کارگاه».
///   [WorkshopOpScreen]        جزئیات یک عملیات: ورودی‌ها (افزودن/حذف)، خروجی‌ها (افزودن/ویرایش/حذف)، نوار زنده، «بستن عملیات»، «بازکردن برای اصلاح».
/// همهٔ نوشتن‌ها با ProcessingStore.write (آنلاین‌اول؛ قطع شبکه ⇒ صف FIFO با uid؛ ترتیب ثبت حفظ می‌شود: output_save قبل از close).
/// سفارش با order_uid شناخته می‌شود تا اکشن‌های صف حتی قبل از رسیدن workshop.open به سرور معتبر باشند.
/// نمای آفلاین = آخرین پاسخ workshop.get (کش) + اکشن‌های صف همین عملیات با wsFlowApply (آینهٔ قواعد سرور).

String _kg(dynamic v) => faNum(ReturnsHelp.d(v), dec: 3);
bool _can(String k) => StaffPerms.I.can(k);
void _snack(BuildContext c, String m) => ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

/// کلید کش/صف یک عملیات: uid سرور یا «id<شناسه>» برای عملیات قدیمی بدون uid.
String wsOpKey(String? uid, int? id) => (uid != null && uid.isNotEmpty) ? uid : 'id${id ?? 0}';

/// لات‌های قابل‌برداشت: اپراتور ⇒ workshop.lots (شناسهٔ سرور، بدون قیمت)؛ بقیه ⇒ موجودی محلی (شناسهٔ محلی؛ هنگام ارسال به سرور تبدیل می‌شود).
class WsLotPicker {
  WsLotPicker._();
  static bool get serverIds => StaffPerms.I.isWorkshopOperatorOnly;

  static Future<Map<String, String>> load() async {
    final Map<String, String> lots = <String, String>{};
    if (serverIds) {
      final Map<String, dynamic> r = await StockApi.call('workshop.lots');
      for (final Map<String, dynamic> l in ReturnsHelp.maps(r['items'])) {
        final double rem = ReturnsHelp.d(l['remaining']);
        if (rem > 0) lots['${l['id']}'] = '${l['code'] ?? ''} · ${l['type_name'] ?? ''} · ${faNum(rem, dec: 3)} کیلو';
      }
      return lots;
    }
    for (final Map<String, dynamic> r in await AppDb.I.inventoryAll()) {
      final double rem = ReturnsHelp.d(r['remaining']);
      if (rem <= 0 || ReturnsHelp.d(r['is_mix']) == 3) continue;
      lots['${r['id']}'] = '${r['code'] ?? ''} · ${r['type_name'] ?? ''} · ${faNum(rem, dec: 3)} کیلو';
    }
    return lots;
  }

  static Future<int> serverId(String key) async {
    if (serverIds) return int.parse(key);
    return ReturnsHelp.serverId('purchase', int.parse(key));
  }

  /// عملیات «شکست»: مشخصات کامل لات‌ها + خطوط شکست فعال.
  /// اپراتور ⇒ هر دو از workshop.lots؛ بقیه ⇒ لات‌ها از موجودی محلی، خطوط از entity محلی (خالی ⇒ از سرور).
  static Future<WsCrackData> loadCrack() async {
    final List<WsLotInfo> lots = <WsLotInfo>[];
    List<WsCrackLine> lines = <WsCrackLine>[];
    Map<String, dynamic>? server;
    if (serverIds) {
      server = await StockApi.call('workshop.lots');
      for (final Map<String, dynamic> l in ReturnsHelp.maps(server['items'])) {
        final WsLotInfo i = WsLotInfo.fromRow('${l['id']}', l, smallLeft: l['small_sacks_remaining'], largeLeft: l['large_sacks_remaining']);
        if (i.remaining > 0) lots.add(i);
      }
    } else {
      for (final Map<String, dynamic> r in await AppDb.I.inventoryAll()) {
        if (ReturnsHelp.d(r['remaining']) <= 0 || ReturnsHelp.d(r['is_mix']) == 3) continue;
        lots.add(WsLotInfo.fromRow('${r['id']}', r, smallLeft: r['small_left'], largeLeft: r['large_left']));
      }
    }
    for (final Map<String, dynamic> r in await EntityStore.I.list('crack_lines')) {
      if (r['active'] == false || r['active'] == 0) continue;
      lines.add(WsCrackLine.fromRow(r));
    }
    if (lines.isEmpty) {
      try {
        server ??= await StockApi.call('workshop.lots');
        lines = <WsCrackLine>[for (final Map<String, dynamic> r in ReturnsHelp.maps(server['lines'])) WsCrackLine.fromRow(r)];
      } on StockApiException catch (_) {
        // آفلاین و بدون خط محلی ⇒ فهرست خالی (فرم راهنما نشان می‌دهد)
      }
    }
    lines.sort((WsCrackLine a, WsCrackLine b) => a.name.compareTo(b.name));
    return WsCrackData(lots, lines);
  }
}

/// یک خط شکست (entity crack_lines): نام + گرم پرتی.
class WsCrackLine {
  const WsCrackLine(this.uid, this.name, this.lossGram);
  factory WsCrackLine.fromRow(Map<String, dynamic> r) => WsCrackLine('${r['uid']}', '${r['name'] ?? ''}', ReturnsHelp.d(r['loss_gram']));
  final String uid;
  final String name;
  final double lossGram;
}

/// مشخصات یک لات برای فرم «شکست».
class WsLotInfo {
  WsLotInfo({
    required this.key,
    required this.code,
    required this.category,
    required this.type,
    required this.seller,
    required this.isMix,
    required this.remaining,
    required this.netWeight,
    required this.smallLeft,
    required this.largeLeft,
    this.gram,
    this.ounce,
  });

  factory WsLotInfo.fromRow(String key, Map<String, dynamic> r, {dynamic smallLeft, dynamic largeLeft}) {
    double? opt(dynamic v) => v == null ? null : ReturnsHelp.d(v);
    return WsLotInfo(
      key: key,
      code: '${r['code'] ?? ''}',
      category: '${r['category_name'] ?? ''}'.trim(),
      type: '${r['type_name'] ?? ''}'.trim(),
      seller: '${r['seller'] ?? ''}'.trim(),
      isMix: ReturnsHelp.d(r['is_mix']).toInt(),
      remaining: ReturnsHelp.d(r['remaining']),
      netWeight: ReturnsHelp.d(r['net_weight']),
      smallLeft: ReturnsHelp.d(smallLeft),
      largeLeft: ReturnsHelp.d(largeLeft),
      gram: opt(r['gram']),
      ounce: opt(r['ounce']),
    );
  }

  final String key;
  final String code;
  final String category;
  final String type;
  final String seller;
  final int isMix;
  final double remaining;
  final double netWeight;
  final double smallLeft;
  final double largeLeft;
  final double? gram;
  final double? ounce;

  /// لات کوت‌ریزی (is_mix=1) ⇒ نام کوت (= نام قلم لات مخلوط)؛ وگرنه نام فروشنده.
  bool get isKout => isMix == 1;
  String get whoLabel => isKout ? 'نام کوت' : 'فروشنده';
  String get who {
    if (isKout) return type.isEmpty ? 'کوت' : type;
    if (seller.isNotEmpty) return seller;
    return type.isEmpty ? code : type;
  }

  /// «دسته نوع» (مثلاً «اکبری دهنبست»).
  String get pistachio => <String>[category, type].where((String s) => s.isNotEmpty).join(' ');
}

class WsCrackData {
  const WsCrackData(this.lots, this.lines);
  final List<WsLotInfo> lots;
  final List<WsCrackLine> lines;
}

// ---------------------------------------------------------------------------
// شروع عملیات (open)
// ---------------------------------------------------------------------------

class _InRow {
  final TextEditingController kg = TextEditingController();
  String? lot;
}

/// یک ورودی عملیات «شکست»: لات + عدل بزرگ + عدل کوچک + وزن.
class _CrackRow {
  final TextEditingController kg = TextEditingController();
  final TextEditingController large = TextEditingController();
  final TextEditingController small = TextEditingController();
  String? lot;
  void dispose() {
    kg.dispose();
    large.dispose();
    small.dispose();
  }
}

class WorkshopOpenFormScreen extends StatefulWidget {
  const WorkshopOpenFormScreen({super.key});

  @override
  State<WorkshopOpenFormScreen> createState() => _WorkshopOpenFormScreenState();
}

class _WorkshopOpenFormScreenState extends State<WorkshopOpenFormScreen> {
  DateTime _date = DateTime.now();
  String _op = 'dehull';
  final TextEditingController _owner = TextEditingController();
  final TextEditingController _ptype = TextEditingController();
  final TextEditingController _defect = TextEditingController();
  final TextEditingController _initial = TextEditingController();
  final TextEditingController _bales = TextEditingController();
  final TextEditingController _note = TextEditingController();
  final List<_InRow> _ins = <_InRow>[_InRow()];
  Map<String, String> _lots = <String, String>{};
  bool _saving = false;

  // ── عملیات «شکست» ──
  final List<_CrackRow> _crack = <_CrackRow>[_CrackRow()];
  Map<String, WsLotInfo> _info = <String, WsLotInfo>{};
  List<WsCrackLine> _lines = <WsCrackLine>[];
  String? _line;
  bool _crackLoaded = false;

  @override
  void initState() {
    super.initState();
    WsLotPicker.load().then((Map<String, String> l) {
      if (mounted) setState(() => _lots = l);
    }).catchError((Object e) {
      if (mounted) _snack(context, e is StockApiException ? e.message : '$e');
    });
  }

  Future<void> _loadCrack() async {
    try {
      final WsCrackData d = await WsLotPicker.loadCrack();
      if (!mounted) return;
      setState(() {
        _info = <String, WsLotInfo>{for (final WsLotInfo i in d.lots) i.key: i};
        _lines = d.lines;
        if (_line != null && !_lines.any((WsCrackLine l) => l.uid == _line)) _line = null;
        if (_line == null && _lines.length == 1) _line = _lines.first.uid;
        _crackLoaded = true;
      });
    } on StockApiException catch (e) {
      if (mounted) {
        setState(() => _crackLoaded = true);
        _snack(context, e.message);
      }
    }
  }

  void _setOp(String? v) {
    setState(() => _op = v ?? 'dehull');
    if (_op == 'crack' && !_crackLoaded) _loadCrack();
  }

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[_owner, _ptype, _defect, _initial, _bales, _note]) {
      c.dispose();
    }
    for (final _InRow r in _ins) {
      r.kg.dispose();
    }
    for (final _CrackRow r in _crack) {
      r.dispose();
    }
    super.dispose();
  }

  // ── «شکست»: محاسبه و اعتبارسنجی ──
  WsCrackLine? get _lineObj {
    for (final WsCrackLine l in _lines) {
      if (l.uid == _line) return l;
    }
    return null;
  }

  WsCrackEstimate get _estimate => wsCrackEstimate(<Map<String, num?>>[
        for (final _CrackRow r in _crack)
          if (r.lot != null) <String, num?>{'kg': wsParseNum(r.kg.text), 'gram': _info[r.lot]?.gram},
      ], _lineObj?.lossGram);

  /// «نوع پسته ورودی»: دسته+نوع لات‌های ورودی، بدون تکرار، با «/».
  String get _crackTypes {
    final List<String> out = <String>[];
    for (final _CrackRow r in _crack) {
      final String t = _info[r.lot]?.pistachio ?? '';
      if (t.isNotEmpty && !out.contains(t)) out.add(t);
    }
    return out.join('/');
  }

  /// خطای موجودی هر ردیف (مجموع ردیف‌های همان لات با موجودی مقایسه می‌شود) یا null.
  String? _rowError(int idx) {
    final _CrackRow r = _crack[idx];
    final WsLotInfo? i = _info[r.lot];
    if (i == null) return null;
    double kg = 0, sm = 0, lg = 0;
    for (final _CrackRow x in _crack) {
      if (x.lot != r.lot) continue;
      kg += wsParseNum(x.kg.text);
      sm += wsParseNum(x.small.text);
      lg += wsParseNum(x.large.text);
    }
    final List<String> e = <String>[];
    if (kg - i.remaining > 1e-6) e.add('وزن از موجودی (${_kg(i.remaining)} کیلو) بیشتر است');
    if (lg - i.largeLeft > 1e-6) e.add('عدل بزرگ از موجودی (${faNum(i.largeLeft, dec: 0)}) بیشتر است');
    if (sm - i.smallLeft > 1e-6) e.add('عدل کوچک از موجودی (${faNum(i.smallLeft, dec: 0)}) بیشتر است');
    return e.isEmpty ? null : e.join(' • ');
  }

  bool get _crackOverStock {
    for (int i = 0; i < _crack.length; i++) {
      if (_rowError(i) != null) return true;
    }
    return false;
  }

  Future<void> _submitCrack() async {
    final WsCrackLine? line = _lineObj;
    if (line == null) return _snack(context, 'خط شکست را انتخاب کنید');
    for (int i = 0; i < _crack.length; i++) {
      final _CrackRow r = _crack[i];
      if (r.lot == null) return _snack(context, 'برای هر ورودی لات را انتخاب کنید');
      if (wsParseNum(r.kg.text) <= 0) return _snack(context, 'وزن هر ورودی باید بیشتر از صفر باشد');
      if (wsParseNum(r.small.text) < 0 || wsParseNum(r.large.text) < 0) return _snack(context, 'تعداد عدل نامعتبر است');
      final String? err = _rowError(i);
      if (err != null) return _snack(context, err);
    }
    setState(() => _saving = true);
    try {
      final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
      double bales = 0;
      for (final _CrackRow r in _crack) {
        final double sm = wsParseNum(r.small.text), lg = wsParseNum(r.large.text);
        bales += sm + lg;
        items.add(<String, dynamic>{
          'uid': ReturnsHelp.newUid('wi'),
          'purchase_id': await WsLotPicker.serverId(r.lot!),
          'kg': wsParseNum(r.kg.text),
          'small_sacks': sm,
          'large_sacks': lg,
          'code': _info[r.lot]?.code, // فقط برای نمای آفلاین؛ سرور نادیده می‌گیرد
          'type_name': _info[r.lot]?.type,
        });
      }
      final WsCrackEstimate est = _estimate;
      final String types = _crackTypes;
      final String uid = ReturnsHelp.newUid('wo');
      final Map<String, dynamic> payload = <String, dynamic>{
        'uid': uid,
        'op_type': 'crack',
        'start_date': ReturnsHelp.iso(_date),
        'owner': _owner.text.trim(),
        'defect_note': _defect.text.trim(), // فقط نمایش و گزارش
        'note': _note.text.trim(),
        'items': items,
        'crack_line_uid': line.uid,
        // سه فیلد زیر فقط برای نمای آفلاین است؛ سرور از خط و لات‌ها خودش می‌سازد
        'crack_line_name': line.name,
        'crack_loss_gram': line.lossGram,
        if (est.sentGram != null) 'input_gram': double.parse(est.sentGram!.toStringAsFixed(2)),
        if (types.isNotEmpty) 'pistachio_type': types.length > 100 ? types.substring(0, 100) : types,
        if (bales > 0) 'bale_count': bales,
      };
      final bool queued = await ProcessingStore.write('workshop.open', payload, 'شروع عملیات کارگاه: شکست (${line.name})');
      if (!mounted) return;
      _snack(context, queued ? 'آفلاین ذخیره شد؛ پس از اتصال ارسال می‌شود' : 'عملیات باز شد؛ خروجی‌ها را در طول کار ثبت کنید');
      Navigator.pushReplacement(context, MaterialPageRoute<bool>(builder: (_) => WorkshopOpScreen(orderUid: uid)));
    } on StockApiException catch (e) {
      _snack(context, e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  double get _inKg => _ins.fold<double>(0, (double s, _InRow r) => s + wsParseNum(r.kg.text));

  Future<void> _submit() async {
    final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
    for (final _InRow r in _ins) {
      if (r.lot == null) return _snack(context, 'برای هر ورودی لات انبار را انتخاب کنید');
      if (wsParseNum(r.kg.text) <= 0) return _snack(context, 'وزن هر ورودی باید بیشتر از صفر باشد');
    }
    setState(() => _saving = true);
    try {
      for (final _InRow r in _ins) {
        final double kg = wsParseNum(r.kg.text);
        items.add(<String, dynamic>{
          'uid': ReturnsHelp.newUid('wi'),
          'purchase_id': await WsLotPicker.serverId(r.lot!),
          'kg': kg,
          'code': _lots[r.lot]?.split(' · ').first, // فقط برای نمای آفلاین؛ سرور نادیده می‌گیرد
        });
      }
      final String uid = ReturnsHelp.newUid('wo');
      final Map<String, dynamic> payload = <String, dynamic>{
        'uid': uid,
        'op_type': _op,
        'start_date': ReturnsHelp.iso(_date),
        'owner': _owner.text.trim(),
        'defect_note': _defect.text.trim(),
        'note': _note.text.trim(),
        'items': items,
      };
      if (_ptype.text.trim().isNotEmpty) payload['pistachio_type'] = _ptype.text.trim();
      if (_initial.text.trim().isNotEmpty) payload['initial_kg'] = wsParseNum(_initial.text);
      if (_bales.text.trim().isNotEmpty) payload['bale_count'] = wsParseNum(_bales.text);
      final bool queued = await ProcessingStore.write('workshop.open', payload, 'شروع عملیات کارگاه: ${kWsOpLabels[_op]}');
      if (!mounted) return;
      _snack(context, queued ? 'آفلاین ذخیره شد؛ پس از اتصال ارسال می‌شود' : 'عملیات باز شد؛ خروجی‌ها را در طول کار ثبت کنید');
      Navigator.pushReplacement(context, MaterialPageRoute<bool>(builder: (_) => WorkshopOpScreen(orderUid: uid)));
    } on StockApiException catch (e) {
      _snack(context, e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _num(TextEditingController c, String label, {bool live = false}) => TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        onChanged: live ? (_) => setState(() {}) : null,
      );

  Widget _opField() => DropdownButtonFormField<String>(
        key: ValueKey<String>('op-$_op'),
        initialValue: _op,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'نوع عملیات', border: OutlineInputBorder()),
        items: <DropdownMenuItem<String>>[
          for (final String k in kWsOpTypes) DropdownMenuItem<String>(value: k, child: Text(kWsOpLabels[k] ?? k)),
        ],
        onChanged: _setOp,
      );

  /// عدد اعشاری با دو رقم ثابت (ارقام فارسی).
  static String _f2(double v) => toFaDigits(v.toStringAsFixed(2)).replaceAll('.', '٫');

  /// کادر جمع‌وجور مشخصات لات انتخاب‌شده.
  Widget _lotInfoBox(WsLotInfo i) {
    final ThemeData th = Theme.of(context);
    Widget kv(String k, String v) => Text.rich(
          TextSpan(children: <InlineSpan>[
            TextSpan(text: '$k: ', style: TextStyle(color: th.hintColor)),
            TextSpan(text: v, style: const TextStyle(fontWeight: FontWeight.w600)),
          ]),
          style: const TextStyle(fontSize: 12.5),
        );
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: th.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: th.dividerColor),
      ),
      child: Wrap(spacing: 18, runSpacing: 4, children: <Widget>[
        kv(i.whoLabel, i.who),
        kv('وزن خالص', '${_kg(i.netWeight)} (موجود ${_kg(i.remaining)}) کیلو'),
        kv('عدل بزرگ', faNum(i.largeLeft, dec: 0)),
        kv('عدل کوچک', faNum(i.smallLeft, dec: 0)),
        kv('گرم', i.gram == null ? '—' : faNum(i.gram!, dec: 2)),
        kv('انس', i.ounce == null ? '—' : faNum(i.ounce!, dec: 2)),
        if (i.pistachio.isNotEmpty) kv('نوع', i.pistachio),
      ]),
    );
  }

  Widget _crackInput(int idx) {
    final _CrackRow r = _crack[idx];
    final WsLotInfo? info = _info[r.lot];
    final String? err = _rowError(idx);
    final List<WsLotInfo> lots = _info.values.toList();
    TextField field(TextEditingController c, String label, {bool decimal = true}) => TextField(
          controller: c,
          keyboardType: TextInputType.numberWithOptions(decimal: decimal),
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
          onChanged: (_) => setState(() {}),
        );
    return Card(
      key: ObjectKey(r),
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Expanded(
              child: DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: r.lot,
                itemHeight: 56,
                decoration: InputDecoration(labelText: 'لات ${_crack.length > 1 ? faNum(idx + 1, dec: 0) : ''}'.trim(), border: const OutlineInputBorder()),
                selectedItemBuilder: (_) => <Widget>[
                  for (final WsLotInfo l in lots) Align(alignment: AlignmentDirectional.centerStart, child: Text('${l.who}  ·  ${l.code}', overflow: TextOverflow.ellipsis)),
                ],
                items: <DropdownMenuItem<String>>[
                  for (final WsLotInfo l in lots)
                    DropdownMenuItem<String>(
                      value: l.key,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(l.isKout ? 'کوت: ${l.who}' : l.who, overflow: TextOverflow.ellipsis),
                          Text('${l.code}  ·  ${_kg(l.remaining)} کیلو', style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor), overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                ],
                onChanged: (String? v) => setState(() => r.lot = v),
              ),
            ),
            if (_crack.length > 1)
              IconButton(
                tooltip: 'حذف ورودی',
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: () => setState(() => _crack.removeAt(idx).dispose()),
              ),
          ]),
          if (info != null) _lotInfoBox(info),
          const SizedBox(height: 10),
          Row(children: <Widget>[
            Expanded(child: field(r.large, 'عدل بزرگ', decimal: false)),
            const SizedBox(width: 8),
            Expanded(child: field(r.small, 'عدل کوچک', decimal: false)),
            const SizedBox(width: 8),
            Expanded(flex: 2, child: field(r.kg, 'وزن خالص (کیلو)')),
          ]),
          if (err != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(err, style: const TextStyle(color: Colors.red, fontSize: 12.5))),
        ]),
      ),
    );
  }

  /// کادر کناری: برآورد خط شکست.
  Widget _estimateCard() {
    final WsCrackEstimate e = _estimate;
    final ThemeData th = Theme.of(context);
    Widget row(String label, String value, {bool strong = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: <Widget>[
            Expanded(child: Text(label, style: TextStyle(color: th.hintColor))),
            const SizedBox(width: 8),
            Flexible(child: Text(value, textAlign: TextAlign.end, style: TextStyle(fontWeight: strong ? FontWeight.bold : FontWeight.w600, fontSize: strong ? 15 : 14))),
          ]),
        );
    final String types = _crackTypes;
    return Card(
      color: th.colorScheme.primaryContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
          Text('برآورد خط شکست', style: th.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
          if (_lineObj != null) Text('${_lineObj!.name} — گرم پرتی ${faNum(_lineObj!.lossGram, dec: 2)}', style: TextStyle(fontSize: 12, color: th.hintColor)),
          const Divider(),
          row('وزن خالص ورودی به خط', '${_kg(e.inKg)} کیلو'),
          const Divider(height: 1),
          row('گرم ارسالی', e.sentGram == null ? '—' : _f2(e.sentGram!)),
          const Divider(height: 1),
          row('نوع پسته ورودی', types.isEmpty ? '—' : types),
          const Divider(height: 1),
          row('برآورد مغز سالم دریافتی', e.kernelKg == null ? '—' : '${_kg(e.kernelKg!)} کیلو', strong: true),
          const Divider(height: 1),
          row('برآورد گرم دریافتی', e.recvGram == null ? '—' : _f2(e.recvGram!)),
          const Divider(height: 1),
          row('برآورد درصد پرت', e.lossPct == null ? '—' : '${_f2(e.lossPct!)}٪'),
          if (_lineObj == null) Padding(padding: const EdgeInsets.only(top: 6), child: Text('برای برآورد، خط شکست را انتخاب کنید.', style: TextStyle(fontSize: 12, color: th.hintColor))),
        ]),
      ),
    );
  }

  Widget _buildCrack(BuildContext context) {
    const SizedBox gap = SizedBox(height: 10);
    return Scaffold(
      appBar: AppBar(title: const Text('شروع عملیات کارگاه — شکست')),
      body: LayoutBuilder(builder: (BuildContext context, BoxConstraints c) {
        final bool wide = c.maxWidth >= 900;
        final bool rowHead = c.maxWidth >= 560;
        final Widget lineField = _lines.isEmpty
            ? InputDecorator(
                decoration: const InputDecoration(labelText: 'خط شکست', border: OutlineInputBorder()),
                child: Text(_crackLoaded ? 'خطی تعریف نشده (منو ← خطوط شکست)' : 'در حال بارگذاری…',
                    style: TextStyle(color: _crackLoaded ? Colors.red : null, fontSize: 12.5), overflow: TextOverflow.ellipsis),
              )
            : DropdownButtonFormField<String>(
                initialValue: _line,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'خط شکست', border: OutlineInputBorder()),
                items: <DropdownMenuItem<String>>[
                  for (final WsCrackLine l in _lines)
                    DropdownMenuItem<String>(value: l.uid, child: Text('${l.name} (پرتی ${faNum(l.lossGram, dec: 2)})', overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (String? v) => setState(() => _line = v),
              );
        final Widget date = JalaliDateField(label: 'تاریخ شروع', value: _date, onChanged: (DateTime d) => setState(() => _date = d));
        final Widget head = rowHead
            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Expanded(child: _opField()),
                const SizedBox(width: 8),
                Expanded(child: date),
                const SizedBox(width: 8),
                Expanded(child: lineField),
              ])
            : Column(children: <Widget>[_opField(), gap, date, gap, lineField]);
        final List<Widget> form = <Widget>[
          head,
          const SizedBox(height: 14),
          Text('ورودی از انبار (همین حالا از موجودی کم می‌شود)', style: Theme.of(context).textTheme.titleMedium),
          if (_crackLoaded && _info.isEmpty) const Padding(padding: EdgeInsets.only(top: 8), child: Text('لات موجودی در انبار نیست.')),
          for (int i = 0; i < _crack.length; i++) _crackInput(i),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(onPressed: () => setState(() => _crack.add(_CrackRow())), icon: const Icon(Icons.add), label: const Text('لات دیگر')),
          ),
          gap,
          TextField(controller: _defect, decoration: const InputDecoration(labelText: 'ایراد بار (اختیاری؛ فقط نمایش و گزارش)', border: OutlineInputBorder())),
          gap,
          Row(children: <Widget>[
            Expanded(child: TextField(controller: _owner, decoration: const InputDecoration(labelText: 'مالک (اختیاری)', border: OutlineInputBorder()))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: _note, decoration: const InputDecoration(labelText: 'یادداشت (اختیاری)', border: OutlineInputBorder()))),
          ]),
          if (!wide) ...<Widget>[const SizedBox(height: 12), _estimateCard()],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: (_saving || _crackOverStock || _lineObj == null) ? null : _submitCrack,
            icon: const Icon(Icons.play_arrow),
            label: Text(_saving ? 'در حال ثبت…' : 'شروع عملیات'),
          ),
        ];
        if (!wide) return ListView(padding: const EdgeInsets.all(14), children: form);
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Expanded(child: ListView(padding: const EdgeInsets.all(14), children: form)),
          SizedBox(
            width: 340,
            child: SingleChildScrollView(padding: const EdgeInsetsDirectional.fromSTEB(0, 14, 14, 14), child: _estimateCard()),
          ),
        ]);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_op == 'crack') return _buildCrack(context);
    const SizedBox gap = SizedBox(height: 10);
    return Scaffold(
      appBar: AppBar(title: const Text('شروع عملیات کارگاه')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: <Widget>[
          _opField(),
          gap,
          JalaliDateField(label: 'تاریخ شروع', value: _date, onChanged: (DateTime d) => setState(() => _date = d)),
          gap,
          TextField(controller: _owner, decoration: const InputDecoration(labelText: 'مالک', border: OutlineInputBorder())),
          gap,
          TextField(controller: _ptype, decoration: const InputDecoration(labelText: 'نوع پسته (خالی = نوع لات اصلی)', border: OutlineInputBorder())),
          gap,
          TextField(controller: _defect, decoration: const InputDecoration(labelText: 'ایراد بار (اختیاری)', border: OutlineInputBorder())),
          gap,
          Row(children: <Widget>[
            Expanded(child: _num(_initial, 'وزن خالص اولیه (کیلو)')),
            const SizedBox(width: 8),
            Expanded(child: _num(_bales, 'تعداد عدل')),
          ]),
          const SizedBox(height: 16),
          Text('ورودی از انبار (همین حالا از موجودی کم می‌شود)', style: Theme.of(context).textTheme.titleMedium),
          for (int i = 0; i < _ins.length; i++)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Expanded(
                  flex: 3,
                  child: DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: _ins[i].lot,
                    decoration: const InputDecoration(labelText: 'لات', border: OutlineInputBorder()),
                    items: <DropdownMenuItem<String>>[
                      for (final MapEntry<String, String> e in _lots.entries)
                        DropdownMenuItem<String>(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (String? v) => setState(() => _ins[i].lot = v),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(flex: 2, child: _num(_ins[i].kg, 'وزن (کیلو)', live: true)),
                if (_ins.length > 1)
                  IconButton(
                    tooltip: 'حذف ورودی',
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: () => setState(() => _ins.removeAt(i).kg.dispose()),
                  ),
              ]),
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(onPressed: () => setState(() => _ins.add(_InRow())), icon: const Icon(Icons.add), label: const Text('ورودی دیگر')),
          ),
          Text('جمع ورودی: ${faNum(_inKg, dec: 3)} کیلو'),
          gap,
          TextField(controller: _note, decoration: const InputDecoration(labelText: 'یادداشت (اختیاری)', border: OutlineInputBorder())),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _saving ? null : _submit,
            icon: const Icon(Icons.play_arrow),
            label: Text(_saving ? 'در حال ثبت…' : 'شروع عملیات'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// فهرست عملیات
// ---------------------------------------------------------------------------

class WorkshopOpsScreen extends StatefulWidget {
  const WorkshopOpsScreen({super.key, this.onlyOpen = true});
  final bool onlyOpen;

  @override
  State<WorkshopOpsScreen> createState() => _WorkshopOpsScreenState();
}

class _WorkshopOpsScreenState extends State<WorkshopOpsScreen> {
  late bool _onlyOpen = widget.onlyOpen;
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _queuedOpens = <Map<String, dynamic>>[];
  double _inWs = 0;
  int _openCount = 0;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final List<String> flushErr = await ProcessingStore.flush();
    String? err;
    try {
      final Map<String, dynamic> r = await StockApi.call('workshop.list');
      _items = ReturnsHelp.maps(r['items']);
      _inWs = ReturnsHelp.d(r['in_workshop_kg']);
      _openCount = ReturnsHelp.d(r['open_count']).toInt();
      await ProcessingStore.cacheWorkshopList(r);
    } on StockApiException catch (e) {
      err = e.message;
      final Map<String, dynamic> c = await ProcessingStore.cachedWorkshopList();
      _items = ReturnsHelp.maps(c['items']);
      _inWs = ReturnsHelp.d(c['in_workshop_kg']);
      _openCount = ReturnsHelp.d(c['open_count']).toInt();
    }
    _queuedOpens = <Map<String, dynamic>>[
      for (final Map<String, dynamic> op in await ProcessingStore.pendingOps())
        if (op['action'] == 'workshop.open' && op['payload'] is Map) Map<String, dynamic>.from(op['payload'] as Map),
    ];
    if (!mounted) return;
    setState(() {
      _error = err ?? (flushErr.isEmpty ? null : flushErr.join('\n'));
      _loading = false;
    });
  }

  Future<void> _go(Widget page) async {
    await Navigator.push(context, MaterialPageRoute<Object>(builder: (_) => page));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final List<Map<String, dynamic>> visible = _onlyOpen ? _items.where((Map<String, dynamic> o) => o['status'] == kWsOpen).toList() : _items;
    return Scaffold(
      appBar: AppBar(
        title: const Text('عملیات کارگاه'),
        actions: <Widget>[IconButton(tooltip: 'به‌روزرسانی', icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      floatingActionButton: _can('workshop.operate') || _can('processing.create')
          ? FloatingActionButton.extended(
              onPressed: () => _go(const WorkshopOpenFormScreen()),
              icon: const Icon(Icons.play_arrow),
              label: const Text('شروع عملیات'),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
          children: <Widget>[
            Wrap(spacing: 8, children: <Widget>[
              FilterChip(
                label: Text('عملیات باز (${faNum(_openCount + _queuedOpens.length, dec: 0)})'),
                selected: _onlyOpen,
                onSelected: (bool v) => setState(() => _onlyOpen = v),
              ),
            ]),
            const SizedBox(height: 6),
            Text('در کارگاه (ورودی کم‌شده از انبار، خروجی هنوز در انبار نیست): ${faNum(_inWs, dec: 3)} کیلو'),
            if (_error != null)
              Card(color: Theme.of(context).colorScheme.errorContainer, child: Padding(padding: const EdgeInsets.all(10), child: Text(_error!))),
            if (_loading) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
            for (final Map<String, dynamic> p in _queuedOpens)
              if (!_items.any((Map<String, dynamic> o) => o['uid'] == p['uid']))
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.cloud_upload_outlined),
                    title: Text('${kWsOpLabels['${p['op_type']}'] ?? 'کارگاه'}  •  در صف ارسال'),
                    subtitle: Text('${jalaliDate('${p['start_date'] ?? ''}')}  •  مالک ${p['owner'] ?? ''}'),
                    onTap: () => _go(WorkshopOpScreen(orderUid: '${p['uid']}')),
                  ),
                ),
            if (!_loading && visible.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('عملیاتی نیست'))),
            for (final Map<String, dynamic> o in visible) wsOpTile(context, o, () => _go(WorkshopOpScreen(orderUid: o['uid'] as String?, id: ReturnsHelp.d(o['id']).toInt()))),
          ],
        ),
      ),
    );
  }
}

/// کاشی یک عملیات داخلی (فهرست کارگاه و صفحهٔ فراوری).
Widget wsOpTile(BuildContext context, Map<String, dynamic> o, VoidCallback onTap) {
  final bool open = o['status'] == kWsOpen;
  final bool? ok = o['balance_ok'] is bool ? o['balance_ok'] as bool : null;
  final String state = open ? 'در کارگاه (باز)' : (ok == false ? 'نیاز به بررسی' : 'بسته');
  return Card(
    child: ListTile(
      leading: Icon(open ? Icons.pending_actions : (ok == false ? Icons.warning_amber_rounded : Icons.factory_outlined), color: open ? Colors.blue : (ok == false ? Colors.orange : null)),
      title: Text('${kWsOpLabels['${o['op_type']}'] ?? o['op_type'] ?? 'کارگاه'}${'${o['owner'] ?? ''}'.isEmpty ? '' : '  •  ${o['owner']}'}  •  $state'),
      subtitle: Text('${jalaliDate('${o['started_at'] ?? o['date'] ?? ''}')}${o['closed_at'] == null ? '' : ' تا ${jalaliDate('${o['closed_at']}')}'}\n'
          'ورودی ${_kg(o['input_kg'])} · خروجی ${_kg(o['output_kg'])} · افت ${_kg(o['loss_kg'])} کیلو'),
      isThreeLine: true,
      onTap: onTap,
    ),
  );
}

// ---------------------------------------------------------------------------
// جزئیات عملیات
// ---------------------------------------------------------------------------

class WorkshopOpScreen extends StatefulWidget {
  const WorkshopOpScreen({super.key, this.orderUid, this.id});
  final String? orderUid;
  final int? id;

  @override
  State<WorkshopOpScreen> createState() => _WorkshopOpScreenState();
}

class _WorkshopOpScreenState extends State<WorkshopOpScreen> {
  Map<String, dynamic> _d = <String, dynamic>{};
  int _pending = 0;
  String? _error;
  bool _loading = true;
  bool _busy = false;
  bool _changed = false;

  String? get _uid => (_d['uid'] as String?) ?? widget.orderUid;
  int? get _id => _d['id'] == null ? widget.id : ReturnsHelp.d(_d['id']).toInt();
  bool get _open => _d['status'] == kWsOpen;

  /// شناسهٔ سفارش برای اکشن‌ها (هم id و هم order_uid اگر معلوم است).
  Map<String, dynamic> get _ref => <String, dynamic>{
        if (_id != null && _id! > 0) 'id': _id,
        if (_uid != null) 'order_uid': _uid,
      };

  @override
  void initState() {
    super.initState();
    _load();
  }

  bool _mine(Map<String, dynamic> op) {
    final dynamic p = op['payload'];
    if (p is! Map || !'${op['action']}'.startsWith('workshop.')) return false;
    if (_uid != null && (p['order_uid'] == _uid || (op['action'] == 'workshop.open' && p['uid'] == _uid))) return true;
    return _id != null && _id! > 0 && p['id'] == _id && op['action'] != 'workshop.open';
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    await ProcessingStore.flush();
    Map<String, dynamic> base = <String, dynamic>{};
    String? err;
    try {
      base = await StockApi.call('workshop.get', <String, dynamic>{
        if (widget.id != null && widget.id! > 0) 'id': widget.id,
        if (widget.orderUid != null) 'order_uid': widget.orderUid,
      });
      await ProcessingStore.cacheDetail(wsOpKey(base['uid'] as String? ?? widget.orderUid, ReturnsHelp.d(base['id']).toInt()), base);
    } on StockApiException catch (e) {
      base = await ProcessingStore.cachedDetail(wsOpKey(widget.orderUid, widget.id)) ?? <String, dynamic>{};
      if (!(e.network || e.code == 404)) err = e.message;
      if (e.network) err = 'آفلاین: آخرین اطلاعات ذخیره‌شده + تغییرات در صف نمایش داده می‌شود';
    }
    _d = base;
    // نمای محلی: اکشن‌های صفِ همین عملیات روی آخرین پاسخ سرور
    final List<Map<String, dynamic>> ops = (await ProcessingStore.pendingOps()).where(_mine).toList();
    for (final Map<String, dynamic> op in ops) {
      _d = wsFlowApply(_d, '${op['action']}'.substring('workshop.'.length), Map<String, dynamic>.from(op['payload'] as Map)).state;
    }
    if (!mounted) return;
    setState(() {
      _pending = ops.length;
      _error = err;
      _loading = false;
    });
  }

  /// ارسال یک اکشن با قواعد محلی (wsFlowCheck) قبل از سرور.
  Future<void> _send(String action, Map<String, dynamic> payload, String label, {String? localError}) async {
    if (localError != null) return _snack(context, kWsFlowErrors[localError] ?? localError);
    setState(() => _busy = true);
    try {
      final bool queued = await ProcessingStore.write('workshop.$action', <String, dynamic>{..._ref, ...payload}, label);
      _changed = true;
      if (mounted && queued) _snack(context, 'آفلاین ذخیره شد؛ پس از اتصال ارسال می‌شود');
      await _load();
    } on StockApiException catch (e) {
      if (mounted) _snack(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<Map<String, dynamic>> get _ins => ReturnsHelp.maps(_d['inputs']);

  /// عملیات «شکست»: خط شکست و برآوردها (از گرم ارسالی ذخیره‌شده روی سفارش؛ فقط نمایش).
  List<Widget> _crackInfo(double inKg) {
    if ('${_d['crack_line_name'] ?? ''}'.isEmpty) return const <Widget>[];
    String f2(double v) => toFaDigits(v.toStringAsFixed(2)).replaceAll('.', '٫');
    final double? g = _d['input_gram'] == null ? null : ReturnsHelp.d(_d['input_gram']);
    final WsCrackEstimate e = wsCrackEstimate(<Map<String, num?>>[<String, num?>{'kg': inKg, 'gram': g}], ReturnsHelp.d(_d['crack_loss_gram']));
    return <Widget>[
      Text('خط شکست: ${_d['crack_line_name']} (گرم پرتی ${faNum(ReturnsHelp.d(_d['crack_loss_gram']), dec: 2)})'),
      if (e.sentGram != null) Text('گرم ارسالی: ${f2(e.sentGram!)}  •  برآورد گرم دریافتی: ${f2(e.recvGram!)}'),
      if (e.kernelKg != null) Text('برآورد مغز سالم دریافتی: ${_kg(e.kernelKg)} کیلو${e.lossPct == null ? '' : '  •  برآورد درصد پرت: ${f2(e.lossPct!)}٪'}'),
    ];
  }
  List<Map<String, dynamic>> get _outs => ReturnsHelp.maps(_d['outputs']);
  bool get _isCrack => '${_d['op_type'] ?? ''}' == 'crack';

  /// v80: کادر «اطلاعات خروجی شکست» (بعد از ثبت مغز): گرم اولیه/دریافتی، افت گرم، درصد پرتی، بهای تمام‌شدهٔ هر کیلو مغز (فقط با مجوز بها).
  Widget? _crackOutCard(WsBalance t) {
    if (!_isCrack) return null;
    double kernel = 0;
    for (final Map<String, dynamic> r in _outs) {
      if (r['grade'] == 'kernel') kernel += ReturnsHelp.d(r['kg']);
    }
    if (kernel <= 0) return null;
    String f2(double v) => toFaDigits(v.toStringAsFixed(2)).replaceAll('.', '٫');
    final bool cost = wsCanCost();
    final double? buy = _d['buy_per_kg'] == null ? null : ReturnsHelp.d(_d['buy_per_kg']);
    final double crackCost = ReturnsHelp.d(_d['crack_cost_per_kg']);
    final WsCrackResult r = wsCrackResult(
      inKg: t.inputKg,
      gram: _d['input_gram'] == null ? null : ReturnsHelp.d(_d['input_gram']),
      kernelKg: kernel,
      buyPerKg: buy,
      crackCost: crackCost,
      lineLoss: _d['crack_loss_gram'] == null ? null : ReturnsHelp.d(_d['crack_loss_gram']),
    );
    // بسته ⇒ مقدار ذخیره‌شدهٔ سرور (همان که روی لات مغز نشسته)
    final double? unit = (_d['status'] == 'done' && _d['kernel_cost_per_kg'] != null) ? ReturnsHelp.d(_d['kernel_cost_per_kg']) : r.unitCost;
    Widget row(String k, String v, {bool strong = false, Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: <Widget>[
            Expanded(child: Text(k)),
            Text(v, style: TextStyle(fontWeight: strong ? FontWeight.bold : null, color: color)),
          ]),
        );
    final String none = r.initGram == null ? '— (گرم لات‌ها ثبت نشده)' : '—';
    return Card(
      color: Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
          Text('اطلاعات خروجی شکست', style: Theme.of(context).textTheme.titleMedium),
          const Divider(),
          row('مغز دریافتی', '${_kg(kernel)} کیلو'),
          if (r.expectedKernelKg != null) row('مغز مورد انتظار (طبق گرم پرتی خط)', '${_kg(r.expectedKernelKg)} کیلو'),
          row('گرم اولیه', r.initGram == null ? none : f2(r.initGram!)),
          row('گرم دریافتی', r.recvGram == null ? '—' : f2(r.recvGram!)),
          row('افت گرم', r.lossGram == null ? none : f2(r.lossGram!), color: (r.lossGram ?? 0) > 0 ? Colors.red : null),
          row('درصد پرتی', r.lossPct == null ? none : '${f2(r.lossPct!)}٪'),
          if (cost) ...<Widget>[
            const Divider(),
            row('میانگین قیمت هر کیلو پستهٔ ورودی', buy == null ? '—' : Fmt.money(buy, label: false)),
            Row(children: <Widget>[
              Expanded(child: Text('هزینهٔ شکست هر کیلو مغز: ${Fmt.money(crackCost, label: false)}')),
              if (_open)
                TextButton.icon(onPressed: _busy ? null : _editCrackCost, icon: const Icon(Icons.edit, size: 18), label: const Text('ثبت هزینه')),
            ]),
            row('بهای تمام‌شدهٔ هر کیلو مغز', unit == null ? '—' : Fmt.money(unit, label: false), strong: true),
            if ('${_d['input_cost_warning'] ?? ''}' == 'missing_input_cost') const Text(kWsMissingInputCost, style: TextStyle(color: Colors.orange)),
          ],
        ]),
      ),
    );
  }

  Future<void> _editCrackCost() async {
    final TextEditingController c = TextEditingController(text: _d['crack_cost_per_kg'] == null ? '' : '${_d['crack_cost_per_kg']}');
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('هزینهٔ شکست هر کیلو مغز'),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'مبلغ هر کیلو مغز', border: OutlineInputBorder()),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ذخیره')),
        ],
      ),
    );
    final String txt = c.text.trim();
    c.dispose();
    if (ok != true || !mounted) return;
    final double v = wsParseNum(txt);
    if (v < 0) return _snack(context, 'هزینه نمی‌تواند منفی باشد');
    await _send('crack_cost', <String, dynamic>{'crack_cost_per_kg': txt.isEmpty ? null : v}, 'هزینهٔ شکست هر کیلو مغز',
        localError: wsFlowCheck(_d['status'] as String?, 'output_save'));
  }

  // ── ورودی ──
  Future<void> _addInput() async {
    Map<String, String> lots;
    try {
      lots = await WsLotPicker.load();
    } on StockApiException catch (e) {
      if (mounted) _snack(context, e.message);
      return;
    }
    if (!mounted) return;
    String? lot;
    final TextEditingController kg = TextEditingController();
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => StatefulBuilder(
        builder: (BuildContext c, StateSetter set) => AlertDialog(
          title: const Text('افزودن ورودی'),
          content: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: lot,
              decoration: const InputDecoration(labelText: 'لات', border: OutlineInputBorder()),
              items: <DropdownMenuItem<String>>[
                for (final MapEntry<String, String> e in lots.entries) DropdownMenuItem<String>(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (String? v) => set(() => lot = v),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: kg,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'وزن (کیلو)', border: OutlineInputBorder()),
            ),
          ]),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('انصراف')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('افزودن')),
          ],
        ),
      ),
    );
    final double w = wsParseNum(kg.text);
    kg.dispose();
    if (ok != true || !mounted) return;
    if (lot == null || w <= 0) return _snack(context, 'لات و وزن بیشتر از صفر لازم است');
    await _send(
      'input_add',
      <String, dynamic>{'uid': ReturnsHelp.newUid('wi'), 'purchase_id': await WsLotPicker.serverId(lot!), 'kg': w, 'code': lots[lot]?.split(' · ').first},
      'ورودی کارگاه: ${faNum(w, dec: 3)} کیلو',
      localError: wsFlowCheck(_d['status'] as String?, 'input_add'),
    );
  }

  Future<void> _removeInput(Map<String, dynamic> r) async {
    if (!await confirm(context, 'این ورودی برداشته شود و به موجودی لات برگردد؟')) return;
    await _send(
      'input_remove',
      <String, dynamic>{if (r['id'] != null) 'input_id': r['id'], if (r['uid'] != null) 'input_uid': r['uid']},
      'برداشتن ورودی کارگاه',
      localError: wsFlowCheck(_d['status'] as String?, 'input_remove', inputs: _ins.length),
    );
  }

  // ── خروجی ──
  Future<void> _editOutput([Map<String, dynamic>? r]) async {
    final Map<String, dynamic>? res = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _OutputDialog(row: r, defaultOwner: '${_d['owner'] ?? ''}', crack: _isCrack),
    );
    if (res == null) return;
    await _send(
      'output_save',
      <String, dynamic>{
        'uid': r?['uid'] ?? ReturnsHelp.newUid('wx'),
        if (r?['id'] != null) 'output_id': r!['id'],
        ...res,
      },
      'خروجی کارگاه: ${res['grade'] == kWsCustomGrade ? res['type_name'] : kWsGradeLabels[res['grade']]} ${faNum(ReturnsHelp.d(res['kg']), dec: 3)} کیلو',
      localError: wsFlowCheck(_d['status'] as String?, 'output_save'),
    );
  }

  Future<void> _deleteOutput(Map<String, dynamic> r) async {
    if (!await confirm(context, 'این ردیف خروجی حذف شود؟')) return;
    await _send(
      'output_delete',
      <String, dynamic>{if (r['id'] != null) 'output_id': r['id'], if (r['uid'] != null) 'uid': r['uid']},
      'حذف خروجی کارگاه',
      localError: wsFlowCheck(_d['status'] as String?, 'output_delete'),
    );
  }

  // ── بستن / بازکردن ──
  Future<void> _close() async {
    final WsBalance t = wsFlowTotals(_d);
    final String? rule = wsFlowCheck(_d['status'] as String?, 'close', inputs: _ins.length, outputs: _outs.length, lossG: wsGrams(t.lossKg));
    if (rule != null) return _snack(context, kWsFlowErrors[rule]!);
    final Map<String, dynamic>? res = await showDialog<Map<String, dynamic>>(context: context, builder: (_) => _CloseDialog(detail: _d, totals: t));
    if (res == null) return;
    await _send('close', res, 'بستن عملیات کارگاه');
  }

  Future<void> _reopen() async {
    final String? block = _d['reopen_block'] as String?;
    if (block != null) return _snack(context, block);
    if (!await confirm(context, 'عملیات برای اصلاح باز شود؟ لات‌های خروجی و بهای آن‌ها حذف می‌شوند تا دوباره بسته شود؛ ورودی‌ها از موجودی کم‌شده می‌مانند.')) return;
    await _send('reopen', <String, dynamic>{}, 'بازکردن عملیات کارگاه', localError: wsFlowCheck(_d['status'] as String?, 'reopen'));
  }

  @override
  Widget build(BuildContext context) {
    final WsBalance t = wsFlowTotals(_d);
    final bool canManage = _can('workshop.manage');
    final bool edit = _open && !_busy;
    final Color tone = t.overOutput ? Colors.red : Colors.green;
    final Widget? crackCard = _crackOutCard(t);
    return Scaffold(
        appBar: AppBar(
          title: Text('${kWsOpLabels['${_d['op_type']}'] ?? 'عملیات کارگاه'}${_open ? ' — در کارگاه' : (_d['status'] == 'done' ? ' — بسته' : '')}'),
          leading: BackButton(onPressed: () => Navigator.pop(context, _changed)),
          actions: <Widget>[IconButton(tooltip: 'به‌روزرسانی', icon: const Icon(Icons.refresh), onPressed: _load)],
        ),
        body: _loading && _d.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
                  children: <Widget>[
                    if (_error != null)
                      Card(color: Theme.of(context).colorScheme.errorContainer, child: Padding(padding: const EdgeInsets.all(10), child: Text(_error!))),
                    if (_d.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('عملیات یافت نشد'))),
                    if (_pending > 0)
                      Card(child: ListTile(leading: const Icon(Icons.cloud_upload_outlined), title: Text('${faNum(_pending, dec: 0)} تغییر در صف ارسال'))),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                          Text('شروع: ${jalaliDate('${_d['started_at'] ?? _d['date'] ?? ''}')}${_d['closed_at'] == null ? '' : '  •  پایان: ${jalaliDate('${_d['closed_at']}')}'}'),
                          if ('${_d['owner'] ?? ''}'.isNotEmpty) Text('مالک: ${_d['owner']}'),
                          if ('${_d['pistachio_type'] ?? ''}'.isNotEmpty) Text('نوع پسته: ${_d['pistachio_type']}'),
                          if ('${_d['defect_note'] ?? ''}'.isNotEmpty) Text('ایراد بار: ${_d['defect_note']}'),
                          if (_d['initial_kg'] != null) Text('وزن خالص اولیه: ${_kg(_d['initial_kg'])} کیلو'),
                          if (_d['bale_count'] != null) Text('تعداد عدل: ${faNum(ReturnsHelp.d(_d['bale_count']), dec: 0)}'),
                          ..._crackInfo(t.inputKg),
                        ]),
                      ),
                    ),
                    // نوار زنده
                    Card(
                      color: tone.withValues(alpha: 0.12),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Wrap(spacing: 16, runSpacing: 4, children: <Widget>[
                          Text('ورودی ${_kg(t.inputKg)}'),
                          Text('Σ خروجی ${_kg(t.inputKg - t.lossKg)}'),
                          Text('افت ${_kg(t.lossKg)}${t.lossPct == null ? '' : ' (${faNum(t.lossPct!, dec: 1)}٪)'}',
                              style: TextStyle(color: t.overOutput ? Colors.red : null, fontWeight: FontWeight.bold)),
                          Text('سالم ${t.soundPct == null ? '—' : '${faNum(t.soundPct!, dec: 1)}٪'}'),
                          if (t.overOutput) const Text('جمع خروجی‌ها از ورودی بیشتر است', style: TextStyle(color: Colors.red)),
                        ]),
                      ),
                    ),
                    _section('ورودی‌ها', <Widget>[
                      for (final Map<String, dynamic> r in _ins)
                        ListTile(
                          dense: true,
                          title: Text('${r['code'] ?? ''} ${r['type_name'] ?? ''}'.trim().isEmpty ? 'لات ${r['purchase_id'] ?? r['lot_id'] ?? ''}' : '${r['code'] ?? ''} ${r['type_name'] ?? ''}'),
                          subtitle: Text('${_kg(r['kg'])} کیلو${r['id'] == null ? '  •  در صف ارسال' : ''}'),
                          trailing: edit && _ins.length > 1
                              ? IconButton(tooltip: 'برداشتن ورودی', icon: const Icon(Icons.remove_circle_outline), onPressed: () => _removeInput(r))
                              : null,
                        ),
                    ], action: edit ? TextButton.icon(onPressed: _addInput, icon: const Icon(Icons.add), label: const Text('افزودن ورودی')) : null),
                    _section('خروجی‌ها (فقط هنگام بستن وارد موجودی می‌شوند)', <Widget>[
                      if (_outs.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('هنوز خروجی ثبت نشده')),
                      for (final Map<String, dynamic> r in _outs)
                        ListTile(
                          dense: true,
                          title: Text('${r['grade'] == kWsCustomGrade ? (r['type_name'] ?? 'سایر') : (kWsGradeLabels['${r['grade']}'] ?? r['grade'])} — ${_kg(r['kg'])} کیلو'),
                          subtitle: Text(<String>[
                            if (ReturnsHelp.d(r['small_sacks']) > 0 || ReturnsHelp.d(r['large_sacks']) > 0)
                              'گونی ${faNum(ReturnsHelp.d(r['small_sacks']), dec: 0)} کوچک / ${faNum(ReturnsHelp.d(r['large_sacks']), dec: 0)} بزرگ',
                            if ('${r['owner'] ?? ''}'.isNotEmpty) 'مالک ${r['owner']}',
                            if ('${r['code'] ?? ''}'.isNotEmpty) 'لات ${r['code']}',
                            if (r['id'] == null) 'در صف ارسال',
                          ].join('  •  ')),
                          onTap: edit ? () => _editOutput(r) : null,
                          trailing: edit ? IconButton(tooltip: 'حذف', icon: const Icon(Icons.delete_outline), onPressed: () => _deleteOutput(r)) : null,
                        ),
                    ], action: edit ? TextButton.icon(onPressed: () => _editOutput(), icon: const Icon(Icons.add), label: const Text('ثبت خروجی')) : null),
                    if (crackCard != null) crackCard,
                    const SizedBox(height: 12),
                    if (_open && canManage)
                      FilledButton.icon(
                        onPressed: (_busy || t.overOutput) ? null : _close,
                        icon: const Icon(Icons.lock_outline),
                        label: const Text('بستن عملیات'),
                      ),
                    if (_open && !canManage) const Text('بستن عملیات با مدیر کارگاه است (مجوز workshop.manage).'),
                    if (_d['status'] == 'done' && canManage) ...<Widget>[
                      OutlinedButton.icon(
                        onPressed: (_busy || _d['reopen_block'] != null) ? null : _reopen,
                        icon: const Icon(Icons.lock_open),
                        label: const Text('بازکردن برای اصلاح'),
                      ),
                      if (_d['reopen_block'] != null)
                        Padding(padding: const EdgeInsets.only(top: 6), child: Text('${_d['reopen_block']}', style: const TextStyle(color: Colors.orange))),
                    ],
                  ],
                ),
              ),
    );
  }

  Widget _section(String title, List<Widget> children, {Widget? action}) => Card(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Row(children: <Widget>[Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)), if (action != null) action]),
            ...children,
          ]),
        ),
      );
}

/// فرم یک ردیف خروجی (درجه، نام برای «سایر»، کیلو، گونی، انبار، مالک، قیمت هر کیلو با مجوز بها).
class _OutputDialog extends StatefulWidget {
  const _OutputDialog({this.row, required this.defaultOwner, this.crack = false});
  final Map<String, dynamic>? row;
  final String defaultOwner;
  /// v80: عملیات «شکست» ⇒ فقط مغز / پوست / نشکن؛ مغز قیمت فروش ندارد (بهایش از فرمول شکست).
  final bool crack;

  @override
  State<_OutputDialog> createState() => _OutputDialogState();
}

class _OutputDialogState extends State<_OutputDialog> {
  late String _grade = widget.crack
      ? (kWsCrackGrades.contains(widget.row?['grade']) ? '${widget.row!['grade']}' : 'kernel')
      : '${widget.row?['grade'] ?? 'sound'}';
  List<String> get _grades => widget.crack ? kWsCrackGrades : <String>[...kWsGrades, kWsCustomGrade];
  bool get _priced => _grade != 'sound' && !(widget.crack && _grade == 'kernel');
  late final TextEditingController _name = TextEditingController(text: widget.row?['grade'] == kWsCustomGrade ? '${widget.row?['type_name'] ?? ''}' : '');
  late final TextEditingController _kg = TextEditingController(text: widget.row == null ? '' : '${widget.row!['kg']}');
  late final TextEditingController _small = TextEditingController(text: '${widget.row?['small_sacks'] ?? 0}');
  late final TextEditingController _large = TextEditingController(text: '${widget.row?['large_sacks'] ?? 0}');
  late final TextEditingController _owner = TextEditingController(text: '${widget.row?['owner'] ?? widget.defaultOwner}');
  late final TextEditingController _price = TextEditingController(text: widget.row?['out_price'] == null ? '' : '${widget.row!['out_price']}');
  late String? _wh = widget.row?['warehouse_uid'] as String?;
  List<WhOption> _whs = <WhOption>[];

  @override
  void initState() {
    super.initState();
    StockLookup.warehouses().then((List<WhOption> w) {
      if (mounted) setState(() => _whs = w);
    }).catchError((Object _) {}); // بدون مجوز انبار ⇒ انبار پیش‌فرض عملیات
  }

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[_name, _kg, _small, _large, _owner, _price]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _num(TextEditingController c, String l) => TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: l, border: const OutlineInputBorder()),
      );

  @override
  Widget build(BuildContext context) {
    const SizedBox gap = SizedBox(height: 8);
    return AlertDialog(
      title: Text(widget.row == null ? 'ثبت خروجی' : 'ویرایش خروجی'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          DropdownButtonFormField<String>(
            initialValue: _grade,
            decoration: const InputDecoration(labelText: 'درجه', border: OutlineInputBorder()),
            items: <DropdownMenuItem<String>>[
              for (final String g in _grades) DropdownMenuItem<String>(value: g, child: Text(kWsGradeLabels[g] ?? g)),
            ],
            onChanged: (String? v) => setState(() => _grade = v ?? _grades.first),
          ),
          if (_grade == kWsCustomGrade) ...<Widget>[
            gap,
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'نام خروجی', border: OutlineInputBorder())),
          ],
          gap,
          _num(_kg, 'وزن (کیلو)'),
          gap,
          Row(children: <Widget>[Expanded(child: _num(_small, 'گونی کوچک')), const SizedBox(width: 8), Expanded(child: _num(_large, 'گونی بزرگ'))]),
          gap,
          TextField(controller: _owner, decoration: const InputDecoration(labelText: 'مالک', border: OutlineInputBorder())),
          if (_whs.isNotEmpty) ...<Widget>[
            gap,
            DropdownButtonFormField<String?>(
              initialValue: _wh,
              decoration: const InputDecoration(labelText: 'انبار', border: OutlineInputBorder()),
              items: <DropdownMenuItem<String?>>[
                const DropdownMenuItem<String?>(value: null, child: Text('انبار عملیات (پیش‌فرض)')),
                for (final WhOption w in _whs) DropdownMenuItem<String?>(value: w.uid, child: Text(w.name)),
              ],
              onChanged: (String? v) => setState(() => _wh = v),
            ),
          ],
          if (wsCanCost() && _priced) ...<Widget>[gap, _num(_price,'قیمت فروش هر کیلو (اختیاری؛ هنگام بستن هم قابل ثبت)')],
        ]),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('انصراف')),
        FilledButton(
          onPressed: () {
            final double kg = wsParseNum(_kg.text);
            if (kg <= 0) return _snack(context, 'وزن باید بیشتر از صفر باشد');
            if (_grade == kWsCustomGrade && _name.text.trim().isEmpty) return _snack(context, 'نام خروجی جدید را وارد کنید');
            Navigator.pop(context, <String, dynamic>{
              'grade': _grade,
              'kg': kg,
              'small_sacks': wsParseNum(_small.text),
              'large_sacks': wsParseNum(_large.text),
              'owner': _owner.text.trim(),
              if (_grade == kWsCustomGrade) 'type_name': _name.text.trim(),
              if (_wh != null) 'warehouse_uid': _wh,
              if (wsCanCost() && _priced && _price.text.trim().isNotEmpty) 'price_per_kg': wsParseNum(_price.text),
            });
          },
          child: const Text('ذخیره'),
        ),
      ],
    );
  }
}

/// فرم بستن: تاریخ پایان + بها (فقط با مجوز). قیمت خرید (V) فقط‌نمایش از بهای لات‌های ورودی.
class _CloseDialog extends StatefulWidget {
  const _CloseDialog({required this.detail, required this.totals});
  final Map<String, dynamic> detail;
  final WsBalance totals;

  @override
  State<_CloseDialog> createState() => _CloseDialogState();
}

class _CloseDialogState extends State<_CloseDialog> {
  DateTime _end = DateTime.now();
  late final Map<String, TextEditingController> _cost = <String, TextEditingController>{
    for (final List<String> f in kWsCostFields) f[0]: TextEditingController(text: widget.detail[f[0]] == null ? '' : '${widget.detail[f[0]]}'),
  };
  late final List<Map<String, dynamic>> _rows = <Map<String, dynamic>>[
    for (final Map<String, dynamic> r in ReturnsHelp.maps(widget.detail['outputs']))
      if (r['grade'] != 'sound' && !(_crack && r['grade'] == 'kernel')) r,
  ];
  /// v80: «شکست» ⇒ بهای مغز از فرمول شکست (هزینهٔ شکست هر کیلو مغز در کادر اطلاعات خروجی)؛ اجرت/سایر هزینه این‌جا نمایش داده نمی‌شود.
  late final bool _crack = '${widget.detail['op_type'] ?? ''}' == 'crack';
  late final List<TextEditingController> _prices = <TextEditingController>[
    for (final Map<String, dynamic> r in _rows) TextEditingController(text: r['out_price'] == null ? '${r['price_per_kg'] ?? ''}' : '${r['out_price']}'),
  ];

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[..._cost.values, ..._prices]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool cost = wsCanCost();
    final WsBalance t = widget.totals;
    const SizedBox gap = SizedBox(height: 8);
    return AlertDialog(
      title: const Text('بستن عملیات'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
          Text('ورودی ${_kg(t.inputKg)} · Σ خروجی ${_kg(t.inputKg - t.lossKg)} · افت ${_kg(t.lossKg)} کیلو'),
          const Text('با بستن، خروجی‌ها لات می‌شوند و وارد موجودی می‌شوند.'),
          gap,
          JalaliDateField(label: 'تاریخ پایان', value: _end, onChanged: (DateTime d) => setState(() => _end = d)),
          if (cost) ...<Widget>[
            gap,
            wsReadOnlyField(kWsBuyLabel, widget.detail['buy_per_kg'] == null ? '—' : Fmt.money(ReturnsHelp.d(widget.detail['buy_per_kg']), label: false),
                helper: 'محاسبهٔ خودکار سرور؛ قابل ویرایش نیست'),
            if ('${widget.detail['input_cost_warning'] ?? ''}' == 'missing_input_cost')
              const Padding(padding: EdgeInsets.only(top: 4), child: Text(kWsMissingInputCost, style: TextStyle(color: Colors.orange))),
            if (_crack) ...<Widget>[
              gap,
              Text('بهای مغز با فرمول شکست حساب می‌شود (هزینهٔ شکست هر کیلو مغز: '
                  '${Fmt.money(ReturnsHelp.d(widget.detail['crack_cost_per_kg']), label: false)}). قیمت پوست و نشکن را وارد کنید.'),
            ],
            for (final List<String> f in _crack ? const <List<String>>[] : kWsCostFields) ...<Widget>[
              gap,
              TextField(
                controller: _cost[f[0]],
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: <ThousandsInputFormatter>[ThousandsInputFormatter()],
                decoration: InputDecoration(labelText: f[1], border: const OutlineInputBorder()),
              ),
            ],
            for (int i = 0; i < _rows.length; i++) ...<Widget>[
              gap,
              TextField(
                controller: _prices[i],
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: <ThousandsInputFormatter>[ThousandsInputFormatter()],
                decoration: InputDecoration(
                  labelText: 'قیمت هر کیلو — ${_rows[i]['grade'] == kWsCustomGrade ? (_rows[i]['type_name'] ?? 'سایر') : kWsGradeLabels['${_rows[i]['grade']}']} (${_kg(_rows[i]['kg'])} کیلو)',
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ] else
            const Padding(padding: EdgeInsets.only(top: 8), child: Text('بها را بعداً دارندهٔ مجوز بها ثبت می‌کند.')),
        ]),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('انصراف')),
        FilledButton(
          onPressed: () {
            final Map<String, dynamic> p = <String, dynamic>{'end_date': ReturnsHelp.iso(_end)};
            if (cost) {
              _cost.forEach((String k, TextEditingController c) {
                if (c.text.trim().isNotEmpty) p[k] = wsParseNum(c.text);
              });
              p['outputs'] = <Map<String, dynamic>>[
                for (int i = 0; i < _rows.length; i++)
                  <String, dynamic>{
                    if (_rows[i]['id'] != null) 'id': _rows[i]['id'],
                    if (_rows[i]['uid'] != null) 'uid': _rows[i]['uid'],
                    'price_per_kg': _prices[i].text.trim().isEmpty ? null : wsParseNum(_prices[i].text),
                  },
              ];
            }
            Navigator.pop(context, p);
          },
          child: const Text('بستن عملیات'),
        ),
      ],
    );
  }
}
