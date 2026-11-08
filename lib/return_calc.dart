// Pure (no Flutter / no DB) helpers for sale/purchase returns, so they can be unit-tested (test/return_calc_test.dart).

/// One due row as seen by [applyReturnCredit].
typedef DueRow = ({String party, bool receivable, bool paid, bool eligible, DateTime date, double amount});

/// Applies each party's return credit to its UNPAID dues, nearest due date first.
///
/// credit(party) = Σ(return value) − Σ(refund already paid back)  (never negative).
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
    final double take = c < r.amount ? c : r.amount;
    out[i] = r.amount - take;
    pool[r.party] = c - take;
  }
  return out;
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
