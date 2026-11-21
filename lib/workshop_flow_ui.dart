import 'package:flutter/material.dart';

import 'db.dart';
import 'entity_store.dart' show EntityStore;
import 'fmt.dart' show Fmt;
import 'form_settings.dart' show FormSettingsLocal;
import 'perms.dart';
import 'processing_flow_ui.dart' show ChainSortDialog, procChainCard, wsMoistureRows; // v85
import 'processing_ui.dart' show ProcessingStore;
import 'returns_ui.dart' show ReturnsHelp;
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException, StockLookup, WhOption;
import 'widgets.dart' show JalaliDateField, confirm;
import 'workshop_calc.dart';
import 'workshop_reports_ui.dart' show CrackLineReportScreen, wsPrintOp, wsPrintOpsList;
import 'workshop_ui.dart' show kWsBuyLabel, kWsCostFields, kWsMissingInputCost, wsCanCost, wsParseNum, wsReadOnlyField;

/// فاز ۲ مجد — «کارگاه مرحله‌ای» (فایل مشترک اندروید و ویندوز؛ بدون واژهٔ مخصوص پلتفرم).
///   [WorkshopOpenFormScreen]  شروع عملیات: سربرگ + ورودی‌ها ⇒ workshop.open (ورودی‌ها همان لحظه از موجودی کم می‌شوند).
///   [WorkshopOpsScreen]       فهرست عملیات کارگاه با فیلتر «عملیات باز» و جمع «در کارگاه».
///   [WorkshopOpScreen]        جزئیات یک عملیات: ورودی‌ها، خروجی‌ها، کادر اطلاعات خروجی، «بستن عملیات»، «بازکردن برای اصلاح».
/// v81: فقط سه نوع عملیات در فرم شروع: «شکست»، «تولید» (تک‌لات + نوع تولید)، «آبخندان» (تک‌لات از دستهٔ دهنبست؛ خروجی مثل اتاق انس).
///   دسته/نوع کالای خروجی از جدول مشترک categories/types (همان خرید و اتاق انس) با امکان افزودن دسته و نوع تازه.
/// همهٔ نوشتن‌ها با ProcessingStore.write (آنلاین‌اول؛ قطع شبکه ⇒ صف FIFO با uid؛ ترتیب ثبت حفظ می‌شود: output_save قبل از close).
/// سفارش با order_uid شناخته می‌شود تا اکشن‌های صف حتی قبل از رسیدن workshop.open به سرور معتبر باشند.
/// نمای آفلاین = آخرین پاسخ workshop.get (کش) + اکشن‌های صف همین عملیات با wsFlowApply (آینهٔ قواعد سرور).

String _kg(dynamic v) => faNum(ReturnsHelp.d(v), dec: 3);
String _f2(num v) => toFaDigits(v.toStringAsFixed(2)).replaceAll('.', '٫');
bool _can(String k) => StaffPerms.I.can(k);
void _snack(BuildContext c, String m) => ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));
double? _optD(dynamic v) => v == null || '$v'.isEmpty ? null : ReturnsHelp.d(v);

/// کلید کش/صف یک عملیات: uid سرور یا «id<شناسه>» برای عملیات قدیمی بدون uid.
String wsOpKey(String? uid, int? id) => (uid != null && uid.isNotEmpty) ? uid : 'id${id ?? 0}';

/// پرسیدن یک نام (دسته/نوع/نوع تولید تازه).
Future<String?> _askName(BuildContext context, String title, {String label = 'نام'}) async {
  final TextEditingController c = TextEditingController();
  final String? r = await showDialog<String>(
    context: context,
    builder: (BuildContext ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller: c, autofocus: true, maxLength: 100, decoration: InputDecoration(labelText: label, border: const OutlineInputBorder())),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('انصراف')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('افزودن')),
      ],
    ),
  );
  c.dispose();
  return (r == null || r.isEmpty) ? null : r;
}

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
    for (final Map<String, dynamic> r in await localLots()) {
      lots['${r['id']}'] = '${r['code'] ?? ''} · ${r['type_name'] ?? ''} · ${faNum(ReturnsHelp.d(r['remaining']), dec: 3)} کیلو';
    }
    return lots;
  }

  /// v82: همهٔ لات‌های دارای موجودی (به‌جز امانی) از دیتابیس محلی. LEFT JOIN دسته ⇒ لاتی که دسته‌اش هنوز در فهرست محلی نیست
  /// (مثلاً مغز/دستهٔ تازهٔ اتاق انس یا خروجی کارگاه) هم نمایش داده می‌شود؛ inventoryAll با JOIN آن‌ها را حذف می‌کرد.
  static Future<List<Map<String, dynamic>>> localLots() async {
    final db = await AppDb.I.db;
    final List<Map<String, Object?>> rows = await db.rawQuery('''
        SELECT p.id, p.code, p.type_name, p.seller, p.is_mix, p.remaining, p.net_weight, p.gram, p.ounce, p.category_id, p.date,
               COALESCE(p.small_sacks_remaining, 0) AS small_left, COALESCE(p.large_sacks_remaining, 0) AS large_left,
               c.name AS category_name, c.preset_key AS category_preset
        FROM purchases p LEFT JOIN categories c ON c.id = p.category_id
        WHERE p.remaining > 0.000001 AND COALESCE(p.is_mix, 0) <> 3
        ORDER BY p.date DESC, p.id DESC''');
    return <Map<String, dynamic>>[for (final Map<String, Object?> r in rows) Map<String, dynamic>.from(r)];
  }

  static Future<int> serverId(String key) async {
    if (serverIds) return int.parse(key);
    return ReturnsHelp.serverId('purchase', int.parse(key));
  }

  /// مشخصات کامل لات‌ها + خطوط شکست فعال + دسته‌ها و انواع کالا.
  /// اپراتور ⇒ همه از workshop.lots؛ بقیه ⇒ لات‌ها و دسته‌ها محلی، خطوط از entity محلی (خالی ⇒ از سرور).
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
      for (final Map<String, dynamic> r in await localLots()) {
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

// ---------------------------------------------------------------------------
// دسته‌ها و انواع کالا (جدول مشترک خرید / اتاق انس / کارگاه)
// ---------------------------------------------------------------------------

/// یک دستهٔ کالا با انواعش. [id] = شناسهٔ سرور برای اپراتور، شناسهٔ محلی برای بقیه.
class WsCat {
  const WsCat(this.id, this.name, this.preset, this.types);
  final int id;
  final String name;
  final String? preset;
  final List<String> types;
}

class WsCats {
  WsCats._();

  static Future<List<WsCat>> load() async {
    if (WsLotPicker.serverIds) {
      final Map<String, dynamic> r = await StockApi.call('workshop.lots');
      return <WsCat>[
        for (final Map<String, dynamic> c in ReturnsHelp.maps(r['categories']))
          WsCat(ReturnsHelp.d(c['id']).toInt(), '${c['name'] ?? ''}', c['preset_key'] as String?, <String>[for (final dynamic t in (c['types'] as List<dynamic>? ?? const <dynamic>[])) '$t']),
      ];
    }
    final List<WsCat> out = <WsCat>[];
    for (final Map<String, dynamic> c in await AppDb.I.categories()) {
      final int id = (c['id'] as num).toInt();
      out.add(WsCat(id, '${c['name'] ?? ''}', c['preset_key'] as String?, <String>[for (final Map<String, dynamic> t in await AppDb.I.typesOf(id)) '${t['name']}']));
    }
    return out;
  }

  static WsCat? byPreset(List<WsCat> cats, String key) {
    for (final WsCat c in cats) {
      if (c.preset == key) return c;
    }
    return null;
  }

  static WsCat? byId(List<WsCat> cats, int? id) {
    for (final WsCat c in cats) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// شناسهٔ سرور دسته (اپراتور ⇒ همان؛ بقیه ⇒ نگاشت شناسهٔ محلی).
  static Future<int> serverId(int id) async {
    if (WsLotPicker.serverIds) return id;
    return ReturnsHelp.serverId('cat', id);
  }

  /// دستهٔ تازه (در همهٔ فهرست‌ها: خرید، اتاق انس، کارگاه). بازگشت: شناسهٔ دستهٔ تازه.
  static Future<int> addCategory(String name) async {
    if (WsLotPicker.serverIds) {
      final Map<String, dynamic> r = await StockApi.call('categories.create', <String, dynamic>{'name': name});
      return ReturnsHelp.d(r['id']).toInt();
    }
    return AppDb.I.addCategory(name);
  }

  /// نوع تازه برای یک دسته (در همهٔ فهرست‌ها).
  static Future<void> addType(WsCat c, String name) async {
    if (WsLotPicker.serverIds) {
      await StockApi.call('types.create', <String, dynamic>{'category_id': c.id, 'name': name});
      return;
    }
    await AppDb.I.addType(c.id, name);
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

/// مشخصات یک لات برای فرم شروع عملیات.
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
    this.preset,
  });

  factory WsLotInfo.fromRow(String key, Map<String, dynamic> r, {dynamic smallLeft, dynamic largeLeft}) {
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
      gram: _optD(r['gram']),
      ounce: _optD(r['ounce']),
      preset: r['category_preset'] as String?,
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
  final String? preset;

  /// لات کوت‌ریزی (is_mix=1) ⇒ نام کوت (= نام قلم لات مخلوط)؛ وگرنه نام فروشنده/مالک.
  bool get isKout => isMix == 1;
  String get whoLabel => isKout ? 'نام کوت' : 'مالک / فروشنده';
  String get who {
    if (isKout) return type.isEmpty ? 'کوت' : type;
    if (seller.isNotEmpty) return seller;
    return type.isEmpty ? code : type;
  }

  /// «دسته نوع» (مثلاً «دهنبست اکبری»).
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

/// یک ورودی: لات + عدل بزرگ + عدل کوچک + وزن خالص (+ «همه موجودی»).
class _LotRow {
  final TextEditingController kg = TextEditingController();
  final TextEditingController large = TextEditingController();
  final TextEditingController small = TextEditingController();
  String? lot;
  bool all = false;
  void dispose() {
    kg.dispose();
    large.dispose();
    small.dispose();
  }
}

String _numText(double v) {
  final String s = v.toStringAsFixed(3);
  return s.contains('.') ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '') : s;
}

class WorkshopOpenFormScreen extends StatefulWidget {
  const WorkshopOpenFormScreen({super.key});

  @override
  State<WorkshopOpenFormScreen> createState() => _WorkshopOpenFormScreenState();
}

class _WorkshopOpenFormScreenState extends State<WorkshopOpenFormScreen> {
  static const String _newKind = '\u0000new';
  DateTime _date = DateTime.now();
  String? _op; // v81: قبل از انتخاب خالی
  final TextEditingController _note = TextEditingController();
  bool _saving = false;

  final List<_LotRow> _rows = <_LotRow>[_LotRow()];
  Map<String, WsLotInfo> _info = <String, WsLotInfo>{};
  List<WsCrackLine> _lines = <WsCrackLine>[];
  String? _line;
  bool _loaded = false;

  // «تولید»
  List<String> _kinds = <String>[...kWsProdKinds];
  String? _kind;
  int _kindRev = 0; // کلید دراپ‌داون: انصراف از «نوع تازه» انتخاب قبلی را برمی‌گرداند

  @override
  void initState() {
    super.initState();
    _load();
    _loadKinds();
  }

  Future<void> _load() async {
    try {
      final WsCrackData d = await WsLotPicker.loadCrack();
      if (!mounted) return;
      setState(() {
        _info = <String, WsLotInfo>{for (final WsLotInfo i in d.lots) i.key: i};
        _lines = d.lines;
        if (_line != null && !_lines.any((WsCrackLine l) => l.uid == _line)) _line = null;
        if (_line == null && _lines.length == 1) _line = _lines.first.uid;
        _loaded = true;
      });
    } on StockApiException catch (e) {
      if (mounted) {
        setState(() => _loaded = true);
        _snack(context, e.message);
      }
    }
  }

  /// انواع تولید = پیش‌فرض‌ها + نوع‌های تازه‌ای که قبلاً روی عملیات «تولید» ثبت شده‌اند (از فهرست کش‌شدهٔ کارگاه).
  Future<void> _loadKinds() async {
    final Map<String, dynamic> c = await ProcessingStore.cachedWorkshopList();
    final List<String> k = <String>[...kWsProdKinds];
    for (final Map<String, dynamic> o in ReturnsHelp.maps(c['items'])) {
      final String v = '${o['prod_kind'] ?? ''}'.trim();
      if (v.isNotEmpty && !k.contains(v)) k.add(v);
    }
    if (mounted) setState(() => _kinds = k);
  }

  bool get _single => _op != null && kWsSingleLotTypes.contains(_op);

  void _setOp(String? v) {
    setState(() {
      _op = v;
      if (_single && _rows.length > 1) {
        for (final _LotRow r in _rows.sublist(1)) {
          r.dispose();
        }
        _rows.removeRange(1, _rows.length);
      }
      // آبخندان فقط دهنبست ⇒ لات نامجاز پاک می‌شود
      for (final _LotRow r in _rows) {
        if (r.lot != null && !_lotAllowed(_info[r.lot])) r.lot = null;
      }
    });
  }

  bool _lotAllowed(WsLotInfo? i) => i != null && (_op != 'abkhandan' || i.preset == 'dombest');

  List<WsLotInfo> get _lotChoices => _info.values.where(_lotAllowed).toList();

  @override
  void dispose() {
    _note.dispose();
    for (final _LotRow r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  WsCrackLine? get _lineObj {
    for (final WsCrackLine l in _lines) {
      if (l.uid == _line) return l;
    }
    return null;
  }

  WsCrackEstimate get _estimate => wsCrackEstimate(<Map<String, num?>>[
        for (final _LotRow r in _rows)
          if (r.lot != null) <String, num?>{'kg': wsParseNum(r.kg.text), 'gram': _info[r.lot]?.gram},
      ], _lineObj?.lossGram);

  /// «نوع پسته ورودی»: دسته+نوع لات‌های ورودی، بدون تکرار، با «/».
  String get _types {
    final List<String> out = <String>[];
    for (final _LotRow r in _rows) {
      final String t = _info[r.lot]?.pistachio ?? '';
      if (t.isNotEmpty && !out.contains(t)) out.add(t);
    }
    return out.join('/');
  }

  /// خطای موجودی هر ردیف (مجموع ردیف‌های همان لات با موجودی مقایسه می‌شود) یا null.
  String? _rowError(int idx) {
    final _LotRow r = _rows[idx];
    final WsLotInfo? i = _info[r.lot];
    if (i == null) return null;
    double kg = 0, sm = 0, lg = 0;
    for (final _LotRow x in _rows) {
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

  bool get _overStock {
    for (int i = 0; i < _rows.length; i++) {
      if (_rowError(i) != null) return true;
    }
    return false;
  }

  /// «همه موجودی»: وزن و عدل‌ها از موجودی انبار لات پر می‌شود.
  void _fillAll(_LotRow r) {
    final WsLotInfo? i = _info[r.lot];
    if (!r.all || i == null) return;
    r.kg.text = _numText(i.remaining);
    r.large.text = _numText(i.largeLeft);
    r.small.text = _numText(i.smallLeft);
  }

  Future<void> _submit() async {
    final String? op = _op;
    if (op == null) return _snack(context, 'نوع عملیات را انتخاب کنید');
    final WsCrackLine? line = _lineObj;
    if (op == 'crack' && line == null) return _snack(context, 'خط شکست را انتخاب کنید');
    if (op == 'production' && (_kind == null || _kind!.isEmpty)) return _snack(context, 'نوع تولید را انتخاب کنید');
    for (int i = 0; i < _rows.length; i++) {
      final _LotRow r = _rows[i];
      if (r.lot == null) return _snack(context, 'برای هر ورودی لات را انتخاب کنید');
      if (!_lotAllowed(_info[r.lot])) return _snack(context, 'در «آبخندان» فقط پستهٔ دستهٔ «دهنبست» قابل انتخاب است');
      if (wsParseNum(r.kg.text) <= 0) return _snack(context, 'وزن هر ورودی باید بیشتر از صفر باشد');
      if (wsParseNum(r.small.text) < 0 || wsParseNum(r.large.text) < 0) return _snack(context, 'تعداد عدل نامعتبر است');
      final String? err = _rowError(i);
      if (err != null) return _snack(context, err);
    }
    setState(() => _saving = true);
    try {
      final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
      double bales = 0;
      for (final _LotRow r in _rows) {
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
      final String types = _types;
      final String uid = ReturnsHelp.newUid('wo');
      final Map<String, dynamic> payload = <String, dynamic>{
        'uid': uid,
        'op_type': op,
        'start_date': ReturnsHelp.iso(_date),
        'note': _note.text.trim(),
        'items': items,
        if (op == 'crack') ...<String, dynamic>{
          'crack_line_uid': line!.uid,
          // سه فیلد زیر فقط برای نمای آفلاین است؛ سرور از خط و لات‌ها خودش می‌سازد
          'crack_line_name': line.name,
          'crack_loss_gram': line.lossGram,
        },
        if (op == 'production') 'prod_kind': _kind,
        if (est.sentGram != null) 'input_gram': double.parse(est.sentGram!.toStringAsFixed(2)),
        if (types.isNotEmpty) 'pistachio_type': types.length > 100 ? types.substring(0, 100) : types,
        if (bales > 0) 'bale_count': bales,
      };
      final String label = op == 'crack' ? 'شکست (${line!.name})' : (op == 'production' ? 'تولید ($_kind)' : (kWsOpLabels[op] ?? op));
      final bool queued = await ProcessingStore.write('workshop.open', payload, 'شروع عملیات کارگاه: $label');
      if (!mounted) return;
      _snack(context, queued ? 'آفلاین ذخیره شد؛ پس از اتصال ارسال می‌شود' : 'عملیات باز شد؛ خروجی‌ها را در طول کار ثبت کنید');
      Navigator.pushReplacement(context, MaterialPageRoute<bool>(builder: (_) => WorkshopOpScreen(orderUid: uid)));
    } on StockApiException catch (e) {
      _snack(context, e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _opField() => DropdownButtonFormField<String>(
        key: ValueKey<String>('op-$_op'),
        initialValue: _op,
        isExpanded: true,
        hint: const Text('انتخاب کنید'),
        decoration: const InputDecoration(labelText: 'نوع عملیات', border: OutlineInputBorder()),
        items: <DropdownMenuItem<String>>[
          for (final String k in kWsOpenTypes) DropdownMenuItem<String>(value: k, child: Text(kWsOpLabels[k] ?? k)),
        ],
        onChanged: _setOp,
      );

  Widget _lineField() => _lines.isEmpty
      ? InputDecorator(
          decoration: const InputDecoration(labelText: 'خط شکست', border: OutlineInputBorder()),
          child: Text(_loaded ? 'خطی تعریف نشده (منو ← خطوط شکست)' : 'در حال بارگذاری…',
              style: TextStyle(color: _loaded ? Colors.red : null, fontSize: 12.5), overflow: TextOverflow.ellipsis),
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

  Widget _kindField() => DropdownButtonFormField<String>(
        key: ValueKey<String>('kind-$_kind-$_kindRev'),
        initialValue: _kind,
        isExpanded: true,
        hint: const Text('انتخاب کنید'),
        decoration: const InputDecoration(labelText: 'نوع تولید', border: OutlineInputBorder()),
        items: <DropdownMenuItem<String>>[
          for (final String k in _kinds) DropdownMenuItem<String>(value: k, child: Text(k, overflow: TextOverflow.ellipsis)),
          const DropdownMenuItem<String>(value: _newKind, child: Text('+ افزودن نوع تازه…', style: TextStyle(color: Colors.blue))),
        ],
        onChanged: (String? v) async {
          if (v != _newKind) return setState(() => _kind = v);
          final String? n = await _askName(context, 'نوع تولید تازه', label: 'نام نوع تولید');
          if (!mounted) return;
          setState(() {
            if (n != null && !_kinds.contains(n)) _kinds = <String>[..._kinds, n];
            _kind = n ?? _kind;
            _kindRev++;
          });
        },
      );

  /// انتخاب لات (فهرست با نام مالک/کوت و کد).
  Widget _lotDropdown(_LotRow r, String label) {
    final List<WsLotInfo> lots = _lotChoices;
    return DropdownButtonFormField<String>(
      key: ValueKey<String>('lot-${identityHashCode(r)}-$_op-${lots.length}'),
      isExpanded: true,
      initialValue: lots.any((WsLotInfo l) => l.key == r.lot) ? r.lot : null,
      itemHeight: 56,
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
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
                Text('${l.code}  ·  ${l.pistachio}  ·  ${_kg(l.remaining)} کیلو', style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor), overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
      ],
      onChanged: (String? v) => setState(() {
        r.lot = v;
        _fillAll(r);
      }),
    );
  }

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
        if (i.pistachio.isNotEmpty) kv('دسته و نوع پسته', i.pistachio),
        kv('وزن خالص در انبار', '${_kg(i.remaining)} کیلو'),
        kv('عدل بزرگ', faNum(i.largeLeft, dec: 0)),
        kv('عدل کوچک', faNum(i.smallLeft, dec: 0)),
        if (i.gram != null) kv('گرم', faNum(i.gram!, dec: 2)),
        if (i.ounce != null) kv('انس', faNum(i.ounce!, dec: 2)),
      ]),
    );
  }

  /// فیلدهای عدل/وزن + «همه موجودی» یک ردیف.
  Widget _qtyFields(_LotRow r) {
    TextField field(TextEditingController c, String label, {bool decimal = true}) => TextField(
          controller: c,
          enabled: !r.all,
          keyboardType: TextInputType.numberWithOptions(decimal: decimal),
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
          onChanged: (_) => setState(() {}),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      const SizedBox(height: 10),
      Row(children: <Widget>[
        Expanded(child: field(r.large, 'عدل بزرگ', decimal: false)),
        const SizedBox(width: 8),
        Expanded(child: field(r.small, 'عدل کوچک', decimal: false)),
        const SizedBox(width: 8),
        Expanded(flex: 2, child: field(r.kg, 'وزن خالص (کیلو)')),
      ]),
      CheckboxListTile(
        value: r.all,
        dense: true,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: const Text('همه موجودی (وزن و عدل‌ها طبق موجودی انبار)'),
        onChanged: r.lot == null
            ? null
            : (bool? v) => setState(() {
                  r.all = v ?? false;
                  _fillAll(r);
                }),
      ),
    ]);
  }

  Widget _lotCard(int idx) {
    final _LotRow r = _rows[idx];
    final WsLotInfo? info = _info[r.lot];
    final String? err = _rowError(idx);
    return Card(
      key: ObjectKey(r),
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Expanded(child: _lotDropdown(r, 'لات ${_rows.length > 1 ? faNum(idx + 1, dec: 0) : ''}'.trim())),
            if (_rows.length > 1)
              IconButton(
                tooltip: 'حذف ورودی',
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: () => setState(() => _rows.removeAt(idx).dispose()),
              ),
          ]),
          if (info != null) _lotInfoBox(info),
          _qtyFields(r),
          if (err != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(err, style: const TextStyle(color: Colors.red, fontSize: 12.5))),
        ]),
      ),
    );
  }

  /// v85: آبخندان چندلاتی ⇒ جمع وزن و میانگین موزون انس و گرم ارسالی لات‌های انتخاب‌شده.
  Widget _abAvgCard() {
    final List<Map<String, num?>> rows = <Map<String, num?>>[
      for (final _LotRow r in _rows)
        if (r.lot != null) <String, num?>{'kg': wsParseNum(r.kg.text), 'ounce': _info[r.lot]?.ounce, 'gram': _info[r.lot]?.gram},
    ];
    final double kg = rows.fold<double>(0, (double s, Map<String, num?> r) => s + (r['kg'] ?? 0).toDouble());
    final double? o = wsWeightedAvg(rows, 'ounce'), g = wsWeightedAvg(rows, 'gram');
    final ThemeData th = Theme.of(context);
    return Card(
      color: th.colorScheme.primaryContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(spacing: 22, runSpacing: 6, children: <Widget>[
          Text('وزن ارسالی کل: ${_kg(kg)} کیلو', style: const TextStyle(fontWeight: FontWeight.bold)),
          Text('میانگین انس ارسالی: ${o == null ? '—' : faNum(o, dec: 2)}'),
          Text('میانگین گرم ارسالی: ${g == null ? '—' : _f2(g)}'),
          if (rows.length > 1) Text('(${faNum(rows.length, dec: 0)} لات؛ میانگین به نسبت وزن)', style: TextStyle(fontSize: 12, color: th.hintColor)),
        ]),
      ),
    );
  }

  /// کادر کناری «شکست»: برآورد خط شکست (+ v81: برآورد وزن پرتی).
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
    final String types = _types;
    final WsCrackLine? l = _lineObj;
    final double? lossKg = l == null || e.inKg <= 0 ? null : l.lossGram / 100 * e.inKg;
    return Card(
      color: th.colorScheme.primaryContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
          Text('برآورد خط شکست', style: th.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
          if (l != null) Text('${l.name} — گرم پرتی ${faNum(l.lossGram, dec: 2)}', style: TextStyle(fontSize: 12, color: th.hintColor)),
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
          row('برآورد وزن پرتی (مغز)', lossKg == null ? '—' : '${_kg(lossKg)} کیلو'),
          const Divider(height: 1),
          row('برآورد درصد پرت', e.lossPct == null ? '—' : '${_f2(e.lossPct!)}٪'),
          if (l == null) Padding(padding: const EdgeInsets.only(top: 6), child: Text('برای برآورد، خط شکست را انتخاب کنید.', style: TextStyle(fontSize: 12, color: th.hintColor))),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const SizedBox gap = SizedBox(height: 10);
    final String? op = _op;
    return Scaffold(
      appBar: AppBar(title: Text(op == null ? 'شروع عملیات کارگاه' : 'شروع عملیات کارگاه — ${kWsOpLabels[op]}')),
      body: LayoutBuilder(builder: (BuildContext context, BoxConstraints c) {
        final bool wide = c.maxWidth >= 900;
        final bool rowHead = c.maxWidth >= 560;
        final Widget date = JalaliDateField(label: 'تاریخ شروع', value: _date, onChanged: (DateTime d) => setState(() => _date = d));
        // سطر اول: نوع عملیات + تاریخ + (خط شکست | نوع تولید | لات آبخندان)
        final Widget? third = op == 'crack'
            ? _lineField()
            : op == 'production'
                ? _kindField()
                : null; // v85: آبخندان چندلاتی ⇒ لات‌ها در کارت‌های پایین
        final List<Widget> headCells = <Widget>[_opField(), date, if (third != null) third];
        final Widget head = rowHead
            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                for (int i = 0; i < headCells.length; i++) ...<Widget>[if (i > 0) const SizedBox(width: 8), Expanded(child: headCells[i])],
              ])
            : Column(children: <Widget>[for (int i = 0; i < headCells.length; i++) ...<Widget>[if (i > 0) gap, headCells[i]]]);
        final List<Widget> form = <Widget>[head];
        if (op == null) {
          form.add(const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('نوع عملیات را انتخاب کنید: شکست، تولید یا آبخندان'))));
        } else {
          if (_loaded && _lotChoices.isEmpty) {
            form.add(Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(op == 'abkhandan' ? 'لات دهنبستی در انبار نیست.' : 'لات موجودی در انبار نیست.', style: const TextStyle(color: Colors.red))));
          }
          if (op == 'crack' || op == 'abkhandan') {
            form.addAll(<Widget>[
              const SizedBox(height: 14),
              Text(op == 'abkhandan' ? 'لات‌های دهنبست (یک یا چند لات؛ همین حالا از موجودی کم می‌شود)' : 'ورودی از انبار (همین حالا از موجودی کم می‌شود)',
                  style: Theme.of(context).textTheme.titleMedium),
              for (int i = 0; i < _rows.length; i++) _lotCard(i),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(onPressed: () => setState(() => _rows.add(_LotRow())), icon: const Icon(Icons.add), label: Text(op == 'abkhandan' ? 'لات دهنبست دیگر' : 'لات دیگر')),
              ),
              if (op == 'abkhandan') _abAvgCard(),
            ]);
          } else if (op == 'production') {
            form.addAll(<Widget>[
              gap,
              _lotDropdown(_rows.first, 'لات (فقط یک لات)'),
              if (_info[_rows.first.lot] != null) _lotInfoBox(_info[_rows.first.lot]!),
              _qtyFields(_rows.first),
            ]);
          } else {
            form.addAll(<Widget>[
              if (_info[_rows.first.lot] != null) _lotInfoBox(_info[_rows.first.lot]!),
              _qtyFields(_rows.first),
            ]);
          }
          if (op == 'production' && _rowError(0) != null) form.add(Text(_rowError(0)!, style: const TextStyle(color: Colors.red, fontSize: 12.5)));
          form.addAll(<Widget>[
            gap,
            TextField(controller: _note, decoration: const InputDecoration(labelText: 'یادداشت (اختیاری)', border: OutlineInputBorder())),
            if (op == 'crack' && !wide) ...<Widget>[const SizedBox(height: 12), _estimateCard()],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: (_saving || _overStock || (op == 'crack' && _lineObj == null)) ? null : _submit,
              icon: const Icon(Icons.play_arrow),
              label: Text(_saving ? 'در حال ثبت…' : 'شروع عملیات'),
            ),
          ]);
        }
        if (!wide || op != 'crack') return ListView(padding: const EdgeInsets.all(14), children: form);
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
        actions: <Widget>[
          IconButton(
            tooltip: 'گزارش خطوط شکست',
            icon: const Icon(Icons.query_stats),
            onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const CrackLineReportScreen())),
          ),
          IconButton(
            tooltip: 'چاپ فهرست',
            icon: const Icon(Icons.print_outlined),
            onPressed: visible.isEmpty ? null : () => wsPrintOpsList(context, visible, titleOf: wsOpTitle, subtitle: _onlyOpen ? 'فقط عملیات باز' : 'همهٔ عملیات'),
          ),
          IconButton(tooltip: 'به‌روزرسانی', icon: const Icon(Icons.refresh), onPressed: _load),
        ],
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
                    title: Text('${wsOpTitle(p)}  •  در صف ارسال'),
                    subtitle: Text(jalaliDate('${p['start_date'] ?? ''}')),
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

/// عنوان یک عملیات: نوع (+ نوع تولید / خط شکست).
String wsOpTitle(Map<String, dynamic> o) {
  final String op = '${o['op_type'] ?? ''}';
  final String base = kWsOpLabels[op] ?? (op.isEmpty ? 'کارگاه' : op);
  final String chain = ReturnsHelp.d(o['parent_id']) > 0 || o['parent'] is Map ? ' (فرایند شکست)' : ''; // v85
  if (op == 'production' && '${o['prod_kind'] ?? ''}'.isNotEmpty) return '$base — ${o['prod_kind']}$chain';
  if (op == 'production') return '$base$chain';
  if (op == 'crack' && '${o['crack_line_name'] ?? ''}'.isNotEmpty) return '$base — ${o['crack_line_name']}';
  return base;
}

/// کاشی یک عملیات داخلی (فهرست کارگاه و صفحهٔ فراوری).
Widget wsOpTile(BuildContext context, Map<String, dynamic> o, VoidCallback onTap) {
  final bool open = o['status'] == kWsOpen;
  final bool? ok = o['balance_ok'] is bool ? o['balance_ok'] as bool : null;
  final String state = open ? 'در کارگاه (باز)' : (ok == false ? 'نیاز به بررسی' : 'بسته');
  return Card(
    child: ListTile(
      leading: Icon(open ? Icons.pending_actions : (ok == false ? Icons.warning_amber_rounded : Icons.factory_outlined), color: open ? Colors.blue : (ok == false ? Colors.orange : null)),
      title: Text('${wsOpTitle(o)}${'${o['owner'] ?? ''}'.isEmpty ? '' : '  •  ${o['owner']}'}  •  $state'),
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
  List<WsCat> _cats = <WsCat>[];

  String? get _uid => (_d['uid'] as String?) ?? widget.orderUid;
  int? get _id => _d['id'] == null ? widget.id : ReturnsHelp.d(_d['id']).toInt();
  bool get _open => _d['status'] == kWsOpen;
  String get _op => '${_d['op_type'] ?? ''}';
  bool get _isCrack => _op == 'crack';
  bool get _single => kWsSingleLotTypes.contains(_op);
  bool get _split => kWsSplitCostTypes.contains(_op); // v85: تولید و آبخندان (کادر بها و ضایعات)

  /// v85: میانگین موزون انس/گرم ارسالی ورودی‌ها (آبخندان چندلاتی).
  double? _avgIn(String key) => wsWeightedAvg(<Map<String, num?>>[
        for (final Map<String, dynamic> r in _ins) <String, num?>{'kg': ReturnsHelp.d(r['kg']), key: _optD(r[key])},
      ], key);

  /// شناسهٔ سفارش برای اکشن‌ها (هم id و هم order_uid اگر معلوم است).
  Map<String, dynamic> get _ref => <String, dynamic>{
        if (_id != null && _id! > 0) 'id': _id,
        if (_uid != null) 'order_uid': _uid,
      };

  @override
  void initState() {
    super.initState();
    _load();
    _loadCats();
  }

  Future<void> _loadCats() async {
    try {
      final List<WsCat> c = await WsCats.load();
      if (mounted) setState(() => _cats = c);
    } on StockApiException catch (_) {
      // آفلاین برای اپراتور ⇒ نام دسته‌ها از خود ردیف‌ها (kind_name) نمایش داده می‌شود
    }
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
  List<Map<String, dynamic>> get _outs => ReturnsHelp.maps(_d['outputs']);

  /// عملیات «شکست»: خط شکست و برآوردها (از گرم ارسالی ذخیره‌شده روی سفارش؛ فقط نمایش).
  List<Widget> _crackInfo(double inKg) {
    if ('${_d['crack_line_name'] ?? ''}'.isEmpty) return const <Widget>[];
    final double? g = _optD(_d['input_gram']);
    final double line = ReturnsHelp.d(_d['crack_loss_gram']);
    final WsCrackEstimate e = wsCrackEstimate(<Map<String, num?>>[<String, num?>{'kg': inKg, 'gram': g}], line);
    return <Widget>[
      Text('خط شکست: ${_d['crack_line_name']} (گرم پرتی ${faNum(line, dec: 2)})'),
      if (e.sentGram != null) Text('گرم ارسالی: ${_f2(e.sentGram!)}  •  برآورد گرم دریافتی: ${_f2(e.recvGram!)}'),
      if (e.kernelKg != null) Text('برآورد مغز سالم دریافتی: ${_kg(e.kernelKg)} کیلو${e.lossPct == null ? '' : '  •  برآورد درصد پرت: ${_f2(e.lossPct!)}٪'}'),
      if (inKg > 0) Text('برآورد وزن پرتی (مغز): ${_kg(line / 100 * inKg)} کیلو'),
    ];
  }

  /// خلاصهٔ اطلاعات خروجی برای برگهٔ چاپی (شکست: گرم‌ها و پرتی؛ تولید/آبخندان: نوع تولید).
  List<List<String>> _printExtra() {
    final List<List<String>> x = <List<String>>[];
    if (_op == 'production' && '${_d['prod_kind'] ?? ''}'.isNotEmpty) x.add(<String>['نوع تولید', '${_d['prod_kind']}']);
    if (_isCrack && _outs.isNotEmpty) {
      final WsBalance t = wsFlowTotals(_d);
      final WsCrackResult r = wsCrackResult(
        inKg: t.inputKg,
        gram: _optD(_d['input_gram']),
        kernelKg: _sumGrade('kernel'),
        lineLoss: _optD(_d['crack_loss_gram']),
        uncrackedKg: _sumGrade('uncracked'),
        outKg: _outKg,
      );
      if (r.recvGram != null) x.add(<String>['گرم دریافتی', _f2(r.recvGram!)]);
      if (r.lossGram != null) x.add(<String>['افت گرم واقعی', _f2(r.lossGram!), 'b']);
      if (r.gramVsLine != null) x.add(<String>['اختلاف با گرم پرتی خط', '${r.gramVsLine! > 0 ? '+' : ''}${_f2(r.gramVsLine!)}']);
      if (r.lossKg != null) x.add(<String>['وزن پرتی (مغز)', '${_kg(r.lossKg)} کیلو']);
    }
    return x;
  }

  double _sumGrade(String g) {
    double s = 0;
    for (final Map<String, dynamic> r in _outs) {
      if (r['grade'] == g) s += ReturnsHelp.d(r['kg']);
    }
    return s;
  }

  double get _outKg => _outs.fold<double>(0, (double s, Map<String, dynamic> r) => s + ReturnsHelp.d(r['kg']));

  Widget _kvRow(String k, String v, {bool strong = false, Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: <Widget>[
          Expanded(child: Text(k)),
          Flexible(child: Text(v, textAlign: TextAlign.end, style: TextStyle(fontWeight: strong ? FontWeight.bold : null, color: color))),
        ]),
      );

  /// تراز وزنی: وزن ارسالی، دریافتی کل، ضایعات و سهم هر لات ورودی از ضایعات (به نسبت وزن).
  List<Widget> _weightBalance(double inKg, String sentLabel) {
    final double out = _outKg;
    final double waste = ((inKg - out) * 1000).round() / 1000;
    final List<Map<String, dynamic>> ins = _ins;
    return <Widget>[
      Text('تراز وزنی', style: Theme.of(context).textTheme.titleSmall),
      _kvRow(sentLabel, '${_kg(inKg)} کیلو'),
      _kvRow('وزن دریافتی کل (Σ خروجی‌ها)', '${_kg(out)} کیلو'),
      _kvRow(waste >= 0 ? 'ضایعات (اختلاف وزن)' : 'اضافه وزن', '${_kg(waste.abs())} کیلو${inKg > 0 ? ' (${_f2(waste.abs() * 100 / inKg)}٪)' : ''}',
          strong: true, color: waste > 0 ? Colors.red : (waste < 0 ? Colors.green : null)),
      if (waste != 0 && ins.length > 1 && inKg > 0)
        for (final Map<String, dynamic> r in ins)
          _kvRow('  سهم لات ${r['code'] ?? ''} (${_kg(r['kg'])} کیلو)', '${_kg(waste * ReturnsHelp.d(r['kg']) / inKg)} کیلو'),
    ];
  }

  /// v80/v81: کادر «اطلاعات خروجی شکست»: گرم اولیه/دریافتی، افت گرم و مقایسه با خط، وزن پرتی، تراز وزنی و ضایعات، بهای هر کیلو مغز.
  Widget? _crackOutCard(WsBalance t) {
    if (!_isCrack || _outs.isEmpty) return null;
    final double kernel = _sumGrade('kernel');
    final double uncr = _sumGrade('uncracked');
    double hullVal = 0;
    for (final Map<String, dynamic> r in _outs) {
      final dynamic hp = r['out_price'] ?? r['price_per_kg']; // صف آفلاین: price_per_kg
      if (r['grade'] == 'hull' && hp != null) hullVal += ReturnsHelp.d(r['kg']) * ReturnsHelp.d(hp);
    }
    final bool cost = wsCanCost();
    final double? buy = _optD(_d['buy_per_kg']);
    final double crackCost = ReturnsHelp.d(_d['crack_cost_per_kg']);
    final double? line = _optD(_d['crack_loss_gram']);
    final WsCrackResult r = wsCrackResult(
      inKg: t.inputKg,
      gram: _optD(_d['input_gram']),
      kernelKg: kernel,
      buyPerKg: buy,
      crackCost: crackCost,
      lineLoss: line,
      uncrackedKg: uncr,
      hullValue: hullVal,
      outKg: _outKg,
    );
    // بسته ⇒ مقدار ذخیره‌شدهٔ سرور (همان که روی لات مغز نشسته)
    final double? unit = (_d['status'] == 'done' && _d['kernel_cost_per_kg'] != null) ? ReturnsHelp.d(_d['kernel_cost_per_kg']) : r.unitCost;
    final String none = r.initGram == null ? '— (گرم لات‌ها ثبت نشده)' : '—';
    String? cmp;
    Color? cmpColor;
    if (r.gramVsLine != null) {
      final double d = r.gramVsLine!;
      if (d.abs() < 0.005) {
        cmp = 'افت گرم واقعی برابر گرم پرتی اعلامی خط است';
      } else {
        cmp = 'افت گرم واقعی ${_f2(d.abs())} گرم ${d > 0 ? 'بیشتر' : 'کمتر'} از گرم پرتی اعلامی خط (${_f2(line!)}) است';
        cmpColor = d > 0 ? Colors.red : Colors.green;
      }
    }
    return Card(
      color: Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
          Text('اطلاعات خروجی شکست', style: Theme.of(context).textTheme.titleMedium),
          const Divider(),
          ..._weightBalance(t.inputKg, 'وزن ارسالی به خط'),
          _kvRow('مغز / پوست / نشکن', '${_kg(kernel)} / ${_kg(_sumGrade('hull'))} / ${_kg(uncr)} کیلو'),
          const Divider(),
          if (kernel > 0) ...<Widget>[
            if (r.expectedKernelKg != null) _kvRow('مغز مورد انتظار (طبق گرم پرتی خط)', '${_kg(r.expectedKernelKg)} کیلو'),
            _kvRow('گرم اولیه', r.initGram == null ? none : _f2(r.initGram!)),
            _kvRow('گرم دریافتی${uncr > 0 ? ' (روی ${_kg(r.crackedKg)} کیلو شکسته‌شده)' : ''}', r.recvGram == null ? '—' : _f2(r.recvGram!)),
            _kvRow('افت گرم', r.lossGram == null ? none : _f2(r.lossGram!), color: (r.lossGram ?? 0) > 0 ? Colors.red : null),
            _kvRow('گرم پرتی اعلامی خط', line == null ? '—' : _f2(line)),
            if (cmp != null) Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(cmp, style: TextStyle(color: cmpColor, fontWeight: FontWeight.bold))),
            _kvRow('وزن پرتی (مغز)', r.lossKg == null ? none : '${_kg(r.lossKg)} کیلو'),
            _kvRow('برآورد وزن پرتی (طبق خط)', r.expectedLossKg == null ? '—' : '${_kg(r.expectedLossKg)} کیلو'),
            _kvRow('درصد پرتی', r.lossPct == null ? none : '${_f2(r.lossPct!)}٪'),
          ] else
            const Text('بعد از ثبت مغز، گرم دریافتی و پرتی نمایش داده می‌شود.'),
          if (cost) ...<Widget>[
            const Divider(),
            _kvRow('میانگین قیمت هر کیلو پستهٔ ورودی (P)', buy == null ? '—' : Fmt.money(buy, label: false)),
            if (uncr > 0) _kvRow('بهای هر کیلو نشکن (= P)', buy == null ? '—' : Fmt.money(buy, label: false)),
            if (hullVal > 0) _kvRow('ارزش پوست (کسر از بهای مغز)', Fmt.money(hullVal, label: false)),
            Row(children: <Widget>[
              Expanded(child: Text('هزینهٔ شکست هر کیلو مغز: ${Fmt.money(crackCost, label: false)}')),
              if (_open) TextButton.icon(onPressed: _busy ? null : _editCosts, icon: const Icon(Icons.edit, size: 18), label: const Text('ثبت هزینه')),
            ]),
            _kvRow('بهای تمام‌شدهٔ هر کیلو مغز', unit == null ? '—' : Fmt.money(unit, label: false), strong: true),
            Text('ارزش ضایعات و پرتی (وزن گم‌شده) روی بهای مغز می‌نشیند؛ نشکن با همان قیمت ورودی برمی‌گردد.',
                style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
            if ('${_d['input_cost_warning'] ?? ''}' == 'missing_input_cost') const Text(kWsMissingInputCost, style: TextStyle(color: Colors.orange)),
          ],
        ]),
      ),
    );
  }

  /// v81: کادر «اطلاعات خروجی» تولید و آبخندان: تراز وزنی + بهای هر کیلو (ارزش ورودی + اجرت + سایر هزینه ÷ وزن خروجی).
  Widget? _splitCard(WsBalance t) {
    if (!_split || _outs.isEmpty) return null;
    final bool cost = wsCanCost();
    final double? buy = _optD(_d['buy_per_kg']);
    final double wage = ReturnsHelp.d(_d['wage_per_kg']);
    final double other = ReturnsHelp.d(_d['other_cost']);
    final double w = buy == null ? 0 : ((t.inputKg * buy) * 100).round() / 100;
    final double z = ((t.inputKg * wage + other) * 100).round() / 100;
    final bool ab = _op == 'abkhandan';
    final List<Map<String, dynamic>> outs = _outs;
    final WsSplit sp = wsSplitCost(<Map<String, num?>>[
      for (final Map<String, dynamic> r in outs)
        <String, num?>{'kg': ReturnsHelp.d(r['kg']), 'price': (ab || r['grade'] == 'sound' || (r['out_price'] ?? r['price_per_kg']) == null) ? null : ReturnsHelp.d(r['out_price'] ?? r['price_per_kg'])},
    ], w + z);
    final bool done = _d['status'] == 'done';
    final double? unit = done && _d['cost_per_kg_sound'] != null ? ReturnsHelp.d(_d['cost_per_kg_sound']) : sp.unit;
    return Card(
      color: Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
          Text(ab ? 'اطلاعات خروجی آبخندان' : 'اطلاعات خروجی تولید', style: Theme.of(context).textTheme.titleMedium),
          const Divider(),
          if (ab) ...<Widget>[
            // v85: وزن ارسالی/دریافتی، کم‌بود یا وزن اضافه‌شده، درصد رطوبت با علامت، میانگین انس و گرم ارسالی
            ...wsMoistureRows(context, sentKg: t.inputKg, recvKg: _outKg, avgOunce: _avgIn('ounce'), avgGram: _avgIn('gram'), buyPerKg: cost ? buy : null),
            const Text('افت یا بالا رفتن وزن روی همهٔ پستهٔ خروجی پخش می‌شود (فی کم‌بود روی بار اعمال می‌شود).'),
          ] else
            ..._weightBalance(t.inputKg, 'وزن ورودی'),
          if (cost) ...<Widget>[
            const Divider(),
            _kvRow(kWsBuyLabel, buy == null ? '—' : Fmt.money(buy, label: false)),
            _kvRow('ارزش ورودی', Fmt.money(w, label: false)),
            Row(children: <Widget>[
              Expanded(child: Text('${ab ? 'اجرت آبخندان' : 'اجرت تولید'} هر کیلو: ${Fmt.money(wage, label: false)}  •  سایر هزینه‌ها: ${Fmt.money(other, label: false)}')),
              if (_open) TextButton.icon(onPressed: _busy ? null : _editCosts, icon: const Icon(Icons.edit, size: 18), label: const Text('ثبت هزینه')),
            ]),
            _kvRow('بهای کل (ورودی + اجرت + سایر)', Fmt.money(w + z, label: false)),
            if (sp.priced > 0) _kvRow('ارزش محصولات فرعی (با قیمت فروش)', Fmt.money(sp.priced, label: false)),
            _kvRow(ab ? 'بهای تمام‌شدهٔ هر کیلو' : 'بهای تمام‌شدهٔ هر کیلو خروجی اصلی', unit == null ? '—' : Fmt.money(unit, label: false), strong: true),
            if (!ab)
              for (int i = 0; i < outs.length; i++)
                _kvRow('  ${_outTitle(outs[i])} (${_kg(outs[i]['kg'])} کیلو)',
                    ReturnsHelp.d(outs[i]['kg']) > 0 ? '${Fmt.money(sp.lots[i] / ReturnsHelp.d(outs[i]['kg']), label: false)} هر کیلو' : '—'),
            Text(ab ? 'بها = (ارزش ورودی + اجرت × وزن ورودی + سایر هزینه) ÷ وزن کل خروجی.' : 'ضایعات بها ندارد ⇒ ارزشش روی خروجی‌ها پخش می‌شود. خروجی با «قیمت فروش» (محصول فرعی) با همان قیمت حساب می‌شود.',
                style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
            if ('${_d['input_cost_warning'] ?? ''}' == 'missing_input_cost') const Text(kWsMissingInputCost, style: TextStyle(color: Colors.orange)),
            if (sp.residual < 0) const Text('هشدار: ارزش محصولات فرعی از بهای کل بیشتر است.', style: TextStyle(color: Colors.red)),
          ],
        ]),
      ),
    );
  }

  /// ثبت هزینه‌ها در عملیات باز: شکست ⇒ هزینهٔ شکست هر کیلو مغز؛ تولید/آبخندان ⇒ اجرت هر کیلو + سایر هزینه‌ها.
  Future<void> _editCosts() async {
    final List<List<String>> fields = _isCrack
        ? <List<String>>[<String>['crack_cost_per_kg', 'هزینهٔ شکست هر کیلو مغز']]
        : <List<String>>[
            <String>['wage_per_kg', _op == 'abkhandan' ? 'اجرت آبخندان هر کیلو (روی وزن ورودی)' : 'اجرت تولید هر کیلو (روی وزن ورودی)'],
            <String>['other_cost', 'سایر هزینه‌ها (مبلغ کل)'],
          ];
    final Map<String, TextEditingController> cs = <String, TextEditingController>{
      for (final List<String> f in fields) f[0]: TextEditingController(text: _d[f[0]] == null ? '' : '${_d[f[0]]}'),
    };
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('ثبت هزینه'),
        content: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          for (final List<String> f in fields)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                controller: cs[f[0]],
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: <ThousandsInputFormatter>[ThousandsInputFormatter()],
                decoration: InputDecoration(labelText: f[1], border: const OutlineInputBorder()),
              ),
            ),
        ]),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ذخیره')),
        ],
      ),
    );
    final Map<String, dynamic> p = <String, dynamic>{};
    for (final MapEntry<String, TextEditingController> e in cs.entries) {
      final String txt = e.value.text.trim();
      p[e.key] = txt.isEmpty ? null : wsParseNum(txt);
      e.value.dispose();
    }
    if (ok != true || !mounted) return;
    if (p.values.any((dynamic v) => v is num && v < 0)) return _snack(context, 'هزینه نمی‌تواند منفی باشد');
    await _send('crack_cost', p, 'ثبت هزینهٔ عملیات کارگاه', localError: wsFlowCheck(_d['status'] as String?, 'output_save'));
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
  String _outTitle(Map<String, dynamic> r) {
    final String kind = '${r['kind_name'] ?? ''}';
    final WsCat? c = WsCats.byId(_cats, r['category_id'] == null ? null : ReturnsHelp.d(r['category_id']).toInt());
    final String grade = r['grade'] == kWsCustomGrade ? '${r['type_name'] ?? 'سایر'}' : (kWsGradeLabels['${r['grade']}'] ?? '${r['grade']}');
    if (kind.isEmpty) return grade;
    if (_isCrack) return kind == grade ? grade : '$grade — $kind';
    return c == null ? kind : '${c.name} — $kind';
  }

  Future<void> _editOutput([Map<String, dynamic>? r]) async {
    if (_cats.isEmpty) await _loadCats();
    if (!mounted) return;
    final Map<String, dynamic>? res = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => WsOutputDialog(row: r, defaultOwner: '${_d['owner'] ?? ''}', op: _op, cats: _cats, inputType: _ins.isEmpty ? null : '${_ins.first['type_name'] ?? ''}'),
    );
    await _loadCats(); // دسته/نوع تازه در دیالوگ
    if (res == null) return;
    await _send(
      'output_save',
      <String, dynamic>{
        'uid': r?['uid'] ?? ReturnsHelp.newUid('wx'),
        if (r?['id'] != null) 'output_id': r!['id'],
        ...res,
      },
      'خروجی کارگاه: ${_outTitle(res)} ${faNum(ReturnsHelp.d(res['kg']), dec: 3)} کیلو',
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

  // ── v85: «تولید (سورت)» در همین فرایند شکست ──
  Widget? _chainCard() {
    if (_d.isEmpty) return null;
    final bool chained = ReturnsHelp.d(_d['parent_id']) > 0 || _d['parent'] is Map;
    if (!_isCrack && !chained) return null;
    if (chained) {
      final Map<String, dynamic>? par = _d['parent'] is Map ? Map<String, dynamic>.from(_d['parent'] as Map) : null;
      return procChainCard(context, _d,
          onOpen: (_) {},
          onOpenParent: () => Navigator.push(context,
              MaterialPageRoute<bool>(builder: (_) => WorkshopOpScreen(orderUid: par?['uid'] as String?, id: ReturnsHelp.d(par?['id'] ?? _d['parent_id']).toInt()))));
    }
    final bool canStart = _can('workshop.operate') || _can('processing.create');
    final bool canClose = _can('workshop.manage');
    String? hint;
    if (_open && _outs.isEmpty) hint = 'پس از ثبت خروجی‌های شکست، می‌توانید آن‌ها را در همین فرایند به تولید (سورت) بفرستید.';
    if (_open && _outs.isNotEmpty && !canClose) hint = 'برای ارسال به تولید، عملیات شکست باید بسته شود (مجوز مدیر کارگاه).';
    final bool can = canStart && _outs.isNotEmpty && (_d['status'] == 'done' || (_open && canClose));
    return procChainCard(context, _d,
        onSend: can && !_busy ? _sendToSort : null,
        hint: hint,
        onOpen: (Map<String, dynamic> c) async {
          await Navigator.push(context, MaterialPageRoute<bool>(builder: (_) => WorkshopOpScreen(orderUid: c['uid'] as String?, id: ReturnsHelp.d(c['id']).toInt())));
          await _load();
        });
  }

  /// خروجی‌های شکست ⇒ «تولید (سورت)» پیوسته (workshop.open با parent_id و لات‌های خروجی). شکستِ باز اول بسته می‌شود تا خروجی‌ها لات شوند.
  Future<void> _sendToSort() async {
    if (_open) {
      if (!await confirm(context, 'برای ارسال خروجی‌ها به تولید (سورت)، ابتدا عملیات شکست بسته می‌شود تا خروجی‌ها لات شوند. ادامه می‌دهید؟')) return;
      await _close();
      if (!mounted || _d['status'] != 'done') return;
    }
    if (_id == null || _id! <= 0 || _outs.any((Map<String, dynamic> r) => r['lot_id'] == null)) {
      return _snack(context, 'خروجی‌های شکست هنوز به سرور نرسیده‌اند؛ پس از اتصال و همگام‌سازی دوباره امتحان کنید');
    }
    final Map<String, dynamic>? r = await showDialog<Map<String, dynamic>>(context: context, builder: (_) => ChainSortDialog(outputs: _outs));
    if (r == null || !mounted) return;
    final String uid = ReturnsHelp.newUid('wo');
    setState(() => _busy = true);
    try {
      await StockApi.call('workshop.open', <String, dynamic>{
        'uid': uid,
        'op_type': 'production',
        'prod_kind': r['prod_kind'],
        'start_date': r['date'],
        'parent_id': _id,
        if (_uid != null) 'parent_uid': _uid,
        'note': 'فرایند ${wsOpTitle(_d)}',
        'items': r['items'],
      });
      _changed = true;
      if (!mounted) return;
      _snack(context, 'تولید (سورت) در همین فرایند شروع شد؛ خروجی‌های تولید را ثبت کنید');
      setState(() => _busy = false);
      await Navigator.push(context, MaterialPageRoute<bool>(builder: (_) => WorkshopOpScreen(orderUid: uid)));
      await _load();
    } on StockApiException catch (e) {
      if (mounted) _snack(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── بستن / بازکردن ──
  Future<void> _close() async {
    final WsBalance t = wsFlowTotals(_d);
    final String? rule = wsFlowCheck(_d['status'] as String?, 'close', inputs: _ins.length, outputs: _outs.length, lossG: wsGrams(t.lossKg), allowOver: _op == 'abkhandan');
    if (rule != null) return _snack(context, kWsFlowErrors[rule]!);
    final Map<String, dynamic>? res = await showDialog<Map<String, dynamic>>(context: context, builder: (_) => _CloseDialog(detail: _d, totals: t, titleOf: _outTitle));
    if (res == null) return;
    await _send('close', res, 'بستن عملیات کارگاه');
  }

  /// v83: حذف کامل عملیات (ورودی‌ها به موجودی برمی‌گردند، لات‌های خروجی حذف می‌شوند). فقط اگر خروجی‌ها فروخته/مصرف نشده‌اند.
  Future<void> _delete() async {
    final String? block = _d['status'] == 'done' ? _d['reopen_block'] as String? : null;
    if (block != null) return _snack(context, block);
    if (!await confirm(context, 'این عملیات کامل حذف شود؟ ورودی‌ها به موجودی لات‌ها برمی‌گردند${_d['status'] == 'done' ? ' و لات‌های خروجی حذف می‌شوند' : ''}. قابل برگشت نیست.')) return;
    if (!mounted) return;
    if (_id == null || _id! <= 0) return _snack(context, 'این عملیات هنوز به سرور نرسیده؛ پس از همگام‌سازی حذف کنید');
    setState(() => _busy = true);
    try {
      await StockApi.call('workshop.delete', <String, dynamic>{'id': _id});
      if (!mounted) return;
      _snack(context, 'عملیات حذف شد');
      Navigator.pop(context, true);
    } on StockApiException catch (e) {
      if (mounted) _snack(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// v83: ویرایش سربرگ عملیات باز: تاریخ شروع، خط شکست / نوع تولید، یادداشت.
  Future<void> _editHeader() async {
    DateTime date = DateTime.tryParse('${_d['started_at'] ?? _d['date'] ?? ''}') ?? DateTime.now();
    final TextEditingController note = TextEditingController(text: '${_d['note'] ?? ''}');
    final TextEditingController kind = TextEditingController(text: '${_d['prod_kind'] ?? ''}');
    String? line = _d['crack_line_uid'] as String?;
    List<WsCrackLine> lines = <WsCrackLine>[];
    if (_isCrack) {
      try {
        lines = (await WsLotPicker.loadCrack()).lines;
      } on StockApiException catch (_) {}
    }
    if (!mounted) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => StatefulBuilder(
        builder: (BuildContext c, StateSetter set) => AlertDialog(
          title: const Text('ویرایش سربرگ عملیات'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
              JalaliDateField(label: 'تاریخ شروع', value: date, onChanged: (DateTime d) => set(() => date = d)),
              if (_isCrack) ...<Widget>[
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: lines.any((WsCrackLine l) => l.uid == line) ? line : null,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'خط شکست', border: OutlineInputBorder()),
                  items: <DropdownMenuItem<String>>[
                    for (final WsCrackLine l in lines) DropdownMenuItem<String>(value: l.uid, child: Text('${l.name} (پرتی ${faNum(l.lossGram, dec: 2)})')),
                  ],
                  onChanged: (String? v) => set(() => line = v),
                ),
              ],
              if (_op == 'production') ...<Widget>[
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: <String>{...kWsProdKinds, if (kind.text.isNotEmpty) kind.text}.contains(kind.text) && kind.text.isNotEmpty ? kind.text : null,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'نوع تولید', border: OutlineInputBorder()),
                  items: <DropdownMenuItem<String>>[
                    for (final String k in <String>{...kWsProdKinds, if (kind.text.isNotEmpty) kind.text}) DropdownMenuItem<String>(value: k, child: Text(k)),
                  ],
                  onChanged: (String? v) => kind.text = v ?? kind.text,
                ),
              ],
              const SizedBox(height: 8),
              TextField(controller: note, decoration: const InputDecoration(labelText: 'یادداشت', border: OutlineInputBorder())),
            ]),
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('انصراف')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('ذخیره')),
          ],
        ),
      ),
    );
    final String n = note.text.trim(), k = kind.text.trim();
    note.dispose();
    kind.dispose();
    if (ok != true || !mounted) return;
    if (_op == 'production' && k.isEmpty) return _snack(context, 'نوع تولید را وارد کنید');
    WsCrackLine? lo;
    for (final WsCrackLine l in lines) {
      if (l.uid == line) lo = l;
    }
    await _send(
      'header_save',
      <String, dynamic>{
        'start_date': ReturnsHelp.iso(date),
        'note': n,
        if (_op == 'production') 'prod_kind': k,
        if (_isCrack && lo != null) ...<String, dynamic>{'crack_line_uid': lo.uid, 'crack_line_name': lo.name, 'crack_loss_gram': lo.lossGram},
      },
      'ویرایش سربرگ عملیات کارگاه',
      localError: wsFlowCheck(_d['status'] as String?, 'output_save'),
    );
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
    final Widget? outCard = _crackOutCard(t) ?? _splitCard(t);
    return Scaffold(
        appBar: AppBar(
          title: Text('${_d.isEmpty ? 'عملیات کارگاه' : wsOpTitle(_d)}${_open ? ' — در کارگاه' : (_d['status'] == 'done' ? ' — بسته' : '')}'),
          leading: BackButton(onPressed: () => Navigator.pop(context, _changed)),
          actions: <Widget>[
            if (_open && (_can('workshop.operate') || _can('workshop.manage')) && _d.isNotEmpty)
              IconButton(tooltip: 'ویرایش سربرگ (تاریخ، خط/نوع، یادداشت)', icon: const Icon(Icons.edit_note), onPressed: _busy ? null : _editHeader),
            if (_can('workshop.manage') && _d.isNotEmpty)
              IconButton(tooltip: 'حذف عملیات', icon: const Icon(Icons.delete_outline), onPressed: _busy ? null : _delete),
            IconButton(
              tooltip: 'چاپ برگهٔ عملیات',
              icon: const Icon(Icons.print_outlined),
              onPressed: _d.isEmpty ? null : () => wsPrintOp(context, _d, title: wsOpTitle(_d), titleOf: _outTitle, extra: _printExtra()),
            ),
            IconButton(tooltip: 'به‌روزرسانی', icon: const Icon(Icons.refresh), onPressed: _load),
          ],
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
                          if (_op == 'production' && '${_d['prod_kind'] ?? ''}'.isNotEmpty) Text('نوع تولید: ${_d['prod_kind']}'),
                          if ('${_d['owner'] ?? ''}'.isNotEmpty) Text('مالک: ${_d['owner']}'),
                          if ('${_d['pistachio_type'] ?? ''}'.isNotEmpty) Text('نوع پسته: ${_d['pistachio_type']}'),
                          if ('${_d['defect_note'] ?? ''}'.isNotEmpty) Text('ایراد بار: ${_d['defect_note']}'),
                          if (_d['initial_kg'] != null) Text('وزن خالص اولیه: ${_kg(_d['initial_kg'])} کیلو'),
                          if (_d['bale_count'] != null) Text('تعداد عدل: ${faNum(ReturnsHelp.d(_d['bale_count']), dec: 0)}'),
                          ..._crackInfo(t.inputKg),
                          if (_op == 'abkhandan' && _ins.isNotEmpty)
                            Text('میانگین انس ارسالی: ${_avgIn('ounce') == null ? '—' : faNum(_avgIn('ounce')!, dec: 2)}  •  میانگین گرم ارسالی: ${_avgIn('gram') == null ? '—' : _f2(_avgIn('gram')!)}'),
                        ]),
                      ),
                    ),
                    // نوار زنده (v81: در «شکست» حذف شد؛ تراز وزنی در کادر اطلاعات خروجی است)
                    if (!_isCrack)
                      Card(
                        color: tone.withValues(alpha: 0.12),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Wrap(spacing: 16, runSpacing: 4, children: <Widget>[
                            Text('ورودی ${_kg(t.inputKg)}'),
                            Text('Σ خروجی ${_kg(t.inputKg - t.lossKg)}'),
                            Text('${t.lossKg < 0 ? 'اضافه وزن' : (_split ? 'ضایعات' : 'افت')} ${_kg(t.lossKg.abs())}${t.lossPct == null ? '' : ' (${faNum(t.lossPct!.abs(), dec: 1)}٪)'}',
                                style: TextStyle(color: t.overOutput && _op != 'abkhandan' ? Colors.red : null, fontWeight: FontWeight.bold)),
                            if (!_split) Text('سالم ${t.soundPct == null ? '—' : '${faNum(t.soundPct!, dec: 1)}٪'}'),
                            if (t.overOutput && _op != 'abkhandan') const Text('جمع خروجی‌ها از ورودی بیشتر است', style: TextStyle(color: Colors.red)),
                          ]),
                        ),
                      ),
                    if (_isCrack && t.overOutput)
                      const Card(child: Padding(padding: EdgeInsets.all(10), child: Text('جمع خروجی‌ها از ورودی بیشتر است', style: TextStyle(color: Colors.red)))),
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
                    ], action: edit && !_single ? TextButton.icon(onPressed: _addInput, icon: const Icon(Icons.add), label: const Text('افزودن ورودی')) : null),
                    _section('خروجی‌ها (فقط هنگام بستن وارد موجودی می‌شوند)', <Widget>[
                      if (_outs.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('هنوز خروجی ثبت نشده')),
                      for (final Map<String, dynamic> r in _outs)
                        ListTile(
                          dense: true,
                          title: Text('${_outTitle(r)} — ${_kg(r['kg'])} کیلو'),
                          subtitle: Text(<String>[
                            if ('${r['lot_name'] ?? ''}'.isNotEmpty) 'نام لات ${r['lot_name']}',
                            if (r['gross_kg'] != null) 'ناخالص ${_kg(r['gross_kg'])}',
                            if (ReturnsHelp.d(r['small_sacks']) > 0 || ReturnsHelp.d(r['large_sacks']) > 0)
                              'عدل ${faNum(ReturnsHelp.d(r['small_sacks']), dec: 0)} کوچک / ${faNum(ReturnsHelp.d(r['large_sacks']), dec: 0)} بزرگ',
                            if (r['attrs'] is Map && (r['attrs'] as Map)['ounce'] != null) 'انس ${faNum(ReturnsHelp.d((r['attrs'] as Map)['ounce']), dec: 2)}',
                            if (r['attrs'] is Map && (r['attrs'] as Map)['gram'] != null) 'گرم ${faNum(ReturnsHelp.d((r['attrs'] as Map)['gram']), dec: 2)}',
                            if ('${r['lot_name'] ?? ''}'.isEmpty && '${r['owner'] ?? ''}'.isNotEmpty) 'مالک ${r['owner']}',
                            if ('${r['code'] ?? ''}'.isNotEmpty) 'لات ${r['code']}',
                            if (r['id'] == null) 'در صف ارسال',
                          ].join('  •  ')),
                          onTap: edit ? () => _editOutput(r) : null,
                          trailing: edit ? IconButton(tooltip: 'حذف', icon: const Icon(Icons.delete_outline), onPressed: () => _deleteOutput(r)) : null,
                        ),
                    ], action: edit ? TextButton.icon(onPressed: () => _editOutput(), icon: const Icon(Icons.add), label: const Text('ثبت خروجی')) : null),
                    if (outCard != null) outCard,
                    if (_chainCard() != null) _chainCard()!, // v85: تولید (سورت) در همین فرایند شکست
                    const SizedBox(height: 12),
                    if (_open && canManage)
                      FilledButton.icon(
                        onPressed: (_busy || (t.overOutput && _op != 'abkhandan')) ? null : _close,
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

/// انتخاب نوع از یک دسته + افزودن نوع تازه (در همهٔ فهرست‌ها).
class _TypePicker extends StatelessWidget {
  const _TypePicker({required this.cat, required this.value, required this.label, required this.onChanged, required this.onAdd});
  final WsCat? cat;
  final String? value;
  final String label;
  final ValueChanged<String?> onChanged;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final List<String> types = <String>{...?cat?.types}.toList(); // نام تکراری ⇒ دراپ‌داون خطا می‌دهد
    if (value != null && value!.isNotEmpty && !types.contains(value)) types.add(value!);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Expanded(
        child: DropdownButtonFormField<String>(
          key: ValueKey<String>('type-${cat?.id}-$value-${types.length}'),
          initialValue: types.contains(value) ? value : null,
          isExpanded: true,
          hint: Text(cat == null ? 'ابتدا دسته را انتخاب کنید' : 'انتخاب کنید'),
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
          items: <DropdownMenuItem<String>>[for (final String t in types) DropdownMenuItem<String>(value: t, child: Text(t, overflow: TextOverflow.ellipsis))],
          onChanged: onChanged,
        ),
      ),
      const SizedBox(width: 6),
      IconButton.filledTonal(onPressed: cat == null ? null : onAdd, icon: const Icon(Icons.add), tooltip: 'افزودن نوع تازه'),
    ]);
  }
}

/// فرم یک ردیف خروجی.
///   قدیمی: درجه، نام «سایر»، کیلو، گونی، مالک، انبار، قیمت.
///   v81 شکست: مغز/پوست/نشکن؛ مغز ⇒ «نوع مغز» (انواع دستهٔ مغز + افزودن)؛ «نام لات» به‌جای مالک.
///   v81 تولید: دستهٔ خروجی (همهٔ دسته‌ها + افزودن) و نوع خروجی (+ افزودن)، وزن ناخالص و عدل ⇒ وزن خالص، انبار، نام لات، قیمت فروش (محصول فرعی).
///   v81 آبخندان: دسته ثابت «خندان»؛ نوع، وزن ناخالص، عدل، انس، گرم، درصدهای اتاق انس، انبار، نام لات.
class WsOutputDialog extends StatefulWidget {
  const WsOutputDialog({super.key, this.row, required this.defaultOwner, required this.op, required this.cats, this.inputType, this.noPrice = false});
  final Map<String, dynamic>? row;
  /// v82: فراوری امانی ⇒ قیمت فروش نمایش داده نمی‌شود (کالا مال ما نیست).
  final bool noPrice;
  final String defaultOwner;
  final String op;
  final List<WsCat> cats;
  final String? inputType;

  @override
  State<WsOutputDialog> createState() => WsOutputDialogState();
}

class WsOutputDialogState extends State<WsOutputDialog> {
  bool get _crack => widget.op == 'crack';
  bool get _prod => widget.op == 'production';
  bool get _ab => widget.op == 'abkhandan';
  bool get _gross => _prod || _ab; // وزن ناخالص ⇒ خالص با تار عدل

  late List<WsCat> _cats = widget.cats;
  late String _grade = _crack
      ? (kWsCrackGrades.contains(widget.row?['grade']) ? '${widget.row!['grade']}' : 'kernel')
      : '${widget.row?['grade'] ?? 'sound'}';
  List<String> get _grades => _crack ? kWsCrackGrades : <String>[...kWsGrades, kWsCustomGrade];
  late int? _catId = widget.row?['category_id'] == null ? null : ReturnsHelp.d(widget.row!['category_id']).toInt();
  late String? _kind = (widget.row?['kind_name'] as String?) ?? (_ab && (widget.inputType ?? '').isNotEmpty ? widget.inputType : null);

  bool get _priced {
    if (widget.noPrice) return false;
    if (_crack) return _grade == 'hull';
    if (_ab) return false;
    if (_prod) return wsGradeFor(_cat?.preset, _kind) != 'sound';
    return _grade != 'sound';
  }

  WsCat? get _cat {
    if (_crack) return _grade == 'kernel' ? WsCats.byPreset(_cats, 'kernel') : null;
    if (_ab) return WsCats.byPreset(_cats, 'khandan');
    return WsCats.byId(_cats, _catId);
  }

  Map<String, dynamic> get _attrs => widget.row?['attrs'] is Map ? Map<String, dynamic>.from(widget.row!['attrs'] as Map) : <String, dynamic>{};
  String _t(dynamic v) => v == null ? '' : '$v';

  late final TextEditingController _name = TextEditingController(text: widget.row?['grade'] == kWsCustomGrade ? '${widget.row?['type_name'] ?? ''}' : '');
  late final TextEditingController _kg = TextEditingController(text: _gross ? _t(widget.row?['gross_kg'] ?? widget.row?['kg']) : (widget.row == null ? '' : '${widget.row!['kg']}'));
  late final TextEditingController _small = TextEditingController(text: '${widget.row?['small_sacks'] ?? 0}');
  late final TextEditingController _large = TextEditingController(text: '${widget.row?['large_sacks'] ?? 0}');
  late final TextEditingController _owner = TextEditingController(text: '${widget.row?['owner'] ?? widget.defaultOwner}');
  late final TextEditingController _lotName = TextEditingController(text: _t(widget.row?['lot_name']));
  late final TextEditingController _price = TextEditingController(text: widget.row?['out_price'] == null ? '' : '${widget.row!['out_price']}');
  late final TextEditingController _ounce = TextEditingController(text: _t(_attrs['ounce']));
  late final TextEditingController _gram = TextEditingController(text: _t(_attrs['gram']));
  final Map<String, TextEditingController> _pcts = <String, TextEditingController>{};
  List<Map<String, dynamic>> _defs = <Map<String, dynamic>>[];
  late String? _wh = widget.row?['warehouse_uid'] as String?;
  List<WhOption> _whs = <WhOption>[];
  List<double> _sack = <double>[0.1, 0.2];

  static const Map<String, String> _core = <String, String>{'tuchin': 'pct_tuchin', 'dombest': 'pct_dombest', 'crooked': 'pct_crooked', 'khandan': 'pct_khandan'};
  static const List<Map<String, dynamic>> _fallbackDefs = <Map<String, dynamic>>[
    <String, dynamic>{'key': 'tuchin', 'label': 'توچین'},
    <String, dynamic>{'key': 'dombest', 'label': 'دهن‌بست'},
    <String, dynamic>{'key': 'crooked', 'label': 'کج'},
    <String, dynamic>{'key': 'khandan', 'label': 'خندان'},
  ];

  @override
  void initState() {
    super.initState();
    StockLookup.warehouses().then((List<WhOption> w) {
      if (mounted) setState(() => _whs = w);
    }).catchError((Object _) {}); // بدون مجوز انبار ⇒ انبار پیش‌فرض عملیات
    if (_gross) {
      FormSettingsLocal.sackKg().then((List<double> k) {
        if (mounted) setState(() => _sack = k);
      }).catchError((Object _) {});
    }
    if (_ab) _loadDefs();
  }

  Future<void> _loadDefs() async {
    List<Map<String, dynamic>> defs = <Map<String, dynamic>>[];
    try {
      defs = (await EntityStore.I.list('pct_defs')).where((Map<String, dynamic> d) => d['active'] != false && d['active'] != 0).toList();
    } catch (_) {
      // بدون دسترسی اتاق انس ⇒ چهار درصد اصلی
    }
    if (defs.isEmpty) defs = _fallbackDefs;
    final Map<String, String> specs = <String, String>{
      for (final dynamic s in (_attrs['specs'] as List<dynamic>? ?? const <dynamic>[]))
        if (s is Map) '${s['label']}': '${s['value']}'.replaceAll('%', ''),
    };
    if (!mounted) return;
    setState(() {
      _defs = defs;
      for (final Map<String, dynamic> d in defs) {
        final String k = '${d['key']}';
        final String? col = _core[k];
        _pcts[k] = TextEditingController(text: col != null ? _t(_attrs[col]) : (specs['${d['label']}'] ?? ''));
      }
    });
  }

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[_name, _kg, _small, _large, _owner, _lotName, _price, _ounce, _gram, ..._pcts.values]) {
      c.dispose();
    }
    super.dispose();
  }

  double get _tare => wsParseNum(_small.text) * _sack[0] + wsParseNum(_large.text) * _sack[1];
  double get _net => _gross ? ((wsParseNum(_kg.text) - _tare) * 1000).round() / 1000 : wsParseNum(_kg.text);

  Widget _num(TextEditingController c, String l, {bool live = false}) => TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: l, border: const OutlineInputBorder()),
        onChanged: live ? (_) => setState(() {}) : null,
      );

  Future<void> _reloadCats() async {
    try {
      final List<WsCat> c = await WsCats.load();
      if (mounted) setState(() => _cats = c);
    } on StockApiException catch (e) {
      if (mounted) _snack(context, e.message);
    }
  }

  Future<void> _addCat() async {
    final String? n = await _askName(context, 'دستهٔ تازه (در همهٔ فهرست‌ها: خرید، اتاق انس، کارگاه)', label: 'نام دسته');
    if (n == null) return;
    try {
      final int id = await WsCats.addCategory(n);
      await _reloadCats();
      if (!mounted) return;
      setState(() {
        _catId = id;
        _kind = null;
      });
    } catch (e) {
      if (mounted) _snack(context, e is StockApiException ? e.message : '$e'.replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _addType() async {
    final WsCat? c = _cat;
    if (c == null) return;
    final String? n = await _askName(context, 'نوع تازه برای «${c.name}» (در همهٔ فهرست‌ها)', label: 'نام نوع');
    if (n == null) return;
    String norm(String x) => x.replaceAll('ي', 'ی').replaceAll('ك', 'ک').replaceAll('\u200C', '').replaceAll(' ', '');
    for (final String t in c.types) {
      if (norm(t) == norm(n)) {
        setState(() => _kind = t); // نوع از قبل هست ⇒ همان انتخاب می‌شود
        return;
      }
    }
    try {
      await WsCats.addType(c, n);
      await _reloadCats();
      if (mounted) setState(() => _kind = n);
    } catch (e) {
      if (mounted) _snack(context, e is StockApiException ? e.message : '$e'.replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _save() async {
    final double net = _net;
    if (net <= 0) return _snack(context, _gross ? 'وزن ناخالص باید از تار عدل‌ها بیشتر باشد' : 'وزن باید بیشتر از صفر باشد');
    if (!_crack && !_prod && !_ab && _grade == kWsCustomGrade && _name.text.trim().isEmpty) return _snack(context, 'نام خروجی جدید را وارد کنید');
    if (_crack && _grade == 'kernel' && (_kind == null || _kind!.isEmpty)) return _snack(context, 'نوع مغز را انتخاب کنید');
    if (_prod && _cat == null) return _snack(context, 'دستهٔ خروجی را انتخاب کنید');
    if (_prod && (_kind == null || _kind!.isEmpty)) return _snack(context, 'نوع خروجی را انتخاب کنید');
    if (_ab && _cat == null) return _snack(context, 'دستهٔ «خندان» تعریف نشده است');
    int? catServer;
    try {
      if (_cat != null && (_prod || _ab || (_crack && _grade == 'kernel'))) catServer = await WsCats.serverId(_cat!.id);
    } on StockApiException catch (e) {
      if (mounted) _snack(context, e.message);
      return;
    }
    if (!mounted) return;
    final String grade = _prod ? wsGradeFor(_cat?.preset, _kind) : (_ab ? 'sound' : _grade);
    final bool newStyle = _crack || _prod || _ab;
    Map<String, dynamic>? attrs;
    if (_ab) {
      attrs = <String, dynamic>{
        if (_ounce.text.trim().isNotEmpty) 'ounce': wsParseNum(_ounce.text),
        if (_gram.text.trim().isNotEmpty) 'gram': wsParseNum(_gram.text),
      };
      final List<Map<String, String>> specs = <Map<String, String>>[];
      for (final Map<String, dynamic> d in _defs) {
        final String k = '${d['key']}';
        final String txt = _pcts[k]?.text.trim() ?? '';
        if (txt.isEmpty) continue;
        final double v = wsParseNum(txt);
        if (v < 0 || v > 100) return _snack(context, 'درصد «${d['label']}» باید بین ۰ تا ۱۰۰ باشد');
        final String? col = _core[k];
        if (col != null) {
          attrs[col] = v;
        } else {
          specs.add(<String, String>{'label': '${d['label']}', 'value': '${_numText(v)}%'});
        }
      }
      if (specs.isNotEmpty) attrs['specs'] = specs;
    }
    if (!mounted) return;
    Navigator.pop(context, <String, dynamic>{
      'grade': grade,
      'kg': net,
      'small_sacks': wsParseNum(_small.text),
      'large_sacks': wsParseNum(_large.text),
      if (!newStyle) 'owner': _owner.text.trim(),
      if (newStyle) 'lot_name': _lotName.text.trim(),
      if (!newStyle && _grade == kWsCustomGrade) 'type_name': _name.text.trim(),
      if (_prod && grade == kWsCustomGrade) 'type_name': _kind,
      if (catServer != null) 'category_id': catServer,
      if (newStyle && _kind != null && (_prod || _ab || _grade == 'kernel')) 'kind_name': _kind,
      if (_gross) 'gross_kg': wsParseNum(_kg.text),
      if (attrs != null && attrs.isNotEmpty) 'attrs': attrs,
      if (_wh != null) 'warehouse_uid': _wh,
      if (wsCanCost() && _priced && _price.text.trim().isNotEmpty) 'price_per_kg': wsParseNum(_price.text),
    });
  }

  @override
  Widget build(BuildContext context) {
    const SizedBox gap = SizedBox(height: 8);
    final WsCat? cat = _cat;
    final List<Widget> fields = <Widget>[];
    if (_prod) {
      fields.addAll(<Widget>[
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Expanded(
            child: DropdownButtonFormField<int>(
              key: ValueKey<String>('cat-$_catId-${_cats.length}'),
              initialValue: _cats.any((WsCat c) => c.id == _catId) ? _catId : null,
              isExpanded: true,
              hint: const Text('انتخاب کنید'),
              decoration: const InputDecoration(labelText: 'دستهٔ خروجی', border: OutlineInputBorder()),
              items: <DropdownMenuItem<int>>[for (final WsCat c in _cats) DropdownMenuItem<int>(value: c.id, child: Text(c.name, overflow: TextOverflow.ellipsis))],
              onChanged: (int? v) => setState(() {
                _catId = v;
                _kind = null;
              }),
            ),
          ),
          const SizedBox(width: 6),
          IconButton.filledTonal(onPressed: _addCat, icon: const Icon(Icons.add), tooltip: 'افزودن دستهٔ تازه'),
        ]),
        gap,
        _TypePicker(cat: cat, value: _kind, label: 'نوع خروجی', onChanged: (String? v) => setState(() => _kind = v), onAdd: _addType),
      ]);
    } else if (_ab) {
      fields.addAll(<Widget>[
        InputDecorator(
          decoration: const InputDecoration(labelText: 'دستهٔ پسته', border: OutlineInputBorder()),
          child: Text(cat?.name ?? 'خندان (تعریف نشده)'),
        ),
        gap,
        _TypePicker(cat: cat, value: _kind, label: 'نوع پسته', onChanged: (String? v) => setState(() => _kind = v), onAdd: _addType),
      ]);
    } else {
      fields.addAll(<Widget>[
        DropdownButtonFormField<String>(
          initialValue: _grade,
          decoration: InputDecoration(labelText: _crack ? 'خروجی' : 'درجه', border: const OutlineInputBorder()),
          items: <DropdownMenuItem<String>>[
            for (final String g in _grades) DropdownMenuItem<String>(value: g, child: Text(kWsGradeLabels[g] ?? g)),
          ],
          onChanged: (String? v) => setState(() {
            _grade = v ?? _grades.first;
            if (_crack && _grade != 'kernel') _kind = null;
          }),
        ),
        if (_crack && _grade == 'kernel') ...<Widget>[
          gap,
          _TypePicker(cat: cat, value: _kind, label: 'نوع مغز', onChanged: (String? v) => setState(() => _kind = v), onAdd: _addType),
          if (cat == null) const Padding(padding: EdgeInsets.only(top: 4), child: Text('دستهٔ «مغز» تعریف نشده است.', style: TextStyle(color: Colors.red))),
        ],
        if (!_crack && _grade == kWsCustomGrade) ...<Widget>[
          gap,
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'نام خروجی', border: OutlineInputBorder())),
        ],
      ]);
    }
    fields.addAll(<Widget>[
      gap,
      _num(_kg, _gross ? 'وزن ناخالص (کیلو)' : 'وزن خالص (کیلو)', live: _gross),
      gap,
      Row(children: <Widget>[
        Expanded(child: _num(_small, 'عدل کوچک', live: _gross)),
        const SizedBox(width: 8),
        Expanded(child: _num(_large, 'عدل بزرگ', live: _gross)),
      ]),
      if (_gross)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('وزن خالص: ${faNum(_net < 0 ? 0 : _net, dec: 3)} کیلو  (تار عدل ${faNum(_tare, dec: 3)})',
              style: TextStyle(fontWeight: FontWeight.bold, color: _net <= 0 && _kg.text.isNotEmpty ? Colors.red : null)),
        ),
      if (_ab) ...<Widget>[
        gap,
        Row(children: <Widget>[Expanded(child: _num(_ounce, 'انس')), const SizedBox(width: 8), Expanded(child: _num(_gram, 'گرم'))]),
        if (_defs.isNotEmpty) ...<Widget>[
          gap,
          const Align(alignment: AlignmentDirectional.centerStart, child: Text('درصدها (مثل اتاق انس)')),
          gap,
          Wrap(spacing: 8, runSpacing: 8, children: <Widget>[
            for (final Map<String, dynamic> d in _defs)
              if (_pcts['${d['key']}'] != null) SizedBox(width: 120, child: _num(_pcts['${d['key']}']!, '${d['label']} ٪')),
          ]),
        ],
      ],
      gap,
      if (_crack || _prod || _ab)
        TextField(controller: _lotName, decoration: const InputDecoration(labelText: 'نام لات (اختیاری)', border: OutlineInputBorder()))
      else
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
      if (wsCanCost() && _priced) ...<Widget>[
        gap,
        _num(_price, _prod ? 'قیمت فروش هر کیلو (اختیاری؛ محصول فرعی)' : 'قیمت فروش هر کیلو (اختیاری؛ هنگام بستن هم قابل ثبت)'),
      ],
    ]);
    return AlertDialog(
      title: Text(widget.row == null ? 'ثبت خروجی' : 'ویرایش خروجی'),
      content: SizedBox(width: 460, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: fields))),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('انصراف')),
        FilledButton(onPressed: _save, child: const Text('ذخیره')),
      ],
    );
  }
}

/// فرم بستن: تاریخ پایان + بها (فقط با مجوز). قیمت خرید (V) فقط‌نمایش از بهای لات‌های ورودی.
class _CloseDialog extends StatefulWidget {
  const _CloseDialog({required this.detail, required this.totals, required this.titleOf});
  final Map<String, dynamic> detail;
  final WsBalance totals;
  final String Function(Map<String, dynamic>) titleOf;

  @override
  State<_CloseDialog> createState() => _CloseDialogState();
}

class _CloseDialogState extends State<_CloseDialog> {
  DateTime _end = DateTime.now();
  late final String _op = '${widget.detail['op_type'] ?? ''}';
  /// v80: «شکست» ⇒ بهای مغز از فرمول شکست؛ نشکن = قیمت ورودی ⇒ فقط پوست قیمت فروش دارد. v81: آبخندان ⇒ همهٔ خروجی هم‌بها (بدون قیمت).
  late final bool _crack = _op == 'crack';
  late final bool _single = kWsSplitCostTypes.contains(_op); // v85: تولید و آبخندان
  late final Map<String, TextEditingController> _cost = <String, TextEditingController>{
    for (final List<String> f in kWsCostFields) f[0]: TextEditingController(text: widget.detail[f[0]] == null ? '' : '${widget.detail[f[0]]}'),
  };
  late final List<Map<String, dynamic>> _rows = <Map<String, dynamic>>[
    for (final Map<String, dynamic> r in ReturnsHelp.maps(widget.detail['outputs']))
      if (r['grade'] != 'sound' && !(_crack && r['grade'] != 'hull') && _op != 'abkhandan') r,
  ];
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
          Text('ورودی ${_kg(t.inputKg)} · Σ خروجی ${_kg(t.inputKg - t.lossKg)} · ${_crack || _single ? 'ضایعات' : 'افت'} ${_kg(t.lossKg)} کیلو'),
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
                  '${Fmt.money(ReturnsHelp.d(widget.detail['crack_cost_per_kg']), label: false)}). نشکن با قیمت ورودی برمی‌گردد. قیمت پوست را وارد کنید (اختیاری؛ از بهای مغز کم می‌شود).'),
            ],
            if (_single) ...<Widget>[
              gap,
              Text(_op == 'abkhandan'
                  ? 'بهای هر کیلو = (ارزش ورودی + اجرت × وزن ورودی + سایر هزینه) ÷ وزن کل خروجی.'
                  : 'بهای خروجی‌ها = (ارزش ورودی + اجرت + سایر هزینه − ارزش محصولات فرعی) ÷ وزن بقیهٔ خروجی‌ها. قیمت فروش محصولات فرعی اختیاری است.'),
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
                  labelText: 'قیمت هر کیلو — ${widget.titleOf(_rows[i])} (${_kg(_rows[i]['kg'])} کیلو)',
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
              if (!_crack) {
                _cost.forEach((String k, TextEditingController c) {
                  if (c.text.trim().isNotEmpty) p[k] = wsParseNum(c.text);
                });
              }
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
