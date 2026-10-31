import 'broker_ui.dart' show BrokerProfitCard;
import 'returns_ui.dart' show ReturnsProfitCard;
import 'package:flutter/material.dart';

import 'charts.dart';
import 'db.dart';
import 'fx_profit.dart' show FxProfitBlock, FxRateBook;
import 'live_query.dart';
import 'license_service.dart';
import 'perms.dart';
import 'profit_lock.dart';
import 'pdf_output.dart';
import 'pdf_service.dart';
import 'fmt.dart' show Fmt;
import 'utils.dart';
import 'widgets.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  DateTime? _from;
  DateTime? _to;
  String _q = ''; // جستجوی کد پسته در گزارش سود
  String? _chartCcy; // S30.T30.6: ارز نمودار سود و زیان؛ null = ریال (پیش‌فرض)
  FxRateBook? _book; // نرخ‌های ثبت‌شدهٔ ارزها (فقط پلن ارزی)
  bool _lockChecked = false; // قفل صفحهٔ سود و زیان
  bool _unlocked = false;

  @override
  void initState() {
    super.initState();
    _checkLock();
    if (LicenseService.I.isFx.value) {
      FxRateBook.load().then((b) {
        if (mounted) setState(() => _book = b);
      }).catchError((_) {});
    }
  }

  @override
  void dispose() {
    ProfitLock.I.lockNow(); // با خروج از صفحه، دفعهٔ بعد دوباره رمز می‌خواهد (حریم خصوصی)
    super.dispose();
  }

  Future<void> _checkLock() async {
    final enabled = await ProfitLock.I.isEnabled();
    if (!mounted) return;
    setState(() {
      _lockChecked = true;
      _unlocked = !enabled || ProfitLock.I.recentlyUnlocked;
    });
  }
  int _chartMode = 0; // 0 = میله‌ای (سود در طول زمان) | 1 = کروی (سهم هر نوع پسته از سود)

  /// بازهٔ مؤثر گزارش سود: اگر کاربر تاریخی انتخاب نکرده باشد، ماه جاری شمسی
  (DateTime?, DateTime?) _effectiveRange() {
    if (_from != null || _to != null) return (_from, _to);
    final now = DateTime.now();
    final j = gregorianToJalali(now.year, now.month, now.day);
    return (jalaliToGregorian(j[0], j[1], 1), jalaliToGregorian(j[0], j[1], daysInJalaliMonth(j[0], j[1])));
  }

  String _profitPeriodLabel() {
    final r = _effectiveRange();
    final f = r.$1 == null ? '...' : jalaliDateFromDt(r.$1!);
    final t = r.$2 == null ? '...' : jalaliDateFromDt(r.$2!);
    return '${(_from == null && _to == null) ? 'ماه جاری' : 'بازهٔ انتخابی'}: از $f تا $t';
  }

  String _periodLabel() {
    if (_from == null && _to == null) return 'همه‌ی بازه‌ها';
    final f = _from == null ? '...' : jalaliDateFromDt(_from!);
    final t = _to == null ? '...' : jalaliDateFromDt(_to!);
    return 'از $f تا $t';
  }

  Future<void> _exportGlobal({required bool isPayments}) async {
    try {
      final rows = isPayments
          ? await AppDb.I.allPaymentTransactions(from: _from, to: _to)
          : await AppDb.I.allReceiptTransactions(from: _from, to: _to);
      final total = rows.fold<double>(0, (s, r) => s + (r['amount'] as num).toDouble());
      final table = <List<String>>[
        ['وضعیت', 'نوع', 'کد پسته', 'تاریخ', 'مبلغ (ریال)', isPayments ? 'فروشنده' : 'خریدار'],
        for (final r in rows)
          [
            (r['paid'] as int) == 1 ? 'تسویه‌شده' : 'باقیمانده',
            r['kind'] as String,
            '${r['code'] ?? '-'}',
            jalaliDate(r['date'] as String),
            Fmt.money(r['amount'] as num, label: false),
            '${r['name'] ?? '-'}',
          ],
      ];
      final file = await PdfService.buildGlobalReport(
        title: isPayments ? 'گزارش کلی تراکنش‌های پرداخت' : 'گزارش کلی تراکنش‌های دریافت وجه',
        periodLabel: _periodLabel(),
        grandTotal: total,
        tableRows: table,
      );
      await PdfOutput.show(context, file);
    } catch (e) {
      if (mounted) snack(context, 'خطا در ساخت PDF: $e');
    }
  }

  /// کارت نمودار سود و زیان: سود (سبز) و زیان (قرمز) جدا از هم نشان داده می‌شوند
  Widget _chartCard(BuildContext context, List<TimeBucket> buckets, List<double> gainsT, List<double> lossesT,
      Map<String, double> byTypeT,
      {({List<double> gains, List<double> losses, Map<String, double> byType})? usdData}) {
    // پلن ارزی: کاربر می‌تواند نمودار را به دلار ببیند (سود/زیان دلاری فروش‌هایی که قیمت دلار و فی دلاریِ خرید دارند)
    final useUsd = usdData != null && _chartCcy != null;
    final cc = _chartCcy ?? '';
    final gains = useUsd ? usdData!.gains : gainsT;
    final losses = useUsd ? usdData!.losses : lossesT;
    final byType = useUsd ? usdData!.byType : byTypeT;
    String fmtFull(double v) => useUsd ? '${faCompactCcy(v)} $cc' : '${faCompactMoney(v)} ${Fmt.unitLabel()}';
    String fmtShort(double v) => useUsd ? faCompactCcy(v) : faCompactMoney(v);
    final groups = <BarGroup>[
      for (var i = 0; i < buckets.length; i++)
        BarGroup(buckets[i].label, buckets[i].fullLabel, [gains[i], losses[i]]),
    ];
    final hasBarData = gains.any((v) => v != 0) || losses.any((v) => v != 0);
    const greens = [Color(0xFF2E7D32), Color(0xFF43A047), Color(0xFF66BB6A), Color(0xFF81C784), Color(0xFFA5D6A7)];
    const reds = [Color(0xFFC62828), Color(0xFFE53935), Color(0xFFEF5350), Color(0xFFE57373), Color(0xFFEF9A9A)];
    final slices = <ChartSlice>[];
    final pos = byType.entries.where((e) => e.value > 0).toList()..sort((a, b) => b.value.compareTo(a.value));
    final neg = byType.entries.where((e) => e.value < 0).toList()..sort((a, b) => a.value.compareTo(b.value));
    for (var i = 0; i < pos.length; i++) {
      slices.add(ChartSlice(pos[i].key, pos[i].value, greens[i < greens.length ? i : greens.length - 1]));
    }
    for (var i = 0; i < neg.length; i++) {
      slices.add(ChartSlice(neg[i].key, -neg[i].value, reds[i < reds.length ? i : reds.length - 1], negative: true));
    }
    final net = byType.values.fold<double>(0, (a, v) => a + v);
    final Widget body;
    if (_chartMode == 0) {
      body = hasBarData
          ? GroupedBarChart(
              groups: groups,
              series: const [BarSeries('سود', kGainColor), BarSeries('زیان', kLossColor)],
              format: fmtFull,
              compact: fmtShort,
            )
          : ChartEmpty(useUsd
              ? 'برای فروش‌های این بازه نرخ ثبت‌شدهٔ $cc در جدول نرخ نیست'
              : 'در این بازه سود یا زیانی ثبت نشده');
    } else {
      body = slices.isEmpty
          ? ChartEmpty(useUsd
              ? 'برای فروش‌های این بازه نرخ ثبت‌شدهٔ $cc در جدول نرخ نیست'
              : 'در این بازه سود یا زیانی ثبت نشده')
          : Center(
              child: DonutChart(
                slices: slices,
                centerTitle: net >= 0 ? 'خالص سود' : 'خالص زیان',
                centerValue: net,
                format: fmtShort,
              ),
            );
    }
    return ChartCard(
      title: useUsd ? 'نمودار سود و زیان ($cc)' : 'نمودار سود و زیان',
      subtitle: _profitPeriodLabel(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (usdData != null) ...[
          SegmentedButton<String>(
            segments: <ButtonSegment<String>>[
              const ButtonSegment<String>(value: '', label: Text('ریال')),
              for (final c in _book?.codes ?? const <String>[]) ButtonSegment<String>(value: c, label: Text(c)),
            ],
            selected: <String>{_chartCcy ?? ''},
            showSelectedIcon: false,
            onSelectionChanged: (v) => setState(() => _chartCcy = v.first.isEmpty ? null : v.first),
          ),
          const SizedBox(height: 8),
        ],
        SegmentedButton<int>(
          segments: const <ButtonSegment<int>>[
            ButtonSegment<int>(value: 0, label: Text('میله‌ای'), icon: Icon(Icons.bar_chart)),
            ButtonSegment<int>(value: 1, label: Text('کروی'), icon: Icon(Icons.donut_large)),
          ],
          selected: <int>{_chartMode},
          showSelectedIcon: false,
          onSelectionChanged: (v) => setState(() => _chartMode = v.first),
        ),
        const SizedBox(height: 14),
        body,
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!StaffPerms.I.can('profit.view')) {
      // T02.2: کارکنی که مجوز سود ندارد اصلاً رقم سود را نمی‌بیند
      return Scaffold(
        appBar: AppBar(title: const Text('گزارش سود و زیان')),
        body: const Center(child: Text('دسترسی مشاهدهٔ سود و زیان را ندارید')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('گزارش سود و زیان'),
        actions: [
          IconButton(
            tooltip: 'قفل صفحهٔ سود و زیان',
            icon: Icon(_unlocked && _lockChecked ? Icons.lock_open_outlined : Icons.lock_outline),
            onPressed: !_unlocked
                ? null
                : () async {
                    await showProfitLockSettings(context);
                    if (mounted) setState(() {});
                  },
          ),
        ],
      ),
      body: !_lockChecked
          ? const Center(child: CircularProgressIndicator())
          : !_unlocked
              ? ProfitLockPad(onUnlocked: () => setState(() => _unlocked = true))
              : LiveQuery<List<Map<String, dynamic>>>(
        load: AppDb.I.sales,
        builder: (context, s) {
            if (!s.hasData) return const Center(child: CircularProgressIndicator());
            final scheme = Theme.of(context).colorScheme;
            final all = s.data!;
            if (all.isEmpty) return const Center(child: Text('هنوز فروشی ثبت نشده'));
            final range = _effectiveRange();
            final q = toEnDigits(_q).trim().toLowerCase();
            final list = all.where((sale) {
              final dt = DateTime.parse(sale['date'] as String);
              if (range.$1 != null && dt.isBefore(range.$1!)) return false;
              if (range.$2 != null && !dt.isBefore(range.$2!.add(const Duration(days: 1)))) return false;
              if (q.isNotEmpty) {
                final codes = (sale['items'] as List).map((it) => '${it['code'] ?? ''}'.toLowerCase());
                if (!codes.any((c) => c.contains(q))) return false;
              }
              return true;
            }).toList();

            // ---- داده‌ی نمودار: سود و زیانِ هر روز (بازه تا ۳۱ روز) یا هر ماه شمسی، جدا از هم ----
            DateTime? cFrom = range.$1;
            DateTime? cTo = range.$2;
            if (list.isNotEmpty) {
              DateTime dtOf(Map<String, dynamic> x) => DateTime.parse(x['date'] as String);
              cFrom ??= list.map(dtOf).reduce((a, b) => a.isBefore(b) ? a : b);
              cTo ??= list.map(dtOf).reduce((a, b) => a.isAfter(b) ? a : b);
            }
            final buckets = (cFrom != null && cTo != null) ? buildBuckets(cFrom, cTo) : <TimeBucket>[];
            final bucketTypes = List<Map<String, double>>.generate(buckets.length, (_) => <String, double>{});
            // نمودار دلاری (فقط پلن ارزی): همان منطق، با سود دلاری هر قلم
            final fxChart = LicenseService.I.isFx.value && _book != null && _book!.codes.isNotEmpty;
            final bucketTypesUsd = List<Map<String, double>>.generate(buckets.length, (_) => <String, double>{});
            final byTypeUsd = <String, double>{};

            double totalRevenue = 0, totalCost = 0;
            final fx = LicenseService.I.isFx.value;
            double usdRevenue = 0, usdCost = 0;
            var usdMissing = 0; // فروش‌هایی که سود دلاری‌شان قابل محاسبه نیست
            final Map<String, double> byType = {}; // "دسته - نوع" -> سود
            final rows = <Widget>[];
            for (final sale in list) {
              final items = sale['items'] as List;
              final sdIso = '${sale['date']}';
              final double? rSale = (fxChart && _chartCcy != null) ? _book!.rateOf(_chartCcy!, sdIso) : null; // null = نرخ ثبت‌شده نیست
              for (final it in items) {
                // قلم‌های مخلوط/جداسازی بر اساس «نوع زیردسته»شان حساب می‌شوند
                final baseT = (it['base_type'] as String?)?.trim() ?? '';
                final key = '${it['category_name']} - ${baseT.isNotEmpty ? baseT : it['type_name']}';
                final w = (it['weight'] as num).toDouble();
                final rev = w * (sale['price'] as num).toDouble();
                final extraCost = w * purchaseExtraPerKg(it as Map<String, dynamic>) + saleExtraShare(sale, it);
                final cost = w * (it['cost_price'] as num).toDouble() + extraCost;
                byType[key] = (byType[key] ?? 0) + (rev - cost);
                final sdt = DateTime.parse(sale['date'] as String);
                // S30.T30.6: ارزش‌گذاری فقط با جدول نرخ — درآمد و هزینهٔ جانبیِ فروش با نرخ روز فروش، بهای قلم و هزینهٔ جانبیِ خرید با نرخ روز خرید
                final pdIso = ((it['purchase_date'] as String?)?.trim().isNotEmpty == true) ? it['purchase_date'] as String : sdIso;
                final double? rBuy = (fxChart && _chartCcy != null) ? _book!.rateOf(_chartCcy!, pdIso) : null;
                final double? profitU = (rSale != null && rBuy != null)
                    ? rev / rSale - (w * (it['cost_price'] as num).toDouble() + w * purchaseExtraPerKg(it)) / rBuy - saleExtraShare(sale, it) / rSale
                    : null;
                if (profitU != null) byTypeUsd[key] = (byTypeUsd[key] ?? 0) + profitU;
                for (var bi = 0; bi < buckets.length; bi++) {
                  if (buckets[bi].contains(sdt)) {
                    bucketTypes[bi][key] = (bucketTypes[bi][key] ?? 0) + (rev - cost);
                    if (profitU != null) bucketTypesUsd[bi][key] = (bucketTypesUsd[bi][key] ?? 0) + profitU;
                    break;
                  }
                }
              }
              final net = (sale['net_weight'] as num).toDouble();
              final price = (sale['price'] as num).toDouble();
              final revenue = net * price;
              final cost = saleItemsCost(sale) + saleExtraCosts(sale); // بهای خرید + هزینه‌های کارگر و حمل‌ونقل/باسکول
              final profit = revenue - cost;
              totalRevenue += revenue;
              totalCost += cost;
              final usd = fx ? saleUsd(sale) : null;
              if (fx) {
                if (usd == null) {
                  usdMissing++;
                } else {
                  usdRevenue += usd.revenue;
                  usdCost += usd.cost;
                }
              }
              final comp = items
                  .map((it) => '${it['type_name']}${it['code'] != null ? ' (کد ${it['code']})' : ''} ${faNum(it['weight'] as num)}')
                  .join(' + ');
              rows.add(Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${jalaliDate(sale['date'] as String)}'
                        '${sale['buyer'] != null ? '  •  ${sale['buyer']}' : ''}',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text(comp),
                      const SizedBox(height: 8),
                      infoRow('مبلغ فروش', '${Fmt.money(revenue)}'),
                      infoRow('بهای خرید و هزینه‌ها', '${Fmt.money(cost)}'),
                      if (saleExtraCosts(sale) > 0)
                        infoRow('هزینه‌های ثبت‌شده در فروش (کارگر / حمل‌ونقل)', '${Fmt.money(saleExtraCosts(sale))}'),
                      infoRow('سود / زیان', '${Fmt.money(profit)}'),
                      if (fx && usd != null) ...[
                        infoRow('مبلغ فروش (دلار)', faUsd(usd.revenue)),
                        infoRow('بهای خرید و هزینه‌ها (دلار)', faUsd(usd.cost)),
                        infoRow('سود / زیان دلاری', faUsd(usd.profit),
                            valueColor: usd.profit >= 0 ? Colors.green.shade800 : scheme.error),
                      ] else if (fx)
                        const Text('سود دلاری: قیمت دلار یا فی دلاریِ خرید ثبت نشده',
                            style: TextStyle(fontSize: 12, color: Colors.black54)),
                    ],
                  ),
                ),
              ));
            }

            final totalProfit = totalRevenue - totalCost;
            final bucketGain = <double>[];
            final bucketLoss = <double>[]; // منفی
            for (final m in bucketTypes) {
              double g = 0, l = 0;
              for (final v in m.values) {
                if (v > 0) g += v;
                if (v < 0) l += v;
              }
              bucketGain.add(g);
              bucketLoss.add(l);
            }
            final bucketGainUsd = <double>[];
            final bucketLossUsd = <double>[];
            for (final m in bucketTypesUsd) {
              double g = 0, l = 0;
              for (final v in m.values) {
                if (v > 0) g += v;
                if (v < 0) l += v;
              }
              bucketGainUsd.add(g);
              bucketLossUsd.add(l);
            }
            double totalGain = 0, totalLoss = 0; // جمعِ نوع‌های سودده / زیان‌ده (منفی)
            for (final v in byType.values) {
              if (v > 0) totalGain += v;
              if (v < 0) totalLoss += v;
            }

            return ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(_profitPeriodLabel(), style: Theme.of(context).textTheme.bodySmall),
                ),
                TextField(
                  decoration: const InputDecoration(
                    labelText: 'جستجو با کد پسته (مثلاً KH00012)',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) => setState(() => _q = v),
                ),
                const SizedBox(height: 8),
                Card(
                  color: totalProfit >= 0
                      ? Theme.of(context).colorScheme.primaryContainer
                      : Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(children: [
                      infoRow('مجموع فروش', '${Fmt.money(totalRevenue)}'),
                      infoRow('مجموع بهای خرید و هزینه‌ها', '${Fmt.money(totalCost)}'),
                      if (totalGain > 0)
                        infoRow('مجموع سود اجناس سودده', '${Fmt.money(totalGain)}', valueColor: kGainColor),
                      if (totalLoss < 0)
                        infoRow('مجموع زیان اجناس زیان‌ده', '${Fmt.money(-totalLoss)}', valueColor: kLossColor),
                      infoRow(totalProfit >= 0 ? 'خالص سود' : 'خالص زیان', '${Fmt.money(totalProfit.abs())}',
                          valueColor: totalProfit >= 0 ? kGainColor : kLossColor),
                      if (fx) ...[
                        const Divider(),
                        infoRow('مجموع فروش (دلار)', faUsd(usdRevenue)),
                        infoRow('مجموع بهای خرید و هزینه‌ها (دلار)', faUsd(usdCost)),
                        infoRow('مجموع سود / زیان دلاری', faUsd(usdRevenue - usdCost),
                            valueColor: (usdRevenue - usdCost) >= 0 ? Colors.green.shade800 : scheme.error),
                        if (usdMissing > 0)
                          Text('${Fmt.money(usdMissing, label: false)} فروش به‌دلیل نبودنِ قیمت دلار یا فی دلاریِ خرید در جمع دلاری نیامده است',
                              style: const TextStyle(fontSize: 12, color: Colors.black54)),
                        FxProfitBlock(sales: list), // S30.T30.5: سود هر ارز از جدول نرخ ثبت‌شده
                      ],
                    ]),
                  ),
                ),
                const SizedBox(height: 12),
                ReturnsProfitCard(range: _effectiveRange(), profit: totalProfit), // S04.T04.4
                BrokerProfitCard(range: _effectiveRange(), profit: totalProfit), // S05.T05.2
                _chartCard(context, buckets, bucketGain, bucketLoss, byType,
                    usdData: fxChart ? (gains: bucketGainUsd, losses: bucketLossUsd, byType: byTypeUsd) : null),
                if (byType.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        sectionTitle(context, 'سود به تفکیک نوع پسته (بازهٔ انتخاب‌شده)'),
                        for (final e in (byType.entries.toList()
                          ..sort((a, b) => b.value.compareTo(a.value))))
                          infoRow(e.key, '${Fmt.money(e.value)}',
                              valueColor: e.value >= 0 ? Colors.green.shade800 : scheme.error),
                      ]),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      sectionTitle(context, 'بازهٔ گزارش و خروجی PDF تراکنش‌ها'),
                      Row(children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () async {
                              final d = await pickDate(context, initial: _from ?? DateTime.now());
                              if (d != null) setState(() => _from = d);
                            },
                            child: Text('از: ${_from == null ? '—' : jalaliDateFromDt(_from!)}'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () async {
                              final d = await pickDate(context, initial: _to ?? DateTime.now());
                              if (d != null) setState(() => _to = d);
                            },
                            child: Text('تا: ${_to == null ? '—' : jalaliDateFromDt(_to!)}'),
                          ),
                        ),
                        if (_from != null || _to != null)
                          IconButton(
                            onPressed: () => setState(() {
                              _from = null;
                              _to = null;
                            }),
                            icon: const Icon(Icons.close),
                            tooltip: 'حذف فیلتر بازه',
                          ),
                      ]),
                      const SizedBox(height: 8),
                      FilledButton.tonalIcon(
                        onPressed: () => _exportGlobal(isPayments: true),
                        icon: const Icon(Icons.picture_as_pdf_outlined),
                        label: const Text('گزارش کلی تراکنش‌های پرداخت (خرید)'),
                      ),
                      const SizedBox(height: 8),
                      FilledButton.tonalIcon(
                        onPressed: () => _exportGlobal(isPayments: false),
                        icon: const Icon(Icons.picture_as_pdf_outlined),
                        label: const Text('گزارش کلی تراکنش‌های دریافت (فروش)'),
                      ),
                    ]),
                  ),
                ),
                const SizedBox(height: 8),
                ...rows,
              ],
            );
          },
      ),
    );
  }
}
