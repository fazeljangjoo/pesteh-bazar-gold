import 'package:flutter/material.dart';

import 'charts.dart';
import 'db.dart';
import 'ledger.dart';
import 'notify_service.dart';
import 'pdf_output.dart';
import 'pdf_service.dart';
import 'fmt.dart' show Fmt, MoneyField;
import 'utils.dart';
import 'widgets.dart';

// ============================================================================
// کارت «گردش واریزی و برداشت» (نمودار میله‌ای در بازهٔ تاریخِ انتخابی)
// ============================================================================
class CashFlowCard extends StatefulWidget {
  /// اگر مقدار داشته باشد فقط همان طرف‌حساب نمایش داده می‌شود
  final String? partyKeyFilter;
  const CashFlowCard({super.key, this.partyKeyFilter});

  @override
  State<CashFlowCard> createState() => _CashFlowCardState();
}

class _CashFlowCardState extends State<CashFlowCard> {
  late DateTime _from;
  late DateTime _to;
  bool _withLoans = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final j = gregorianToJalali(now.year, now.month, now.day);
    _from = jalaliToGregorian(j[0], j[1], 1);
    _to = jalaliToGregorian(j[0], j[1], daysInJalaliMonth(j[0], j[1]));
  }

  @override
  Widget build(BuildContext context) {
    return ChartCard(
      title: 'گردش واریزی و برداشت',
      subtitle: 'فقط تراکنش‌های انجام‌شده • از ${jalaliDateFromDt(_from)} تا ${jalaliDateFromDt(_to)}',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () async {
                final d = await pickDate(context, initial: _from);
                if (d != null) setState(() => _from = d);
              },
              child: Text('از: ${jalaliDateFromDt(_from)}'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton(
              onPressed: () async {
                final d = await pickDate(context, initial: _to);
                if (d != null) setState(() => _to = d);
              },
              child: Text('تا: ${jalaliDateFromDt(_to)}'),
            ),
          ),
        ]),
        const SizedBox(height: 6),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilterChip(
            label: const Text('با احتساب قرض و وام'),
            selected: _withLoans,
            onSelected: (v) => setState(() => _withLoans = v),
          ),
        ),
        const SizedBox(height: 8),
        FutureBuilder<List<CashFlow>>(
          future: _to.isBefore(_from)
              ? Future.value(<CashFlow>[])
              : loadCashFlows(
                  from: _from, to: _to, partyKeyFilter: widget.partyKeyFilter, includeLoans: _withLoans),
          builder: (context, snap) {
            if (snap.hasError) return ChartEmpty('خطا در بارگذاری: ${snap.error}');
            if (!snap.hasData) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (_to.isBefore(_from)) return const ChartEmpty('تاریخ «تا» باید بعد از «از» باشد');
            final rows = snap.data!;
            final buckets = buildBuckets(_from, _to);
            final ins = List<double>.filled(buckets.length, 0);
            final outs = List<double>.filled(buckets.length, 0);
            double totalIn = 0, totalOut = 0;
            for (final r in rows) {
              if (r.isIn) {
                totalIn += r.amount;
              } else {
                totalOut += r.amount;
              }
              for (var i = 0; i < buckets.length; i++) {
                if (buckets[i].contains(r.date)) {
                  if (r.isIn) {
                    ins[i] += r.amount;
                  } else {
                    outs[i] += r.amount;
                  }
                  break;
                }
              }
            }
            if (rows.isEmpty) return const ChartEmpty('در این بازه تراکنشی انجام نشده');
            final net = totalIn - totalOut;
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              GroupedBarChart(
                groups: [
                  for (var i = 0; i < buckets.length; i++)
                    BarGroup(buckets[i].label, buckets[i].fullLabel, [ins[i], outs[i]]),
                ],
                series: const [
                  BarSeries('واریزی', kGainColor),
                  BarSeries('برداشت', Color(0xFFD9822B)),
                ],
                format: (v) => '${faCompactMoney(v)} ${Fmt.unitLabel()}',
              ),
              const SizedBox(height: 12),
              Row(children: [
                MiniStat(label: 'جمع واریزی', value: faCompactMoney(totalIn), color: kGainColor),
                MiniStat(label: 'جمع برداشت', value: faCompactMoney(totalOut), color: const Color(0xFFD9822B)),
                MiniStat(label: 'خالص', value: faCompactMoney(net), color: net >= 0 ? kGainColor : kLossColor),
              ]),
            ]);
          },
        ),
      ]),
    );
  }
}

// ============================================================================
// ثبت قرض / بازپرداخت
// ============================================================================

/// [maxIn]: مانده‌ای که هنوز می‌تواند از او پس بگیرد (طلب قرضی)، [maxOut]: مانده‌ای که هنوز باید پس بدهد (بدهی قرضی).
/// فقط برای بازپرداخت استفاده می‌شود.
Future<void> showLoanSheet(BuildContext context,
    {required String party, required String kind, double maxIn = 0, double maxOut = 0}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _LoanSheet(party: party, kind: kind, maxIn: maxIn, maxOut: maxOut),
  );
}

/// یک ردیف سررسید در فرم قرض
class _DueRow {
  final amount = TextEditingController();
  final note = TextEditingController();
  DateTime date;
  _DueRow(this.date);
  void dispose() {
    amount.dispose();
    note.dispose();
  }
}

class _LoanSheet extends StatefulWidget {
  final String party;
  final String kind;
  final double maxIn;
  final double maxOut;
  const _LoanSheet({required this.party, required this.kind, required this.maxIn, required this.maxOut});
  @override
  State<_LoanSheet> createState() => _LoanSheetState();
}

class _LoanSheetState extends State<_LoanSheet> with EditGuard<_LoanSheet> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  DateTime _date = DateTime.now();
  late String _kind;
  bool _busy = false;
  final List<_DueRow> _dues = [];

  bool get _isRepay => widget.kind == 'repay_in' || widget.kind == 'repay_out';

  @override
  void initState() {
    super.initState();
    _kind = widget.kind;
    if (!_isRepay) _dues.add(_DueRow(DateTime.now().add(const Duration(days: 30))));
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    for (final d in _dues) {
      d.dispose();
    }
    super.dispose();
  }

  String get _title => _isRepay ? 'ثبت بازپرداخت' : (_kind == 'given' ? 'اعطای قرض' : 'دریافت قرض');

  String get _hint => switch (_kind) {
        'given' => 'پولی که به ${widget.party} قرض می‌دهید',
        'taken' => 'پولی که از ${widget.party} قرض می‌گیرید',
        'repay_in' => 'پولی که ${widget.party} به شما پس می‌دهد',
        _ => 'پولی که شما به ${widget.party} پس می‌دهید',
      };

  double get _dueSum => _dues.fold<double>(0, (a, d) => a + (MoneyField.stored(d.amount) ?? 0));

  double get _repayMax => _kind == 'repay_in' ? widget.maxIn : widget.maxOut;

  Future<void> _save() async {
    final amt = (MoneyField.stored(_amount) ?? 0).toDouble();
    if (amt <= 0) {
      snack(context, 'مبلغ را وارد کنید');
      return;
    }
    if (_isRepay && _repayMax <= 0.5) {
      snack(context, 'بدهی برای بازپرداخت وجود ندارد');
      return;
    }
    if (_isRepay && amt > _repayMax + 0.5) {
      snack(context, 'مبلغ بازپرداخت از مانده (${Fmt.money(_repayMax)}) بیشتر است');
      return;
    }
    final dueList = <Map<String, dynamic>>[];
    if (!_isRepay) {
      // یک سررسید با مبلغ خالی = کل مبلغ قرض
      if (_dues.length == 1 && (MoneyField.stored(_dues.first.amount) ?? 0) <= 0) {
        _dues.first.amount.text = _amount.text;
      }
      for (var i = 0; i < _dues.length; i++) {
        final a = (MoneyField.stored(_dues[i].amount) ?? 0).toDouble();
        if (a <= 0) {
          snack(context, 'مبلغ سررسید ${Fmt.money(i + 1, label: false)} را وارد کنید');
          return;
        }
        final n = _dues[i].note.text.trim();
        dueList.add({'amount': a, 'due_date': _dues[i].date.toIso8601String(), 'note': n.isEmpty ? null : n});
      }
      if ((_dueSum - amt).abs() > 0.5) {
        snack(context, 'جمع مبلغ سررسیدها (${Fmt.money(_dueSum, label: false)}) باید برابر مبلغ قرض (${Fmt.money(amt, label: false)}) باشد');
        return;
      }
    }
    setState(() => _busy = true);
    final note = _note.text.trim();
    final ok = await saveConfirmed(
      context,
      () => AppDb.I.addLoanEntry(
        party: widget.party,
        kind: _kind,
        amount: amt,
        date: _date,
        note: note.isEmpty ? null : note,
        dues: dueList,
      ),
      successMsg: '${kLoanKindLabel[_kind]} با موفقیت ثبت شد',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      NotifyService.I.rescheduleAll(); // یادآوری سررسیدهای تازه
      Navigator.pop(context);
    }
  }

  Widget _dueCard(int i) {
    final d = _dues[i];
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text('سررسید ${Fmt.money(i + 1, label: false)}', style: const TextStyle(fontWeight: FontWeight.w700))),
            if (_dues.length > 1)
              IconButton(
                tooltip: 'حذف این سررسید',
                icon: const Icon(Icons.close),
                onPressed: () => setState(() {
                  _dues.removeAt(i).dispose();
                }),
              ),
          ]),
          MoneyField(controller: d.amount, label: 'مبلغ سررسید', required: true, onChanged: () => setState(() {})),
          dateField(context, 'تاریخ سررسید', d.date, (v) => setState(() => d.date = v)),
          textField(d.note, 'جزئیات (اختیاری)'),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final amt = (MoneyField.stored(_amount) ?? 0).toDouble();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(_title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(widget.party, style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 12),
            if (_isRepay) ...[
              SegmentedButton<String>(
                segments: <ButtonSegment<String>>[
                  ButtonSegment<String>(
                      value: 'repay_in', label: const Text('او به ما پس داد'), enabled: widget.maxIn > 0.5),
                  ButtonSegment<String>(
                      value: 'repay_out', label: const Text('ما به او پس دادیم'), enabled: widget.maxOut > 0.5),
                ],
                selected: <String>{_kind},
                showSelectedIcon: false,
                onSelectionChanged: (v) => setState(() => _kind = v.first),
              ),
              const SizedBox(height: 6),
              Text('مانده قابل بازپرداخت: ${Fmt.money(_repayMax)}',
                  style: const TextStyle(fontSize: 12.5, color: Colors.black54)),
              const SizedBox(height: 10),
            ],
            MoneyField(controller: _amount, label: 'مبلغ', required: true, hint: _hint, onChanged: () => setState(() {})),
            dateField(context, _isRepay ? 'تاریخ بازپرداخت' : (_kind == 'given' ? 'تاریخ اعطای قرض' : 'تاریخ دریافت قرض'), _date,
                (d) => setState(() => _date = d)),
            textField(_note, 'توضیحات (اختیاری)'),
            if (!_isRepay) ...[
              const SizedBox(height: 4),
              Text('سررسیدها (حداکثر ۲۰ مورد)', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 2),
              const Text('در هر سررسید یادآوری می‌شود و از صفحهٔ «سررسیدها» می‌توانید «انجام شد» را بزنید.',
                  style: TextStyle(fontSize: 12, color: Colors.black54)),
              const SizedBox(height: 8),
              for (var i = 0; i < _dues.length; i++) _dueCard(i),
              Row(children: [
                Expanded(
                  child: Text(
                    'جمع سررسیدها: ${Fmt.money(_dueSum, label: false)} از ${Fmt.money(amt)}',
                    style: TextStyle(
                        fontSize: 12.5,
                        color: (_dueSum - amt).abs() <= 0.5 ? Colors.green.shade800 : Colors.deepOrange.shade800),
                  ),
                ),
                TextButton.icon(
                  onPressed: _dues.length >= 20
                      ? null
                      : () => setState(() => _dues.add(_DueRow(_dues.last.date.add(const Duration(days: 30))))),
                  icon: const Icon(Icons.add),
                  label: const Text('افزودن سررسید'),
                ),
              ]),
            ],
            const Text('این مبلغ در سود و زیان حساب نمی‌شود.', style: TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _save,
              icon: _busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check),
              label: const Text('ثبت'),
            ),
          ]),
        ),
      ),
    );
  }
}

// ============================================================================
// PDF دفتر قرض و وام (یک طرف‌حساب یا همهٔ طرف‌حساب‌ها)
// ============================================================================
Future<void> exportLoanPdf(BuildContext context, {PartyAccount? party, List<PartyAccount>? all}) async {
  try {
    final accounts = party != null ? [party] : (all ?? <PartyAccount>[]);
    final withLoans = accounts.where((a) => a.hasLoans).toList();
    if (withLoans.isEmpty) {
      snack(context, 'هنوز قرض یا وامی ثبت نشده است');
      return;
    }
    final keys = withLoans.map((a) => a.key).toSet();
    double recv = 0, pay = 0;
    for (final a in withLoans) {
      if (a.loanReceivable > 0) recv += a.loanReceivable;
      if (a.loanPayable > 0) pay += a.loanPayable;
    }
    final single = withLoans.length == 1;
    final entries = <List<String>>[
      [if (!single) 'طرف‌حساب', 'نوع', 'مبلغ (ریال)', 'تاریخ', 'توضیحات'],
    ];
    for (final a in withLoans) {
      for (final l in a.loans) {
        entries.add([
          if (!single) a.name,
          l.label,
          Fmt.money(l.amount, label: false),
          jalaliDateFromDt(l.date),
          l.note ?? '',
        ]);
      }
    }
    final dueRows = <List<String>>[
      [if (!single) 'طرف‌حساب', 'نوع', 'مبلغ (ریال)', 'سررسید', 'وضعیت', 'جزئیات'],
    ];
    for (final r in await AppDb.I.loanDueRows(includePaid: true)) {
      if (!keys.contains(partyKey(r['party'] as String?))) continue;
      final given = r['kind'] == 'given';
      final paid = ((r['paid'] as num?) ?? 0) == 1;
      dueRows.add([
        if (!single) partyKey(r['party'] as String?),
        given ? 'قرض اعطایی' : 'قرض دریافتی',
        Fmt.money((r['amount'] as num).toDouble(), label: false),
        jalaliDateFromDt(DateTime.parse(r['due_date'] as String)),
        paid ? (given ? 'دریافت شد' : 'پرداخت شد') : 'در انتظار',
        (r['note'] as String?) ?? '',
      ]);
    }
    final file = await PdfService.buildLoanLedger(
      title: single ? 'دفتر قرض و وام — ${withLoans.first.name}' : 'دفتر قرض و وام — همهٔ طرف‌حساب‌ها',
      subtitle: '',
      summary: [
        ('مانده طلب قرضی', '${Fmt.money(recv)}'),
        ('مانده بدهی قرضی', '${Fmt.money(pay)}'),
      ],
      sections: [
        (heading: 'تراکنش‌های قرض و بازپرداخت', rows: entries),
        (heading: 'سررسیدها', rows: dueRows),
      ],
    );
    if (context.mounted) await PdfOutput.show(context, file);
  } catch (e) {
    if (context.mounted) snack(context, 'خطا در ساخت PDF: $e');
  }
}

// ============================================================================
// تعریف طرف‌حساب جدید
// ============================================================================
Future<void> showNewPartyDialog(BuildContext context) {
  return showDialog<void>(context: context, builder: (_) => const _NewPartyDialog());
}

class _NewPartyDialog extends StatefulWidget {
  const _NewPartyDialog();
  @override
  State<_NewPartyDialog> createState() => _NewPartyDialogState();
}

class _NewPartyDialogState extends State<_NewPartyDialog> with EditGuard<_NewPartyDialog> {
  final _name = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      snack(context, 'نام طرف‌حساب را وارد کنید');
      return;
    }
    setState(() => _busy = true);
    final name = _name.text.trim();
    final ok = await saveConfirmed(context, () => AppDb.I.addParty(name),
        successMsg: 'طرف‌حساب «$name» با موفقیت تعریف شد');
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('طرف‌حساب جدید'),
      content: TextField(
        controller: _name,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'نام طرف‌حساب', border: OutlineInputBorder()),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('انصراف')),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('تعریف')),
      ],
    );
  }
}
