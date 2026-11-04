// کارگاه داخلی (مرحلهٔ ۱) — آینهٔ Dart منطق تراز سرور (`public_html/backend/api/workshop_calc.php`، تابع pb_ws_balance).
// تست مشترک: test/workshop_cases.json (کپی بایت‌به‌بایت از backend/tests/workshop_cases.json) + test/workshop_balance_test.dart.
//
// فرمول اکسل: R = H − (I+J+K+L+M+N+O)؛ «تراز صحیح» وقتی |R| < ۰٫۰۱ کیلو؛ S = I/H؛ T = F − H.
// محاسبه روی گرمِ صحیح انجام می‌شود تا مرز ۰٫۰۱ در ممیز شناور جابه‌جا نشود (اختلاف باید *کمتر* از ۱۰ گرم باشد).
// این فایل عمداً هیچ import ندارد (تست خالص Dart).

const int kWsTolGrams = 10; // 0.01 kg

const List<String> kWsGrades = <String>['sound', 'deformed_fine', 'hull', 'kernel', 'soil', 'discolored'];

const Map<String, String> kWsGradeLabels = <String, String>{
  'sound': 'سالم',
  'deformed_fine': 'بدشکل و ریز',
  'hull': 'پوست',
  'kernel': 'مغز',
  'soil': 'خاک',
  'discolored': 'بدرنگ',
};

const List<String> kWsOpTypes = <String>['dehull', 'desoil', 'split', 'fines', 'crack'];

const Map<String, String> kWsOpLabels = <String, String>{
  'dehull': 'پوست‌گیری',
  'desoil': 'خاک‌گیری',
  'split': 'جداسازی پوست و مغز',
  'fines': 'ریزبرداری و بدشکل',
  'crack': 'شکست',
};

int wsGrams(num? kg) => ((kg ?? 0) * 1000).round();

class WsBalance {
  final double inputKg;
  final double soundKg;
  final double wasteKg; // P = J+K+L+M+N+O (شامل افت)
  final double lossKg;
  final double outPlusLossKg; // Q = I+P
  final double diffKg; // R = H−Q
  final double? soundPct; // S (درصد، ۳ رقم اعشار)؛ H=0 ⇒ null
  final double? undeliveredKg; // T = F−H؛ F نامشخص ⇒ null
  final bool ok;

  const WsBalance({
    required this.inputKg,
    required this.soundKg,
    required this.wasteKg,
    required this.lossKg,
    required this.outPlusLossKg,
    required this.diffKg,
    required this.soundPct,
    required this.undeliveredKg,
    required this.ok,
  });

  String get status => ok ? 'ok' : 'check';
  String get label => ok ? 'تراز صحیح' : 'نیاز به بررسی';
}

/// [out] کلیدهای kWsGrades (کلید غایب = ۰)؛ [lossKg] = O؛ [initialKg] = F (null = ثبت‌نشده).
WsBalance wsBalance({required num inputKg, Map<String, num> out = const <String, num>{}, num lossKg = 0, num? initialKg}) {
  final int h = wsGrams(inputKg);
  final int o = wsGrams(lossKg);
  int g(String k) => wsGrams(out[k]);
  final int sound = g('sound');
  final int p = g('deformed_fine') + g('hull') + g('kernel') + g('soil') + g('discolored') + o;
  final int q = sound + p;
  final int r = h - q;
  final bool ok = r.abs() < kWsTolGrams;
  return WsBalance(
    inputKg: h / 1000,
    soundKg: sound / 1000,
    wasteKg: p / 1000,
    lossKg: o / 1000,
    outPlusLossKg: q / 1000,
    diffKg: r / 1000,
    soundPct: h > 0 ? (sound / h * 100 * 1000).round() / 1000 : null,
    undeliveredKg: initialKg == null ? null : (wsGrams(initialKg) - h) / 1000,
    ok: ok,
  );
}

// ───────────────────────── مرحلهٔ ۲: بهای تمام‌شدهٔ کارگاه (ریال) ─────────────────────────
// آینهٔ pb_ws_cost / pb_ws_alloc در سرور. تست مشترک: test/workshop_cost_cases.json + test/workshop_cost_test.dart.
//   W=H·V · Z=H·X+Y · AF=J·AA+K·AC+L·AE+M·AD+N·AB (افت ارزش ندارد) · AG=W+Z−AF (منفی ⇒ فقط هشدار) · AH=AG/I (I=0 ⇒ null)

const Map<String, String> kWsPriceKeys = <String, String>{
  'deformed_fine': 'price_deformed',
  'hull': 'price_hull',
  'kernel': 'price_kernel',
  'soil': 'price_soil',
  'discolored': 'price_discolored',
};

double wsR2(double v) {
  final double r = (v * 100).round() / 100;
  return r == 0 ? 0.0 : r;
}

class WsCost {
  final double valueIn; // W
  final double costTotal; // Z
  final double recoveryValue; // AF
  final double costSound; // AG (می‌تواند منفی باشد)
  final double? costPerKgSound; // AH؛ I=0 ⇒ null
  final double soundKg;
  final String? warning; // 'negative_cost'

  const WsCost({
    required this.valueIn,
    required this.costTotal,
    required this.recoveryValue,
    required this.costSound,
    required this.costPerKgSound,
    required this.soundKg,
    required this.warning,
  });
}

/// [pr]: buy_per_kg=V, wage_per_kg=X, other_cost=Y, price_deformed=AA, price_discolored=AB, price_hull=AC, price_soil=AD, price_kernel=AE (غایب = ۰).
WsCost wsCost({required num inputKg, Map<String, num> out = const <String, num>{}, Map<String, num> pr = const <String, num>{}}) {
  double n(String k) => (pr[k] ?? 0).toDouble();
  final double h = wsGrams(inputKg) / 1000;
  final double w = wsR2(h * n('buy_per_kg'));
  final double z = wsR2(h * n('wage_per_kg') + n('other_cost'));
  double af = 0;
  kWsPriceKeys.forEach((String grade, String key) {
    af += wsR2(wsGrams(out[grade]) / 1000 * n(key));
  });
  af = wsR2(af);
  final double ag = wsR2(w + z - af);
  final double i = wsGrams(out['sound']) / 1000;
  return WsCost(
    valueIn: w,
    costTotal: z,
    recoveryValue: af,
    costSound: ag,
    costPerKgSound: i > 0 ? (ag / i * 10000).round() / 10000 : null,
    soundKg: i,
    warning: ag < 0 ? 'negative_cost' : null,
  );
}

/// تخصیص بها به لات‌های خروجی (هم‌اندیس [outs]؛ هر عنصر {'grade': String, 'kg': num}).
/// لات فرعی = kg×قیمت دسته؛ لات‌های سالم = (W+Z−Σفرعی) به نسبت وزن، باقی‌ماندهٔ گرد روی آخرین لات سالم.
List<double> wsAlloc(List<Map<String, Object>> outs, Map<String, num> pr, WsCost cost) {
  final List<double> res = List<double>.filled(outs.length, 0.0);
  final List<int> sound = <int>[];
  double soundKg = 0;
  double af = 0;
  for (int i = 0; i < outs.length; i++) {
    final String g = outs[i]['grade'] as String;
    final double kg = (outs[i]['kg'] as num).toDouble();
    if (g == 'sound') {
      sound.add(i);
      soundKg += kg;
    } else {
      res[i] = wsR2(kg * (pr[kWsPriceKeys[g]] ?? 0).toDouble());
      af += res[i];
    }
  }
  final double pool = wsR2(cost.valueIn + cost.costTotal - af);
  double left = pool;
  for (int k = 0; k < sound.length; k++) {
    final int i = sound[k];
    if (k == sound.length - 1) {
      res[i] = wsR2(left);
      break;
    }
    final double part = soundKg > 0 ? wsR2(pool * ((outs[i]['kg'] as num).toDouble() / soundKg)) : 0.0;
    res[i] = part;
    left -= part;
  }
  return res;
}

/// مرحلهٔ ۳-الف — گزارش خط شکست (برگهٔ اکسل «گزارش خط شکست»). آینهٔ `pb_cr_calc` در سرور (workshop_calc.php)؛ تست مشترک: test/crack_cases.json.
///   N = L*M/100 · X = U/T*60 (T خالی/۰ ⇒ null) · AJ = L · AL = L−U · loss% = AL/AJ*100 · AP = M − AK*100/AJ (تأییدنشده؛ AK/M خالی یا AJ=۰ ⇒ null)
///   AN = تعداد توقف‌ها · مجموع دقیقهٔ توقف. kg روی گرم صحیح؛ دقیقه روی صدم صحیح؛ خروجی‌ها ۳ رقم اعشار.
double _crR3(double v) {
  final double r = (v * 1000).round() / 1000;
  return r == 0 ? 0.0 : r;
}

class CrackCalc {
  final double? estimatedKernelKg; // N
  final double? capacityKgh; // X
  final double inputKg; // AJ
  final double lossKg; // AL
  final double? lossPct;
  final double? apUnconfirmed; // AP (معنی تأییدنشده)
  final int stopCount; // AN
  final double stopTotalMin;
  const CrackCalc({
    required this.estimatedKernelKg,
    required this.capacityKgh,
    required this.inputKg,
    required this.lossKg,
    required this.lossPct,
    required this.apUnconfirmed,
    required this.stopCount,
    required this.stopTotalMin,
  });
}

CrackCalc crackCalc({
  num? inputKg,
  num? gramPct,
  num? kernelKg,
  num? runMinutes,
  num? initialKernelKg,
  List<num> stopMinutes = const <num>[],
}) {
  final int lg = wsGrams(inputKg);
  final int ug = wsGrams(kernelKg);
  final double? m = gramPct?.toDouble();
  final double? t = runMinutes?.toDouble();
  final double? ak = initialKernelKg?.toDouble();
  int stopCents = 0;
  for (final num s in stopMinutes) {
    stopCents += (s * 100).round();
  }
  final int lossG = lg - ug;
  return CrackCalc(
    estimatedKernelKg: m == null ? null : (lg * m / 100).round() / 1000,
    capacityKgh: (t == null || t <= 0) ? null : _crR3((ug / 1000) * 60 / t),
    inputKg: lg / 1000,
    lossKg: lossG / 1000,
    lossPct: lg > 0 ? _crR3(lossG / lg * 100) : null,
    apUnconfirmed: (m == null || ak == null || lg <= 0) ? null : _crR3(m - (ak * 100) / (lg / 1000)),
    stopCount: stopMinutes.length,
    stopTotalMin: stopCents / 100,
  );
}

/// مرحلهٔ ۴ — «فایل خام شکست کارگاه‌ها» (کارگاه بیرونی با قبض). آینهٔ PHP `pb_ow_calc` / `pb_ow_totals`؛ تست مشترک: test/outside_cases.json.
///   G = F*E/100 · J = G−H · K = F−I (نقطهٔ درصد گرم). مقدار خالی ⇒ null.
class OutsideCalc {
  final double? estKernelKg; // G
  final double? remainingKernelKg; // J
  final double? lossGram; // K
  const OutsideCalc({required this.estKernelKg, required this.remainingKernelKg, required this.lossGram});
}

OutsideCalc outsideCalc({num? sentKg, num? sentGramPct, num? recvKernelKg, num? recvGramPct}) {
  final int e = wsGrams(sentKg);
  final int? gG = sentGramPct == null ? null : (e * sentGramPct.toDouble() / 100).round();
  final int? hG = recvKernelKg == null ? null : wsGrams(recvKernelKg);
  return OutsideCalc(
    estKernelKg: gG == null ? null : gG / 1000,
    remainingKernelKg: (gG == null || hG == null) ? null : (gG - hG) / 1000,
    lossGram: (sentGramPct == null || recvGramPct == null) ? null : _crR3(sentGramPct.toDouble() - recvGramPct.toDouble()),
  );
}

/// ردیف جمع: هر ردیف {sent_kg, sent_gram_pct, recv_kernel_kg, recv_gram_pct}.
Map<String, double?> outsideTotals(List<Map<String, num?>> rows) {
  int eG = 0, gG = 0, hG = 0;
  double f = 0, i = 0;
  bool hasF = false, hasI = false;
  for (final Map<String, num?> r in rows) {
    final OutsideCalc c = outsideCalc(sentKg: r['sent_kg'], sentGramPct: r['sent_gram_pct'], recvKernelKg: r['recv_kernel_kg'], recvGramPct: r['recv_gram_pct']);
    eG += wsGrams(r['sent_kg']);
    if (c.estKernelKg != null) gG += wsGrams(c.estKernelKg);
    if (r['recv_kernel_kg'] != null) hG += wsGrams(r['recv_kernel_kg']);
    if (r['sent_gram_pct'] != null) {
      f += r['sent_gram_pct']!.toDouble();
      hasF = true;
    }
    if (r['recv_gram_pct'] != null) {
      i += r['recv_gram_pct']!.toDouble();
      hasI = true;
    }
  }
  return <String, double?>{
    'sent_kg': eG / 1000,
    'est_kernel_kg': gG / 1000,
    'recv_kernel_kg': hG / 1000,
    'remaining_kernel_kg': (gG - hG) / 1000,
    'sent_gram_sum': hasF ? _crR3(f) : null,
    'recv_gram_sum': hasI ? _crR3(i) : null,
    'loss_gram': (hasF && hasI) ? _crR3(f - i) : null,
  };
}

/// مرحلهٔ ۵ — «موجودی پستهٔ خرجی» (نمای جدا از انبار اصلی). آینهٔ PHP `pb_feed_calc` / `pb_feed_totals`؛ تست مشترک: test/feed_cases.json.
///   outside: in_progress ⇒ ارسالی=input_kg؛ done ⇒ برگشتی=output_kg، ضایعات=waste_kg · crack: برگشتی=kernel+hull+soil · adjust: in ⇒ ارسالی، out ⇒ برگشتی.
///   مانده = ارسالی − برگشتی − ضایعات. بدون مبلغ.
class FeedCalc {
  final double sentKg;
  final double returnedKg;
  final double wasteKg;
  final double remainingKg;
  const FeedCalc({required this.sentKg, required this.returnedKg, required this.wasteKg, required this.remainingKg});
}

/// [m]: {source: outside|crack|adjust, status?, kind?, input_kg?, output_kg?, waste_kg?, kernel_kg?, hull_kg?, soil_kg?, kg?}.
FeedCalc feedCalc(Map<String, dynamic> m) {
  int sent = 0, ret = 0, waste = 0;
  final String src = (m['source'] ?? '').toString();
  if (src == 'outside') {
    sent = wsGrams(m['input_kg'] as num?);
    if (m['status'] == 'done') {
      ret = wsGrams(m['output_kg'] as num?);
      waste = wsGrams(m['waste_kg'] as num?);
    }
  } else if (src == 'crack') {
    sent = wsGrams(m['input_kg'] as num?);
    ret = wsGrams(m['kernel_kg'] as num?) + wsGrams(m['hull_kg'] as num?) + wsGrams(m['soil_kg'] as num?);
  } else if (src == 'adjust') {
    final int g = wsGrams(m['kg'] as num?);
    if (m['kind'] == 'out') {
      ret = g;
    } else {
      sent = g;
    }
  }
  return FeedCalc(sentKg: sent / 1000, returnedKg: ret / 1000, wasteKg: waste / 1000, remainingKg: (sent - ret - waste) / 1000);
}

/// جمع‌ها + summary کارت صفحهٔ اصلی. هر ردیف: {workshop, sent_kg, returned_kg, waste_kg}.
/// کلیدها: sent_kg, returned_kg, waste_kg, remaining_kg, total_sent_kg, total_returned_kg, total_balance_kg, workshops_count, open_count.
Map<String, double> feedTotals(List<Map<String, dynamic>> rows) {
  int s = 0, r = 0, w = 0, open = 0;
  final Set<String> ws = <String>{};
  for (final Map<String, dynamic> x in rows) {
    final int sg = wsGrams(x['sent_kg'] as num?), rg = wsGrams(x['returned_kg'] as num?), wg = wsGrams(x['waste_kg'] as num?);
    s += sg;
    r += rg;
    w += wg;
    final int rem = sg - rg - wg;
    if (rem > 0) open++;
    final String name = (x['workshop'] ?? '').toString().trim();
    if (rem != 0 && name.isNotEmpty) ws.add(name);
  }
  final double bal = (s - r - w) / 1000;
  return <String, double>{
    'sent_kg': s / 1000,
    'returned_kg': r / 1000,
    'waste_kg': w / 1000,
    'remaining_kg': bal,
    'total_sent_kg': s / 1000,
    'total_returned_kg': r / 1000,
    'total_balance_kg': bal,
    'workshops_count': ws.length.toDouble(),
    'open_count': open.toDouble(),
  };
}

/// مرحلهٔ ۶ — «کارتکس مالک» (آینهٔ PHP `pb_cartex_build`؛ تست مشترک: test/cartex_cases.json).
/// رویداد: {date 'YYYY-MM-DD', ord, event (send|receive)، owner, bale_count?, in_kg?, out_kg?, gram_pct?, note?, ref_id?}.
/// مانده (balanceKg) = مانده قبلیِ همان مالک + ورود − خروج؛ رویدادهای قبل از `from` فقط در openingKg می‌آیند و بعد از `to` حذف می‌شوند.
/// انس و دهنبست همیشه null (تصمیم کاربر). هیچ قیمتی در گزارش نیست.
class CartexRow {
  const CartexRow({required this.date, required this.event, required this.owner, this.baleCount, required this.inKg, required this.outKg, this.gramPct, required this.balanceKg, required this.note, this.refId});
  final String date;
  final String event;
  final String owner;
  final double? baleCount;
  final double inKg;
  final double outKg;
  final double? gramPct;
  final double balanceKg;
  final String note;
  final Object? refId;
}

class CartexOwner {
  const CartexOwner({required this.owner, required this.openingKg, required this.inKg, required this.outKg, required this.balanceKg});
  final String owner;
  final double openingKg;
  final double inKg;
  final double outKg;
  final double balanceKg;
}

class CartexResult {
  const CartexResult({required this.rows, required this.owners, required this.openingKg, required this.inKg, required this.outKg, required this.balanceKg});
  final List<CartexRow> rows;
  final List<CartexOwner> owners; // به ترتیب اولین ظهور
  final double openingKg;
  final double inKg;
  final double outKg;
  final double balanceKg;
}

CartexResult cartexBuild(List<Map<String, dynamic>> events, {String? from, String? to}) {
  final String? f = (from == null || from.isEmpty) ? null : from;
  final String? t = (to == null || to.isEmpty) ? null : to;
  final List<MapEntry<int, Map<String, dynamic>>> idx = <MapEntry<int, Map<String, dynamic>>>[for (int i = 0; i < events.length; i++) MapEntry<int, Map<String, dynamic>>(i, events[i])];
  idx.sort((MapEntry<int, Map<String, dynamic>> a, MapEntry<int, Map<String, dynamic>> b) {
    final int c = (a.value['date'] ?? '').toString().compareTo((b.value['date'] ?? '').toString());
    if (c != 0) return c;
    final int o = ((a.value['ord'] as num?) ?? 0).toInt().compareTo(((b.value['ord'] as num?) ?? 0).toInt());
    return o != 0 ? o : a.key.compareTo(b.key);
  });
  final Map<String, int> bal = <String, int>{}, open = <String, int>{}, inn = <String, int>{}, out = <String, int>{};
  final List<String> order = <String>[];
  final List<CartexRow> rows = <CartexRow>[];
  for (final MapEntry<int, Map<String, dynamic>> x in idx) {
    final Map<String, dynamic> e = x.value;
    final String d = (e['date'] ?? '').toString();
    if (t != null && d.compareTo(t) > 0) continue;
    final String o = (e['owner'] ?? '').toString().trim();
    if (!bal.containsKey(o)) {
      bal[o] = 0;
      open[o] = 0;
      inn[o] = 0;
      out[o] = 0;
      order.add(o);
    }
    final int ig = wsGrams(e['in_kg'] as num?), og = wsGrams(e['out_kg'] as num?);
    bal[o] = bal[o]! + ig - og;
    if (f != null && d.compareTo(f) < 0) {
      open[o] = open[o]! + ig - og;
      continue;
    }
    inn[o] = inn[o]! + ig;
    out[o] = out[o]! + og;
    final Object? gp = e['gram_pct'];
    final Object? bc = e['bale_count'];
    rows.add(CartexRow(
      date: d,
      event: (e['event'] ?? '').toString(),
      owner: o,
      baleCount: (bc is num) ? bc.toDouble() : null,
      inKg: ig / 1000,
      outKg: og / 1000,
      gramPct: (gp is num) ? (gp.toDouble() * 1000).round() / 1000 : null,
      balanceKg: bal[o]! / 1000,
      note: (e['note'] ?? '').toString(),
      refId: e['ref_id'],
    ));
  }
  int to0 = 0, ti = 0, tu = 0, tb = 0;
  final List<CartexOwner> owners = <CartexOwner>[];
  for (final String o in order) {
    to0 += open[o]!;
    ti += inn[o]!;
    tu += out[o]!;
    tb += bal[o]!;
    owners.add(CartexOwner(owner: o, openingKg: open[o]! / 1000, inKg: inn[o]! / 1000, outKg: out[o]! / 1000, balanceKg: bal[o]! / 1000));
  }
  return CartexResult(rows: rows, owners: owners, openingKg: to0 / 1000, inKg: ti / 1000, outKg: tu / 1000, balanceKg: tb / 1000);
}

// ───────────── مرحلهٔ ۶-۲ — خلاصهٔ مدیریتی و مقایسه (آینهٔ PHP؛ تست مشترک: test/summary_cases.json و test/compare_cases.json) ─────────────

int _wsMinutesCents(Object? v) => (((v is num) ? v : 0) * 100).round();
double? _wsPct3(int a, int b) => b > 0 ? (a / b * 100 * 1000).round() / 1000 : null;

/// جمع ستون‌های «کنترل ورود و خروج تولید» (کارگاه داخلی)؛ هر ردیف: {initial_kg?, input_kg, loss_kg, sound_kg, deformed_fine_kg, hull_kg, kernel_kg, soil_kg, discolored_kg}.
/// کلیدها: orders_count, delivered_kg, input_kg, sound_kg, deformed_fine_kg, hull_kg, kernel_kg, soil_kg, discolored_kg, loss_kg, waste_total_kg, diff_kg, undelivered_kg, sound_pct (nullable), check_count.
Map<String, double?> wsumInternal(List<Map<String, dynamic>> rows) {
  int f = 0, h = 0, i = 0, j = 0, k = 0, l = 0, m = 0, n = 0, o = 0, p = 0, r = 0, t = 0, check = 0;
  for (final Map<String, dynamic> x in rows) {
    final int hh = wsGrams(x['input_kg'] as num?), ii = wsGrams(x['sound_kg'] as num?), jj = wsGrams(x['deformed_fine_kg'] as num?), kk = wsGrams(x['hull_kg'] as num?);
    final int ll = wsGrams(x['kernel_kg'] as num?), mm = wsGrams(x['soil_kg'] as num?), nn = wsGrams(x['discolored_kg'] as num?), oo = wsGrams(x['loss_kg'] as num?);
    final int pp = jj + kk + ll + mm + nn + oo, rr = hh - (ii + pp);
    final Object? ini = x['initial_kg'];
    if (ini is num) {
      f += wsGrams(ini);
      t += wsGrams(ini) - hh;
    }
    h += hh;
    i += ii;
    j += jj;
    k += kk;
    l += ll;
    m += mm;
    n += nn;
    o += oo;
    p += pp;
    r += rr;
    if (!(rr.abs() < 10)) check++;
  }
  return <String, double?>{
    'orders_count': rows.length.toDouble(), 'delivered_kg': f / 1000, 'input_kg': h / 1000, 'sound_kg': i / 1000, 'deformed_fine_kg': j / 1000, 'hull_kg': k / 1000,
    'kernel_kg': l / 1000, 'soil_kg': m / 1000, 'discolored_kg': n / 1000, 'loss_kg': o / 1000, 'waste_total_kg': p / 1000, 'diff_kg': r / 1000,
    'undelivered_kg': t / 1000, 'sound_pct': _wsPct3(i, h), 'check_count': check.toDouble(),
  };
}

const List<String> kWsumSubKeys = <String>['sound_kg', 'wheat_kg', 'super_fine_kg', 'flower_kg', 'split_kg', 'unbreakable_kg', 'pink_kg', 'waste_kernel_kg'];

/// بخش «خط شکست» خلاصه. returned_all_kg = مغز+پوست+خاک+زیرمجموعه‌های مغز (تصمیم کاربر؛ ممکن است دوبار‌شماری باشد ⇒ اجزا هم برمی‌گردند).
/// ظرفیت (kg/h) = Σمغزِ نوبت‌های دارای زمان × ۶۰ ÷ Σدقیقه.
Map<String, double?> wsumCrack(List<Map<String, dynamic>> rows) {
  int inn = 0, k = 0, h = 0, s = 0, sub = 0, ck = 0, cm = 0, rm = 0, sm = 0;
  for (final Map<String, dynamic> x in rows) {
    inn += wsGrams(x['input_kg'] as num?);
    k += wsGrams(x['kernel_kg'] as num?);
    h += wsGrams(x['hull_kg'] as num?);
    s += wsGrams(x['soil_kg'] as num?);
    for (final String key in kWsumSubKeys) {
      sub += wsGrams(x[key] as num?);
    }
    final int m = _wsMinutesCents(x['run_minutes']);
    rm += m > 0 ? m : 0;
    sm += _wsMinutesCents(x['stop_minutes']);
    if (m > 0) {
      ck += wsGrams(x['kernel_kg'] as num?);
      cm += m;
    }
  }
  return <String, double?>{
    'runs_count': rows.length.toDouble(), 'input_kg': inn / 1000, 'kernel_kg': k / 1000, 'hull_kg': h / 1000, 'soil_kg': s / 1000, 'sub_kernel_kg': sub / 1000,
    'returned_all_kg': (k + h + s + sub) / 1000, 'loss_kg': (inn - k) / 1000, 'loss_pct': _wsPct3(inn - k, inn), 'kernel_pct': _wsPct3(k, inn),
    'capacity_kgh': cm > 0 ? ((ck / 1000) * 60 / (cm / 100) * 1000).round() / 1000 : null, 'run_minutes': rm / 100, 'stop_minutes': sm / 100,
  };
}

class WcmpRow {
  const WcmpRow({required this.source, required this.name, required this.count, required this.inputKg, required this.goodKg, required this.lossKg, this.yieldPct, this.lossPct, this.capacityKgh, this.avgGramLoss});
  final String source;
  final String name;
  final int count;
  final double inputKg;
  final double goodKg;
  final double lossKg;
  final double? yieldPct;
  final double? lossPct;
  final double? capacityKgh;
  final double? avgGramLoss;
}

/// مقایسه: آیتم {source, name, input_kg, good_kg, loss_kg, cap_kg?, cap_min?, gram_loss?} → ردیف‌های گروه‌شده، مرتب: بازده نزولی (null آخر) ← نام ← source.
List<WcmpRow> wcmpBuild(List<Map<String, dynamic>> items) {
  final Map<String, List<int>> acc = <String, List<int>>{}; // [n, in, good, loss, ck, cm, gl, gn]
  final Map<String, List<String>> meta = <String, List<String>>{};
  final List<String> order = <String>[];
  for (final Map<String, dynamic> x in items) {
    final String source = (x['source'] ?? '').toString(), name = (x['name'] ?? '').toString().trim();
    final String key = '$source\u001f$name';
    if (!acc.containsKey(key)) {
      acc[key] = List<int>.filled(8, 0);
      meta[key] = <String>[source, name];
      order.add(key);
    }
    final List<int> r = acc[key]!;
    r[0]++;
    r[1] += wsGrams(x['input_kg'] as num?);
    r[2] += wsGrams(x['good_kg'] as num?);
    r[3] += wsGrams(x['loss_kg'] as num?);
    final int cm = _wsMinutesCents(x['cap_min']);
    if (cm > 0) {
      r[4] += wsGrams(x['cap_kg'] as num?);
      r[5] += cm;
    }
    final Object? gl = x['gram_loss'];
    if (gl is num) {
      r[6] += (gl * 1000).round();
      r[7]++;
    }
  }
  final List<WcmpRow> rows = <WcmpRow>[
    for (final String key in order)
      WcmpRow(
        source: meta[key]![0], name: meta[key]![1], count: acc[key]![0], inputKg: acc[key]![1] / 1000, goodKg: acc[key]![2] / 1000, lossKg: acc[key]![3] / 1000,
        yieldPct: _wsPct3(acc[key]![2], acc[key]![1]), lossPct: _wsPct3(acc[key]![3], acc[key]![1]),
        capacityKgh: acc[key]![5] > 0 ? ((acc[key]![4] / 1000) * 60 / (acc[key]![5] / 100) * 1000).round() / 1000 : null,
        avgGramLoss: acc[key]![7] > 0 ? (acc[key]![6] / acc[key]![7]).round() / 1000 : null,
      ),
  ];
  rows.sort((WcmpRow a, WcmpRow b) {
    if ((a.yieldPct == null) != (b.yieldPct == null)) return a.yieldPct == null ? 1 : -1;
    if (a.yieldPct != null && a.yieldPct != b.yieldPct) return a.yieldPct! < b.yieldPct! ? 1 : -1;
    final int c = a.name.compareTo(b.name);
    return c != 0 ? c : a.source.compareTo(b.source);
  });
  return rows;
}
