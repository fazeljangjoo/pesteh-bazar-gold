import 'package:flutter/material.dart';

import 'fmt.dart' show Fmt;
import 'form_settings.dart' show FormSettingsLocal;
import 'processing_ui.dart' show ProcessingStore;
import 'returns_ui.dart' show ReturnsHelp;
import 'utils.dart';
import 'warehouse_ui.dart' show StockApiException, StockLookup, WhOption;
import 'widgets.dart' show JalaliDateField;
import 'workshop_calc.dart';
import 'workshop_flow_ui.dart' show WsCat, WsCats, WsCrackData, WsCrackLine, WsLotInfo, WsLotPicker, WsOutputDialog;
import 'workshop_ui.dart' show wsParseNum;

/// v82 — برون‌سپاری و فراوری امانی با همان سه نوع عملیات کارگاه داخلی (شکست / تولید / آبخندان). فایل مشترک اندروید و ویندوز.
///   [ProcOrderFormScreen]  ثبت/ویرایش سفارش:
///      برون‌سپاری (paid): لات‌های خودمان ⇒ فراوری‌کننده؛ اجرت تولید + سایر هزینه‌ها = بستانکار فراوری‌کننده (روی بهای خروجی‌ها می‌نشیند).
///      فراوری امانی (received): پستهٔ مشتری با مشخصات دقیق (دسته، نوع، وزن ناخالص، عدل، انس، گرم، درصدها) ⇒ لات امانی؛
///        اجرت تولید + سایر هزینه‌ها = بدهکار مشتری؛ گزینهٔ «فراوری‌کنندهٔ بیرونی» (کرایهٔ او بستانکارش می‌شود).
///   [ProcReceiveScreen]    دریافت خروجی‌ها با همان فرم خروجی کارگاه داخلی (امانی بدون قیمت)؛ ضایعات = ورودی − Σ خروجی.
///   [procOpInfo]           اطلاعات نوع عملیات و شکست (گرم و پرتی) در جزئیات سفارش.

const String kProcPaidDir = 'paid';
const String kProcReceivedDir = 'received';

String _kg(dynamic v) => faNum(ReturnsHelp.d(v), dec: 3);
String _f2(num v) => toFaDigits(v.toStringAsFixed(2)).replaceAll('.', '٫');
void _snack(BuildContext c, String m) => ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));
InputDecoration _dec(String l, {String? helper}) => InputDecoration(labelText: l, helperText: helper, border: const OutlineInputBorder());
const TextInputType _numKb = TextInputType.numberWithOptions(decimal: true);

String _numText(double v) {
  final String s = v.toStringAsFixed(3);
  return s.contains('.') ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '') : s;
}

/// ورودی برون‌سپاری: لات خودمان.
class _PaidIn {
  final TextEditingController kg = TextEditingController();
  final TextEditingController small = TextEditingController();
  final TextEditingController large = TextEditingController();
  String? lot;
  bool all = false;
  void dispose() {
    kg.dispose();
    small.dispose();
    large.dispose();
  }
}

/// ورودی فراوری امانی: مشخصات کامل پستهٔ تحویلی مشتری.
class _RecIn {
  int? catId;
  String? kind;
  final TextEditingController gross = TextEditingController();
  final TextEditingController small = TextEditingController();
  final TextEditingController large = TextEditingController();
  final TextEditingController ounce = TextEditingController();
  final TextEditingController gram = TextEditingController();
  final Map<String, TextEditingController> pct = <String, TextEditingController>{
    for (final String k in _kPctCols.keys) k: TextEditingController(),
  };
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[gross, small, large, ounce, gram, ...pct.values]) {
      c.dispose();
    }
  }
}

/// چهار درصد اصلی اتاق انس ⇒ ستون لات.
const Map<String, String> _kPctCols = <String, String>{'pct_tuchin': 'توچین', 'pct_dombest': 'دهن‌بست', 'pct_crooked': 'کج', 'pct_khandan': 'خندان'};

class ProcOrderFormScreen extends StatefulWidget {
  const ProcOrderFormScreen({super.key, required this.direction, this.edit});
  final String direction;
  /// ویرایش سفارش برون‌سپاری «در جریان» (پاسخ processing.get) ⇒ processing.update.
  final Map<String, dynamic>? edit;

  @override
  State<ProcOrderFormScreen> createState() => _ProcOrderFormScreenState();
}

class _ProcOrderFormScreenState extends State<ProcOrderFormScreen> {
  static const String _newKind = '\u0000new';
  bool get _paid => widget.direction == kProcPaidDir;
  bool get _isEdit => widget.edit != null;

  final TextEditingController _party = TextEditingController();
  final TextEditingController _note = TextEditingController();
  final TextEditingController _fee = TextEditingController();
  final TextEditingController _other = TextEditingController();
  final TextEditingController _receiptNo = TextEditingController();
  final TextEditingController _declared = TextEditingController();
  final TextEditingController _extParty = TextEditingController();
  final TextEditingController _extFee = TextEditingController();
  DateTime _date = DateTime.now();
  String? _op;
  String _basis = 'per_kg';
  String? _line;
  String? _kind;
  int _kindRev = 0;
  List<String> _kinds = <String>[...kWsProdKinds];
  bool _ext = false;
  bool _saving = false;
  bool _loaded = false;

  final List<_PaidIn> _paidIns = <_PaidIn>[_PaidIn()];
  final List<_RecIn> _recIns = <_RecIn>[_RecIn()];
  Map<String, WsLotInfo> _info = <String, WsLotInfo>{};
  List<WsCrackLine> _lines = <WsCrackLine>[];
  List<WsCat> _cats = <WsCat>[];
  List<WhOption> _whs = <WhOption>[];
  String? _wh;
  List<double> _sack = <double>[0.1, 0.2];

  @override
  void initState() {
    super.initState();
    final Map<String, dynamic>? e = widget.edit;
    if (e != null) {
      _party.text = '${e['party'] ?? ''}';
      _note.text = '${e['note'] ?? ''}';
      _fee.text = '${e['fee_value'] ?? ''}';
      _other.text = e['other_cost'] == null ? '' : '${e['other_cost']}';
      _receiptNo.text = '${e['receipt_no'] ?? ''}';
      _declared.text = e['crack_loss_gram'] == null ? '' : '${e['crack_loss_gram']}';
      _date = DateTime.tryParse('${e['date'] ?? ''}') ?? _date;
      _op = kWsOpenTypes.contains(e['op_type']) ? '${e['op_type']}' : null;
      _kind = e['prod_kind'] as String?;
      _basis = e['fee_basis'] == 'per_kg' ? 'per_kg' : 'fixed';
      _paidIns.clear();
      for (final Map<String, dynamic> it in ReturnsHelp.maps(e['inputs'])) {
        _paidIns.add(_PaidIn()
          ..lot = '${it['lot_id']}'
          ..kg.text = '${it['kg']}'
          ..small.text = '${it['small_sacks'] ?? 0}'
          ..large.text = '${it['large_sacks'] ?? 0}');
      }
      if (_paidIns.isEmpty) _paidIns.add(_PaidIn());
    }
    _init();
  }

  Future<void> _init() async {
    try {
      final WsCrackData d = await WsLotPicker.loadCrack();
      final List<WsCat> cats = _paid ? <WsCat>[] : await WsCats.load();
      final List<WhOption> whs = _paid ? <WhOption>[] : await StockLookup.warehouses().catchError((Object _) => <WhOption>[]);
      final List<double> sack = await FormSettingsLocal.sackKg().catchError((Object _) => <double>[0.1, 0.2]);
      final Map<String, dynamic> c = await ProcessingStore.cachedWorkshopList();
      if (!mounted) return;
      setState(() {
        _info = <String, WsLotInfo>{for (final WsLotInfo i in d.lots) i.key: i};
        // ویرایش: لات‌های همین سفارش (الان از موجودی کم شده‌اند) هم در فهرست باشند؛ سهم همین سفارش به موجودی برگردانده می‌شود
        for (final Map<String, dynamic> it in ReturnsHelp.maps(widget.edit?['inputs'])) {
          final String k = '${it['lot_id']}';
          final WsLotInfo? cur = _info[k];
          if (cur != null) {
            _info[k] = WsLotInfo(
              key: k,
              code: cur.code,
              category: cur.category,
              type: cur.type,
              seller: cur.seller,
              isMix: cur.isMix,
              remaining: cur.remaining + ReturnsHelp.d(it['kg']),
              netWeight: cur.netWeight,
              smallLeft: cur.smallLeft + ReturnsHelp.d(it['small_sacks']),
              largeLeft: cur.largeLeft + ReturnsHelp.d(it['large_sacks']),
              gram: cur.gram,
              ounce: cur.ounce,
              preset: cur.preset,
            );
            continue;
          }
          _info.putIfAbsent(
              k,
              () => WsLotInfo(
                    key: k,
                    code: '${it['code'] ?? ''}',
                    category: '',
                    type: '${it['type_name'] ?? ''}',
                    seller: 'همین سفارش',
                    isMix: 0,
                    remaining: ReturnsHelp.d(it['kg']),
                    netWeight: ReturnsHelp.d(it['kg']),
                    smallLeft: ReturnsHelp.d(it['small_sacks']),
                    largeLeft: ReturnsHelp.d(it['large_sacks']),
                  ));
        }
        _lines = d.lines;
        _cats = cats;
        _whs = whs;
        _wh = whs.isEmpty ? null : (whs.any((WhOption w) => w.isDefault) ? whs.firstWhere((WhOption w) => w.isDefault).uid : whs.first.uid);
        _sack = sack;
        for (final Map<String, dynamic> o in ReturnsHelp.maps(c['items'])) {
          final String v = '${o['prod_kind'] ?? ''}'.trim();
          if (v.isNotEmpty && !_kinds.contains(v)) _kinds.add(v);
        }
        if (_kind != null && !_kinds.contains(_kind)) _kinds.add(_kind!);
        _loaded = true;
      });
    } on StockApiException catch (e) {
      if (mounted) {
        setState(() => _loaded = true);
        _snack(context, e.message);
      }
    }
  }

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[_party, _note, _fee, _other, _receiptNo, _declared, _extParty, _extFee]) {
      c.dispose();
    }
    for (final _PaidIn r in _paidIns) {
      r.dispose();
    }
    for (final _RecIn r in _recIns) {
      r.dispose();
    }
    super.dispose();
  }

  bool get _single => _op != null && kWsSingleLotTypes.contains(_op);

  void _setOp(String? v) => setState(() {
        _op = v;
        if (_single) {
          while (_paidIns.length > 1) {
            _paidIns.removeLast().dispose();
          }
          while (_recIns.length > 1) {
            _recIns.removeLast().dispose();
          }
        }
        for (final _PaidIn r in _paidIns) {
          if (r.lot != null && !_lotAllowed(_info[r.lot])) r.lot = null;
        }
      });

  bool _lotAllowed(WsLotInfo? i) => i != null && (_op != 'abkhandan' || i.preset == 'dombest');

  double _netOf(_RecIn r) => ((wsParseNum(r.gross.text) - wsParseNum(r.small.text) * _sack[0] - wsParseNum(r.large.text) * _sack[1]) * 1000).round() / 1000;

  double get _inKg => _paid
      ? _paidIns.fold<double>(0, (double s, _PaidIn r) => s + wsParseNum(r.kg.text))
      : _recIns.fold<double>(0, (double s, _RecIn r) => s + (_netOf(r) > 0 ? _netOf(r) : 0));

  double get _feeTotal => (_basis == 'per_kg' ? wsParseNum(_fee.text) * _inKg : wsParseNum(_fee.text)) + wsParseNum(_other.text);

  /// گرم ارسالی (میانگین موزون).
  double? get _sentGram {
    double gk = 0, k = 0;
    if (_paid) {
      for (final _PaidIn r in _paidIns) {
        final double? g = _info[r.lot]?.gram;
        final double kg = wsParseNum(r.kg.text);
        if (g != null && g > 0 && kg > 0) {
          gk += g * kg;
          k += kg;
        }
      }
    } else {
      for (final _RecIn r in _recIns) {
        final double g = wsParseNum(r.gram.text), kg = _netOf(r);
        if (g > 0 && kg > 0) {
          gk += g * kg;
          k += kg;
        }
      }
    }
    return k > 0 ? gk / k : null;
  }

  String? _paidRowError(int idx) {
    final _PaidIn r = _paidIns[idx];
    final WsLotInfo? i = _info[r.lot];
    if (i == null) return null;
    double kg = 0, sm = 0, lg = 0;
    for (final _PaidIn x in _paidIns) {
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

  void _fillAll(_PaidIn r) {
    final WsLotInfo? i = _info[r.lot];
    if (!r.all || i == null) return;
    r.kg.text = _numText(i.remaining);
    r.large.text = _numText(i.largeLeft);
    r.small.text = _numText(i.smallLeft);
  }

  Future<void> _submit() async {
    final ScaffoldMessengerState sm = ScaffoldMessenger.of(context);
    void msg(String m) => sm.showSnackBar(SnackBar(content: Text(m)));
    final String party = _party.text.trim();
    if (party.isEmpty) return msg(_paid ? 'نام فراوری‌کننده را وارد کنید' : 'نام مشتری (صاحب کالا) را وارد کنید');
    if (_op == null) return msg('نوع عملیات را انتخاب کنید');
    if (_op == 'production' && (_kind == null || _kind!.isEmpty)) return msg('نوع تولید را انتخاب کنید');
    if (wsParseNum(_fee.text) < 0 || wsParseNum(_other.text) < 0) return msg('اجرت و هزینه نمی‌تواند منفی باشد');
    if (!_paid && _ext && _extParty.text.trim().isEmpty) return msg('نام فراوری‌کنندهٔ بیرونی را وارد کنید');
    setState(() => _saving = true);
    try {
      final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
      double bales = 0;
      if (_paid) {
        for (int i = 0; i < _paidIns.length; i++) {
          final _PaidIn r = _paidIns[i];
          if (r.lot == null) return msg('برای هر ورودی لات را انتخاب کنید');
          if (!_lotAllowed(_info[r.lot])) return msg('در «آبخندان» فقط پستهٔ دستهٔ «دهنبست» قابل انتخاب است');
          final double kg = wsParseNum(r.kg.text);
          if (kg <= 0) return msg('وزن هر ورودی باید بیشتر از صفر باشد');
          final String? rowErr = _paidRowError(i);
          if (rowErr != null) return msg(rowErr);
          bales += wsParseNum(r.small.text) + wsParseNum(r.large.text);
          items.add(<String, dynamic>{
            'purchase_id': await WsLotPicker.serverId(r.lot!),
            'kg': kg,
            'small_sacks': wsParseNum(r.small.text),
            'large_sacks': wsParseNum(r.large.text),
          });
        }
      } else {
        for (final _RecIn r in _recIns) {
          final WsCat? c = WsCats.byId(_cats, r.catId);
          if (c == null) return msg('دستهٔ پستهٔ هر ورودی را انتخاب کنید');
          if (r.kind == null || r.kind!.isEmpty) return msg('نوع پستهٔ هر ورودی را انتخاب کنید');
          final double net = _netOf(r);
          if (net <= 0) return msg('وزن ناخالص هر ورودی باید از تار عدل‌ها بیشتر باشد');
          final Map<String, dynamic> attrs = <String, dynamic>{
            if (r.ounce.text.trim().isNotEmpty) 'ounce': wsParseNum(r.ounce.text),
            if (r.gram.text.trim().isNotEmpty) 'gram': wsParseNum(r.gram.text),
          };
          for (final MapEntry<String, TextEditingController> e in r.pct.entries) {
            if (e.value.text.trim().isEmpty) continue;
            final double v = wsParseNum(e.value.text);
            if (v < 0 || v > 100) return msg('درصد «${_kPctCols[e.key]}» باید بین ۰ تا ۱۰۰ باشد');
            attrs[e.key] = v;
          }
          bales += wsParseNum(r.small.text) + wsParseNum(r.large.text);
          items.add(<String, dynamic>{
            'type_name': r.kind,
            'category_id': await WsCats.serverId(c.id),
            'kg': net,
            'gross_kg': wsParseNum(r.gross.text),
            'small_sacks': wsParseNum(r.small.text),
            'large_sacks': wsParseNum(r.large.text),
            if (attrs.isNotEmpty) 'attrs': attrs,
          });
        }
      }
      final Map<String, dynamic> payload = <String, dynamic>{
        'uid': ReturnsHelp.newUid('proc'),
        'direction': widget.direction,
        'party': party,
        'date': ReturnsHelp.iso(_date),
        'service': 'other',
        'op_type': _op,
        if (_op == 'production') 'prod_kind': _kind,
        if (!_paid && _op == 'crack' && _line != null) 'crack_line_uid': _line,
        'fee_basis': _basis,
        'fee_value': wsParseNum(_fee.text),
        'other_cost': wsParseNum(_other.text),
        'standard_yield_pct': 100,
        'waste_charge_per_kg': 0,
        'note': _note.text.trim(),
        'items': items,
        if (!_paid && _wh != null) 'warehouse_uid': _wh,
        if (!_paid && _ext) 'ext_party': _extParty.text.trim(),
        if (!_paid && _ext) 'ext_fee': wsParseNum(_extFee.text),
        if (_paid) 'receipt_no': _receiptNo.text.trim(),
        if (_paid && bales > 0) 'bale_count': bales,
        if (_paid && _op == 'crack') 'crack_loss_gram': _declared.text.trim().isEmpty ? null : wsParseNum(_declared.text),
        if (_paid && _sentGram != null) 'sent_gram_pct': double.parse(_sentGram!.toStringAsFixed(3)),
      };
      if (_isEdit) {
        payload.remove('uid');
        payload['id'] = widget.edit!['id'];
        if (widget.edit!['edit_version'] != null) payload['base_version'] = widget.edit!['edit_version'];
      }
      final String label = '${_isEdit ? 'ویرایش ' : ''}${_paid ? 'برون‌سپاری' : 'فراوری امانی'} (${kWsOpLabels[_op]}): $party';
      final bool queued = await ProcessingStore.write(_isEdit ? 'processing.update' : 'processing.create', payload, label);
      if (!mounted) return;
      msg(queued ? 'آفلاین ذخیره شد؛ پس از اتصال ارسال می‌شود' : 'ثبت شد');
      Navigator.pop(context, true);
    } on StockApiException catch (e) {
      msg(e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── ویجت‌ها ──
  Widget _opField() => DropdownButtonFormField<String>(
        key: ValueKey<String>('op-$_op'),
        initialValue: _op,
        isExpanded: true,
        hint: const Text('انتخاب کنید'),
        decoration: _dec('نوع عملیات'),
        items: <DropdownMenuItem<String>>[for (final String k in kWsOpenTypes) DropdownMenuItem<String>(value: k, child: Text(kWsOpLabels[k] ?? k))],
        onChanged: _setOp,
      );

  Widget _kindField() => DropdownButtonFormField<String>(
        key: ValueKey<String>('kind-$_kind-$_kindRev'),
        initialValue: _kinds.contains(_kind) ? _kind : null,
        isExpanded: true,
        hint: const Text('انتخاب کنید'),
        decoration: _dec('نوع تولید'),
        items: <DropdownMenuItem<String>>[
          for (final String k in _kinds) DropdownMenuItem<String>(value: k, child: Text(k, overflow: TextOverflow.ellipsis)),
          const DropdownMenuItem<String>(value: _newKind, child: Text('+ افزودن نوع تازه…', style: TextStyle(color: Colors.blue))),
        ],
        onChanged: (String? v) async {
          if (v != _newKind) return setState(() => _kind = v);
          final String? n = await _ask('نوع تولید تازه');
          if (!mounted) return;
          setState(() {
            if (n != null && !_kinds.contains(n)) _kinds = <String>[..._kinds, n];
            _kind = n ?? _kind;
            _kindRev++;
          });
        },
      );

  Future<String?> _ask(String title) async {
    final TextEditingController c = TextEditingController();
    final String? r = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(title),
        content: TextField(controller: c, autofocus: true, maxLength: 100, decoration: _dec('نام')),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('افزودن')),
        ],
      ),
    );
    c.dispose();
    return (r == null || r.isEmpty) ? null : r;
  }

  Widget _third() {
    if (_op == 'production') return _kindField();
    if (_op == 'crack' && _paid) {
      return TextField(controller: _declared, keyboardType: _numKb, decoration: _dec('گرم پرتی اعلامی فراوری‌کننده'));
    }
    if (_op == 'crack' && !_paid) {
      return DropdownButtonFormField<String>(
        initialValue: _line,
        isExpanded: true,
        decoration: _dec('خط شکست (کارگاه خودمان)'),
        items: <DropdownMenuItem<String>>[
          const DropdownMenuItem<String>(value: null, child: Text('— بدون خط —')),
          for (final WsCrackLine l in _lines) DropdownMenuItem<String>(value: l.uid, child: Text('${l.name} (پرتی ${faNum(l.lossGram, dec: 2)})', overflow: TextOverflow.ellipsis)),
        ],
        onChanged: (String? v) => setState(() => _line = v),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _lotInfo(WsLotInfo i) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(8)),
        child: Text(
          '${i.whoLabel}: ${i.who}  •  ${i.pistachio}  •  موجود ${_kg(i.remaining)} کیلو  •  عدل ${faNum(i.largeLeft, dec: 0)} بزرگ / ${faNum(i.smallLeft, dec: 0)} کوچک'
          '${i.gram == null ? '' : '  •  گرم ${faNum(i.gram!, dec: 2)}'}${i.ounce == null ? '' : '  •  انس ${faNum(i.ounce!, dec: 2)}'}',
          style: const TextStyle(fontSize: 12.5),
        ),
      );

  Widget _paidCard(int idx) {
    final _PaidIn r = _paidIns[idx];
    final List<WsLotInfo> lots = _info.values.where(_lotAllowed).toList();
    final String? err = _paidRowError(idx);
    TextField f(TextEditingController c, String l) => TextField(controller: c, enabled: !r.all, keyboardType: _numKb, decoration: _dec(l), onChanged: (_) => setState(() {}));
    return Card(
      key: ObjectKey(r),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Row(children: <Widget>[
            Expanded(
              child: DropdownButtonFormField<String>(
                key: ValueKey<String>('pl-${identityHashCode(r)}-$_op-${lots.length}'),
                isExpanded: true,
                initialValue: lots.any((WsLotInfo l) => l.key == r.lot) ? r.lot : null,
                decoration: _dec('لات انبار'),
                items: <DropdownMenuItem<String>>[
                  for (final WsLotInfo l in lots)
                    DropdownMenuItem<String>(value: l.key, child: Text('${l.who}  ·  ${l.code}  ·  ${l.pistachio}  ·  ${_kg(l.remaining)} کیلو', overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (String? v) => setState(() {
                  r.lot = v;
                  _fillAll(r);
                }),
              ),
            ),
            if (_paidIns.length > 1) IconButton(tooltip: 'حذف ورودی', icon: const Icon(Icons.remove_circle_outline), onPressed: () => setState(() => _paidIns.removeAt(idx).dispose())),
          ]),
          if (_info[r.lot] != null) _lotInfo(_info[r.lot]!),
          const SizedBox(height: 8),
          Row(children: <Widget>[
            Expanded(child: f(r.large, 'عدل بزرگ')),
            const SizedBox(width: 8),
            Expanded(child: f(r.small, 'عدل کوچک')),
            const SizedBox(width: 8),
            Expanded(flex: 2, child: f(r.kg, 'وزن خالص (کیلو)')),
          ]),
          CheckboxListTile(
            value: r.all,
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('همه موجودی'),
            onChanged: r.lot == null
                ? null
                : (bool? v) => setState(() {
                      r.all = v ?? false;
                      _fillAll(r);
                    }),
          ),
          if (err != null) Text(err, style: const TextStyle(color: Colors.red, fontSize: 12.5)),
        ]),
      ),
    );
  }

  Widget _recCard(int idx) {
    final _RecIn r = _recIns[idx];
    final WsCat? cat = WsCats.byId(_cats, r.catId);
    final List<String> types = <String>{...?cat?.types}.toList();
    TextField f(TextEditingController c, String l) => TextField(controller: c, keyboardType: _numKb, decoration: _dec(l), onChanged: (_) => setState(() {}));
    final double net = _netOf(r);
    return Card(
      key: ObjectKey(r),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Expanded(
              child: DropdownButtonFormField<int>(
                key: ValueKey<String>('rc-${identityHashCode(r)}-${r.catId}-${_cats.length}'),
                initialValue: _cats.any((WsCat c) => c.id == r.catId) ? r.catId : null,
                isExpanded: true,
                hint: const Text('انتخاب کنید'),
                decoration: _dec('دستهٔ پسته'),
                items: <DropdownMenuItem<int>>[for (final WsCat c in _cats) DropdownMenuItem<int>(value: c.id, child: Text(c.name))],
                onChanged: (int? v) => setState(() {
                  r.catId = v;
                  r.kind = null;
                }),
              ),
            ),
            IconButton(
              tooltip: 'دستهٔ تازه',
              icon: const Icon(Icons.add),
              onPressed: () async {
                final String? n = await _ask('دستهٔ تازه (در همهٔ فهرست‌ها)');
                if (n == null) return;
                try {
                  final int id = await WsCats.addCategory(n);
                  final List<WsCat> c = await WsCats.load();
                  if (mounted) {
                    setState(() {
                      _cats = c;
                      r.catId = id;
                      r.kind = null;
                    });
                  }
                } catch (e) {
                  if (mounted) _snack(context, e is StockApiException ? e.message : '$e');
                }
              },
            ),
            const SizedBox(width: 6),
            Expanded(
              child: DropdownButtonFormField<String>(
                key: ValueKey<String>('rt-${identityHashCode(r)}-${r.catId}-${r.kind}-${types.length}'),
                initialValue: types.contains(r.kind) ? r.kind : null,
                isExpanded: true,
                hint: Text(cat == null ? 'ابتدا دسته' : 'انتخاب کنید'),
                decoration: _dec('نوع پسته'),
                items: <DropdownMenuItem<String>>[for (final String t in types) DropdownMenuItem<String>(value: t, child: Text(t))],
                onChanged: (String? v) => setState(() => r.kind = v),
              ),
            ),
            IconButton(
              tooltip: 'نوع تازه',
              icon: const Icon(Icons.add),
              onPressed: cat == null
                  ? null
                  : () async {
                      final String? n = await _ask('نوع تازه برای «${cat.name}»');
                      if (n == null) return;
                      try {
                        if (!cat.types.contains(n)) await WsCats.addType(cat, n);
                        final List<WsCat> c = await WsCats.load();
                        if (mounted) {
                          setState(() {
                            _cats = c;
                            r.kind = n;
                          });
                        }
                      } catch (e) {
                        if (mounted) _snack(context, e is StockApiException ? e.message : '$e');
                      }
                    },
            ),
            if (_recIns.length > 1) IconButton(tooltip: 'حذف ورودی', icon: const Icon(Icons.remove_circle_outline), onPressed: () => setState(() => _recIns.removeAt(idx).dispose())),
          ]),
          const SizedBox(height: 8),
          Row(children: <Widget>[
            Expanded(flex: 2, child: f(r.gross, 'وزن ناخالص (کیلو)')),
            const SizedBox(width: 8),
            Expanded(child: f(r.small, 'عدل کوچک')),
            const SizedBox(width: 8),
            Expanded(child: f(r.large, 'عدل بزرگ')),
          ]),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('وزن خالص: ${faNum(net < 0 ? 0 : net, dec: 3)} کیلو', style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: <Widget>[
            SizedBox(width: 110, child: f(r.ounce, 'انس')),
            SizedBox(width: 110, child: f(r.gram, 'گرم')),
            for (final MapEntry<String, String> e in _kPctCols.entries) SizedBox(width: 110, child: f(r.pct[e.key]!, '${e.value} ٪')),
          ]),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const SizedBox gap = SizedBox(height: 10);
    final double? sg = _sentGram;
    return Scaffold(
      appBar: AppBar(title: Text('${_isEdit ? 'ویرایش ' : ''}${_paid ? 'برون‌سپاری فراوری' : 'فراوری امانی'}${_op == null ? '' : ' — ${kWsOpLabels[_op]}'}')),
      body: LayoutBuilder(builder: (BuildContext context, BoxConstraints c) {
        final bool row = c.maxWidth >= 600;
        final List<Widget> head = <Widget>[
          TextField(controller: _party, decoration: _dec(_paid ? 'فراوری‌کننده' : 'مشتری (صاحب کالا)')),
          JalaliDateField(label: 'تاریخ', value: _date, onChanged: (DateTime d) => setState(() => _date = d)),
          _opField(),
          if (_op == 'production' || _op == 'crack') _third(),
        ];
        return ListView(padding: const EdgeInsets.all(14), children: <Widget>[
          if (row)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              for (int i = 0; i < head.length; i++) ...<Widget>[if (i > 0) const SizedBox(width: 8), Expanded(child: head[i])],
            ])
          else
            for (final Widget w in head) Padding(padding: const EdgeInsets.only(bottom: 10), child: w),
          if (_op == null)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('نوع عملیات را انتخاب کنید: شکست، تولید یا آبخندان')))
          else ...<Widget>[
            gap,
            Text(_paid ? 'لات‌های ارسالی (از موجودی کم می‌شود)' : 'پستهٔ تحویلی مشتری (لات امانی؛ در موجودی ما حساب نمی‌شود)', style: Theme.of(context).textTheme.titleMedium),
            if (!_loaded) const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator()),
            if (_paid) for (int i = 0; i < _paidIns.length; i++) _paidCard(i) else for (int i = 0; i < _recIns.length; i++) _recCard(i),
            if (!_single)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () => setState(() => _paid ? _paidIns.add(_PaidIn()) : _recIns.add(_RecIn())),
                  icon: const Icon(Icons.add),
                  label: Text(_paid ? 'لات دیگر' : 'ورودی دیگر'),
                ),
              ),
            Text('جمع ورودی: ${_kg(_inKg)} کیلو${sg == null ? '' : '  •  گرم ارسالی ${_f2(sg)}'}'),
            gap,
            Text(_paid ? 'اجرت و هزینه‌ها (بستانکار فراوری‌کننده؛ روی بهای خروجی‌ها)' : 'اجرت و هزینه‌ها (بدهکار مشتری)', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: <Widget>[
              SizedBox(
                width: 180,
                child: DropdownButtonFormField<String>(
                  initialValue: _basis,
                  decoration: _dec('روش اجرت'),
                  items: const <DropdownMenuItem<String>>[
                    DropdownMenuItem<String>(value: 'per_kg', child: Text('هر کیلو')),
                    DropdownMenuItem<String>(value: 'fixed', child: Text('مبلغ کل')),
                  ],
                  onChanged: (String? v) => setState(() => _basis = v ?? 'per_kg'),
                ),
              ),
              SizedBox(
                width: 200,
                child: TextField(
                  controller: _fee,
                  keyboardType: _numKb,
                  inputFormatters: <ThousandsInputFormatter>[ThousandsInputFormatter()],
                  decoration: _dec(_basis == 'per_kg' ? 'اجرت تولید هر کیلو' : 'اجرت تولید (کل)'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              SizedBox(
                width: 200,
                child: TextField(
                  controller: _other,
                  keyboardType: _numKb,
                  inputFormatters: <ThousandsInputFormatter>[ThousandsInputFormatter()],
                  decoration: _dec('سایر هزینه‌ها (مبلغ کل)'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ]),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('${_paid ? 'بستانکار فراوری‌کننده' : 'بدهکار مشتری'}: ${Fmt.money(_feeTotal, label: false)}', style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            if (_paid) ...<Widget>[
              gap,
              TextField(controller: _receiptNo, decoration: _dec('شمارهٔ قبض (اختیاری)')),
            ],
            if (!_paid) ...<Widget>[
              gap,
              if (_whs.isNotEmpty)
                DropdownButtonFormField<String>(
                  initialValue: _wh,
                  decoration: _dec('انبار محل نگهداری'),
                  items: <DropdownMenuItem<String>>[for (final WhOption w in _whs) DropdownMenuItem<String>(value: w.uid, child: Text(w.name))],
                  onChanged: (String? v) => setState(() => _wh = v),
                ),
              SwitchListTile(
                value: _ext,
                contentPadding: EdgeInsets.zero,
                title: const Text('این پسته را به فراوری‌کنندهٔ بیرونی می‌دهیم'),
                subtitle: const Text('کرایهٔ او بستانکارش می‌شود؛ خروجی‌ها همچنان امانی مشتری‌اند.'),
                onChanged: (bool v) => setState(() => _ext = v),
              ),
              if (_ext)
                Row(children: <Widget>[
                  Expanded(child: TextField(controller: _extParty, decoration: _dec('فراوری‌کنندهٔ بیرونی'))),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _extFee,
                      keyboardType: _numKb,
                      inputFormatters: <ThousandsInputFormatter>[ThousandsInputFormatter()],
                      decoration: _dec('کرایهٔ فراوری‌کنندهٔ بیرونی (کل)'),
                    ),
                  ),
                ]),
            ],
            gap,
            TextField(controller: _note, decoration: _dec('یادداشت (اختیاری)')),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _saving ? null : _submit,
              icon: const Icon(Icons.save_outlined),
              label: Text(_saving ? 'در حال ثبت…' : 'ثبت سفارش'),
            ),
          ],
        ]);
      }),
    );
  }
}

/// دریافت خروجی‌های سفارش برون‌سپاری/امانی با فرم خروجی کارگاه داخلی.
class ProcReceiveScreen extends StatefulWidget {
  const ProcReceiveScreen({super.key, required this.order});
  final Map<String, dynamic> order;

  @override
  State<ProcReceiveScreen> createState() => _ProcReceiveScreenState();
}

class _ProcReceiveScreenState extends State<ProcReceiveScreen> {
  final List<Map<String, dynamic>> _outs = <Map<String, dynamic>>[];
  List<WsCat> _cats = <WsCat>[];
  DateTime _date = DateTime.now();
  bool _saving = false;

  Map<String, dynamic> get _o => widget.order;
  bool get _rec => _o['direction'] == kProcReceivedDir;
  String get _op => '${_o['op_type'] ?? 'production'}';
  double get _inKg => ReturnsHelp.d(_o['input_kg']);
  double get _outKg => _outs.fold<double>(0, (double s, Map<String, dynamic> r) => s + ReturnsHelp.d(r['kg']));
  double get _waste => ((_inKg - _outKg) * 1000).round() / 1000;

  @override
  void initState() {
    super.initState();
    _loadCats();
  }

  Future<void> _loadCats() async {
    try {
      final List<WsCat> c = await WsCats.load();
      if (mounted) setState(() => _cats = c);
    } on StockApiException catch (e) {
      if (mounted) _snack(context, e.message);
    }
  }

  String _title(Map<String, dynamic> r) {
    final String kind = '${r['kind_name'] ?? ''}';
    final String grade = kWsGradeLabels['${r['grade']}'] ?? '${r['grade'] ?? ''}';
    final WsCat? c = WsCats.byId(_cats, r['category_id'] == null ? null : ReturnsHelp.d(r['category_id']).toInt());
    if (kind.isEmpty) return grade;
    if (_op == 'crack') return kind == grade ? grade : '$grade — $kind';
    return c == null ? kind : '${c.name} — $kind';
  }

  Future<void> _edit([int? i]) async {
    final Map<String, dynamic>? row = i == null ? null : _outs[i];
    final List<Map<String, dynamic>> ins = ReturnsHelp.maps(_o['inputs']);
    final Map<String, dynamic>? res = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => WsOutputDialog(row: row, defaultOwner: '', op: _op, cats: _cats, noPrice: true, inputType: ins.isEmpty ? null : '${ins.first['type_name'] ?? ''}'),
    );
    await _loadCats();
    if (res == null || !mounted) return;
    setState(() => i == null ? _outs.add(res) : _outs[i] = res);
  }

  Future<void> _submit() async {
    if (_outs.isEmpty) return _snack(context, 'حداقل یک خروجی ثبت کنید');
    if (_waste < -0.0005 && _op != 'abkhandan') return _snack(context, 'جمع خروجی‌ها (${_kg(_outKg)}) از ورودی (${_kg(_inKg)}) بیشتر است');
    setState(() => _saving = true);
    try {
      final bool queued = await ProcessingStore.write('processing.receive', <String, dynamic>{
        'uid': ReturnsHelp.newUid('precv'),
        'id': ReturnsHelp.d(_o['id']).toInt(),
        'date': ReturnsHelp.iso(_date),
        'waste_kg': _waste,
        'outputs': <Map<String, dynamic>>[
          for (final Map<String, dynamic> r in _outs)
            <String, dynamic>{
              ...r,
              'type_name': '${r['kind_name'] ?? ''}'.isNotEmpty ? r['kind_name'] : (r['type_name'] ?? kWsGradeLabels['${r['grade']}'] ?? 'خروجی'),
            },
        ],
        if (_outs.any((Map<String, dynamic> r) => r['warehouse_uid'] != null)) 'warehouse_uid': _outs.firstWhere((Map<String, dynamic> r) => r['warehouse_uid'] != null)['warehouse_uid'],
      }, 'دریافت خروجی ${_rec ? 'فراوری امانی' : 'برون‌سپاری'}: ${_o['party'] ?? ''}');
      if (!mounted) return;
      _snack(context, queued ? 'آفلاین ذخیره شد؛ پس از اتصال ارسال می‌شود' : 'دریافت ثبت شد');
      Navigator.pop(context, true);
    } on StockApiException catch (e) {
      if (mounted) _snack(context, e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic> preview = <String, dynamic>{..._o, 'outputs': _outs};
    return Scaffold(
      appBar: AppBar(title: Text('دریافت خروجی — ${kWsOpLabels[_op] ?? ''}')),
      body: ListView(padding: const EdgeInsets.all(14), children: <Widget>[
        Text('${_rec ? 'مشتری' : 'فراوری‌کننده'}: ${_o['party'] ?? ''}  •  ورودی ${_kg(_inKg)} کیلو'),
        const SizedBox(height: 8),
        JalaliDateField(label: 'تاریخ دریافت', value: _date, onChanged: (DateTime d) => setState(() => _date = d)),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Row(children: <Widget>[
                Expanded(child: Text('خروجی‌ها', style: Theme.of(context).textTheme.titleMedium)),
                TextButton.icon(onPressed: () => _edit(), icon: const Icon(Icons.add), label: const Text('ثبت خروجی')),
              ]),
              if (_outs.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('هنوز خروجی ثبت نشده')),
              for (int i = 0; i < _outs.length; i++)
                ListTile(
                  dense: true,
                  title: Text('${_title(_outs[i])} — ${_kg(_outs[i]['kg'])} کیلو'),
                  subtitle: '${_outs[i]['lot_name'] ?? ''}'.isEmpty ? null : Text('نام لات ${_outs[i]['lot_name']}'),
                  onTap: () => _edit(i),
                  trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => setState(() => _outs.removeAt(i))),
                ),
            ]),
          ),
        ),
        ...procOpInfo(context, preview, showMoney: false),
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: _saving ? null : _submit, icon: const Icon(Icons.check), label: Text(_saving ? 'در حال ثبت…' : 'ثبت دریافت')),
      ]),
    );
  }
}

/// اطلاعات نوع عملیات + تراز وزنی + (شکست) گرم و پرتی برای سفارش برون‌سپاری/امانی.
List<Widget> procOpInfo(BuildContext context, Map<String, dynamic> d, {bool showMoney = true}) {
  final String op = '${d['op_type'] ?? ''}';
  if (op.isEmpty) return const <Widget>[];
  final bool rec = d['direction'] == kProcReceivedDir;
  final List<Map<String, dynamic>> outs = ReturnsHelp.maps(d['outputs']);
  final double inKg = ReturnsHelp.d(d['input_kg']);
  final double outKg = outs.fold<double>(0, (double s, Map<String, dynamic> r) => s + ReturnsHelp.d(r['kg']));
  double sum(String g) => outs.where((Map<String, dynamic> r) => r['grade'] == g).fold<double>(0, (double s, Map<String, dynamic> r) => s + ReturnsHelp.d(r['kg']));
  Widget kv(String k, String v, {bool strong = false, Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: <Widget>[
          Expanded(child: Text(k)),
          Flexible(child: Text(v, textAlign: TextAlign.end, style: TextStyle(fontWeight: strong ? FontWeight.bold : null, color: color))),
        ]),
      );
  final double? declared = d['crack_loss_gram'] == null ? null : ReturnsHelp.d(d['crack_loss_gram']);
  final List<Widget> rows = <Widget>[
    Text('${rec ? 'فراوری امانی' : 'برون‌سپاری'} — ${kWsOpLabels[op] ?? op}${'${d['prod_kind'] ?? ''}'.isEmpty ? '' : ' (${d['prod_kind']})'}',
        style: Theme.of(context).textTheme.titleMedium),
    if ('${d['crack_line_name'] ?? ''}'.isNotEmpty) Text('خط شکست: ${d['crack_line_name']}'),
    if ('${d['ext_party'] ?? ''}'.isNotEmpty) Text('فراوری‌کنندهٔ بیرونی: ${d['ext_party']}${showMoney && d['ext_fee'] != null ? ' — کرایه ${Fmt.money(ReturnsHelp.d(d['ext_fee']), label: false)}' : ''}'),
    if (showMoney && d['other_cost'] != null) Text('سایر هزینه‌ها: ${Fmt.money(ReturnsHelp.d(d['other_cost']), label: false)} (داخل ${rec ? 'مطالبه' : 'کرایه'})'),
    const Divider(),
    kv('وزن ورودی', '${_kg(inKg)} کیلو'),
  ];
  if (outs.isNotEmpty) {
    final double waste = ((inKg - outKg) * 1000).round() / 1000;
    rows.addAll(<Widget>[
      kv('وزن خروجی کل', '${_kg(outKg)} کیلو'),
      kv(waste >= 0 ? 'ضایعات' : 'اضافه وزن', '${_kg(waste.abs())} کیلو${inKg > 0 ? ' (${_f2(waste.abs() * 100 / inKg)}٪)' : ''}', strong: true, color: waste > 0 ? Colors.red : null),
    ]);
    if (op == 'crack' && sum('kernel') > 0) {
      final WsCrackResult r = wsCrackResult(
        inKg: inKg,
        gram: d['input_gram'] == null ? (d['sent_gram_pct'] == null ? null : ReturnsHelp.d(d['sent_gram_pct'])) : ReturnsHelp.d(d['input_gram']),
        kernelKg: sum('kernel'),
        lineLoss: declared,
        uncrackedKg: sum('uncracked'),
        outKg: outKg,
      );
      rows.addAll(<Widget>[
        const Divider(),
        kv('مغز / پوست / نشکن', '${_kg(sum('kernel'))} / ${_kg(sum('hull'))} / ${_kg(sum('uncracked'))} کیلو'),
        kv('گرم ارسالی', r.initGram == null ? '—' : _f2(r.initGram!)),
        kv('گرم دریافتی', r.recvGram == null ? '—' : _f2(r.recvGram!)),
        kv('افت گرم واقعی', r.lossGram == null ? '—' : _f2(r.lossGram!), strong: true),
        if (declared != null) kv(rec ? 'گرم پرتی خط' : 'گرم پرتی اعلامی فراوری‌کننده', _f2(declared)),
        if (r.gramVsLine != null)
          Text(
            r.gramVsLine!.abs() < 0.005 ? 'افت واقعی برابر اعلامی است' : 'افت واقعی ${_f2(r.gramVsLine!.abs())} گرم ${r.gramVsLine! > 0 ? 'بیشتر' : 'کمتر'} از اعلامی است',
            style: TextStyle(fontWeight: FontWeight.bold, color: r.gramVsLine! > 0.005 ? Colors.red : Colors.green),
          ),
        if (r.lossKg != null) kv('وزن پرتی (مغز)', '${_kg(r.lossKg)} کیلو'),
      ]);
    }
  }
  return <Widget>[
    Card(
      color: Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.4),
      child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows)),
    ),
  ];
}
