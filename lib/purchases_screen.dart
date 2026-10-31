import 'broker_ui.dart';
import 'package:flutter/material.dart';
import 'fmt.dart' show Fmt;

import 'db.dart';
import 'correction_ui.dart' show showCorrectionDialog;
import 'doc_drafts.dart' show DraftsScreen;
import 'form_settings.dart' show FormSettingsLocal;
import 'grade_lines_ui.dart' show GradeCostRows;
import 'vouchers_links.dart';
import 'live_query.dart';
import 'invoice_service.dart';
import 'license_service.dart';
import 'payment_screen.dart';
import 'pdf_output.dart';
import 'weigh_docs_pdf.dart';
import 'weigh_print_menu.dart' show weighPrintMenu;
import 'pdf_service.dart';
import 'purchase_form.dart';
import 'returns_ui.dart';
import 'perms.dart';
import 'notify_service.dart';
import 'barcode_utils.dart';
import 'utils.dart';
import 'widgets.dart';

class PurchasesScreen extends StatefulWidget {
  /// اگر از اسکن آمده باشیم، جزئیات همین کد یک‌بار باز می‌شود
  const PurchasesScreen({super.key, this.openCode});

  final String? openCode;
  @override
  State<PurchasesScreen> createState() => _PurchasesScreenState();
}

class _PurchasesScreenState extends State<PurchasesScreen> {
  String _query = '';
  bool _openedCode = false;

  void _details(BuildContext context, Map<String, dynamic> p) {
    String? pct(String k) => p[k] == null ? null : '${faNum(p[k] as num)}٪';
    final preset = p['category_preset'] as String?;
    final customSpecs = AppDb.decodeCustomSpecs(p['custom_specs'] as String?);
    final rows = <List<String>>[
      ['تاریخ', jalaliDate(p['date'] as String)],
      if (p['seller'] != null) ['فروشنده', p['seller']],
      if (p['ounce'] != null) ['انس', faNum(p['ounce'] as num)],
      ['فی خرید', '${Fmt.money(p['price'] as num)}'],
      if (LicenseService.I.isFx.value && p['usd_rate'] != null) ['قیمت دلار روز خرید', '${faNum(p['usd_rate'] as num, dec: 0)} ریال'],
      if (LicenseService.I.isFx.value && p['price_usd'] != null) ['فی خرید به دلار (هر کیلو)', faUsd(p['price_usd'] as num, dec: 4)],
      ['وزن کل (ناخالص)', '${faNum(p['total_weight'] as num)} کیلو'],
      ['گونی کوچک (۱۰۰گ)', faNum(p['small_sack_count'] as num)],
      ['گونی بزرگ (۲۰۰گ)', faNum(p['large_sack_count'] as num)],
      ['وزن پسته (خالص)', '${faNum(p['net_weight'] as num)} کیلو'],
      ['مانده در انبار (خالص)', '${faNum(p['remaining'] as num)} کیلو'],
      ['گونی کوچک مانده', faNum((p['small_sacks_remaining'] as num?) ?? 0)],
      ['گونی بزرگ مانده', faNum((p['large_sacks_remaining'] as num?) ?? 0)],
      if (p['labor_cost'] != null) ['هزینه کارگر', '${Fmt.money(p['labor_cost'] as num)}'],
      if (p['transport_cost'] != null) ['هزینه حمل‌ونقل / باسکول', '${Fmt.money(p['transport_cost'] as num)}'],
      if (((p['in_mix_codes'] as List?) ?? const []).isNotEmpty)
        ['داخل مخلوط/جداسازی (هنوز فروش نرفته)', ((p['in_mix_codes'] as List).cast<String>()).join('، ')],
      if (preset == 'dombest' && p['gram'] != null) ['گرم', faNum(p['gram'] as num)],
      if (preset == 'dombest' && pct('pct_khandan') != null) ['درصد خندان در دنبست', pct('pct_khandan')!],
      if (preset == 'khandan' && pct('pct_dombest') != null) ['درصد دنبست در خندان', pct('pct_dombest')!],
      if (preset == 'khandan' && pct('pct_tuchin') != null) ['درصد توچین', pct('pct_tuchin')!],
      if ((preset == 'dombest' || preset == 'khandan') && pct('pct_crooked') != null)
        ['درصد کج / ناخالص', pct('pct_crooked')!],
      for (final s in customSpecs) [s['label'] ?? '', s['value'] ?? ''],
      if (p['note'] != null) ['توضیحات', p['note']],
    ];
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${p['category_name']} - ${p['type_name']}',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
                    infoRow('کد پسته', p['code'] as String? ?? '-'),
              BarcodeBox(p['code'] as String? ?? ''),
              if (((p['has_photo'] as num?) ?? 0) == 1)
                FutureBuilder<String?>(
                  future: AppDb.I.localPhoto(p['id'] as int),
                  builder: (c, snap) {
                    final ph = snap.data;
                    if (ph == null) return const SizedBox.shrink();
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(photoBytes(ph),
                          height: 180, width: double.infinity, fit: BoxFit.cover),
                    );
                  },
                ),
              const SizedBox(height: 8),
              for (final r in rows) infoRow(r[0], r[1]),
              GradeCostRows(docType: 'purchase', docId: p['id'] as int), // S35.T35.3c
              LocalDocVoucherLinks(mapKind: 'pur', localId: p['id'] as int, sourceType: 'purchase'),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PaymentScreen(
                        purchaseId: p['id'] as int,
                        purchaseLabel: '${p['category_name']} - ${p['type_name']}',
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.payments_outlined),
                label: const Text('مدیریت پرداخت'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  final file = await PdfService.buildStockCard(
                    code: p['code'] as String? ?? '-',
                    totalWeight: (p['total_weight'] as num).toDouble(),
                    netWeight: (p['net_weight'] as num).toDouble(),
                    smallSacks: (p['small_sack_count'] as num).toDouble(),
                    largeSacks: (p['large_sack_count'] as num).toDouble(),
                  );
                  await PdfOutput.show(context, file);
                },
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: const Text('دریافت کارتکس A6'),
              ),
              const SizedBox(height: 8),
              // S35.T35.13c: رسید باسکول و بارنامه (قالب A4/A5/رول)
              Wrap(spacing: 8, children: [
                weighPrintMenu(context, 'رسید باسکول', (WeighPaper w) async {
                  final f = await WeighDocs.buildSlip(p, paper: w);
                  if (context.mounted) await PdfOutput.show(context, f);
                }),
                weighPrintMenu(context, 'بارنامه', (WeighPaper w) async {
                  final f = await WeighDocs.buildWaybill(p, paper: w, items: <Map<String, dynamic>>[
                    <String, dynamic>{'type_name': p['type_name'], 'code': p['code'], 'weight': p['net_weight'], 'sacks': '${p['small_sack_count'] ?? 0} / ${p['large_sack_count'] ?? 0}'},
                  ]);
                  if (context.mounted) await PdfOutput.show(context, f);
                }),
              ]),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => InvoiceService.forPurchase(context, p),
                icon: const Icon(Icons.receipt_long_outlined),
                label: const Text('فاکتور خرید'),
              ),
              if (StaffPerms.I.can('purchases.create') && p['is_mix'] != true && '${p['is_mix']}' != '1') ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => openBrokerDialog(context, isSale: false, doc: p),
                  icon: const Icon(Icons.handshake_outlined),
                  label: const Text('دلال / کمیسیون'),
                ),
              ],
              if (StaffPerms.I.can('purchases.return') && p['is_mix'] != true && '${p['is_mix']}' != '1') ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => openPurchaseReturn(context, p),
                  icon: const Icon(Icons.assignment_return_outlined),
                  label: const Text('برگشت از خرید'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// یکسان‌سازی «ي/ك» عربی و «ی/ک» فارسی برای جستجو
  static String _norm(String s) => toEnDigits(s.replaceAll('ي', 'ی').replaceAll('ك', 'ک')).trim().toLowerCase();

  /// مثل وب: «فروخته‌شده» فقط وقتی است که وزنی از خودش نمانده باشد و مقداری از آن هم
  /// داخل مخلوطِ فروش‌نرفته نباشد.
  static bool _isSold(Map<String, dynamic> p) => !AppDb.isAvailable(p);

  static String _inMixLine(Map<String, dynamic> p) {
    final codes = ((p['in_mix_codes'] as List?) ?? const []).cast<String>();
    if (codes.isEmpty) return '';
    final rem = (p['remaining'] as num).toDouble();
    return '\n🔀 ${rem <= 1e-6 ? 'کل موجودی آن' : 'بخشی از آن'} داخل مخلوط/جداسازی ${codes.join('، ')} است (هنوز کامل فروش نرفته)';
  }

  Widget _card(BuildContext context, Map<String, dynamic> p) {
    final hasPhoto = ((p['has_photo'] as num?) ?? 0) == 1;
    final sold = _isSold(p);
    return Card(
      child: ListTile(
        onTap: () => _details(context, p),
        leading: CircleAvatar(child: Icon(hasPhoto ? Icons.photo_camera_outlined : Icons.grass)),
        title: Text('${p['category_name']} - ${p['type_name']}'),
        subtitle: Text(
            'کد ${p['code'] ?? '-'}  •  ${jalaliDate(p['date'] as String)}  •  ${faNum(p['net_weight'] as num)} کیلو (خالص)\n'
            '${sold ? 'فروخته‌شده' : 'مانده ${faNum(p['remaining'] as num)} کیلو (خالص)'}  •  فی ${Fmt.money(p['price'] as num)}'
            '${LicenseService.I.isFx.value && p['price_usd'] != null ? ' (${faUsd(p['price_usd'] as num, dec: 3)})' : ''}'
            '${_inMixLine(p)}'),
        isThreeLine: true,
        trailing: PopupMenuButton<String>(
          onSelected: (v) async {
            if (v == 'edit') {
              Navigator.push(context, MaterialPageRoute(builder: (_) => PurchaseForm(existing: p)));
            } else if (v == 'corr') {
              await showCorrectionDialog(context, docType: 'purchase', id: p['id'] as int, price: p['price'] as num, netWeight: p['net_weight'] as num); // S35.T35.9c
            } else if (v == 'del') {
              final String? delReason = await askDeleteReason(context, 'این خرید حذف شود؟'); // S35.T35.9a
              if (delReason == null) return;
              final pay = await AppDb.I.paymentOf(p['id'] as int);
              var creditIds = <int>[], chequeIds = <int>[];
              if (pay != null) {
                final payId = pay['id'] as int;
                creditIds = (await AppDb.I.creditInstList(payId)).map((r) => r['id'] as int).toList();
                chequeIds = (await AppDb.I.chequeInstList(payId)).map((r) => r['id'] as int).toList();
              }
              final ok = await AppDb.I.deletePurchase(p['id'] as int, reason: delReason);
              if (ok) {
                for (final id in creditIds) {
                  await NotifyService.I.cancelCreditRow(id);
                }
                for (final id in chequeIds) {
                  await NotifyService.I.cancelChequeRow(id);
                }
              } else if (context.mounted) {
                snack(context, 'از این خرید فروش انجام شده؛ ابتدا فروش را حذف کنید');
              }
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('ویرایش')),
            PopupMenuItem(value: 'corr', child: Text('سند اصلاحی (فی/وزن)')),
            PopupMenuItem(value: 'del', child: Text('حذف')),
          ],
        ),
      ),
    );
  }

  Widget _tabList(BuildContext context, List<Map<String, dynamic>> list, String emptyText) {
    if (list.isEmpty) return Center(child: Text(_query.trim().isEmpty ? emptyText : 'نتیجه‌ای پیدا نشد'));
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 88),
      itemCount: list.length,
      itemBuilder: (context, i) => _card(context, list[i]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('خرید'),
          actions: <Widget>[
            FutureBuilder<bool>(
              future: FormSettingsLocal.isOn('draft'), // S35.T35.9b
              builder: (BuildContext c, AsyncSnapshot<bool> s) => s.data == true
                  ? IconButton(
                      tooltip: 'پیش‌نویس‌ها',
                      icon: const Icon(Icons.edit_note),
                      onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const DraftsScreen(docType: 'purchase'))),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
          bottom: const TabBar(tabs: [
            Tab(text: 'خریدهای موجود'),
            Tab(text: 'خریدهای فروخته‌شده'),
          ]),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () =>
              Navigator.push(context, MaterialPageRoute(builder: (_) => const PurchaseForm())),
          icon: const Icon(Icons.add),
          label: const Text('خرید جدید'),
        ),
        body: LiveQuery<List<Map<String, dynamic>>>(
          tab: 1,
          load: AppDb.I.purchases,
          builder: (context, s) {
              if (!s.hasData) return const Center(child: CircularProgressIndicator());
              final all = s.data!;
              // اسکن موفق: جزئیات همان پسته یک‌بار باز شود
              if (widget.openCode != null && !_openedCode) {
                _openedCode = true;
                final hit = all.where((p) => p['code'] == widget.openCode).toList();
                if (hit.isNotEmpty) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _details(context, hit.first);
                  });
                }
              }
              final q = _norm(_query);
              final filtered = q.isEmpty
                  ? all
                  : all
                      .where((p) => _norm('${p['code']} ${p['category_name']} ${p['type_name']}').contains(q))
                      .toList();
              final available = filtered.where((p) => !_isSold(p)).toList();
              final sold = filtered.where(_isSold).toList();
              return Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: TextField(
                    decoration: const InputDecoration(
                      labelText: 'جستجو با کد، دسته یا نوع',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ),
                Expanded(
                  child: TabBarView(children: [
                    _tabList(context, available, 'هیچ خرید موجودی در انبار نیست'),
                    _tabList(context, sold, 'هنوز خریدِ کاملاً فروخته‌شده‌ای نداریم'),
                  ]),
                ),
              ]);
            },
        ),
      ),
    );
  }
}

