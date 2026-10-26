import 'package:flutter/material.dart';

import 'barcode_utils.dart';
import 'charts.dart';
import 'consignment_ui.dart';
import 'db.dart';
import 'live_query.dart';
import 'mix_form.dart';
import 'orchard_ui.dart';
import 'pdf_output.dart';
import 'pdf_service.dart';
import 'processing_ui.dart';
import 'separation_form.dart';
import 'stock_reports_screen.dart';
import 'utils.dart';
import 'warehouse_ui.dart';
import 'widgets.dart';

/// یکسان‌سازی «ي/ك» عربی و «ی/ک» فارسی برای جستجو
String _norm(String s) => toEnDigits(s.replaceAll('ي', 'ی').replaceAll('ك', 'ک')).trim().toLowerCase();

class InventoryScreen extends StatefulWidget {
  const InventoryScreen({super.key});
  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends State<InventoryScreen> {
  String _query = '';
  bool _showSold = false; // false = موجود | true = فروش رفته (مثل وب)
  bool _showMixed = false; // false = پسته‌های خریداری‌شده | true = مخلوط/جداسازی (ساخته‌شده از انبار خودمان)

  Future<void> _showMixDetails(BuildContext context, Map<String, dynamic> l) async {
    final sources = await AppDb.I.mixSourcesOf(l['id'] as int);
    final rem = (l['remaining'] as num).toDouble();
    final net = (l['net_weight'] as num).toDouble();
    final canUndo = rem >= net - 1e-6; // یعنی هنوز چیزی از این مخلوط فروخته نشده
    if (!context.mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${l['category_name']} - ${l['type_name']}',
                  style: Theme.of(ctx).textTheme.titleMedium),
                infoRow('کد پسته', l['code'] as String? ?? '-'),
              BarcodeBox(l['code'] as String? ?? ''),
              const SizedBox(height: 4),
              const Text('اجناس مصرف‌شده در این مخلوط/جداسازی:',
                  style: TextStyle(color: Colors.black54)),
              const SizedBox(height: 8),
              for (final s in sources)
                Card(
                  child: ListTile(
                    dense: true,
                    title: Text('${s['category_name']} - ${s['type_name']}'),
                    subtitle: Text('کد ${s['code'] ?? '-'}  •  ${faNum(s['weight'] as num)} کیلو (خالص)  •  '
                        '${jalaliDate(s['source_date'] as String)}'
                        '${(((s['small_sacks'] as num?) ?? 0) > 0 || ((s['large_sacks'] as num?) ?? 0) > 0) ? '\nگونی مصرفی: کوچک ${faNum((s['small_sacks'] as num?) ?? 0)} / بزرگ ${faNum((s['large_sacks'] as num?) ?? 0)}' : ''}'),
                    isThreeLine: ((s['small_sacks'] as num?) ?? 0) > 0 || ((s['large_sacks'] as num?) ?? 0) > 0,
                  ),
                ),
              const SizedBox(height: 8),
              infoRow('وزن این قلم (خالص)', '${faNum(net)} کیلو'),
              if (l['waste'] != null && (l['waste'] as num) > 0)
                infoRow('ضایعات/خاک', '${faNum(l['waste'] as num)} کیلو'),
              infoRow('مانده فعلی (خالص)', '${faNum(rem)} کیلو'),
              infoRow('گونی کوچک مانده', faNum((l['small_left'] as num?) ?? 0)),
              infoRow('گونی بزرگ مانده', faNum((l['large_left'] as num?) ?? 0)),
              if (l['ounce'] != null) infoRow('انس', faNum(l['ounce'] as num)),
              if (l['gram'] != null) infoRow('گرم', faNum(l['gram'] as num)),
              if (l['note'] != null && (l['note'] as String).isNotEmpty)
                infoRow('توضیحات', l['note'] as String),
              const SizedBox(height: 12),
              if (canUndo)
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    Navigator.push(context,
                        MaterialPageRoute(builder: (_) => MixForm(existing: l)));
                  },
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('ویرایش مخلوط/جداسازی'),
                ),
              OutlinedButton.icon(
                onPressed: () async {
                  final file = await PdfService.buildStockCard(
                    code: l['code'] as String? ?? '-',
                    totalWeight: (l['total_weight'] as num).toDouble(),
                    netWeight: net,
                    smallSacks: (l['small_sack_count'] as num).toDouble(),
                    largeSacks: (l['large_sack_count'] as num).toDouble(),
                  );
                  await PdfOutput.show(context, file);
                },
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: const Text('دریافت کارتکس A6'),
              ),
              if (canUndo)
                OutlinedButton.icon(
                  onPressed: () async {
                    final ok = await confirm(ctx,
                        'این مخلوط/جداسازی حذف شود و وزن/گونیِ برداشته‌شده به بارهای مبدأ برگردد؟');
                    if (!ok) return;
                    final done = await AppDb.I.deleteMix(l['id'] as int);
                    if (ctx.mounted) {
                      Navigator.pop(ctx);
                      if (!done) {
                        snack(context, 'از این مخلوط/جداسازی فروش انجام شده؛ حذف امکان‌پذیر نیست');
                      }
                    }
                  },
                  icon: const Icon(Icons.undo),
                  label: const Text('حذف مخلوط/جداسازی و بازگرداندن به انبار'),
                )
              else
                const Text('چون بخشی از این قلم فروخته شده، دیگر قابل حذف نیست.',
                    style: TextStyle(color: Colors.black54)),
            ],
          ),
        ),
      ),
    );
  }

  /// نمودار کروی «تفکیک موجودی خالص بر اساس نوع پسته»؛ قلم‌های مخلوط/جداسازی بر اساس «نوع زیردسته»شان حساب می‌شوند
  Widget _stockChart(BuildContext context, List<Map<String, dynamic>> items) {
    final data = <String, double>{};
    for (final l in items) {
      final rem = (l['remaining'] as num).toDouble();
      if (rem <= 1e-6) continue;
      final base = (l['base_type'] as String?)?.trim() ?? '';
      final key = base.isNotEmpty ? base : '${l['type_name']}';
      data[key] = (data[key] ?? 0) + rem;
    }
    return ChartCard(
      title: 'تفکیک موجودی بر اساس نوع پسته',
      subtitle: '${_showMixed ? 'مخلوط / جداسازی' : 'خریداری‌شده'} • وزن (خالص)',
      child: data.isEmpty
          ? const ChartEmpty('موجودی‌ای برای نمایش نیست')
          : Center(
              child: DonutChart(
                slices: topSlices(data, maxSlices: 5),
                centerTitle: 'جمع موجودی (خالص)',
                format: (v) => '${faNum(v)} کیلو',
              ),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('موجودی انبار'),
        actions: <Widget>[
          IconButton(
            tooltip: 'جداسازی چندخروجی و ردیابی',
            icon: const Icon(Icons.call_split),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const SeparationsScreen()),
            ),
          ),
          IconButton(
            tooltip: 'باغ‌ها و عملکرد',
            icon: const Icon(Icons.park_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const OrchardsScreen()),
            ),
          ),
          IconButton(
            tooltip: 'فراوری (برون‌سپاری و امانی)',
            icon: const Icon(Icons.precision_manufacturing_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const ProcessingScreen()),
            ),
          ),
          IconButton(
            tooltip: 'امانی (دریافتی و ارسالی)',
            icon: const Icon(Icons.swap_horiz),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const ConsignmentsScreen()),
            ),
          ),
          IconButton(
            tooltip: 'گزارش‌های انبار',
            icon: const Icon(Icons.assessment_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const StockReportsScreen()),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () =>
            Navigator.push(context, MaterialPageRoute(builder: (_) => const MixForm())),
        icon: const Icon(Icons.merge_type),
        label: const Text('مخلوط / جداسازی'),
      ),
      body: LiveQuery<List<Map<String, dynamic>>>(
        tab: 3,
        load: AppDb.I.inventoryAll,
        builder: (context, s) {
            if (!s.hasData) return const Center(child: CircularProgressIndicator());
            final all = s.data!;
            if (all.isEmpty) return const Center(child: Text('انبار خالی است'));

            // انبار دو دسته است: پسته‌های خریداری‌شده | مخلوط/جداسازی‌شده (ساخته‌شده از انبار خودمان)
            bool isMixRow(Map<String, dynamic> p) => ((p['is_mix'] as num?) ?? 0) >= 1; // 1 = mix, 2 = separation output (S07)
            final boughtAll = all.where((p) => !isMixRow(p)).toList();
            final mixedAll = all.where(isMixRow).toList();
            final kindItems = _showMixed ? mixedAll : boughtAll;
            final otherKindItems = _showMixed ? boughtAll : mixedAll;

            // «موجود» مثل وب: هنوز وزنی از خودش مانده، یا مقداری از آن داخل مخلوطِ فروش‌نرفته است
            final available = kindItems.where(AppDb.isAvailable).toList();
            final soldOut = kindItems.where((p) => !AppDb.isAvailable(p)).toList();
            final q = _norm(_query);
            bool match(Map<String, dynamic> p) =>
                q.isEmpty ||
                _norm('${p['code']} ${p['category_name']} ${p['type_name']}').contains(q);
            final base = _showSold ? soldOut : available;
            final other = _showSold ? available : soldOut;
            final lots = base.where(match).toList();

            final totalWaste = mixedAll.fold<double>(0, (a, p) => a + ((p['waste'] as num?) ?? 0).toDouble());
            final children = <Widget>[
              SegmentedButton<bool>(
                segments: <ButtonSegment<bool>>[
                  ButtonSegment<bool>(
                      value: false,
                      label: Text('خریداری‌شده (${faNum(boughtAll.where(AppDb.isAvailable).length, dec: 0)})')),
                  ButtonSegment<bool>(
                      value: true,
                      label: Text('مخلوط/جداسازی (${faNum(mixedAll.where(AppDb.isAvailable).length, dec: 0)})')),
                ],
                selected: <bool>{_showMixed},
                showSelectedIcon: false,
                onSelectionChanged: (v) => setState(() => _showMixed = v.first),
              ),
              const SizedBox(height: 8),
              SegmentedButton<bool>(
                segments: <ButtonSegment<bool>>[
                  ButtonSegment<bool>(
                      value: false, label: Text('موجود (${faNum(available.length, dec: 0)})')),
                  ButtonSegment<bool>(
                      value: true, label: Text('فروش رفته (${faNum(soldOut.length, dec: 0)})')),
                ],
                selected: <bool>{_showSold},
                showSelectedIcon: false,
                onSelectionChanged: (v) => setState(() => _showSold = v.first),
              ),
              const SizedBox(height: 8),
            ];

            if (!_showSold) {
              double totalKg = 0, totalValue = 0, totalSmall = 0, totalLarge = 0;
              for (final l in available) {
                final rem = (l['remaining'] as num).toDouble();
                totalKg += rem;
                totalValue += rem * (l['price'] as num).toDouble();
                totalSmall += (l['small_left'] as num).toDouble();
                totalLarge += (l['large_left'] as num).toDouble();
              }
              children.add(Card(
                color: Theme.of(context).colorScheme.primaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(children: [
                    infoRow('مجموع موجودی (خالص)', '${faNum(totalKg)} کیلو'),
                    infoRow('ارزش خرید موجودی', '${faNum(totalValue, dec: 0)} تومان'),
                    infoRow('تعداد گونی کل', '${faNum(totalSmall + totalLarge)} عدد'),
                    infoRow('گونی کوچک', faNum(totalSmall)),
                    infoRow('گونی بزرگ', faNum(totalLarge)),
                    if (_showMixed && totalWaste > 0.0005)
                      infoRow('مجموع ضایعات ثبت‌شده', '${faNum(totalWaste)} کیلو'),
                  ]),
                ),
              ));
              children.add(const SizedBox(height: 4));
              children.add(_stockChart(context, available));
            } else {
              double soldKg = 0, soldValue = 0;
              for (final p in soldOut) {
                final w = (p['net_weight'] as num).toDouble();
                soldKg += w;
                soldValue += w * (p['price'] as num).toDouble();
              }
              children.add(Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(children: [
                    infoRow('تعداد خریدهای فروش‌رفته', '${faNum(soldOut.length, dec: 0)} بار'),
                    infoRow('مجموع وزن فروش‌رفته (خالص)', '${faNum(soldKg)} کیلو'),
                    infoRow('ارزش خرید آن‌ها', '${faNum(soldValue, dec: 0)} تومان'),
                    if (_showMixed && totalWaste > 0.0005)
                      infoRow('مجموع ضایعات ثبت‌شده', '${faNum(totalWaste)} کیلو'),
                  ]),
                ),
              ));
            }

            children.add(Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: TextField(
                decoration: const InputDecoration(
                  labelText: 'جستجو با کد پسته (مثلاً KH00012 یا MX00003)، نوع یا دسته',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ));

            if (lots.isEmpty) {
              final otherHits = q.isEmpty ? 0 : other.where(match).length;
              final otherKindHits = q.isEmpty ? 0 : otherKindItems.where(match).length;
              children.add(Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                    child: Text(q.isNotEmpty
                        ? 'نتیجه‌ای پیدا نشد'
                        : (_showSold
                            ? (_showMixed
                                ? 'هنوز هیچ مخلوط/جداسازی‌ای به‌طور کامل فروش نرفته است'
                                : 'هنوز هیچ خریدی به‌طور کامل فروش نرفته است')
                            : (_showMixed
                                ? 'هیچ مخلوط/جداسازی‌ای در انبار موجود نیست'
                                : 'هیچ جنسی در انبار موجود نیست')))),
              ));
              if (otherHits > 0) {
                children.add(OutlinedButton(
                  onPressed: () => setState(() => _showSold = !_showSold),
                  child: Text(
                      '${faNum(otherHits, dec: 0)} مورد در بخش «${_showSold ? 'موجود' : 'فروش رفته'}» پیدا شد — نمایش'),
                ));
              }
              if (otherKindHits > 0) {
                children.add(OutlinedButton(
                  onPressed: () => setState(() => _showMixed = !_showMixed),
                  child: Text(
                      '${faNum(otherKindHits, dec: 0)} مورد در دستهٔ «${_showMixed ? 'خریداری‌شده' : 'مخلوط/جداسازی'}» پیدا شد — نمایش'),
                ));
              }
            } else {
              // دسته -> نوع -> بارها
              final Map<String, Map<String, List<Map<String, dynamic>>>> g = {};
              for (final l in lots) {
                g
                    .putIfAbsent(l['category_name'] as String, () => {})
                    .putIfAbsent(l['type_name'] as String, () => [])
                    .add(l);
              }
              for (final catEntry in g.entries) {
                children.add(sectionTitle(context, catEntry.key));
                for (final e in catEntry.value.entries) {
                  final sumRem =
                      e.value.fold<double>(0, (a, l) => a + (l['remaining'] as num).toDouble());
                  final sumNet =
                      e.value.fold<double>(0, (a, l) => a + (l['net_weight'] as num).toDouble());
                  children.add(Card(
                    child: ExpansionTile(
                      // هنگام جستجو نتیجه‌ها باز نمایش داده می‌شوند
                      key: PageStorageKey('${_showMixed}/${_showSold}/${catEntry.key}/${e.key}/${q.isNotEmpty}'),
                      initiallyExpanded: q.isNotEmpty,
                      title: Text(e.key),
                      subtitle: Text(
                          '${faNum(_showSold ? sumNet : sumRem)} کیلو (خالص)  •  ${faNum(e.value.length, dec: 0)} بار'),
                      children: [for (final l in e.value) _lotTile(context, l)],
                    ),
                  ));
                }
              }
            }
            children.add(const SizedBox(height: 72));
            return ListView(padding: const EdgeInsets.all(12), children: children);
          },
      ),
    );
  }

  Widget _lotTile(BuildContext context, Map<String, dynamic> l) {
    final int mixKind = ((l['is_mix'] as num?) ?? 0).toInt(); // 0 buy, 1 mix, 2 separation output
    final isMix = mixKind >= 1;
    final isSep = mixKind == 2;
    final net = (l['net_weight'] as num).toDouble();
    final rem = (l['remaining'] as num).toDouble();
    final soldW = net - rem < 0 ? 0.0 : net - rem;
    final codes = ((l['in_mix_codes'] as List?) ?? const []).cast<String>();
    final sold = !AppDb.isAvailable(l);
    final lines = <String>[
      'کد پسته: ${l['code'] ?? '-'}',
      'خرید ${jalaliDate(l['date'] as String)}  •  فی ${faNum(l['price'] as num, dec: 0)}',
      if (!sold && soldW > 1e-6) 'از ${faNum(net)} کیلو (خالص) خریداری‌شده، ${faNum(soldW)} کیلو (خالص) فروخته/مصرف شده',
      if (codes.isNotEmpty)
        '🔀 ${rem <= 1e-6 ? 'کل موجودی آن' : 'بخشی از آن'} داخل مخلوط/جداسازی ${codes.join('، ')} است (هنوز کامل فروش نرفته)',
      if (isMix && ((l['waste'] as num?) ?? 0) > 0.0005) 'ضایعات/خاک: ${faNum(l['waste'] as num)} کیلو',
      if (!sold)
        'گونی مانده: کوچک ${faNum(l['small_left'] as num)} / بزرگ ${faNum(l['large_left'] as num)}'
            '${l['ounce'] != null ? '  •  انس ${faNum(l['ounce'] as num)}' : ''}'
            '${l['gram'] != null ? '  •  گرم ${faNum(l['gram'] as num)}' : ''}',
    ];
    return ListTile(
      dense: true,
      onTap: isMix ? () => (isSep ? showSeparationLotSheet(context, l) : _showMixDetails(context, l)) : null,
      leading: isMix
          ? Tooltip(
              message: isSep ? 'محصول جداسازی — ردیابی‌پذیر با کد K-…' : 'مخلوط/جداسازی — از جنس‌های خودِ انبار ساخته شده',
              child: Icon(isSep ? Icons.call_split : Icons.merge_type))
          : null,
      title: Text(sold
          ? '${faNum(net)} کیلو (خالص)  •  فروش رفت${isMix ? (isSep ? '  •  محصول جداسازی' : '  •  مخلوط/جداسازی') : ''}'
          : '${faNum(rem)} کیلو (خالص) مانده${isMix ? (isSep ? '  •  محصول جداسازی' : '  •  مخلوط/جداسازی') : ''}'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(lines.join('\n')),
          // S01: انبار / درجه‌بندی اونس (بارِ بدون انبار = انبار پیش‌فرض)
          FutureBuilder<String>(
            future: StockLookup.lotLabel(l),
            builder: (BuildContext c, AsyncSnapshot<String> snap) {
              final t = snap.data ?? '';
              return t.isEmpty ? const SizedBox.shrink() : Text(t, style: const TextStyle(color: Colors.black54));
            },
          ),
        ],
      ),
      isThreeLine: lines.length >= 3,
    );
  }
}
