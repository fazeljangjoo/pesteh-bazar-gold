import 'broker_ui.dart';
import 'package:flutter/material.dart';

import 'barcode_utils.dart';
import 'db.dart';
import 'vouchers_links.dart';
import 'live_query.dart';
import 'invoice_service.dart';
import 'license_service.dart';
import 'receipt_screen.dart';
import 'returns_ui.dart';
import 'sale_form.dart';
import 'notify_service.dart';
import 'perms.dart';
import 'utils.dart';
import 'widgets.dart';

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
      appBar: AppBar(title: const Text('فروش')),
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
                              } else if (v == 'del') {
                                if (await confirm(context,
                                    'این فروش حذف شود؟ وزن و گونی‌ها به انبار برمی‌گردند.')) {
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
                                  await AppDb.I.deleteSale(id);
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
                        if (sale['labor_cost'] != null) infoRow('هزینه کارگر', '${faNum(sale['labor_cost'] as num, dec: 0)} تومان'),
                        if (sale['transport_cost'] != null) infoRow('هزینه حمل‌ونقل / باسکول', '${faNum(sale['transport_cost'] as num, dec: 0)} تومان'),
                        infoRow('وزن پسته (خالص)', '${faNum(net)} کیلو'),
                        infoRow('فی فروش', '${faNum(price, dec: 0)} تومان'),
                        infoRow('مبلغ فروش', '${faNum(revenue, dec: 0)} تومان'),
                        if (fx) ...[
                          if (rate != null) infoRow('قیمت دلار روز فروش', '${faNum(rate, dec: 0)} تومان'),
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
                          if (StaffPerms.I.can('sales.return'))
                            OutlinedButton.icon(
                              onPressed: () => openSaleReturn(context, sale),
                              icon: const Icon(Icons.assignment_return_outlined),
                              label: const Text('برگشت از فروش'),
                            ),
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
