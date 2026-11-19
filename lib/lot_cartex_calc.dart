// مرحلهٔ ۱۱ — «کارتکس لات» (زیرتب انبار): مدل‌ها، پارس خروجی سرور و محاسبهٔ آینه (آفلاین/تست).
// آینهٔ دقیق WEB_public_html/backend/api/lot_cartex.php (pb_lot_cartex_build / range). هیچ قیمت/مبلغی در این فایل نیست.
// دور از Flutter-UI نگه داشته شده تا با test/lot_cartex_cases.json تست شود. «کارتکس مالک» قدیمی از این جداست.
import 'code_kind.dart' show mixGroupKeys;
import 'utils.dart' show gregorianToJalali, jalaliToGregorian, toFaDigits;

const List<String> kLotCartexPresetTypes = ['اکبری', 'احمدآقایی', 'فندقی', 'کله‌قوچی'];
const int _epsG = 1; // کمتر از ۱ گرم = صفر

/// ---------------- مرتب‌سازی فارسی ----------------
const String _faOrder = 'ابپتثجچحخدذرزژسشصضطظعغفقکگلمنوهی';
const Map<String, String> _faNorm = {
  'ي': 'ی', 'ك': 'ک', 'ة': 'ه', 'ۀ': 'ه', 'ئ': 'ی', 'ؤ': 'و', 'أ': 'ا', 'إ': 'ا', 'آ': 'ا', 'ى': 'ی',
};

/// کلید مرتب‌سازی فارسی (همان قاعدهٔ pb_lc_sort_key): نرمال‌سازی ي/ی ك/ک ة/ه، حذف نیم‌فاصله/اعراب/کشیده/فاصله.
String persianSortKey(String s) {
  final buf = StringBuffer();
  for (final r in s.runes) {
    var ch = String.fromCharCode(r);
    ch = _faNorm[ch] ?? ch;
    final cp0 = ch.runes.first;
    // نیم‌فاصله/جهت‌نما/اعراب/کشیده/فاصله حذف
    if (cp0 == 0x200C || cp0 == 0x200D || cp0 == 0x200F || cp0 == 0x200E || cp0 == 0x0640 || cp0 == 0x0670) continue;
    if (cp0 >= 0x064B && cp0 <= 0x0652) continue;
    if (ch.trim().isEmpty) continue;
    ch = ch.toLowerCase();
    final idx = _faOrder.indexOf(ch);
    if (idx >= 0) {
      buf.writeCharCode(0xA0 + idx + 1);
      continue;
    }
    var cp = ch.runes.first;
    if (cp >= 0x06F0 && cp <= 0x06F9) {
      cp = 0x30 + (cp - 0x06F0);
    } else if (cp >= 0x0660 && cp <= 0x0669) {
      cp = 0x30 + (cp - 0x0660);
    }
    buf.writeCharCode(cp < 0x80 ? (cp < 0x20 ? 0x20 : cp) : 0x7E);
  }
  return buf.toString();
}

/// مقایسهٔ نام فارسی؛ نام خالی آخر.
int persianCompareName(String a, String b) {
  a = a.trim();
  b = b.trim();
  if (a.isEmpty && b.isEmpty) return 0;
  if (a.isEmpty) return 1;
  if (b.isEmpty) return -1;
  return persianSortKey(a).compareTo(persianSortKey(b));
}

/// ---------------- مدل‌ها ----------------
double _d(Object? v) => v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);
int _i(Object? v) => v is num ? v.toInt() : (int.tryParse('${v ?? ''}') ?? 0);
int? _iN(Object? v) => v == null ? null : (v is num ? v.toInt() : int.tryParse('$v'));
String _s(Object? v) => v == null ? '' : '$v';

double? _dN(Object? v) => (v == null || '$v'.isEmpty) ? null : _d(v);

class LotCartexRow {
  final int lotId;
  final String code, party, entryDate, exitType, exitLabel;
  final int isMix;
  final double netKg, weightKg;
  final double? remainingKg, soldKg, ounce, gram;
  final String? exitDate;
  final bool partial;
  final int? kotId, orderId, colorKey;
  const LotCartexRow({
    required this.lotId,
    required this.code,
    required this.party,
    required this.entryDate,
    required this.exitType,
    required this.exitLabel,
    required this.isMix,
    required this.netKg,
    required this.weightKg,
    this.remainingKg,
    this.soldKg,
    this.ounce,
    this.gram,
    this.exitDate,
    this.partial = false,
    this.kotId,
    this.orderId,
    this.colorKey,
  });

  factory LotCartexRow.fromJson(Map<String, dynamic> j) => LotCartexRow(
        lotId: _i(j['lot_id']),
        code: _s(j['code']),
        party: _s(j['party']),
        entryDate: _s(j['entry_date']),
        exitType: _s(j['exit_type']),
        exitLabel: _s(j['exit_label']),
        isMix: _i(j['is_mix']),
        netKg: _d(j['net_kg']),
        weightKg: _d(j['weight_kg']),
        remainingKg: j['remaining_kg'] == null ? null : _d(j['remaining_kg']),
        soldKg: j['sold_kg'] == null ? null : _d(j['sold_kg']),
        ounce: _dN(j['ounce']),
        gram: _dN(j['gram']),
        exitDate: (j['exit_date'] == null || _s(j['exit_date']).isEmpty) ? null : _s(j['exit_date']),
        partial: j['partial'] == true || j['partial'] == 1,
        kotId: _iN(j['kot_id']),
        orderId: _iN(j['order_id']),
        colorKey: _iN(j['color_key']),
      );
}

/// لاتی که داخل یک کوت رفته (برای پنجرهٔ جزئیات کوت).
class LotCartexKotItem {
  final int lotId, isMix;
  final String code, party, typeName, entryDate;
  final double weightKg;
  final double? ounce, gram;
  const LotCartexKotItem({
    required this.lotId,
    required this.code,
    required this.party,
    required this.typeName,
    required this.weightKg,
    required this.entryDate,
    required this.isMix,
    this.ounce,
    this.gram,
  });
  factory LotCartexKotItem.fromJson(Map<String, dynamic> j) => LotCartexKotItem(
        lotId: _i(j['lot_id']),
        code: _s(j['code']),
        party: _s(j['party']),
        typeName: _s(j['type_name']),
        weightKg: _d(j['weight_kg']),
        entryDate: _s(j['entry_date']),
        isMix: _i(j['is_mix']),
        ounce: _dN(j['ounce']),
        gram: _dN(j['gram']),
      );
}

class LotCartexKot {
  final int kotId, colorKey;
  final String code, date;
  final double totalKg; // جمع سهم لات‌های درون کوت
  final double weightKg; // وزن خود کوت (purchases.net_weight)
  final double? ounce, gram; // انس و گرم خود کوت
  final List<LotCartexRow> items; // لات‌های همین نوع پسته که وارد این کوت شده‌اند (در بازه)
  final List<LotCartexKotItem> allItems; // همهٔ لات‌های درون کوت (برای پنجرهٔ جزئیات)
  const LotCartexKot({
    required this.kotId,
    required this.colorKey,
    required this.code,
    required this.date,
    required this.totalKg,
    required this.items,
    required this.allItems,
    this.weightKg = 0,
    this.ounce,
    this.gram,
  });
  String get title => code.isNotEmpty ? code : '#$kotId';
  factory LotCartexKot.fromJson(Map<String, dynamic> j) => LotCartexKot(
        kotId: _i(j['kot_id']),
        colorKey: _iN(j['color_key']) ?? _i(j['kot_id']),
        code: _s(j['code']),
        date: _s(j['date']),
        totalKg: _d(j['total_kg']),
        weightKg: j['weight_kg'] == null ? _d(j['total_kg']) : _d(j['weight_kg']),
        ounce: _dN(j['ounce']),
        gram: _dN(j['gram']),
        items: [for (final x in (j['items'] as List? ?? const [])) LotCartexRow.fromJson(Map<String, dynamic>.from(x as Map))],
        allItems: [for (final x in (j['all_items'] as List? ?? const [])) LotCartexKotItem.fromJson(Map<String, dynamic>.from(x as Map))],
      );
}

/// لات ساخته‌شده از یک پستهٔ فراوری‌شده/شکسته (زیر خود پستهٔ مبدأ نمایش داده می‌شود).
class LotCartexOutput {
  final int lotId;
  final String code, party, typeName, entryDate;
  final double weightKg;
  final double? ounce, gram;
  const LotCartexOutput({
    required this.lotId,
    required this.code,
    required this.party,
    required this.typeName,
    required this.weightKg,
    required this.entryDate,
    this.ounce,
    this.gram,
  });
  factory LotCartexOutput.fromJson(Map<String, dynamic> j) => LotCartexOutput(
        lotId: _i(j['lot_id']),
        code: _s(j['code']),
        party: _s(j['party']),
        typeName: _s(j['type_name']),
        weightKg: _d(j['weight_kg']),
        entryDate: _s(j['entry_date']),
        ounce: _dN(j['ounce']),
        gram: _dN(j['gram']),
      );
}

/// گروه فراوری/شکست: پسته(های) مبدأ (items) + همهٔ لات‌های ساخته‌شده از آن (outputs) با یک رنگ.
class LotCartexProcGroup {
  final String groupId, kind, date, label; // kind: proc | crack
  /// فاز ۲ کارگاه: عملیات باز ⇒ «در کارگاه» (ورودی کم شده، خروجی هنوز در انبار نیست).
  final bool inWorkshop;
  final int orderId, colorKey;
  final double inKg, outKg;
  final List<LotCartexRow> items;
  final List<LotCartexOutput> outputs;
  const LotCartexProcGroup({
    required this.groupId,
    required this.kind,
    required this.orderId,
    required this.date,
    required this.label,
    required this.colorKey,
    required this.inKg,
    required this.outKg,
    required this.items,
    required this.outputs,
    this.inWorkshop = false,
  });
  factory LotCartexProcGroup.fromJson(Map<String, dynamic> j) => LotCartexProcGroup(
        groupId: _s(j['group_id']),
        kind: _s(j['kind']),
        orderId: _i(j['order_id']),
        date: _s(j['date']),
        label: _s(j['label']),
        colorKey: _i(j['color_key']),
        inKg: _d(j['in_kg']),
        outKg: _d(j['out_kg']),
        items: [for (final x in (j['items'] as List? ?? const [])) LotCartexRow.fromJson(Map<String, dynamic>.from(x as Map))],
        outputs: [for (final x in (j['outputs'] as List? ?? const [])) LotCartexOutput.fromJson(Map<String, dynamic>.from(x as Map))],
        inWorkshop: j['in_workshop'] == true,
      );
}

class LotCartexType {
  final String typeName;
  final double totalKg;
  final List<LotCartexRow> normal, exited; // normal = موجود در انبار؛ exited = خارج‌شده (فروش)
  final List<LotCartexRow> overview; // دید کلی: همهٔ لات‌ها؛ وضعیت در exitLabel
  final List<LotCartexKot> kot;
  final List<LotCartexProcGroup> processed;
  const LotCartexType({
    required this.typeName,
    required this.totalKg,
    required this.normal,
    required this.kot,
    required this.processed,
    this.exited = const [],
    this.overview = const [],
  });
  factory LotCartexType.fromJson(Map<String, dynamic> j) => LotCartexType(
        typeName: _s(j['type_name']),
        totalKg: _d(j['total_kg']),
        normal: [for (final x in (j['normal'] as List? ?? const [])) LotCartexRow.fromJson(Map<String, dynamic>.from(x as Map))],
        exited: [for (final x in (j['exited'] as List? ?? const [])) LotCartexRow.fromJson(Map<String, dynamic>.from(x as Map))],
        overview: [for (final x in (j['overview'] as List? ?? const [])) LotCartexRow.fromJson(Map<String, dynamic>.from(x as Map))],
        kot: [for (final x in (j['kot'] as List? ?? const [])) LotCartexKot.fromJson(Map<String, dynamic>.from(x as Map))],
        processed: [for (final x in (j['processed'] as List? ?? const [])) LotCartexProcGroup.fromJson(Map<String, dynamic>.from(x as Map))],
      );
}

class LotCartexYear {
  final int yearStart;
  final String label;
  const LotCartexYear(this.yearStart, this.label);
}

class LotCartexReport {
  final String from, to, label;
  final List<LotCartexType> types;
  final List<LotCartexYear> years;
  final int month, day;
  final bool offline; // true = محاسبهٔ محلی (زبانهٔ فراوری ناقص)
  const LotCartexReport({
    required this.from,
    required this.to,
    required this.label,
    required this.types,
    this.years = const [],
    this.month = 7,
    this.day = 1,
    this.offline = false,
  });

  /// خروجی `stock.lot_cartex` سرور.
  factory LotCartexReport.fromJson(Map<String, dynamic> j) {
    final r = Map<String, dynamic>.from((j['range'] as Map?) ?? const {});
    final st = Map<String, dynamic>.from((j['settings'] as Map?) ?? const {});
    return LotCartexReport(
      from: _s(r['from']),
      to: _s(r['to']),
      label: _s(r['label']),
      types: [for (final x in (j['types'] as List? ?? const [])) LotCartexType.fromJson(Map<String, dynamic>.from(x as Map))],
      years: [
        for (final x in (j['years'] as List? ?? const [])) LotCartexYear(_i((x as Map)['year_start']), _s(x['label']))
      ],
      month: st['month'] == null ? 7 : _i(st['month']),
      day: st['day'] == null ? 1 : _i(st['day']),
    );
  }
}

/// ---------------- بازه و سال پسته‌ای ----------------
int lotCartexDaysInJMonth(int m) => m <= 6 ? 31 : (m <= 11 ? 30 : 29);

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// بازهٔ سال پسته‌ایِ شروع‌شده در سال شمسی [jy] (پیش‌فرض ۱ مهر تا ۳۱ شهریور).
({String from, String to, String label}) lotCartexRange(int jy, int month, int day) {
  month = month.clamp(1, 12);
  day = day.clamp(1, lotCartexDaysInJMonth(month));
  final a = jalaliToGregorian(jy, month, day);
  final b = jalaliToGregorian(jy + 1, month, day);
  final last = DateTime(b.year, b.month, b.day - 1);
  return (from: _iso(a), to: _iso(last), label: toFaDigits('سال پسته\u200Cای $jy–${jy + 1}'));
}

/// سال شمسیِ شروع بازه‌ای که تاریخ [ymd] (میلادی yyyy-mm-dd) در آن می‌افتد.
int lotCartexStartYearOf(String ymd, int month, int day) {
  final j = gregorianToJalali(int.parse(ymd.substring(0, 4)), int.parse(ymd.substring(5, 7)), int.parse(ymd.substring(8, 10)));
  return (j[1] < month || (j[1] == month && j[2] < day)) ? j[0] - 1 : j[0];
}

/// سال‌های دارای داده + سال جاری، نزولی.
List<LotCartexYear> lotCartexYears(Iterable<String> lotDates, String today, int month, int day) {
  final ys = <int>{lotCartexStartYearOf(today, month, day)};
  for (final d in lotDates) {
    if (d.length >= 10) ys.add(lotCartexStartYearOf(d, month, day));
  }
  final l = ys.toList()..sort((a, b) => b.compareTo(a));
  return [for (final y in l) LotCartexYear(y, lotCartexRange(y, month, day).label)];
}

/// ---------------- محاسبهٔ آینه ----------------
int _g(Object? kg) => (_d(kg) * 1000).round();
double _kg(int g) => g / 1000.0;

List<T> _stableSorted<T>(Iterable<T> src, int Function(T, T) cmp) {
  final l = src.toList();
  final dec = [for (var i = 0; i < l.length; i++) (i, l[i])];
  dec.sort((a, b) {
    final c = cmp(a.$2, b.$2);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final e in dec) e.$2];
}

/// تابع خالص (بدون دیتابیس/شبکه): ورودی‌ها همان شکل PHP:
/// lots [{id,code,type_name,seller,net_weight,remaining,date,is_mix,ounce?,gram?}]، mixSources [{mix_purchase_id,source_purchase_id,weight}]،
/// procInputs [{lot_id,kg,order_id,order_date,op_type,kind?}]، saleItems [{purchase_id,weight,date}]،
/// procOutputs [{order_id,lot_id,source_lot_id?,kind?}] (لات‌های ساخته‌شده از فراوری/شکست).
/// «موجود در انبار»: هر لات دارای مانده، به‌جز خود لات کوت (is_mix=1) و لات‌های ساخته‌شده از فراوری/شکست؛
/// مانده‌ی پستهٔ مبدأِ نیمه‌کوت/نیمه‌فراوری همان‌جا می‌ماند. «دید کلی»: همهٔ لات‌ها با وضعیت.
/// «خارج‌شده»: مانده=۰، فروش>۰ و نه کوت‌شده نه فراوری‌شده.
LotCartexReport lotCartexBuild(
  List<Map<String, dynamic>> lots,
  List<Map<String, dynamic>> mixSources,
  List<Map<String, dynamic>> procInputs,
  List<Map<String, dynamic>> saleItems, {
  List<Map<String, dynamic>> procOutputs = const <Map<String, dynamic>>[],
  required String from,
  required String to,
  String label = '',
  bool offline = false,
}) {
  final byId = <int, Map<String, dynamic>>{for (final l in lots) _i(l['id']): l};
  final keys = mixGroupKeys([for (final l in lots) {'id': l['id'], 'is_mix': l['is_mix'] ?? 0}], mixSources);

  final kots = <int, Map<int, int>>{}; // mixId → {src → g}
  final kotOfLot = <int, Map<int, int>>{}; // lotId → {mixId → g}
  for (final m in mixSources) {
    final mid = _i(m['mix_purchase_id']), sid = _i(m['source_purchase_id']);
    final g = _g(m['weight']);
    if (mid <= 0 || sid <= 0 || g <= 0 || !byId.containsKey(mid)) continue;
    kots.putIfAbsent(mid, () => {})[sid] = (kots[mid]![sid] ?? 0) + g;
    kotOfLot.putIfAbsent(sid, () => {})[mid] = (kotOfLot[sid]![mid] ?? 0) + g;
  }

  final procOf = <int, Map<String, _Proc>>{};
  final procGroups = <String, _Proc>{}; // groupKey → اطلاعات گروه (o<orderId> | r<runId>)
  for (final p in procInputs) {
    final lid = _i(p['lot_id']);
    final g = _g(p['kg']);
    if (lid <= 0 || g <= 0) continue;
    final isRun = _s(p['kind']) == 'crack_run';
    final crack = _s(p['op_type']) == 'crack' || isRun;
    final oid = _i(p['order_id']);
    final rk = '${crack && isRun ? 'r' : 'o'}$oid';
    final open = !isRun && _s(p['status']) == 'open'; // فاز ۲ کارگاه
    final m = procOf.putIfAbsent(lid, () => {});
    final e = m.putIfAbsent(rk, () => _Proc(_s(p['order_date']), crack, oid, isRun, open: open));
    e.g += g;
    procGroups.putIfAbsent(rk, () => _Proc(_s(p['order_date']), crack, oid, isRun, open: open));
  }
  final outOf = <String, Map<int, int>>{}; // groupKey → {lotId → lotId} (بدون تکرار، با حفظ ترتیب)
  for (final o in procOutputs) {
    final lid = _i(o['lot_id']), oid = _i(o['order_id']);
    if (lid <= 0 || oid <= 0) continue;
    final rk = '${_s(o['kind']) == 'crack_run' ? 'r' : 'o'}$oid';
    outOf.putIfAbsent(rk, () => {})[lid] = lid;
  }

  final outLots = <int>{}; // لات‌های خروجی فراوری/شکست
  for (final ids in outOf.values) {
    outLots.addAll(ids.keys);
  }

  final soldG = <int, int>{};
  final soldLast = <int, String>{};
  for (final s in saleItems) {
    final lid = _i(s['purchase_id']);
    final g = _g(s['weight']);
    if (lid <= 0 || g <= 0) continue;
    final d = _s(s['date']);
    soldG[lid] = (soldG[lid] ?? 0) + g;
    if (d.compareTo(soldLast[lid] ?? '') > 0) soldLast[lid] = d;
  }

  final secs = <String, _Sec>{};
  for (final l in lots) {
    final id = _i(l['id']);
    final kind = _i(l['is_mix']);
    if (kind == 3) continue;
    final date = _s(l['date']);
    if (date.compareTo(from) < 0 || date.compareTo(to) > 0) continue;
    final type = _s(l['type_name']).trim();
    final sec = secs.putIfAbsent(type, () => _Sec(type));
    final netG = _g(l['net_weight']);
    var remG = _g(l['remaining']);
    if (remG < 0) remG = 0;
    if (remG < _epsG) remG = 0;
    sec.totalG += netG;
    final party = _s(l['seller']).trim();
    final code = _s(l['code']);
    final ounce = _round3N(l['ounce']), gram = _round3N(l['gram']);
    LotCartexRow mk({required double w, required String et, String el = '', String? ed, double? rem, double? sold, bool partial = false, int? kotId, int? orderId}) =>
        LotCartexRow(
          lotId: id, code: code, party: party, entryDate: date, isMix: kind, netKg: _kg(netG), weightKg: w,
          exitType: et, exitLabel: el, exitDate: ed, remainingKg: rem, soldKg: sold, partial: partial,
          kotId: kotId, orderId: orderId, ounce: ounce, gram: gram,
        );

    final hasKot = (kotOfLot[id] ?? const <int, int>{}).isNotEmpty;
    final procs = (procOf[id] ?? const <String, _Proc>{}).values;
    final hasProc = procs.any((_Proc x) => !x.open); // فاز ۲: عملیات باز کارگاه = «در کارگاه»
    final inWs = procs.any((_Proc x) => x.open);
    final sold = soldG[id] ?? 0;

    final isOutLot = outLots.contains(id);
    final derived = kind == 1 || isOutLot; // خود لات کوت یا لات ساخته‌شده از فراوری/شکست
    final partialRow = remG < netG - _epsG;

    // «دید کلی»: همهٔ لات‌ها با وضعیت
    final parts = <String>[
      if (kind == 1) 'لات کوت',
      if (isOutLot) 'ساخته‌شده از فراوری/شکست',
      if (hasKot) 'وارد کوت شده',
      if (hasProc) 'وارد فراوری/شکست شده',
      if (inWs) 'در کارگاه',
      remG > 0 ? 'موجود در انبار' : (sold > 0 ? 'فروش رفته' : 'مانده ندارد'),
    ];
    sec.overview.add(mk(w: _kg(netG), et: 'overview', el: parts.join(' · '), rem: _kg(remG), sold: _kg(sold), partial: partialRow));

    // «موجود در انبار»: هر لات دارای مانده به‌جز لات کوت و لات‌های ساخته‌شده از فراوری
    if (remG > 0 && !derived) {
      sec.normal.add(mk(w: _kg(netG), et: 'in_stock', rem: _kg(remG), sold: _kg(sold), partial: partialRow));
    }
    // «خارج‌شده»: کاملاً فروش رفته و نه کوت شده نه فراوری/شکست
    if (remG == 0 && sold > 0 && !hasKot && !hasProc && !inWs) {
      sec.exited.add(mk(w: _kg(sold), et: 'sold', el: 'فروش رفته', ed: soldLast[id], rem: 0, sold: _kg(sold)));
    }
    for (final e in (kotOfLot[id] ?? const <int, int>{}).entries) {
      sec.kotRows.putIfAbsent(e.key, () => []).add(mk(
          w: _kg(e.value), et: 'kot', ed: _s(byId[e.key]?['date']), rem: _kg(remG), kotId: e.key));
    }
    for (final pe in (procOf[id] ?? const <String, _Proc>{}).entries) {
      final pr = pe.value;
      sec.procRows.putIfAbsent(pe.key, () => []).add(mk(
          w: _kg(pr.g), et: pr.crack ? 'crack' : 'proc', ed: pr.date, rem: _kg(remG), orderId: pr.orderId));
    }
  }

  int cmpRow(LotCartexRow a, LotCartexRow b) {
    final c = persianCompareName(a.party, b.party);
    if (c != 0) return c;
    final d = a.entryDate.compareTo(b.entryDate);
    return d != 0 ? d : a.lotId.compareTo(b.lotId);
  }

  LotCartexKot kotOf(int mid, List<LotCartexRow> rows) {
    final items = <LotCartexKotItem>[];
    var tot = 0;
    for (final e in (kots[mid] ?? const <int, int>{}).entries) {
      final s = byId[e.key];
      if (s == null) continue;
      tot += e.value;
      items.add(LotCartexKotItem(
          lotId: e.key, code: _s(s['code']), party: _s(s['seller']).trim(), typeName: _s(s['type_name']).trim(),
          weightKg: _kg(e.value), entryDate: _s(s['date']), isMix: _i(s['is_mix']),
          ounce: _round3N(s['ounce']), gram: _round3N(s['gram'])));
    }
    final sortedItems = _stableSorted<LotCartexKotItem>(
        items,
        (a, b) {
          final c = persianCompareName(a.party, b.party);
          if (c != 0) return c;
          final d = a.entryDate.compareTo(b.entryDate);
          return d != 0 ? d : a.lotId.compareTo(b.lotId);
        });
    final m = byId[mid]!;
    return LotCartexKot(
        kotId: mid, code: _s(m['code']), date: _s(m['date']), totalKg: _kg(tot), colorKey: keys[mid] ?? mid,
        weightKg: _kg(_g(m['net_weight'])), ounce: _round3N(m['ounce']), gram: _round3N(m['gram']),
        items: _stableSorted(rows, cmpRow), allItems: sortedItems);
  }

  LotCartexProcGroup procGroupOf(String rk, List<LotCartexRow> rows) {
    final pg = procGroups[rk] ?? _Proc('', false, 0, false);
    var inG = 0;
    for (final r in rows) {
      inG += _g(r.weightKg);
    }
    final outs = <LotCartexOutput>[];
    var outG = 0;
    for (final olid in (outOf[rk] ?? const <int, int>{}).keys) {
      final o = byId[olid];
      final og = _g(o?['net_weight']);
      outG += og;
      outs.add(LotCartexOutput(
          lotId: olid, code: _s(o?['code']), party: _s(o?['seller']).trim(), typeName: _s(o?['type_name']).trim(),
          weightKg: _kg(og), entryDate: _s(o?['date']), ounce: _round3N(o?['ounce']), gram: _round3N(o?['gram'])));
    }
    final sortedOuts = _stableSorted<LotCartexOutput>(outs, (a, b) {
      final c = persianCompareName(a.party, b.party);
      if (c != 0) return c;
      final d = a.entryDate.compareTo(b.entryDate);
      return d != 0 ? d : a.lotId.compareTo(b.lotId);
    });
    return LotCartexProcGroup(
        groupId: rk, kind: pg.crack ? 'crack' : 'proc', orderId: pg.orderId, date: pg.date,
        label: pg.open ? 'در کارگاه — عملیات ${pg.orderId}' : (pg.crack ? 'شکسته شده' : 'فراوری سفارش ${pg.orderId}'),
        inWorkshop: pg.open,
        colorKey: (pg.run ? 2000000 : 1000000) + pg.orderId, inKg: _kg(inG), outKg: _kg(outG),
        items: _stableSorted(rows, cmpRow), outputs: sortedOuts);
  }

  final out = <LotCartexType>[];
  for (final sec in secs.values) {
    final kotList = [for (final e in sec.kotRows.entries) kotOf(e.key, e.value)];
    kotList.sort((a, b) {
      final c = b.date.compareTo(a.date);
      return c != 0 ? c : b.kotId.compareTo(a.kotId);
    });
    final procList = [for (final e in sec.procRows.entries) procGroupOf(e.key, e.value)];
    procList.sort((a, b) {
      final c = b.date.compareTo(a.date);
      if (c != 0) return c;
      final o = b.orderId.compareTo(a.orderId);
      return o != 0 ? o : a.groupId.compareTo(b.groupId);
    });
    final overview = _stableSorted(sec.overview, cmpRow);
    final exited = _stableSorted(sec.exited, (LotCartexRow a, LotCartexRow b) {
      final c = (b.exitDate ?? '').compareTo(a.exitDate ?? ''); // جدیدترین خروج اول
      return c != 0 ? c : cmpRow(a, b);
    });
    out.add(LotCartexType(
        typeName: sec.name, totalKg: _kg(sec.totalG), normal: _stableSorted(sec.normal, cmpRow), kot: kotList,
        processed: procList, exited: exited, overview: overview));
  }
  final presetIdx = {for (var i = 0; i < kLotCartexPresetTypes.length; i++) kLotCartexPresetTypes[i]: i};
  final sorted = _stableSorted<LotCartexType>(out, (a, b) {
    final pa = presetIdx[a.typeName], pb = presetIdx[b.typeName];
    if (pa != null && pb != null) return pa.compareTo(pb);
    if (pa != null) return -1;
    if (pb != null) return 1;
    return persianCompareName(a.typeName, b.typeName);
  });
  return LotCartexReport(from: from, to: to, label: label, types: sorted, offline: offline);
}

/// null می‌ماند اگر مقدار خالی باشد؛ وگرنه گرد‌شده به ۳ رقم (همان round($v,3) سرور).
double? _round3N(Object? v) {
  if (v == null || '$v'.isEmpty) return null;
  return (_d(v) * 1000).round() / 1000.0;
}

class _Proc {
  final String date;
  final bool crack, run, open;
  final int orderId;
  int g = 0;
  _Proc(this.date, this.crack, this.orderId, this.run, {this.open = false});
}

class _Sec {
  final String name;
  int totalG = 0;
  final List<LotCartexRow> normal = [], exited = [], overview = [];
  final Map<int, List<LotCartexRow>> kotRows = {};
  final Map<String, List<LotCartexRow>> procRows = {};
  _Sec(this.name);
}
