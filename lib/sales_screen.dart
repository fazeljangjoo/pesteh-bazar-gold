import 'broker_ui.dart';
import 'package:flutter/material.dart';
import 'fmt.dart' show Fmt;

import 'barcode_utils.dart';
import 'db.dart';
import 'correction_ui.dart' show showCorrectionDialog;
import 'doc_drafts.dart' show DraftsScreen;
import 'form_settings.dart' show FormSettingsLocal;
import 'vouchers_links.dart';
import 'live_query.dart';
import 'invoice_service.dart';
import 'license_service.dart';
import 'receipt_screen.dart';
import 'returns_ui.dart';
import 'sale_form.dart';
import 'sale_export_ui.dart'; // S31.T31.10b/11b
import 'notify_service.dart';
import 'perms.dart';
import 'utils.dart';
import 'widgets.dart';
import 'pdf_output.dart';
import 'weigh_docs_pdf.dart';
import 'weigh_print_menu.dart' show weighPrintMenu;

/// یکسان‌سازی «ي/ك» عربی و «ی/ک» فارسی برای جستجو
String _norm(String s) => toEnDigits(s.replaceAll('ي', 'ی').replaceAll('ك', 'ک')).trim().toLowerCase();

class SalesScreen extends StatefulWidget {
  const SalesScreen({super.key});
  @override
  State<SalesScreen> createState() => _SalesScreenState();
}

class _SalesScreenState extends State<SalesScreen> {
  String _query = '';

  /// کد پسته‌ی فروش (هر فروش فقط یک قلم دارد)
  static String _codeOf(Map<String, dynamic> sale) {
    final items = sale['items'] as List;
    if (items.isEmpty) return '-';
    return (items.first['code'] as String?) ?? '-';
  }

  static bool _matches(Map<String, dynamic> sale, String q) {
    if (q.isEmpty) return true;
    final items = sale['items'] as List;
    final it = items.isEmpty ? const <String, dynamic>{} : items.first as Map;
    final hay = _norm('${it['code']} ${it['category_name']} ${it['type_name']} ${sale['buyer'] ?? ''}');
    return hay.contains(q);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('فروش'),
        actions: <Widget>[
          FutureBuilder<bool>(
            future: FormSettingsLocal.isOn('draft'), // S35.T35.9b
            builder: (BuildContext c, AsyncSnapshot<bool> s) => s.data == true
                ? IconButton(
                    tooltip: 'پیش‌نویس‌ها',
                    icon: const Icon(Icons.edit_note),
                    onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const DraftsScreen(docType: 'sale'))),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () =>
            Navigator.push(context, MaterialPageRoute(builder: (_) => const SaleForm())),
        icon: const Icon(Icons.add),
        label: const Text('فروش جدید'),
      ),
      body: LiveQuery<List<Map<String, dynamic>>>(
        tab: 2,
        load: AppDb.I.sales,
        builder: (context, s) {
            if (!s.hasData) return const Center(child: CircularProgressIndicator());
            final all = s.data!;
            if (all.isEmpty) return const Center(child: Text('هنوز فروشی ثبت نشده'));
            final q = _norm(_query);
            final list = all.where((sale) => _matches(sale, q)).toList();
            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
              itemCount: list.length + 1,
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(children: [
                      TextField(
                        decoration: const InputDecoration(
                          labelText: 'جستجو با کد پسته، نوع، دسته یا خریدار',
                          prefixIcon: Icon(Icons.search),
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (v) => setState(() => _query = v),
                      ),
                      if (list.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(top: 24),
                          child: Text('نتیجه‌ای پیدا نشد'),
                        ),
                    ]),
                  );
                }
                final sale = list[i - 1];
                final id = sale['id'] as int;
                final items = sale['items'] as List;
                final net = (sale['net_weight'] as num).toDouble();
                final price = (sale['price'] as num).toDouble();
                final revenue = net * price;
                final total = (sale['total_weight'] as num).toDouble();
                final tare = total - net < 0 ? 0.0 : total - net;
                final small = (sale['small_sack_count'] as num).toDouble();
                final large = (sale['large_sack_count'] as num).toDouble();
                final sackCounts = '';
                final comp = items
                    .map((it) => '${it['category_name']} - ${it['type_name']}')
                    .join(' + ');
                final fx = LicenseService.I.isFx.value;
                final usd = fx ? saleUsd(sale) : null;
                final rate = (sale['usd_rate'] as num?)?.toDouble();
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Expanded(
                            child: Text(
                              '${jalaliDate(sale['date'] as String)}'
                              '${sale['buyer'] != null ? '  •  ${sale['buyer']}' : ''}',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          PopupMenuButton<String>(
                            onSelected: (v) async {
                              if (v == 'edit') {
                                Navigator.push(context,
                                    MaterialPageRoute(builder: (_) => SaleForm(editSaleId: id)));
                              } else if (v == 'corr') {
                                await showCorrectionDialog(context, docType: 'sale', id: id, price: (sale['price'] as num?) ?? 0, netWeight: (sale['net_weight'] as num?) ?? 0); // S35.T35.9c
                              } else if (v == 'del') {
                                final String? delReason = await askDeleteReason(context,
                                    'این فروش حذف شود؟ وزن و گونی‌ها به انبار برمی‌گردند.'); // S35.T35.9a
                                if (delReason != null) {
                                  final rec = await AppDb.I.receiptOf(id);
                                  var creditIds = <int>[], chequeIds = <int>[];
                                  if (rec != null) {
                                    final recId = rec['id'] as int;
                                    creditIds = (await AppDb.I.receiptCreditInstList(recId))
                                        .map((r) => r['id'] as int)
                                        .toList();
                                    chequeIds = (await AppDb.I.receiptChequeInstList(recId))
                                        .map((r) => r['id'] as int)
                                        .toList();
                                  }
                                  await AppDb.I.deleteSale(id, reason: delReason);
                                  for (final cid in creditIds) {
                                    await NotifyService.I.cancelReceiptCreditRow(cid);
                                  }
                                  for (final cid in chequeIds) {
                                    await NotifyService.I.cancelReceiptChequeRow(cid);
                                  }
                                }
                              }
                            },
                            itemBuilder: (_) => <PopupMenuEntry<String>>[
                              if (StaffPerms.I.can('sales.update'))
                                const PopupMenuItem<String>(value: 'edit', child: Text('ویرایش')),
                              if (StaffPerms.I.can('sales.update'))
                                const PopupMenuItem<String>(value: 'corr', child: Text('سند اصلاحی (فی/وزن)')),
                              if (StaffPerms.I.can('sales.delete'))
                                const PopupMenuItem<String>(value: 'del', child: Text('حذف')),
                            ],
                          ),
                        ]),
                        Text(comp),
                        infoRow('کد پسته', _codeOf(sale)),
                        for (final c in printableCodesIn(_codeOf(sale))) BarcodeBox(c, height: 44),
                        const SizedBox(height: 8),
                        infoRow('وزن کل (ناخالص - با گونی)', '${faNum(total)} کیلو'),
                        infoRow('وزن گونی‌ها', '${faNum(tare)} کیلو'),
                        if (small + large > 0) ...[
                          infoRow('گونی کوچک', faNum(small)),
                          infoRow('گونی بزرگ', faNum(large)),
                        ],
                        if (sale['labor_cost'] != null) infoRow('هزینه کارگر', '${Fmt.money(sale['labor_cost'] as num)}'),
                        if (sale['transport_cost'] != null) infoRow('هزینه حمل‌ونقل / باسکول', '${Fmt.money(sale['transport_cost'] as num)}'),
                        infoRow('وزن پسته (خالص)', '${faNum(net)} کیلو'),
                        infoRow('فی فروش', '${Fmt.money(price)}'),
                        infoRow('مبلغ فروش', '${Fmt.money(revenue)}'),
                        if (fx) ...[
                          if (rate != null) infoRow('قیمت دلار روز فروش', '${faNum(rate, dec: 0)} ریال'),
                          if (rate != null) infoRow('فی فروش به دلار', faUsd(price / rate, dec: 4)),
                          if (usd != null) infoRow('مبلغ فروش به دلار', faUsd(usd.revenue)),
                        ],
                        LocalDocVoucherLinks(mapKind: 'sale', localId: id, sourceType: 'sale'),
                        const SizedBox(height: 8),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          OutlinedButton.icon(
                            onPressed: () => InvoiceService.forSale(context, sale),
                            icon: const Icon(Icons.receipt_long_outlined),
                            label: const Text('فاکتور فروش'),
                          ),
                          if (StaffPerms.I.can('sales.create'))
                            OutlinedButton.icon(
                              onPressed: () => openBrokerDialog(context, isSale: true, doc: sale),
                              icon: const Icon(Icons.handshake_outlined),
                              label: const Text('دلال / کمیسیون'),
                            ),
                          if (LicenseService.I.isFx.value && StaffPerms.I.can('sales.view'))
                            OutlinedButton.icon(
                              onPressed: () async {
                                final int? sid = await AppDb.I.serverIdOf('sale', id);
                                if (!context.mounted) return;
                                if (sid == null) {
                                  snack(context, 'ابتدا همگام‌سازی شود');
                                  return;
                                }
                                Navigator.push(context, MaterialPageRoute<void>(builder: (_) => SaleExportScreen(saleId: sid)));
                              },
                              icon: const Icon(Icons.local_shipping_outlined),
                              label: const Text('اطلاعات صادراتی'),
                            ),
                          if (StaffPerms.I.can('sales.return'))
                            OutlinedButton.icon(
                              onPressed: () => openSaleReturn(context, sale),
                              icon: const Icon(Icons.assignment_return_outlined),
                              label: const Text('برگشت از فروش'),
                            ),
                          // S35.T35.13d: رسید باسکول و بارنامه (قالب A4/A5/رول ۸۰)
                          weighPrintMenu(context, 'رسید باسکول', (WeighPaper w) async {
                            final f = await WeighDocs.buildSlip(sale, paper: w);
                            if (context.mounted) await PdfOutput.show(context, f);
                          }),
                          weighPrintMenu(context, 'بارنامه', (WeighPaper w) async {
                            final f = await WeighDocs.buildWaybill(sale, paper: w, items: <Map<String, dynamic>>[
                              <String, dynamic>{'type_name': sale['type_name'], 'code': sale['code'], 'weight': sale['net_weight'] ?? sale['weight'], 'sacks': '${sale['small_sack_count'] ?? 0} / ${sale['large_sack_count'] ?? 0}'},
                            ]);
                            if (context.mounted) await PdfOutput.show(context, f);
                          }),
                          FilledButton.tonalIcon(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ReceiptScreen(
                                  saleId: id,
                                  saleLabel: sale['buyer'] != null
                                      ? '${sale['buyer']}'
                                      : jalaliDate(sale['date'] as String),
                                ),
                              ),
                            ),
                            icon: const Icon(Icons.request_quote_outlined),
                            label: const Text('وصول مطالبات'),
                          ),
                        ]),
                      ],
                    ),
                  ),
                );
              },
            );
          },
      ),
    );
  }
}
