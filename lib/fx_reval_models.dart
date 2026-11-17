// تسعیر ارز حرفه‌ای — مرحلهٔ ۹: مدل‌های immutable خروجی accounting.fx_reval.*
//
// این فایل عمداً «Dart خالص» است (هیچ ایمپورتی ندارد) تا در `flutter test` بدون پلاگین/شبکه تست شود.
// همهٔ fromJson ها ایمن‌اند: فیلد ناموجود/null/نوع اشتباه ⇒ مقدار پیش‌فرض، نه استثنا
// (PDO ممکن است عددها را رشته بدهد؛ ردیف‌های قدیمیِ fx_revals فیلدهای جدید را ندارند).
// مبالغ ریال = int؛ مقدار ارزی = double (۴ رقم اعشار)؛ تاریخ‌ها همان رشتهٔ میلادی سرور (YYYY-MM-DD).

// ───────────────────────── ابزارهای تجزیهٔ ایمن ─────────────────────────

Map<String, dynamic> _m(dynamic v) {
  if (v is Map) return <String, dynamic>{for (final MapEntry<dynamic, dynamic> e in v.entries) e.key.toString(): e.value};
  return const <String, dynamic>{};
}

List<dynamic> _l(dynamic v) => v is List ? v : const <dynamic>[];

String _s(dynamic v, [String d = '']) => v == null ? d : v.toString();

String? _sn(dynamic v) {
  if (v == null) return null;
  final String t = v.toString();
  return t.isEmpty ? null : t;
}

int _i(dynamic v, [int d = 0]) {
  if (v is int) return v;
  if (v is num) return v.isFinite ? v.round() : d;
  if (v is String) {
    final String t = v.trim();
    final int? a = int.tryParse(t);
    if (a != null) return a;
    final double? b = double.tryParse(t);
    if (b != null && b.isFinite) return b.round();
  }
  return d;
}

double? _dn(dynamic v) {
  if (v is num) return v.isFinite ? v.toDouble() : null;
  if (v is String) {
    final double? b = double.tryParse(v.trim());
    if (b != null && b.isFinite) return b;
  }
  return null;
}

double _d(dynamic v, [double d = 0]) => _dn(v) ?? d;

bool _b(dynamic v, [bool d = false]) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final String t = v.trim().toLowerCase();
    if (t == '1' || t == 'true') return true;
    if (t == '0' || t == 'false' || t.isEmpty) return false;
  }
  return d;
}

/// تاریخ/زمان سرور → فقط YYYY-MM-DD (null/خالی ⇒ '').
String _date(dynamic v) {
  final String t = _s(v);
  return t.length >= 10 ? t.substring(0, 10) : t;
}

String? _daten(dynamic v) {
  final String t = _date(v);
  return t.isEmpty ? null : t;
}

DateTime? _parseDate(String? iso) => (iso == null || iso.isEmpty) ? null : DateTime.tryParse(iso);

double _round4(double x) => (x * 10000).round() / 10000;

List<T> _mapList<T>(dynamic raw, T Function(Map<String, dynamic>) f) {
  final List<T> out = <T>[];
  for (final dynamic x in _l(raw)) {
    if (x is Map) out.add(f(_m(x)));
  }
  return List<T>.unmodifiable(out);
}

/// برچسب فارسی طرف: ar = طلب (فروش)، ap = بدهی (خرید).
String fxRevalSideLabel(String side) => side == 'ap' ? 'بدهی (خرید)' : 'طلب (فروش)';

// ───────────────────────── نرخ ─────────────────────────

/// نرخ تسعیر یک ارز (ریال به‌ازای هر واحد). `missing` ⇒ تا as_of نرخی ثبت نشده.
class FxRevalRate {
  final String ccy;
  final double? rate;
  final String? rateDate;
  final bool missing;

  const FxRevalRate({required this.ccy, this.rate, this.rateDate, this.missing = false});

  factory FxRevalRate.fromJson(Map<String, dynamic> j, {String ccy = ''}) {
    final double? r = _dn(j['rate']);
    final String c = _s(j['ccy'], ccy).toUpperCase();
    return FxRevalRate(ccy: c, rate: r, rateDate: _daten(j['rate_date']), missing: _b(j['missing']) || r == null);
  }

  /// سرور دو شکل می‌دهد: check ⇒ لیست `[{ccy,rate,rate_date,missing}]`؛ preview/apply/detail ⇒ نگاشت `{USD:{rate,rate_date,missing}}`.
  static List<FxRevalRate> listFrom(dynamic raw) {
    final List<FxRevalRate> out = <FxRevalRate>[];
    if (raw is List) {
      for (final dynamic x in raw) {
        if (x is Map) out.add(FxRevalRate.fromJson(_m(x)));
      }
    } else if (raw is Map) {
      for (final MapEntry<dynamic, dynamic> e in raw.entries) {
        if (e.value is Map) {
          out.add(FxRevalRate.fromJson(_m(e.value), ccy: e.key.toString()));
        } else {
          out.add(FxRevalRate.fromJson(<String, dynamic>{'rate': e.value}, ccy: e.key.toString()));
        }
      }
    }
    out.sort((FxRevalRate a, FxRevalRate b) => a.ccy.compareTo(b.ccy));
    return List<FxRevalRate>.unmodifiable(out);
  }

  DateTime? get rateDateTime => _parseDate(rateDate);
}

// ───────────────────────── سطرهای محاسبه ─────────────────────────

/// اثر سودی/زیانی یک مبلغ delta: طلب (ar) ⇒ delta؛ بدهی (ap) ⇒ −delta. مثبت = سود، منفی = زیان.
int fxRevalEffect(String side, int delta) => side == 'ap' ? -delta : delta;

/// یک فاکتور ارزی باز (ریز سند).
class FxRevalDoc {
  final String side; // 'ar' | 'ap'
  final int docId;
  final String ref;
  final String party;
  final String ccy;
  final double bookedRate;
  final double totalCcy;
  final double paidCcy;
  final double remCcy;
  final double rate;
  final int delta; // ریال؛ علامت‌دار: نرخ روز − نرخ ثبت‌شده، ضرب در مانده

  const FxRevalDoc({
    this.side = 'ar',
    this.docId = 0,
    this.ref = '',
    this.party = '',
    this.ccy = '',
    this.bookedRate = 0,
    this.totalCcy = 0,
    this.paidCcy = 0,
    this.remCcy = 0,
    this.rate = 0,
    this.delta = 0,
  });

  factory FxRevalDoc.fromJson(Map<String, dynamic> j) {
    final int id = _i(j['doc_id'] ?? j['id']);
    final String ref = _s(j['ref']);
    return FxRevalDoc(
      side: _s(j['side'], 'ar') == 'ap' ? 'ap' : 'ar',
      docId: id,
      ref: ref.isNotEmpty ? ref : (id > 0 ? '#$id' : ''),
      party: _s(j['party']),
      ccy: _s(j['ccy']).toUpperCase(),
      bookedRate: _d(j['booked_rate']),
      totalCcy: _d(j['total_ccy']),
      paidCcy: _d(j['paid_ccy']),
      remCcy: _d(j['rem_ccy']),
      rate: _d(j['rate']),
      delta: _i(j['delta']),
    );
  }

  bool get isReceivable => side == 'ar';
  bool get isPayable => side == 'ap';
  String get sideLabel => fxRevalSideLabel(side);

  /// سود (+) / زیان (−) واقعی این سطر برای شرکت.
  int get effect => fxRevalEffect(side, delta);
  bool get isGain => effect > 0;
  bool get isLoss => effect < 0;
}

/// یک طرف‌حساب (ناخالص up/down؛ سند تسعیر از همین ساخته می‌شود).
class FxRevalParty {
  final String party;
  final String side;
  final bool noParty;
  final int up;
  final int down;
  final int? tafsiliId; // فقط در detail ذخیره‌شده (پس از apply)

  const FxRevalParty({this.party = '', this.side = 'ar', this.noParty = false, this.up = 0, this.down = 0, this.tafsiliId});

  factory FxRevalParty.fromJson(Map<String, dynamic> j) => FxRevalParty(
        party: _s(j['party']),
        side: _s(j['side'], 'ar') == 'ap' ? 'ap' : 'ar',
        noParty: _b(j['no_party']),
        up: _i(j['up']),
        down: _i(j['down']),
        tafsiliId: j['tafsili_id'] == null ? null : _i(j['tafsili_id']),
      );

  int get delta => up - down;
  int get effect => fxRevalEffect(side, delta);
  bool get isGain => effect > 0;
  bool get isLoss => effect < 0;
  String get sideLabel => fxRevalSideLabel(side);
}

/// جمع هر ارز×طرف (ar/ap).
class FxRevalItem {
  final String side;
  final String ccy;
  final double rate;
  final double openCcy;
  final int delta;

  const FxRevalItem({this.side = 'ar', this.ccy = '', this.rate = 0, this.openCcy = 0, this.delta = 0});

  factory FxRevalItem.fromJson(Map<String, dynamic> j) => FxRevalItem(
        side: _s(j['side'], 'ar') == 'ap' ? 'ap' : 'ar',
        ccy: _s(j['ccy']).toUpperCase(),
        rate: _d(j['rate']),
        openCcy: _d(j['open_ccy']),
        delta: _i(j['delta']),
      );

  int get effect => fxRevalEffect(side, delta);
  bool get isGain => effect > 0;
  bool get isLoss => effect < 0;
  String get sideLabel => fxRevalSideLabel(side);
}

/// گروه فاکتورها (برای نمایش جدول‌های تو در تو): ارز × طرف (ar/ap) × طرف‌حساب، یا فقط ارز × طرف.
class FxRevalDocGroup {
  final String ccy;
  final String side;
  final String? party; // null ⇒ گروه‌بندی فقط بر اساس ارز×طرف
  final List<FxRevalDoc> docs;
  final double remCcy;
  final int delta;

  const FxRevalDocGroup({required this.ccy, required this.side, this.party, this.docs = const <FxRevalDoc>[], this.remCcy = 0, this.delta = 0});

  int get effect => fxRevalEffect(side, delta);
  bool get isGain => effect > 0;
  bool get isLoss => effect < 0;
  String get sideLabel => fxRevalSideLabel(side);
}

/// گروه‌بندی docs. ترتیب خروجی: ارز (الفبایی)، طلب پیش از بدهی، نام طرف‌حساب. ترتیب فاکتورها درون گروه حفظ می‌شود.
List<FxRevalDocGroup> fxRevalGroupDocs(List<FxRevalDoc> docs, {bool byParty = true}) {
  final Map<String, List<FxRevalDoc>> buckets = <String, List<FxRevalDoc>>{};
  for (final FxRevalDoc d in docs) {
    final String k = '${d.ccy}\u001f${d.side}\u001f${byParty ? d.party : ''}';
    (buckets[k] ??= <FxRevalDoc>[]).add(d);
  }
  final List<FxRevalDocGroup> out = <FxRevalDocGroup>[];
  for (final List<FxRevalDoc> list in buckets.values) {
    double rem = 0;
    int delta = 0;
    for (final FxRevalDoc d in list) {
      rem = _round4(rem + d.remCcy);
      delta += d.delta;
    }
    out.add(FxRevalDocGroup(
      ccy: list.first.ccy,
      side: list.first.side,
      party: byParty ? list.first.party : null,
      docs: List<FxRevalDoc>.unmodifiable(list),
      remCcy: rem,
      delta: delta,
    ));
  }
  out.sort((FxRevalDocGroup a, FxRevalDocGroup b) {
    final int c = a.ccy.compareTo(b.ccy);
    if (c != 0) return c;
    if (a.side != b.side) return a.side == 'ar' ? -1 : 1;
    return (a.party ?? '').compareTo(b.party ?? '');
  });
  return List<FxRevalDocGroup>.unmodifiable(out);
}

/// سود خالص تحقق‌نیافته = Σ delta طلب‌ها − Σ delta بدهی‌ها (مثبت = سود، منفی = زیان).
int fxRevalNetGainOfDocs(Iterable<FxRevalDoc> docs) {
  int n = 0;
  for (final FxRevalDoc d in docs) {
    n += d.effect;
  }
  return n;
}

// ───────────────────────── فاکتور قابل انتخاب (action docs) ─────────────────────────

/// یک فاکتور ارزیِ باز در فهرست انتخاب. `key` همان مقداری است که در `doc_keys` به preview/check/apply فرستاده می‌شود ("ar:12" / "ap:7").
/// `rate`/`delta` وقتی نرخ ارز ثبت نشده null است (فاکتور نمایش داده می‌شود ولی تسعیرش rate_missing می‌دهد).
/// `coveredBy` = شمارهٔ تسعیر فعالِ همین تاریخ که این فاکتور را قبلاً در بر گرفته (قابل انتخاب نیست مگر آن تسعیر ابطال شود).
class FxRevalCandidate {
  final String key;
  final String side; // 'ar' | 'ap'
  final int docId;
  final String ref;
  final String party;
  final String ccy;
  final String date;
  final double bookedRate;
  final double remCcy;
  final double? rate;
  final int? delta;
  final int? coveredBy;

  const FxRevalCandidate({
    this.key = '',
    this.side = 'ar',
    this.docId = 0,
    this.ref = '',
    this.party = '',
    this.ccy = '',
    this.date = '',
    this.bookedRate = 0,
    this.remCcy = 0,
    this.rate,
    this.delta,
    this.coveredBy,
  });

  factory FxRevalCandidate.fromJson(Map<String, dynamic> j) {
    final String side = _s(j['side'], 'ar') == 'ap' ? 'ap' : 'ar';
    final int id = _i(j['doc_id']);
    final String k = _s(j['key']);
    final String ref = _s(j['ref']);
    final bool noRate = _b(j['rate_missing']) || j['rate'] == null || j['delta'] == null;
    return FxRevalCandidate(
      key: k.isNotEmpty ? k : '$side:$id',
      side: side,
      docId: id,
      ref: ref.isNotEmpty ? ref : (id > 0 ? '#$id' : ''),
      party: _s(j['party']),
      ccy: _s(j['ccy']).toUpperCase(),
      date: _date(j['date']),
      bookedRate: _d(j['booked_rate']),
      remCcy: _d(j['rem_ccy']),
      rate: noRate ? null : _dn(j['rate']),
      delta: noRate ? null : _i(j['delta']),
      coveredBy: j['covered_by'] == null ? null : _i(j['covered_by']),
    );
  }

  static List<FxRevalCandidate> listFrom(dynamic raw) => _mapList<FxRevalCandidate>(raw, FxRevalCandidate.fromJson);

  bool get rateMissing => delta == null;
  bool get isCovered => coveredBy != null;
  bool get selectable => !isCovered;
  String get sideLabel => fxRevalSideLabel(side);

  /// سود (+) / زیان (−) برای شرکت؛ بدون نرخ ⇒ null.
  int? get effect => delta == null ? null : fxRevalEffect(side, delta!);
}

// ───────────────────────── پیش‌نمایش / نتیجهٔ محاسبه ─────────────────────────

/// خروجی `preview` (و بخش محاسباتی `apply` و `detail` ذخیره‌شده).
class FxRevalPreview {
  final String asOf; // YYYY-MM-DD
  final List<FxRevalItem> items;
  final List<FxRevalDoc> docs;
  final List<FxRevalParty> parties;
  final List<FxRevalRate> rates;
  final int arUp;
  final int arDown;
  final int apUp;
  final int apDown;
  final int docCount;
  final int netDelta;
  final String fingerprint;

  const FxRevalPreview({
    this.asOf = '',
    this.items = const <FxRevalItem>[],
    this.docs = const <FxRevalDoc>[],
    this.parties = const <FxRevalParty>[],
    this.rates = const <FxRevalRate>[],
    this.arUp = 0,
    this.arDown = 0,
    this.apUp = 0,
    this.apDown = 0,
    this.docCount = 0,
    this.netDelta = 0,
    this.fingerprint = '',
  });

  /// `detail` ردیف‌های قدیمی fx_revals یک آرایهٔ items بود؛ این‌جا فقط شکل شیء پشتیبانی می‌شود (قدیمی را FxRevalRecord تبدیل می‌کند).
  factory FxRevalPreview.fromJson(Map<String, dynamic> j) {
    final List<FxRevalDoc> docs = _mapList<FxRevalDoc>(j['docs'], FxRevalDoc.fromJson);
    return FxRevalPreview(
      asOf: _date(j['as_of']),
      items: _mapList<FxRevalItem>(j['items'], FxRevalItem.fromJson),
      docs: docs,
      parties: _mapList<FxRevalParty>(j['parties'], FxRevalParty.fromJson),
      rates: FxRevalRate.listFrom(j['rates']),
      arUp: _i(j['ar_up']),
      arDown: _i(j['ar_down']),
      apUp: _i(j['ap_up']),
      apDown: _i(j['ap_down']),
      docCount: j.containsKey('doc_count') ? _i(j['doc_count']) : docs.length,
      netDelta: _i(j['net_delta']),
      fingerprint: _s(j['fingerprint']),
    );
  }

  DateTime? get asOfDate => _parseDate(asOf);

  /// آیا چیزی برای ثبت هست؟ (سند تسعیر فقط وقتی ساخته می‌شود که حداقل یکی از چهار مبلغ غیرصفر باشد.)
  bool get hasChanges => arUp != 0 || arDown != 0 || apUp != 0 || apDown != 0;

  /// جمع سودها / زیان‌ها (ناخالص بین طرف‌حساب‌ها): سود = بالارفتنِ طلب + پایین‌رفتنِ بدهی.
  int get totalGain => arUp + apDown;
  int get totalLoss => arDown + apUp;

  /// سود خالص تحقق‌نیافته: اول از ریز فاکتورها (طلب delta − بدهی delta)، بعد از items، و در نبود هر دو از ستون‌های up/down.
  int get netGain {
    if (docs.isNotEmpty) return fxRevalNetGainOfDocs(docs);
    if (items.isNotEmpty) {
      int n = 0;
      for (final FxRevalItem it in items) {
        n += it.effect;
      }
      return n;
    }
    return (arUp - arDown) - (apUp - apDown);
  }

  bool get isGain => netGain > 0;
  bool get isLoss => netGain < 0;

  /// گروه‌بندی فاکتورها: ارز×طرف×طرف‌حساب (پیش‌فرض) یا فقط ارز×طرف.
  List<FxRevalDocGroup> groupDocs({bool byParty = true}) => fxRevalGroupDocs(docs, byParty: byParty);

  /// ارزهایی که نرخشان نیست.
  List<String> get missingCcys => <String>[
        for (final FxRevalRate r in rates)
          if (r.missing) r.ccy
      ];

  FxRevalRate? rateOf(String ccy) {
    final String c = ccy.toUpperCase();
    for (final FxRevalRate r in rates) {
      if (r.ccy == c) return r;
    }
    return null;
  }
}

/// پاسخ `apply`: خروجی محاسبه + شناسهٔ سند و وضعیت برگشت خودکار.
class FxRevalApplyResult {
  final int id;
  final String? revDate;
  final String revStatus; // posted | pending
  final String? note;
  final FxRevalPreview preview;

  const FxRevalApplyResult({this.id = 0, this.revDate, this.revStatus = 'none', this.note, this.preview = const FxRevalPreview()});

  factory FxRevalApplyResult.fromJson(Map<String, dynamic> j) => FxRevalApplyResult(
        id: _i(j['id']),
        revDate: _daten(j['rev_date']),
        revStatus: _s(j['rev_status'], 'none'),
        note: _sn(j['note']),
        preview: FxRevalPreview.fromJson(j),
      );

  /// برگشت خودکار هم‌زمان ثبت شد.
  bool get reversalPosted => revStatus == 'posted';

  /// برگشت خودکار منتظر باز شدن سال/دورهٔ تاریخ برگشت است.
  bool get reversalPending => revStatus == 'pending';
}

// ───────────────────────── بررسی پیش از اعمال (check) ─────────────────────────

/// یک مشکل از `check.problems` (کدها: in_future، no_fiscal_year، locked، rate_missing، duplicate، nothing_to_reval).
class FxRevalProblem {
  final String code;
  final String message;
  final List<String> ccys;

  const FxRevalProblem({this.code = '', this.message = '', this.ccys = const <String>[]});

  factory FxRevalProblem.fromJson(Map<String, dynamic> j) => FxRevalProblem(
        code: _s(j['code']),
        message: _s(j['message']),
        ccys: List<String>.unmodifiable(<String>[for (final dynamic c in _l(j['ccys'])) _s(c).toUpperCase()]),
      );
}

class FxRevalCheck {
  final String asOf;
  final List<FxRevalRate> rates;
  final int openDocsAr;
  final int openDocsAp;
  final int? activeRevalId; // تسعیر فعالِ همان تاریخ (null = ندارد)
  final String? activeRevalStatus;
  final bool fiscalOk;
  final String? fiscalName;
  final String? fiscalStatus;
  final bool periodLocked;
  final bool inFuture;
  final int ignoredCheques; // اقساط/چک‌های پرداخت‌نشده که تسویه حساب نمی‌شوند
  final bool canApply;
  final List<FxRevalProblem> problems;

  const FxRevalCheck({
    this.asOf = '',
    this.rates = const <FxRevalRate>[],
    this.openDocsAr = 0,
    this.openDocsAp = 0,
    this.activeRevalId,
    this.activeRevalStatus,
    this.fiscalOk = false,
    this.fiscalName,
    this.fiscalStatus,
    this.periodLocked = false,
    this.inFuture = false,
    this.ignoredCheques = 0,
    this.canApply = false,
    this.problems = const <FxRevalProblem>[],
  });

  factory FxRevalCheck.fromJson(Map<String, dynamic> j) {
    final Map<String, dynamic> open = _m(j['open_docs']);
    final dynamic act = j['has_active_reval'];
    final Map<String, dynamic> actM = _m(act);
    final Map<String, dynamic> fy = _m(j['fiscal']);
    return FxRevalCheck(
      asOf: _date(j['as_of']),
      rates: FxRevalRate.listFrom(j['rates']),
      openDocsAr: _i(open['ar']),
      openDocsAp: _i(open['ap']),
      activeRevalId: actM.isEmpty ? null : _i(actM['id']),
      activeRevalStatus: actM.isEmpty ? null : _sn(actM['status']),
      fiscalOk: _b(fy['ok']),
      fiscalName: _sn(fy['fy_name']),
      fiscalStatus: _sn(fy['status']),
      periodLocked: _b(j['period_locked']),
      inFuture: _b(j['in_future']),
      ignoredCheques: _i(_m(j['ignored_cheques'])['count']),
      canApply: _b(j['can_apply']),
      problems: _mapList<FxRevalProblem>(j['problems'], FxRevalProblem.fromJson),
    );
  }

  DateTime? get asOfDate => _parseDate(asOf);
  int get openDocs => openDocsAr + openDocsAp;
  bool get hasActiveReval => activeRevalId != null;

  bool hasProblem(String code) {
    for (final FxRevalProblem p in problems) {
      if (p.code == code) return true;
    }
    return false;
  }

  FxRevalProblem? problem(String code) {
    for (final FxRevalProblem p in problems) {
      if (p.code == code) return p;
    }
    return null;
  }

  /// همهٔ ارزهای بدون نرخ (از rates و از مشکل rate_missing)، مرتب و یکتا.
  List<String> get missingCcys {
    final Set<String> s = <String>{
      for (final FxRevalRate r in rates)
        if (r.missing) r.ccy,
      ...?problem('rate_missing')?.ccys,
    };
    final List<String> out = s.toList()..sort();
    return List<String>.unmodifiable(out);
  }

  FxRevalRate? rateOf(String ccy) {
    final String c = ccy.toUpperCase();
    for (final FxRevalRate r in rates) {
      if (r.ccy == c) return r;
    }
    return null;
  }
}

// ───────────────────────── ردیف تسعیر (list / detail) ─────────────────────────

/// برچسب وضعیت فارسی. `status`: active|reversed؛ `revStatus`: none|pending|posted|cancelled.
/// توجه: پس از برگشت خودکار `status` همچنان active است (طبق طراحی)، پس rev_status تعیین‌کننده است.
String fxRevalStatusLabel(String status, String revStatus) {
  if (status == 'reversed' || revStatus == 'cancelled') return 'ابطال شده';
  if (revStatus == 'posted') return 'برگشت خودکار شده';
  if (revStatus == 'pending') return 'در انتظار برگشت خودکار';
  if (status == 'active') return 'فعال';
  return status.isEmpty ? 'نامشخص' : status;
}

/// یک ردیف تسعیر ثبت‌شده؛ از `list` (بدون detail) یا `detail` (با snapshot).
class FxRevalRecord {
  final int id;
  final String asOf;
  final String status; // active | reversed
  final String revStatus; // none | pending | posted | cancelled
  final String? revDate;
  final int arUp;
  final int arDown;
  final int apUp;
  final int apDown;
  final int netDelta;
  final int docCount;
  final bool stale; // فقط detail؛ ورودی‌ها پس از اعمال تغییر کرده‌اند
  final String? note;
  final String? createdBy;
  final String? createdAt;
  final String? reversedAt;
  final String? reversedBy;

  /// فقط در `detail`: snapshot ذخیره‌شده. ردیف قدیمی ⇒ فقط items (آرایهٔ قدیمی) یا null.
  final FxRevalPreview? snapshot;

  const FxRevalRecord({
    this.id = 0,
    this.asOf = '',
    this.status = '',
    this.revStatus = 'none',
    this.revDate,
    this.arUp = 0,
    this.arDown = 0,
    this.apUp = 0,
    this.apDown = 0,
    this.netDelta = 0,
    this.docCount = 0,
    this.stale = false,
    this.note,
    this.createdBy,
    this.createdAt,
    this.reversedAt,
    this.reversedBy,
    this.snapshot,
  });

  factory FxRevalRecord.fromJson(Map<String, dynamic> j) {
    final String asOf = _date(j['as_of']);
    final dynamic raw = j['detail'];
    FxRevalPreview? snap;
    if (raw is Map || raw is List) {
      // مبالغ کل از ستون‌های ردیف می‌آید؛ detail فقط items/docs/parties/rates/fingerprint دارد.
      final Map<String, dynamic> merged = <String, dynamic>{
        'as_of': asOf,
        'ar_up': j['ar_up'],
        'ar_down': j['ar_down'],
        'ap_up': j['ap_up'],
        'ap_down': j['ap_down'],
        'net_delta': j['net_delta'],
        if (j.containsKey('doc_count')) 'doc_count': j['doc_count'],
      };
      if (raw is Map) {
        merged.addAll(_m(raw));
      } else {
        merged['items'] = raw; // ردیف قدیمی: آرایهٔ items
      }
      snap = FxRevalPreview.fromJson(merged);
    }
    return FxRevalRecord(
      id: _i(j['id']),
      asOf: asOf,
      status: _s(j['status']),
      revStatus: _s(j['rev_status'], 'none'),
      revDate: _daten(j['rev_date']),
      arUp: _i(j['ar_up']),
      arDown: _i(j['ar_down']),
      apUp: _i(j['ap_up']),
      apDown: _i(j['ap_down']),
      netDelta: _i(j['net_delta']),
      docCount: _i(j['doc_count']),
      stale: _b(j['stale']),
      note: _sn(j['note']),
      createdBy: _sn(j['created_by']),
      createdAt: _sn(j['created_at']),
      reversedAt: _sn(j['reversed_at']),
      reversedBy: _sn(j['reversed_by']),
      snapshot: snap,
    );
  }

  /// فهرست `list` ⇒ `{revals:[...]}`.
  static List<FxRevalRecord> listFrom(dynamic raw) => _mapList<FxRevalRecord>(raw, FxRevalRecord.fromJson);

  DateTime? get asOfDate => _parseDate(asOf);
  DateTime? get revDateTime => _parseDate(revDate);

  String get statusLabel => fxRevalStatusLabel(status, revStatus);

  bool get isActive => status == 'active';
  bool get isPending => revStatus == 'pending';
  bool get isAutoReversed => revStatus == 'posted';
  bool get isCancelled => status == 'reversed' || revStatus == 'cancelled';

  /// هنوز اثر حسابداری دارد (فعال و هنوز برگشت‌نخورده). فقط این ردیف‌ها stale معنا دارند.
  bool get isEffective => isActive && !isAutoReversed && !isCancelled;

  /// ابطال دستی مجاز است؟ (سرور: فعال و rev_status ≠ posted)
  bool get canReverse => isEffective;

  /// سود خالص تحقق‌نیافته: ستون net_delta؛ اگر صفر/ناموجود (ردیف قدیمی) از ستون‌های up/down.
  int get netGain => netDelta != 0 ? netDelta : (arUp - arDown) - (apUp - apDown);
  bool get isGain => netGain > 0;
  bool get isLoss => netGain < 0;

  int get totalGain => arUp + apDown;
  int get totalLoss => arDown + apUp;
}

// ───────────────────────── خروجی Excel/PDF ─────────────────────────

class FxRevalSheet {
  final List<String> headers;
  final List<List<Object?>> rows;

  const FxRevalSheet({this.headers = const <String>[], this.rows = const <List<Object?>>[]});

  factory FxRevalSheet.fromJson(Map<String, dynamic> j) => FxRevalSheet(
        headers: List<String>.unmodifiable(<String>[for (final dynamic h in _l(j['headers'])) _s(h)]),
        rows: List<List<Object?>>.unmodifiable(<List<Object?>>[
          for (final dynamic r in _l(j['rows']))
            if (r is List) List<Object?>.unmodifiable(r)
        ]),
      );
}

class FxRevalExportTotals {
  final int arUp;
  final int arDown;
  final int apUp;
  final int apDown;
  final int gain;
  final int loss;
  final int netDelta;
  final int docCount;

  const FxRevalExportTotals({this.arUp = 0, this.arDown = 0, this.apUp = 0, this.apDown = 0, this.gain = 0, this.loss = 0, this.netDelta = 0, this.docCount = 0});

  factory FxRevalExportTotals.fromJson(Map<String, dynamic> j) => FxRevalExportTotals(
        arUp: _i(j['ar_up']),
        arDown: _i(j['ar_down']),
        apUp: _i(j['ap_up']),
        apDown: _i(j['ap_down']),
        gain: _i(j['gain']),
        loss: _i(j['loss']),
        netDelta: _i(j['net_delta']),
        docCount: _i(j['doc_count']),
      );
}

/// خروجی `export`: صفحهٔ اصلی (یک سطر برای هر ارز) + سه برگهٔ ریز (docs/parties/items). اعداد خام؛ as_of میلادی.
class FxRevalExport {
  final String title;
  final String asOf;
  final List<String> headers;
  final List<List<Object?>> rows;
  final FxRevalExportTotals totals;
  final FxRevalSheet docsSheet;
  final FxRevalSheet partiesSheet;
  final FxRevalSheet itemsSheet;

  /// true ⇒ از پیش‌نمایش (هنوز ثبت نشده) ساخته شده؛ فقط برای پانویس/عنوان خروجی.
  final bool isPreview;

  const FxRevalExport({
    this.title = '',
    this.asOf = '',
    this.headers = const <String>[],
    this.rows = const <List<Object?>>[],
    this.totals = const FxRevalExportTotals(),
    this.docsSheet = const FxRevalSheet(),
    this.partiesSheet = const FxRevalSheet(),
    this.itemsSheet = const FxRevalSheet(),
    this.isPreview = false,
  });

  /// همان ساختار خروجی سرور (`pb_fxr_export_build`) را محلی از پیش‌نمایش جاری می‌سازد (بدون فراخوانی سرور).
  /// ستون‌ها و ترتیب ردیف‌ها عیناً مثل سرور است؛ فقط عنوان و `isPreview` فرق دارد.
  factory FxRevalExport.fromPreview(FxRevalPreview p, {String title = 'گزارش پیش‌نمایش تسعیر ارز'}) {
    double r4(double v) => double.parse(v.toStringAsFixed(4));
    final Map<String, ({double rate, double arOpen, double apOpen, int arDelta, int apDelta})> sum = <String, ({double rate, double arOpen, double apOpen, int arDelta, int apDelta})>{};
    final List<List<Object?>> itemRows = <List<Object?>>[];
    for (final FxRevalItem it in p.items) {
      final String c = it.ccy.trim().toUpperCase();
      itemRows.add(<Object?>[it.sideLabel, c, it.rate, it.openCcy, it.delta]);
      final ({double rate, double arOpen, double apOpen, int arDelta, int apDelta}) x = sum[c] ?? (rate: it.rate, arOpen: 0.0, apOpen: 0.0, arDelta: 0, apDelta: 0);
      sum[c] = it.side == 'ap'
          ? (rate: x.rate, arOpen: x.arOpen, apOpen: r4(x.apOpen + it.openCcy), arDelta: x.arDelta, apDelta: x.apDelta + it.delta)
          : (rate: x.rate, arOpen: r4(x.arOpen + it.openCcy), apOpen: x.apOpen, arDelta: x.arDelta + it.delta, apDelta: x.apDelta);
    }
    final List<String> ccys = sum.keys.toList()..sort();
    final List<List<Object?>> rows = <List<Object?>>[
      for (final String c in ccys) <Object?>[c, sum[c]!.rate, sum[c]!.arOpen, sum[c]!.apOpen, sum[c]!.arDelta, sum[c]!.apDelta, sum[c]!.arDelta - sum[c]!.apDelta],
    ];
    return FxRevalExport(
      title: title,
      asOf: p.asOf,
      headers: const <String>['ارز', 'نرخ تسعیر', 'مانده طلب ارزی', 'مانده بدهی ارزی', 'سود/زیان طلب (ریال)', 'سود/زیان بدهی (ریال)', 'خالص سود/زیان (ریال)'],
      rows: rows,
      totals: FxRevalExportTotals(
        arUp: p.arUp,
        arDown: p.arDown,
        apUp: p.apUp,
        apDown: p.apDown,
        gain: p.totalGain,
        loss: p.totalLoss,
        netDelta: p.netGain,
        docCount: p.docCount > 0 ? p.docCount : p.docs.length,
      ),
      docsSheet: FxRevalSheet(
        headers: const <String>['نوع', 'شمارهٔ سند', 'طرف‌حساب', 'ارز', 'نرخ ثبت‌شده', 'مبلغ ارزی', 'پرداخت‌شده', 'مانده ارزی', 'نرخ تسعیر', 'تفاوت (ریال)'],
        rows: <List<Object?>>[
          for (final FxRevalDoc d in p.docs) <Object?>[d.sideLabel, d.ref, d.party, d.ccy, d.bookedRate, d.totalCcy, d.paidCcy, d.remCcy, d.rate, d.delta],
        ],
      ),
      partiesSheet: FxRevalSheet(
        headers: const <String>['نوع', 'طرف‌حساب', 'افزایش (ریال)', 'کاهش (ریال)', 'سود/زیان خالص (ریال)'],
        rows: <List<Object?>>[
          for (final FxRevalParty q in p.parties) <Object?>[q.sideLabel, q.party, q.up, q.down, q.effect],
        ],
      ),
      itemsSheet: FxRevalSheet(
        headers: const <String>['نوع', 'ارز', 'نرخ تسعیر', 'مانده ارزی', 'تفاوت (ریال)'],
        rows: itemRows,
      ),
      isPreview: true,
    );
  }

  factory FxRevalExport.fromJson(Map<String, dynamic> j) {
    final FxRevalSheet main = FxRevalSheet.fromJson(<String, dynamic>{'headers': j['headers'], 'rows': j['rows']});
    final Map<String, dynamic> sh = _m(j['sheets']);
    return FxRevalExport(
      title: _s(j['title']),
      asOf: _date(j['as_of']),
      headers: main.headers,
      rows: main.rows,
      totals: FxRevalExportTotals.fromJson(_m(j['totals'])),
      docsSheet: FxRevalSheet.fromJson(_m(sh['docs'])),
      partiesSheet: FxRevalSheet.fromJson(_m(sh['parties'])),
      itemsSheet: FxRevalSheet.fromJson(_m(sh['items'])),
    );
  }

  DateTime? get asOfDate => _parseDate(asOf);
  bool get isEmpty => rows.isEmpty && docsSheet.rows.isEmpty;
}

// ───────────────────────── خطا ─────────────────────────

/// خطای لایهٔ API تسعیر. `code` یکی از ثابت‌های `code*` است.
class FxRevalException implements Exception {
  static const String codeRateMissing = 'rate_missing';
  static const String codeEditionRequired = 'edition_required';
  static const String codeForbidden = 'forbidden';
  static const String codeConflict = 'conflict'; // HTTP 409
  static const String codeNetwork = 'network';
  static const String codeServer = 'server'; // هر خطای دیگر (۴۰۰، ۴۰۴، ۵۰۰ …)

  final String code;
  final String message;

  /// فقط برای rate_missing: همهٔ ارزهای بدون نرخ.
  final List<String> ccys;

  /// کد HTTP (۰ = پاسخی نبوده).
  final int httpCode;

  /// زیرکد سرور برای 409/400 در apply: duplicate، locked، in_future، no_fiscal_year، nothing_to_reval.
  final String? reason;

  /// فهرست مشکلات اعتبارسنجی که سرور همراه خطا فرستاده (اگر بود).
  final List<FxRevalProblem> problems;

  const FxRevalException(this.code, this.message, {this.ccys = const <String>[], this.httpCode = 0, this.reason, this.problems = const <FxRevalProblem>[]});

  /// ترجمهٔ پاسخ خطای StockApi (message = متن آمادهٔ نمایش، data = بدنهٔ JSON خطا در صورت وجود).
  factory FxRevalException.fromResponse({required String message, int httpCode = 0, bool network = false, Map<String, dynamic>? data}) {
    if (network) {
      return FxRevalException(codeNetwork, message.isEmpty ? 'اتصال به سرور برقرار نشد. اینترنت را بررسی کنید.' : message, httpCode: httpCode);
    }
    final Map<String, dynamic> d = data ?? const <String, dynamic>{};
    final String err = _s(d['error']);
    final String dataMsg = _s(d['message']);
    final String shown = dataMsg.isNotEmpty ? dataMsg : message;
    final String? reason = _sn(d['code']);
    final List<FxRevalProblem> problems = _mapList<FxRevalProblem>(d['problems'], FxRevalProblem.fromJson);

    if (err == 'rate_missing') {
      final List<String> ccys = <String>[for (final dynamic c in _l(d['ccys'])) _s(c).toUpperCase()];
      if (ccys.isEmpty && _s(d['ccy']).isNotEmpty) ccys.add(_s(d['ccy']).toUpperCase());
      return FxRevalException(codeRateMissing, shown.isEmpty ? 'نرخ ارز برای تاریخ تسعیر ثبت نشده است' : shown,
          ccys: List<String>.unmodifiable(ccys), httpCode: httpCode, reason: 'rate_missing', problems: problems);
    }
    if (err == 'edition_required') {
      return FxRevalException(codeEditionRequired, 'تسعیر ارز فقط در نسخهٔ طلایی-ارزی در دسترس است', httpCode: httpCode);
    }
    if (httpCode == 403) {
      return FxRevalException(codeForbidden, shown.isEmpty || shown == 'forbidden' ? 'دسترسی لازم را ندارید' : shown, httpCode: httpCode);
    }
    if (httpCode == 409) {
      return FxRevalException(codeConflict, shown.isEmpty ? 'عملیات با وضعیت فعلی سازگار نیست' : shown, httpCode: httpCode, reason: reason, problems: problems);
    }
    return FxRevalException(codeServer, shown.isEmpty ? 'خطای ناشناخته' : shown, httpCode: httpCode, reason: reason, problems: problems);
  }

  bool get isNetwork => code == codeNetwork;
  bool get isRateMissing => code == codeRateMissing;
  bool get isConflict => code == codeConflict;

  @override
  String toString() => message;
}
