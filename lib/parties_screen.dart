import 'package:flutter/material.dart';

import 'db.dart';
import 'live_query.dart';
import 'ledger.dart';
import 'loans_ui.dart';
import 'party_master_screen.dart'; // T03.1
import 'party_statement_screen.dart'; // T03.2
import 'crm_ui.dart'; // T03.4
import 'payment_screen.dart';
import 'receipt_screen.dart';
import 'utils.dart';
import 'widgets.dart';

/// طرف‌حساب‌ها: برای هر فروشنده/خریدار، جمع خرید و فروش و بدهی/طلب باقی‌مانده
class PartiesScreen extends StatefulWidget {
  const PartiesScreen({super.key});
  @override
  State<PartiesScreen> createState() => _PartiesScreenState();
}

class _PartiesScreenState extends State<PartiesScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('طرف‌حساب‌ها'), actions: <Widget>[
        IconButton(
          tooltip: 'سن بدهی و مطالبات',
          icon: const Icon(Icons.hourglass_bottom),
          onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const PartyAgingScreen())),
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showNewPartyDialog(context),
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('طرف‌حساب جدید'),
      ),
      body: LiveQuery<List<PartyAccount>>(
        load: loadParties,
        builder: (context, snap) {
            if (snap.hasError) return Center(child: Text('خطا: ${snap.error}'));
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final all = snap.data!;
            if (all.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('هنوز طرف‌حسابی نیست.\nبا دکمهٔ «طرف‌حساب جدید» یکی تعریف کنید یا خرید/فروش ثبت کنید.',
                      textAlign: TextAlign.center),
                ),
              );
            }
            double weOwe = 0, theyOwe = 0, loanRecv = 0, loanPay = 0;
            for (final a in all) {
              if (a.weOwe > 0) weOwe += a.weOwe;
              if (a.theyOwe > 0) theyOwe += a.theyOwe;
              if (a.loanReceivable > 0) loanRecv += a.loanReceivable;
              if (a.loanPayable > 0) loanPay += a.loanPayable;
            }
            final q = partyKey(_query);
            final list = q.isEmpty ? all : all.where((a) => a.key.contains(q)).toList();
            final scheme = Theme.of(context).colorScheme;
            return ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: [
                Card(
                  color: scheme.primaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(children: [
                      infoRow('جمع طلب‌ها (از خریدارها)', '${faNum(theyOwe, dec: 0)} تومان',
                          valueColor: Colors.green.shade800),
                      infoRow('جمع بدهی‌ها (به فروشنده‌ها)', '${faNum(weOwe, dec: 0)} تومان',
                          valueColor: Colors.red.shade800),
                      if (loanRecv > 0.5 || loanPay > 0.5) ...[
                        const Divider(),
                        infoRow('مانده طلب قرضی', '${faNum(loanRecv, dec: 0)} تومان',
                            valueColor: Colors.green.shade800),
                        infoRow('مانده بدهی قرضی', '${faNum(loanPay, dec: 0)} تومان',
                            valueColor: Colors.red.shade800),
                      ],
                      if (all.any((a) => a.hasLoans))
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: TextButton.icon(
                            onPressed: () => exportLoanPdf(context, all: all),
                            icon: const Icon(Icons.picture_as_pdf_outlined),
                            label: const Text('PDF دفتر قرض همهٔ طرف‌حساب‌ها'),
                          ),
                        ),
                    ]),
                  ),
                ),
                const SizedBox(height: 8),
                const CashFlowCard(),
                const SizedBox(height: 8),
                TextField(
                  decoration: const InputDecoration(
                    labelText: 'جستجوی نام',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
                const SizedBox(height: 8),
                for (final a in list) _tile(context, a),
                const SizedBox(height: 70), // جا برای دکمهٔ شناور
                if (list.isEmpty)
                  const Padding(
                      padding: EdgeInsets.all(24), child: Center(child: Text('موردی پیدا نشد'))),
              ],
            );
          },
      ),
    );
  }

  Widget _tile(BuildContext context, PartyAccount a) {
    final total = a.totalNet;
    final settled = total.abs() < 1;
    final color = settled
        ? Colors.black54
        : (total > 0 ? Colors.green.shade800 : Colors.red.shade800);
    final lines = <String>[
      if (a.bought > 0) 'خرید ${faNum(a.bought, dec: 0)}',
      if (a.sold > 0) 'فروش ${faNum(a.sold, dec: 0)}',
      if (a.loanReceivable.abs() > 0.5) 'طلب قرضی ${faNum(a.loanReceivable, dec: 0)}',
      if (a.loanPayable.abs() > 0.5) 'بدهی قرضی ${faNum(a.loanPayable, dec: 0)}',
    ].join('  •  ');
    return Card(
      key: ValueKey('party${a.key}'),
      child: ListTile(
        title: Text(a.name),
        subtitle: Text(lines.isEmpty ? 'بدون تراکنش' : lines),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(settled ? 'تسویه' : faNum(total.abs(), dec: 0),
                style: TextStyle(fontWeight: FontWeight.w700, color: color)),
            Text(settled ? '' : (total > 0 ? 'طلب ما' : 'بدهی ما'),
                style: TextStyle(fontSize: 11, color: color)),
          ],
        ),
        onTap: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => PartyDetailScreen(partyKeyValue: a.key))),
      ),
    );
  }
}

class PartyDetailScreen extends StatelessWidget {
  final String partyKeyValue;
  const PartyDetailScreen({super.key, required this.partyKeyValue});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: AppDb.I.version,
      builder: (_, __, ___) => FutureBuilder<List<PartyAccount>>(
        future: loadParties(),
        builder: (context, snap) {
          PartyAccount? a;
          if (snap.hasData) {
            for (final x in snap.data!) {
              if (x.key == partyKeyValue) a = x;
            }
          }
          return Scaffold(
            appBar: AppBar(
              title: Text(partyKeyValue.isEmpty ? 'بدون نام' : partyKeyValue),
              actions: <Widget>[
                if (partyKeyValue.isNotEmpty)
                  IconButton(
                    tooltip: 'یادداشت و پیگیری',
                    icon: const Icon(Icons.support_agent_outlined),
                    onPressed: () => Navigator.push(
                        context, MaterialPageRoute<void>(builder: (_) => PartyCrmScreen(partyName: partyKeyValue))),
                  ),
                if (partyKeyValue.isNotEmpty)
                  IconButton(
                    tooltip: 'صورت‌حساب',
                    icon: const Icon(Icons.receipt_long_outlined),
                    onPressed: () => Navigator.push(context,
                        MaterialPageRoute<void>(builder: (_) => PartyStatementScreen(partyName: partyKeyValue))),
                  ),
                if (partyKeyValue.isNotEmpty)
                  IconButton(
                    tooltip: 'مشخصات و مانده افتتاحیه',
                    icon: const Icon(Icons.badge_outlined),
                    onPressed: () => Navigator.push(
                        context, MaterialPageRoute<bool>(builder: (_) => PartyMasterScreen(partyName: partyKeyValue))),
                  ),
              ],
            ),
            body: a == null
                ? const Center(child: CircularProgressIndicator())
                : _body(context, a),
          );
        },
      ),
    );
  }

  Widget _body(BuildContext context, PartyAccount a) {
    final scheme = Theme.of(context).colorScheme;
    final settled = a.net.abs() < 1;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        if (a.bought > 0 || a.sold > 0)
        Card(
          color: scheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              if (a.bought > 0) ...[
                infoRow('جمع خرید از او', '${faNum(a.bought, dec: 0)} تومان'),
                infoRow('پرداخت‌شده به او', '${faNum(a.paid, dec: 0)} تومان'),
                infoRow('بدهی ما به او', '${faNum(a.weOwe, dec: 0)} تومان',
                    valueColor: a.weOwe > 0.5 ? Colors.red.shade800 : null),
              ],
              if (a.bought > 0 && a.sold > 0) const Divider(),
              if (a.sold > 0) ...[
                infoRow('جمع فروش به او', '${faNum(a.sold, dec: 0)} تومان'),
                infoRow('دریافت‌شده از او', '${faNum(a.received, dec: 0)} تومان'),
                infoRow('طلب ما از او', '${faNum(a.theyOwe, dec: 0)} تومان',
                    valueColor: a.theyOwe > 0.5 ? Colors.green.shade800 : null),
              ],
              if (a.bought > 0 && a.sold > 0) ...[
                const Divider(),
                infoRow(
                  settled ? 'تراز نهایی' : (a.net > 0 ? 'تراز نهایی: او به ما بدهکار است' : 'تراز نهایی: ما به او بدهکاریم'),
                  settled ? 'تسویه' : '${faNum(a.net.abs(), dec: 0)} تومان',
                ),
              ],
            ]),
          ),
        ),
        const SizedBox(height: 8),
        if (a.key.isNotEmpty) ...[
          _loanBook(context, a),
          const SizedBox(height: 8),
        ],
        CashFlowCard(partyKeyFilter: a.key),
        if (a.entries.isNotEmpty) sectionTitle(context, 'خرید و فروش‌ها'),
        for (final e in a.entries) _entry(context, a, e),
      ],
    );
  }

  /// دفتر قرض و وام این طرف‌حساب (جدا از خرید/فروش؛ در سود و زیان حساب نمی‌شود)
  Widget _loanBook(BuildContext context, PartyAccount a) {
    final scheme = Theme.of(context).colorScheme;
    final net = a.loanNet;
    final settledLoan = net.abs() < 1;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.handshake_outlined, color: scheme.primary),
            const SizedBox(width: 8),
            Text('دفتر قرض و وام', style: Theme.of(context).textTheme.titleMedium),
          ]),
          const SizedBox(height: 4),
          const Text('این مبالغ در سود و زیان حساب نمی‌شوند.',
              style: TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 8),
          if (a.hasLoans) ...[
            if (a.loanGiven > 0) infoRow('قرض اعطایی (به او داده‌ایم)', '${faNum(a.loanGiven, dec: 0)} تومان'),
            if (a.loanTaken > 0) infoRow('قرض دریافتی (از او گرفته‌ایم)', '${faNum(a.loanTaken, dec: 0)} تومان'),
            if (a.repaidToUs > 0) infoRow('بازپرداخت دریافتی', '${faNum(a.repaidToUs, dec: 0)} تومان'),
            if (a.repaidByUs > 0) infoRow('بازپرداخت پرداختی', '${faNum(a.repaidByUs, dec: 0)} تومان'),
            const Divider(),
            infoRow(
              settledLoan ? 'مانده قرض' : (net > 0 ? 'مانده طلب قرضی (او به ما بدهکار است)' : 'مانده بدهی قرضی (ما به او بدهکاریم)'),
              settledLoan ? 'تسویه' : '${faNum(net.abs(), dec: 0)} تومان',
              valueColor: settledLoan ? null : (net > 0 ? Colors.green.shade800 : Colors.red.shade800),
            ),
          ] else
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Text('هنوز قرض یا وامی ثبت نشده.'),
            ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.tonalIcon(
              onPressed: () => showLoanSheet(context, party: a.name, kind: 'given'),
              icon: const Icon(Icons.north_east),
              label: const Text('اعطای قرض'),
            ),
            FilledButton.tonalIcon(
              onPressed: () => showLoanSheet(context, party: a.name, kind: 'taken'),
              icon: const Icon(Icons.south_west),
              label: const Text('دریافت قرض'),
            ),
            OutlinedButton.icon(
              onPressed: () {
                // بازپرداخت فقط وقتی معنی دارد که بدهی/طلب قرضی باز داشته باشیم
                if (a.loanReceivable <= 0.5 && a.loanPayable <= 0.5) {
                  snack(context, 'بدهی برای بازپرداخت وجود ندارد. برای قرض تازه از «اعطای قرض» یا «دریافت قرض» استفاده کنید.');
                  return;
                }
                showLoanSheet(context,
                    party: a.name,
                    kind: a.loanReceivable > 0.5 ? 'repay_in' : 'repay_out',
                    maxIn: a.loanReceivable > 0.5 ? a.loanReceivable : 0,
                    maxOut: a.loanPayable > 0.5 ? a.loanPayable : 0);
              },
              icon: const Icon(Icons.swap_horiz),
              label: const Text('ثبت بازپرداخت'),
            ),
            if (a.hasLoans)
              OutlinedButton.icon(
                onPressed: () => exportLoanPdf(context, party: a),
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: const Text('PDF دفتر قرض'),
              ),
          ]),
          if (a.hasLoans) ...[
            const SizedBox(height: 8),
            for (final l in a.loans) _loanTile(context, l),
          ],
        ]),
      ),
    );
  }

  Widget _loanTile(BuildContext context, LoanEntry l) {
    final color = l.isIn ? Colors.green.shade800 : Colors.deepOrange.shade800;
    return ListTile(
      key: ValueKey('loan${l.id}'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(l.isIn ? Icons.south_west : Icons.north_east, color: color),
      title: Text('${l.label} • ${faNum(l.amount, dec: 0)} تومان', style: TextStyle(color: color, fontWeight: FontWeight.w600)),
      subtitle: Text('${jalaliDateFromDt(l.date)}${(l.note ?? '').isEmpty ? '' : '\n${l.note}'}'),
      isThreeLine: (l.note ?? '').isNotEmpty,
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'حذف',
        onPressed: () async {
          final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('حذف این مورد؟'),
              content: Text('${l.label} به مبلغ ${faNum(l.amount, dec: 0)} تومان حذف می‌شود.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('حذف')),
              ],
            ),
          );
          if (ok == true && context.mounted) {
            await saveConfirmed(context, () => AppDb.I.deleteLoanEntry(l.id), successMsg: 'حذف شد');
          }
        },
      ),
    );
  }

  Widget _entry(BuildContext context, PartyAccount a, PartyEntry e) {
    final open = e.remaining > 0.5;
    return Card(
      key: ValueKey('${e.isPurchase}${e.id}'),
      child: ListTile(
        leading: Icon(e.isPurchase ? Icons.shopping_cart_outlined : Icons.sell_outlined),
        title: Text('${e.isPurchase ? 'خرید' : 'فروش'} ${e.label} • ${faNum(e.weight)} کیلو (خالص)'),
        subtitle: Text(
          '${jalaliDateFromDt(e.date)}\n'
          'مبلغ ${faNum(e.total, dec: 0)} • تسویه‌شده ${faNum(e.settled, dec: 0)}'
          '${open ? ' • مانده ${faNum(e.remaining, dec: 0)}' : ' • تسویه کامل'}',
          style: TextStyle(color: open ? Theme.of(context).colorScheme.error : null),
        ),
        isThreeLine: true,
        trailing: const Icon(Icons.chevron_left),
        onTap: () {
          if (e.isPurchase) {
            Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => PaymentScreen(
                        purchaseId: e.id, purchaseLabel: '${e.label} - ${jalaliDateFromDt(e.date)}')));
          } else {
            Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => ReceiptScreen(
                        saleId: e.id, saleLabel: '${a.name} - ${jalaliDateFromDt(e.date)}')));
          }
        },
      ),
    );
  }
}
