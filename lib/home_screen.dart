import 'package:flutter/material.dart';

import 'sync_screen.dart';
import 'sync_service.dart';
import 'db.dart';
import 'live_query.dart';
import 'license_service.dart';
import 'assistant_screen.dart';
import 'messages_card.dart';
import 'crm_ui.dart';
import 'dues_screen.dart';
import 'fiscal_ui.dart';
import 'ledger.dart';
import 'purchase_form.dart';
import 'purchases_screen.dart';
import 'sale_form.dart';
import 'statements_ui.dart'; // S18.T18.3
import 'scan_entry.dart';
import 'utils.dart';
import 'widgets.dart';

/// صفحهٔ اصلی: یک نگاه سریع به وضعیت امروز + دسترسی به کارهای پرتکرار
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('پسته بازار'), actions: const <Widget>[FiscalSwitcher()]),
      body: LiveQuery<List<Object?>>(
        tab: 0,
        load: () => Future.wait<Object?>([
          AppDb.I.lots(),
          AppDb.I.sales(),
          loadDues(),
        ]),
        builder: (context, snap) {
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final lots = snap.data![0] as List<Map<String, dynamic>>;
            final sales = snap.data![1] as List<Map<String, dynamic>>;
            final dues = snap.data![2] as List<DueItem>;

            final now = DateTime.now();
            final startOfMonth = DateTime(now.year, now.month, 1);

            double invKg = 0;
            for (final l in lots) {
              invKg += (l['remaining'] as num).toDouble();
            }

            // حریم خصوصی: در صفحهٔ اصلی فقط مقدارِ فروش (کیلوگرم) و موجودی دیده می‌شود؛ سود و زیان فقط در صفحهٔ «سود و زیان» (قابل قفل)
            double todayKg = 0, monthKg = 0;
            int todayCount = 0;
            for (final s in sales) {
              final date = DateTime.parse(s['date'] as String);
              final net = (s['net_weight'] as num).toDouble();
              if (_sameDay(date, now)) {
                todayKg += net;
                todayCount++;
              }
              if (!date.isBefore(startOfMonth)) monthKg += net;
            }

            final overdue = dues.where((d) => daysUntil(d.date) < 0).toList();
            final soon =
                dues.where((d) => daysUntil(d.date) >= 0 && daysUntil(d.date) <= 7).toList();
            double overdueAmt = overdue.fold(0.0, (s, d) => s + d.amount);
            double soonAmt = soon.fold(0.0, (s, d) => s + d.amount);

            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const MessagesCard(),
                const CrmHomeCard(),
                const InstantPnlCard(),
                _quickActions(context),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => _scanAndOpen(context),
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('اسکن بارکد'),
                ),
                // دستیار: فقط برای کاربر پلن fx دیده می‌شود (isFx از ورود/بوت ذخیره می‌شود)
                ValueListenableBuilder<bool>(
                  valueListenable: LicenseService.I.isFx,
                  builder: (context, fx, _) => !fx
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: InkWell(
                            onTap: () => Navigator.push(context,
                                MaterialPageRoute(builder: (_) => const AssistantScreen())),
                            child: Card(
                              color: scheme.secondaryContainer,
                              child: Padding(
                                padding: const EdgeInsets.all(14),
                                child: Row(children: [
                                  const Icon(Icons.smart_toy_outlined),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text('دستیار پسته بازار',
                                        style: Theme.of(context).textTheme.titleMedium
                                            ?.copyWith(fontWeight: FontWeight.w700)),
                                  ),
                                  const Icon(Icons.chevron_left),
                                ]),
                              ),
                            ),
                          ),
                        ),
                ),
                const SizedBox(height: 16),
                // موجودی انبار: درشت و پررنگ
                Card(
                  color: scheme.primaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 14),
                    child: Column(children: [
                      Text('موجودی انبار (خالص)', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 6),
                      Text('${faNum(invKg)} کیلو',
                          style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
                    ]),
                  ),
                ),
                const SizedBox(height: 12),
                sectionTitle(context, 'فروش'),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(children: [
                      infoRow('فروش امروز', '${faNum(todayCount)} مورد • ${faNum(todayKg)} کیلو (خالص)'),
                      infoRow('فروش این ماه', '${faNum(monthKg)} کیلو (خالص)'),
                    ]),
                  ),
                ),
                const SizedBox(height: 12),
                InkWell(
                  onTap: () => Navigator.push(
                      context, MaterialPageRoute(builder: (_) => const DuesScreen())),
                  child: Card(
                    color: overdue.isNotEmpty ? scheme.errorContainer : null,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Row(children: [
                          Expanded(
                              child: Text('سررسیدها',
                                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800))),
                          const Icon(Icons.chevron_left),
                        ]),
                        if (overdue.isEmpty && soon.isEmpty)
                          const Text('چیزی سررسید نزدیک ندارد')
                        else ...[
                          if (overdue.isNotEmpty)
                            infoRow('عقب‌افتاده', '${faNum(overdue.length)} مورد • ${faNum(overdueAmt, dec: 0)} ریال',
                                valueColor: scheme.error),
                          if (soon.isNotEmpty)
                            infoRow('تا ۷ روز آینده',
                                '${faNum(soon.length)} مورد • ${faNum(soonAmt, dec: 0)} ریال'),
                        ],
                      ]),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                InkWell(
                  onTap: () => Navigator.push(
                      context, MaterialPageRoute(builder: (_) => const SyncScreen())),
                  child: ValueListenableBuilder<SyncInfo>(
                    valueListenable: SyncService.I.info,
                    builder: (context, info, _) => Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(children: [
                          Icon(info.failed > 0
                              ? Icons.error_outline
                              : info.offline
                                  ? Icons.cloud_off
                                  : info.pending > 0
                                      ? Icons.cloud_sync_outlined
                                      : Icons.cloud_done_outlined),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(info.failed > 0
                                ? 'همگام‌سازی: ${faNum(info.failed)} مورد خطادار'
                                : info.offline
                                    ? 'آفلاین — ${faNum(info.pending)} تغییر در صف ارسال'
                                    : info.pending > 0
                                        ? 'همگام‌سازی: ${faNum(info.pending)} تغییر در صف ارسال'
                                        : 'همگام‌سازی: به‌روز است'),
                          ),
                          const Icon(Icons.chevron_left),
                        ]),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            );
          },
      ),
    );
  }

  /// اسکن → پیدا کردن همان پسته در حساب → باز کردن جزئیاتش در صفحهٔ خرید
  Future<void> _scanAndOpen(BuildContext context) async {
    final code = await scanBarcode(context);
    if (code == null || !context.mounted) return;
    final lot = await AppDb.I.lotByCode(code);
    if (!context.mounted) return;
    if (lot == null) {
      snack(context, 'این کد در حساب شما نیست');
      return;
    }
    Navigator.push(context, MaterialPageRoute(builder: (_) => PurchasesScreen(openCode: code)));
  }

  Widget _quickActions(BuildContext context) {
    return Row(children: [
      Expanded(
        child: FilledButton.icon(
          onPressed: () =>
              Navigator.push(context, MaterialPageRoute(builder: (_) => const PurchaseForm())),
          icon: const Icon(Icons.shopping_cart_outlined),
          label: const Text('خرید جدید'),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: FilledButton.icon(
          onPressed: () =>
              Navigator.push(context, MaterialPageRoute(builder: (_) => const SaleForm())),
          icon: const Icon(Icons.sell_outlined),
          label: const Text('فروش جدید'),
        ),
      ),
    ]);
  }
}
