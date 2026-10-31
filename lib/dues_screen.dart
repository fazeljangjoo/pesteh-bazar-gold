import 'package:flutter/material.dart';
import 'fmt.dart' show Fmt;

import 'cheque_ui.dart';
import 'db.dart';
import 'live_query.dart';
import 'ledger.dart';
import 'notify_service.dart';
import 'utils.dart';
import 'widgets.dart';

enum _DueFilter { all, payable, receivable }

DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

/// چند روز تا سررسید (منفی = گذشته)
int daysUntil(DateTime due) => _dayOf(due).difference(_dayOf(DateTime.now())).inDays;

String dueWhen(DateTime due) {
  final n = daysUntil(due);
  if (n == 0) return 'امروز';
  if (n > 0) return '${faNum(n)} روز دیگر';
  return '${faNum(-n)} روز گذشته';
}

/// صفحهٔ سررسیدها: همهٔ چک‌ها، اقساط و پرداخت‌های زمان‌دار — هم پرداختی هم دریافتی
class DuesScreen extends StatefulWidget {
  const DuesScreen({super.key});
  @override
  State<DuesScreen> createState() => _DuesScreenState();
}

class _DuesScreenState extends State<DuesScreen> {
  _DueFilter _filter = _DueFilter.all;

  Future<void> _cancelNotification(DueItem i) async {
    try {
      switch (i.table) {
        case 'credit_inst':
          await NotifyService.I.cancelCreditRow(i.id);
          break;
        case 'cheque_inst':
          await NotifyService.I.cancelChequeRow(i.id);
          break;
        case 'receipt_credit_inst':
          await NotifyService.I.cancelReceiptCreditRow(i.id);
          break;
        case 'receipt_cheque_inst':
          await NotifyService.I.cancelReceiptChequeRow(i.id);
          break;
        case 'loan_dues':
          await NotifyService.I.cancelLoanRow(i.id);
          break;
      }
    } catch (_) {}
  }

  Future<void> _markDone(DueItem i) async {
    final verb = i.receivable ? 'دریافت' : 'پرداخت';
    final who = i.party.isEmpty ? '' : ' ${i.receivable ? 'از' : 'به'} ${i.party}';
    final ok = await confirm(
        context, '${i.kind} به مبلغ ${Fmt.money(i.amount)}$who «$verb شد» ثبت شود؟');
    if (!ok) return;
    final done = await saveConfirmed(context, () => AppDb.I.setPaid(i.table, i.id, true),
        successMsg: '$verb با موفقیت ثبت شد');
    if (!done) return;
    await _cancelNotification(i);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('سررسیدها'), actions: <Widget>[
        IconButton(
          tooltip: 'مدیریت چک',
          icon: const Icon(Icons.receipt_outlined),
          onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const ChequeListScreen())),
        ),
      ]),
      body: LiveQuery<List<DueItem>>(
        load: loadDues,
        builder: (context, snap) {
            if (snap.hasError) {
              return Center(child: Text('خطا: ${snap.error}'));
            }
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final all = snap.data!;
            final list = all.where((i) {
              if (_filter == _DueFilter.payable) return !i.receivable;
              if (_filter == _DueFilter.receivable) return i.receivable;
              return true;
            }).toList();

            double pay = 0, rec = 0, overdue = 0;
            for (final i in all) {
              if (i.receivable) {
                rec += i.amount;
              } else {
                pay += i.amount;
              }
              if (daysUntil(i.date) < 0) overdue += i.amount;
            }

            final lateList = list.where((i) => daysUntil(i.date) < 0).toList();
            final soon = list.where((i) {
              final n = daysUntil(i.date);
              return n >= 0 && n <= 7;
            }).toList();
            final later = list.where((i) => daysUntil(i.date) > 7).toList();

            return ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: [
                Card(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(children: [
                      infoRow('جمع پرداختی‌های باقی‌مانده', '${Fmt.money(pay)}'),
                      infoRow('جمع دریافتی‌های باقی‌مانده', '${Fmt.money(rec)}'),
                      if (overdue > 0)
                        infoRow('سررسید گذشته', '${Fmt.money(overdue)}',
                            valueColor: Theme.of(context).colorScheme.error),
                    ]),
                  ),
                ),
                const SizedBox(height: 8),
                SegmentedButton<_DueFilter>(
                  segments: const <ButtonSegment<_DueFilter>>[
                    ButtonSegment<_DueFilter>(value: _DueFilter.all, label: Text('همه')),
                    ButtonSegment<_DueFilter>(value: _DueFilter.payable, label: Text('پرداختی')),
                    ButtonSegment<_DueFilter>(value: _DueFilter.receivable, label: Text('دریافتی')),
                  ],
                  selected: <_DueFilter>{_filter},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => setState(() => _filter = s.first),
                ),
                if (list.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text('سررسید بازی وجود ندارد')),
                  ),
                if (lateList.isNotEmpty) ...[
                  sectionTitle(context, 'سررسید گذشته'),
                  for (final i in lateList) _tile(context, i),
                ],
                if (soon.isNotEmpty) ...[
                  sectionTitle(context, 'تا ۷ روز آینده'),
                  for (final i in soon) _tile(context, i),
                ],
                if (later.isNotEmpty) ...[
                  sectionTitle(context, 'بعداً'),
                  for (final i in later) _tile(context, i),
                ],
              ],
            );
          },
      ),
    );
  }

  Widget _tile(BuildContext context, DueItem i) {
    final scheme = Theme.of(context).colorScheme;
    final isLate = daysUntil(i.date) < 0;
    final color = i.receivable ? Colors.green.shade800 : Colors.red.shade800;
    final extra = <String>[
      i.kind,
      if ((i.bank ?? '').isNotEmpty) i.bank!,
      if ((i.ref ?? '').isNotEmpty) 'شماره ${i.ref}',
    ].join(' • ');
    return Card(
      key: ValueKey('${i.table}${i.id}'),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: i.receivable ? Colors.green.shade50 : Colors.red.shade50,
          child: Icon(i.receivable ? Icons.south_west : Icons.north_east, color: color),
        ),
        title: Text('${i.receivable ? 'دریافت از' : 'پرداخت به'} ${i.party.isEmpty ? 'بدون نام' : i.party}'),
        subtitle: Text('$extra\n${jalaliDateFromDt(i.date)} • ${dueWhen(i.date)}',
            style: TextStyle(color: isLate ? scheme.error : null)),
        isThreeLine: true,
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(Fmt.money(i.amount, label: false),
                style: TextStyle(fontWeight: FontWeight.w700, color: color)),
            const Text('ریال', style: TextStyle(fontSize: 11)),
          ],
        ),
        onTap: () => _markDone(i),
      ),
    );
  }
}
