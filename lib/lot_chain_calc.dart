// T5 (مسیر پسته) — منطق خالص خط زمانی از پاسخ `lot_chain.get` (بدون Flutter؛ با flutter_test قابل‌آزمون).
// ورودی = Map پاسخ سرور (lot, up, down, nodes, edges, summary, truncated). هیچ مبلغی در آن نیست.

/// گره‌هایی که «مرحله»‌اند (در میانهٔ خط زمانی می‌آیند). باغ/خرید/امانی = مبدأ؛ فروش/ضایعات/برگشتی = مقصد.
const Set<String> kChainStageKinds = <String>{'lot', 'mix', 'separation', 'workshop_internal', 'workshop_outside'};

String chainKindLabel(String kind) {
  switch (kind) {
    case 'orchard':
      return 'باغ';
    case 'purchase':
      return 'خرید';
    case 'consign':
      return 'امانی';
    case 'lot':
      return 'لات';
    case 'mix':
      return 'مخلوط';
    case 'separation':
      return 'جداسازی';
    case 'workshop_internal':
      return 'کارگاه داخلی';
    case 'workshop_outside':
      return 'کارگاه بیرونی';
    case 'sale':
      return 'فروش';
    case 'sale_return':
      return 'برگشت از فروش';
    case 'purchase_return':
      return 'برگشت از خرید';
    case 'waste':
      return 'ضایعات/افت';
    default:
      return kind;
  }
}

/// برچسب نوع «منشأ» در summary.origins (orchard | purchase | consign | outside).
String chainOriginLabel(String kind) {
  switch (kind) {
    case 'orchard':
      return 'باغ';
    case 'purchase':
      return 'خرید از فروشنده';
    case 'consign':
      return 'امانی';
    case 'outside':
      return 'کارگاه بیرونی/دریافتی';
    default:
      return kind;
  }
}

class ChainOrigin {
  final String kind;
  final String name;
  final double pct;
  const ChainOrigin(this.kind, this.name, this.pct);
}

class ChainStep {
  final String key;
  final String kind;
  final String label;
  final String? code;
  final String? date; // میلادی (API)؛ نمایش شمسی با UI
  final double kg;
  final int depth; // فاصله از لات انتخابی (۰ = خود لات)
  final int isMix;

  const ChainStep({required this.key, required this.kind, required this.label, this.code, this.date, this.kg = 0, this.depth = 0, this.isMix = 0});

  /// شناسهٔ لات (فقط گره‌های lot/mix)؛ برای باز کردن مسیر همان لات.
  int? get lotId => key.startsWith('lot:') ? int.tryParse(key.substring(4)) : null;
  bool get isLot => lotId != null;
}

class ChainTimeline {
  final List<ChainOrigin> origins;
  final List<ChainStep> before; // مراحل پیش از این پسته (دورترین اول)
  final ChainStep self;
  final List<ChainStep> after; // مراحل پس از آن (نزدیک‌ترین اول)
  final List<ChainStep> sales;
  final List<ChainStep> waste;
  final List<ChainStep> returned;
  final double soldKg;
  final double remainingKg;
  final double wasteKg;
  final double returnedKg;
  final bool truncated;

  const ChainTimeline({
    required this.origins,
    required this.before,
    required this.self,
    required this.after,
    required this.sales,
    required this.waste,
    required this.returned,
    required this.soldKg,
    required this.remainingKg,
    required this.wasteKg,
    required this.returnedKg,
    required this.truncated,
  });
}

double _num(dynamic v) => v is num ? v.toDouble() : 0.0;

/// کمترین عمق هر key در درخت تو در توی up/down (عناصر `seen` هم شمرده می‌شوند ولی عمق کمتر را نمی‌شکنند).
Map<String, int> chainDepths(dynamic tree) {
  final Map<String, int> out = <String, int>{};
  void walk(dynamic els, int d) {
    if (els is! List) return;
    for (final dynamic e in els) {
      if (e is! Map) continue;
      final String k = '${e['node']}';
      final int? cur = out[k];
      if (cur == null || d < cur) out[k] = d;
      walk(e['children'], d + 1);
    }
  }

  walk(tree, 1);
  return out;
}

int _cmpStr(String? a, String? b) => (a ?? '').compareTo(b ?? '');

/// خط زمانی: مراحل پیش از لات = عمق بیشتر اول (سپس تاریخ، سپس key)؛ پس از لات = عمق کمتر اول.
ChainTimeline chainToTimeline(Map<String, dynamic> r) {
  final Map<String, Map<String, dynamic>> nodes = <String, Map<String, dynamic>>{};
  for (final dynamic n in (r['nodes'] as List?) ?? const <dynamic>[]) {
    if (n is Map) nodes['${n['key']}'] = Map<String, dynamic>.from(n);
  }
  final Map<String, dynamic> lot = Map<String, dynamic>.from((r['lot'] as Map?) ?? const <String, dynamic>{});
  final String rootKey = 'lot:${lot['id']}';
  final Map<String, int> up = chainDepths(r['up']);
  final Map<String, int> down = chainDepths(r['down']);

  ChainStep step(String key, int depth) {
    final Map<String, dynamic> n = nodes[key] ?? <String, dynamic>{'key': key, 'kind': 'lot', 'label': key};
    final dynamic meta = n['meta'];
    final String kind = '${n['kind']}';
    final int isMix = meta is Map && meta['is_mix'] is num ? (meta['is_mix'] as num).toInt() : (kind == 'mix' ? 1 : 0);
    return ChainStep(
      key: key,
      kind: kind,
      label: '${n['label'] ?? key}',
      code: n['code'] as String?,
      date: n['date'] as String?,
      kg: _num(n['kg']),
      depth: depth,
      isMix: isMix,
    );
  }

  List<ChainStep> pick(Map<String, int> depths, bool Function(String kind) want, {required bool farFirst}) {
    final List<ChainStep> out = <ChainStep>[
      for (final MapEntry<String, int> e in depths.entries)
        if (e.key != rootKey && want(step(e.key, e.value).kind)) step(e.key, e.value),
    ];
    out.sort((ChainStep a, ChainStep b) {
      final int d = farFirst ? b.depth.compareTo(a.depth) : a.depth.compareTo(b.depth);
      if (d != 0) return d;
      final int t = _cmpStr(a.date, b.date);
      return t != 0 ? t : a.key.compareTo(b.key);
    });
    return out;
  }

  final bool Function(String) isStage = kChainStageKinds.contains;
  final List<ChainStep> returned = <ChainStep>[
    ...pick(down, (String k) => k == 'purchase_return', farFirst: false),
    ...pick(up, (String k) => k == 'sale_return', farFirst: false),
  ];
  final Map<String, dynamic> sum = Map<String, dynamic>.from((r['summary'] as Map?) ?? const <String, dynamic>{});
  final List<ChainOrigin> origins = <ChainOrigin>[
    for (final dynamic o in (sum['origins'] as List?) ?? const <dynamic>[])
      if (o is Map) ChainOrigin('${o['kind']}', '${o['name']}', _num(o['pct'])),
  ];
  final int selfMix = lot['is_mix'] is num ? (lot['is_mix'] as num).toInt() : 0;
  return ChainTimeline(
    origins: origins,
    before: pick(up, isStage, farFirst: true),
    self: ChainStep(
      key: rootKey,
      kind: selfMix == 1 ? 'mix' : 'lot',
      label: '${lot['type_name'] ?? ''}',
      code: lot['code'] as String?,
      date: lot['date'] as String?,
      kg: _num(lot['net_weight']),
      depth: 0,
      isMix: selfMix,
    ),
    after: pick(down, isStage, farFirst: false),
    sales: pick(down, (String k) => k == 'sale', farFirst: false),
    waste: pick(down, (String k) => k == 'waste', farFirst: false),
    returned: returned,
    soldKg: _num(sum['sold_kg']),
    remainingKg: _num(sum['remaining_kg']),
    wasteKg: _num(sum['waste_kg']),
    returnedKg: _num(sum['returned_kg']),
    truncated: r['truncated'] == true,
  );
}
