// Pure (no Flutter / no DB) helpers for sale/purchase returns, so they can be unit-tested (test/return_calc_test.dart).

/// One due row as seen by [applyReturnCredit].
typedef DueRow = ({String party, bool receivable, bool paid, bool eligible, DateTime date, double amount});

/// Core allocation: the credit each row would consume right now, nearest due date first (ties: original order).
/// Same algorithm as server `pb_dues_credit_allocate`. Returns {row index: take} for rows that get credit (take > 0).
/// [receivableCredit]/[payableCredit] are the party pools AFTER subtracting the credit already consumed by paid rows
/// (Σ credit_used, see `loadReturnCredits`). Only `eligible` and not `paid` rows are touched; a row is reduced, never split.
Map<int, double> allocateReturnCredit({
  required List<DueRow> rows,
  required Map<String, double> receivableCredit,
  required Map<String, double> payableCredit,
}) {
  final Map<int, double> take = <int, double>{};
  final Map<String, double> rc = Map<String, double>.of(receivableCredit);
  final Map<String, double> pc = Map<String, double>.of(payableCredit);
  final List<int> idx = <int>[
    for (int i = 0; i < rows.length; i++)
      if (rows[i].eligible && !rows[i].paid) i,
  ]..sort((int a, int b) {
      final int c = rows[a].date.compareTo(rows[b].date);
      return c != 0 ? c : a.compareTo(b);
    });
  for (final int i in idx) {
    final DueRow r = rows[i];
    final Map<String, double> pool = r.receivable ? rc : pc;
    final double c = pool[r.party] ?? 0;
    if (c <= 0) continue;
    final double t = c < r.amount ? c : r.amount;
    if (t <= 0) continue;
    pool[r.party] = c - t;
    take[i] = t;
  }
  return take;
}

/// Applies each party's return credit to its UNPAID dues, nearest due date first.
///
/// credit(party) = Σ(return value) − Σ(refund already paid back) − Σ(credit_used of PAID rows of that party/side) (never negative;
/// the last term is subtracted by the caller in `loadReturnCredits`, so a consumed credit is never applied to the next instalment again).
/// [receivableCredit] reduces receivable dues (sales returns), [payableCredit] reduces payable dues (purchase returns).
/// Only rows with `eligible == true` (cash / instalment / cheque of a purchase or sale; NOT loans or payroll) and
/// `paid == false` are touched. A row is reduced, never split. Returns the new amount per input index
/// (same length / order as [rows]); a result below [dust] means the row is fully covered and should be hidden.
List<double> applyReturnCredit({
  required List<DueRow> rows,
  required Map<String, double> receivableCredit,
  required Map<String, double> payableCredit,
}) {
  final List<double> out = rows.map((DueRow r) => r.amount).toList();
  allocateReturnCredit(rows: rows, receivableCredit: receivableCredit, payableCredit: payableCredit)
      .forEach((int i, double take) => out[i] = rows[i].amount - take);
  return out;
}

/// Result of [settleDueRow]. [changed] == false ⇒ the row must be left as is (idempotent no-op).
typedef DueSettle = ({double amount, double creditUsed, double? ccyAmount, bool changed});

double _round2(double v) => (v * 100).roundToDouble() / 100;

/// Pure equivalent of server `pb_dues_set_paid` for ONE row (no DB):
///  * paid=true (was unpaid): take = min([take], amount); when take > 0.004 → amount −= take, credit_used = take, ccy_amount follows.
///  * paid=false (was paid with credit_used > 0): amount += credit_used, credit_used = 0, ccy_amount follows.
///  * already in the requested state ⇒ no change (never reduces twice).
/// ccy_amount follows the new rial amount: amount ÷ [fxRateInStored] (rate in stored money unit per 1 ccy) when known,
/// otherwise proportionally (ccy × new ÷ old). Rows without a currency ([ccyAmount] null) keep null.
DueSettle settleDueRow({
  required double amount,
  required double creditUsed,
  required bool wasPaid,
  required bool paid,
  required double take,
  double? ccyAmount,
  double? fxRateInStored,
}) {
  double? ccyFor(double newAmount) {
    if (ccyAmount == null) return null;
    if (fxRateInStored != null && fxRateInStored > 0) return (newAmount / fxRateInStored * 10000).roundToDouble() / 10000;
    return amount > 0 ? (ccyAmount * newAmount / amount * 10000).roundToDouble() / 10000 : ccyAmount;
  }

  final DueSettle none = (amount: amount, creditUsed: creditUsed, ccyAmount: ccyAmount, changed: false);
  if (paid == wasPaid) return none;
  if (paid) {
    final double t = take < amount ? take : amount;
    if (t <= 0.004) return none;
    final double next = _round2(amount - t);
    return (amount: next, creditUsed: _round2(t), ccyAmount: ccyFor(next), changed: true);
  }
  if (creditUsed > 0.004) {
    final double orig = _round2(amount + creditUsed);
    return (amount: orig, creditUsed: 0.0, ccyAmount: ccyFor(orig), changed: true);
  }
  return none;
}

/// Effective COST per kg of a sold consigned lot (pure mirror of server `pb_cons_cost_sql` / Flutter `consCostSql`).
/// purchase_on_sale → [agreedPrice]; otherwise sale unit price minus commission (percent: unit×(1−v/100), fixed: unit−v).
double consCostPerKg({
  required String? settlementMode,
  required String? commissionType,
  required double commissionValue,
  required double? agreedPrice,
  required double saleUnitPrice,
}) {
  if (settlementMode == 'purchase_on_sale') return agreedPrice ?? 0;
  return commissionType == 'percent' ? saleUnitPrice * (1 - commissionValue / 100) : saleUnitPrice - commissionValue;
}

/// Foreign-currency revenue/cost REVERSED by one `sale_returns.profit_lines` row.
/// Same basis as `saleFx`: revenue at the rate of the original sale date; the lot cost (+ purchase extras per kg)
/// at the rate of `purchase_date` when the row has it, otherwise the sale date. A full return therefore cancels the sale exactly.
/// Returns null when a needed rate is missing (the caller must show a warning instead of a number).
({double revenue, double cost})? returnFx(Map<String, dynamic> r, double? Function(String isoDate) rateOf) {
  double n(dynamic v) => (v is num) ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0.0);
  String s(dynamic v) => '${v ?? ''}'.trim();
  final String sd = s(r['sale_date']).isNotEmpty ? s(r['sale_date']) : s(r['date']);
  final String pd = s(r['purchase_date']).isNotEmpty ? s(r['purchase_date']) : sd;
  final double? rs = rateOf(sd);
  final double? rp = rateOf(pd);
  if (rs == null || rs <= 0 || rp == null || rp <= 0) return null;
  final double kg = n(r['kg']);
  return (revenue: kg * n(r['unit_price']) / rs, cost: kg * (n(r['cost_price']) + n(r['extra_per_kg'])) / rp);
}
