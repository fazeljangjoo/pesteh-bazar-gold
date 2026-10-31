import 'db.dart';

/// یکسان‌سازی نام طرف حساب: «ي/ك» عربی، فاصله‌های اضافه
String partyKey(String? name) {
  if (name == null) return '';
  return name
      .replaceAll('ي', 'ی')
      .replaceAll('ك', 'ک')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

// ======================= سررسیدها =======================

/// یک تراکنش پرداخت‌نشده (یکجا/قسط/چک) از خرید (پرداختی) یا فروش (دریافتی)
class DueItem {
  final String table; // نام جدول برای علامت‌گذاری «انجام شد»
  final int id;
  final bool receivable; // true = باید از خریدار بگیریم، false = باید به فروشنده بدهیم
  final String kind; // یکجا | قسط | چک
  final String party;
  final String label;
  final String? ref; // شماره چک
  final String? bank;
  final double amount;
  final DateTime date;
  final bool paid;
  DueItem({
    required this.table,
    required this.id,
    required this.receivable,
    required this.kind,
    required this.party,
    required this.label,
    required this.ref,
    required this.bank,
    required this.amount,
    required this.date,
    required this.paid,
  });
}

Future<List<DueItem>> loadDues({bool includePaid = false}) async {
  final d = await AppDb.I.db;
  final out = <DueItem>[];

  Future<void> add(String sql, String table, bool receivable, String kind) async {
    final rows = await d.rawQuery(sql);
    for (final r in rows) {
      final paid = ((r['paid'] as num?) ?? 0) == 1;
      if (paid && !includePaid) continue;
      out.add(DueItem(
        table: table,
        id: r['id'] as int,
        receivable: receivable,
        kind: kind,
        party: partyKey(r['party'] as String?),
        label: (r['label'] as String?) ?? '',
        ref: r['ref'] as String?,
        bank: r['bank'] as String?,
        amount: (r['amount'] as num).toDouble(),
        date: DateTime.parse(r['date'] as String),
        paid: paid,
      ));
    }
  }

  // ---- پرداختی‌ها (خرید) ----
  const payBase = 'FROM %T% x JOIN payments pay ON pay.id = x.payment_id '
      'JOIN purchases p ON p.id = pay.purchase_id ';
  await add(
      'SELECT x.id AS id, x.amount AS amount, x.date AS date, x.paid AS paid, '
      'p.seller AS party, p.type_name AS label, NULL AS ref, NULL AS bank '
      '${payBase.replaceAll('%T%', 'lump_tx')} WHERE pay.pay_type IN (\'lump\', \'mixed\')',
      'lump_tx',
      false,
      'یکجا');
  await add(
      'SELECT x.id AS id, x.amount AS amount, x.due_date AS date, x.paid AS paid, '
      'p.seller AS party, p.type_name AS label, NULL AS ref, NULL AS bank '
      '${payBase.replaceAll('%T%', 'credit_inst')} '
      'WHERE (pay.pay_type = \'mixed\' OR (pay.pay_type = \'staged\' AND pay.staged_type = \'credit\'))',
      'credit_inst',
      false,
      'قسط');
  await add(
      'SELECT x.id AS id, x.amount AS amount, x.due_date AS date, x.paid AS paid, '
      'p.seller AS party, p.type_name AS label, x.cheque_no AS ref, x.bank_name AS bank '
      '${payBase.replaceAll('%T%', 'cheque_inst')} '
      'WHERE (pay.pay_type = \'mixed\' OR (pay.pay_type = \'staged\' AND pay.staged_type = \'cheque\'))',
      'cheque_inst',
      false,
      'چک');

  // ---- دریافتی‌ها (فروش) ----
  const recBase = 'FROM %T% x JOIN receipts rec ON rec.id = x.receipt_id '
      'JOIN sales s ON s.id = rec.sale_id ';
  await add(
      'SELECT x.id AS id, x.amount AS amount, x.date AS date, x.paid AS paid, '
      's.buyer AS party, \'فروش\' AS label, NULL AS ref, NULL AS bank '
      '${recBase.replaceAll('%T%', 'receipt_lump_tx')} WHERE rec.recv_type = \'lump\'',
      'receipt_lump_tx',
      true,
      'یکجا');
  await add(
      'SELECT x.id AS id, x.amount AS amount, x.due_date AS date, x.paid AS paid, '
      's.buyer AS party, \'فروش\' AS label, NULL AS ref, NULL AS bank '
      '${recBase.replaceAll('%T%', 'receipt_credit_inst')} '
      'WHERE rec.recv_type = \'staged\' AND rec.staged_type = \'credit\'',
      'receipt_credit_inst',
      true,
      'قسط');
  await add(
      'SELECT x.id AS id, x.amount AS amount, x.due_date AS date, x.paid AS paid, '
      's.buyer AS party, \'فروش\' AS label, x.cheque_no AS ref, x.bank_name AS bank '
      '${recBase.replaceAll('%T%', 'receipt_cheque_inst')} '
      'WHERE rec.recv_type = \'staged\' AND rec.staged_type = \'cheque\'',
      'receipt_cheque_inst',
      true,
      'چک');

  // ---- سررسید قرض و وام (اعطای قرض = دریافتی ما، دریافت قرض = پرداختیِ ما) ----
  for (final r in await AppDb.I.loanDueRows(includePaid: includePaid)) {
    final given = r['kind'] == 'given';
    out.add(DueItem(
      table: 'loan_dues',
      id: r['id'] as int,
      receivable: given,
      kind: 'قرض',
      party: partyKey(r['party'] as String?),
      label: given ? 'قرض اعطایی' : 'قرض دریافتی',
      ref: null,
      bank: null,
      amount: (r['amount'] as num).toDouble(),
      date: DateTime.parse(r['due_date'] as String),
      paid: ((r['paid'] as num?) ?? 0) == 1,
    ));
  }

  out.sort((a, b) => a.date.compareTo(b.date));
  return out;
}

// ======================= حساب طرف‌ها =======================

class PartyEntry {
  final bool isPurchase; // true = خرید از او، false = فروش به او
  final int id;
  final DateTime date;
  final String label;
  final double weight;
  final double total;
  final double settled;
  PartyEntry({
    required this.isPurchase,
    required this.id,
    required this.date,
    required this.label,
    required this.weight,
    required this.total,
    required this.settled,
  });
  double get remaining => total - settled;
}

/// نام‌های رسمی انواع تراکنش دفتر قرض و وام
const Map<String, String> kLoanKindLabel = {
  'given': 'قرض اعطایی',
  'taken': 'قرض دریافتی',
  'repay_in': 'بازپرداخت دریافتی',
  'repay_out': 'بازپرداخت پرداختی',
};

/// آیا این نوع تراکنش پول به حساب ما وارد می‌کند؟ (قرض دریافتی / بازپرداخت دریافتی)
bool loanKindIsIn(String kind) => kind == 'taken' || kind == 'repay_in';

class LoanEntry {
  final int id;
  final String uid;
  final String kind; // given | taken | repay_in | repay_out
  final double amount;
  final DateTime date;
  final String? note;
  LoanEntry({
    required this.id,
    required this.uid,
    required this.kind,
    required this.amount,
    required this.date,
    required this.note,
  });
  String get label => kLoanKindLabel[kind] ?? kind;
  bool get isIn => loanKindIsIn(kind);
}

class PartyAccount {
  final String key;
  double bought = 0; // جمع خرید از او
  double paid = 0; // پرداخت‌شده به او
  double sold = 0; // جمع فروش به او
  double received = 0; // دریافت‌شده از او
  final List<PartyEntry> entries = [];

  // ---- دفتر قرض و وام (جدا از خرید/فروش؛ در سود و زیان حساب نمی‌شود) ----
  double loanGiven = 0; // قرض اعطایی
  double loanTaken = 0; // قرض دریافتی
  double repaidToUs = 0; // بازپرداخت دریافتی (او به ما پس داده)
  double repaidByUs = 0; // بازپرداخت پرداختی (ما به او پس داده‌ایم)
  final List<LoanEntry> loans = [];

  PartyAccount(this.key);

  /// مانده طلب قرضی: چقدر از قرضِ اعطایی هنوز به ما برنگشته
  double get loanReceivable => loanGiven - repaidToUs;

  /// مانده بدهی قرضی: چقدر از قرضِ دریافتی هنوز پس نداده‌ایم
  double get loanPayable => loanTaken - repaidByUs;

  /// مثبت = او بابت قرض به ما بدهکار است، منفی = ما بدهکاریم
  double get loanNet => loanReceivable - loanPayable;

  bool get hasLoans => loans.isNotEmpty;

  /// تراز کل (خرید/فروش + قرض)
  double get totalNet => net + loanNet;

  String get name => key.isEmpty ? 'بدون نام' : key;

  /// بدهی ما به او
  double get weOwe => bought - paid;

  /// طلب ما از او
  double get theyOwe => sold - received;

  /// مثبت = او به ما بدهکار است، منفی = ما به او بدهکاریم
  double get net => theyOwe - weOwe;
}

double _settledOf(String? type, String? staged, num lump, num credit, num cheque) {
  if (type == 'lump') return lump.toDouble();
  if (type == 'staged' && staged == 'credit') return credit.toDouble();
  if (type == 'staged' && staged == 'cheque') return cheque.toDouble();
  if (type == 'mixed') return (lump + credit + cheque).toDouble();
  return 0;
}

Future<List<PartyAccount>> loadParties() async {
  final d = await AppDb.I.db;
  final map = <String, PartyAccount>{};
  PartyAccount acc(String? name) => map.putIfAbsent(partyKey(name), () => PartyAccount(partyKey(name)));

  final purchases = await d.rawQuery('''
      SELECT p.id AS id, p.seller AS party, p.date AS date, p.type_name AS label,
             p.net_weight AS net, p.price AS price,
             pay.pay_type AS pt, pay.staged_type AS st,
             COALESCE((SELECT SUM(amount) FROM lump_tx WHERE payment_id = pay.id AND paid = 1), 0) AS lp,
             COALESCE((SELECT SUM(amount) FROM credit_inst WHERE payment_id = pay.id AND paid = 1), 0) AS cp,
             COALESCE((SELECT SUM(amount) FROM cheque_inst WHERE payment_id = pay.id AND paid = 1), 0) AS hp
      FROM purchases p LEFT JOIN payments pay ON pay.purchase_id = p.id
      WHERE p.is_mix = 0''');
  for (final r in purchases) {
    final net = (r['net'] as num).toDouble();
    final total = net * (r['price'] as num).toDouble();
    final settled = _settledOf(r['pt'] as String?, r['st'] as String?, r['lp'] as num,
        r['cp'] as num, r['hp'] as num);
    final a = acc(r['party'] as String?);
    a.bought += total;
    a.paid += settled;
    a.entries.add(PartyEntry(
      isPurchase: true,
      id: r['id'] as int,
      date: DateTime.parse(r['date'] as String),
      label: (r['label'] as String?) ?? '',
      weight: net,
      total: total,
      settled: settled,
    ));
  }

  final sales = await d.rawQuery('''
      SELECT s.id AS id, s.buyer AS party, s.date AS date,
             s.net_weight AS net, s.price AS price,
             rec.recv_type AS rt, rec.staged_type AS st,
             COALESCE((SELECT SUM(amount) FROM receipt_lump_tx WHERE receipt_id = rec.id AND paid = 1), 0) AS lp,
             COALESCE((SELECT SUM(amount) FROM receipt_credit_inst WHERE receipt_id = rec.id AND paid = 1), 0) AS cp,
             COALESCE((SELECT SUM(amount) FROM receipt_cheque_inst WHERE receipt_id = rec.id AND paid = 1), 0) AS hp
      FROM sales s LEFT JOIN receipts rec ON rec.sale_id = s.id''');
  for (final r in sales) {
    final net = (r['net'] as num).toDouble();
    final total = net * (r['price'] as num).toDouble();
    final settled = _settledOf(r['rt'] as String?, r['st'] as String?, r['lp'] as num,
        r['cp'] as num, r['hp'] as num);
    final a = acc(r['party'] as String?);
    a.sold += total;
    a.received += settled;
    a.entries.add(PartyEntry(
      isPurchase: false,
      id: r['id'] as int,
      date: DateTime.parse(r['date'] as String),
      label: 'فروش',
      weight: net,
      total: total,
      settled: settled,
    ));
  }

  // طرف‌حساب‌هایی که دستی تعریف شده‌اند (حتی اگر هنوز خرید/فروشی نداشته باشند)
  for (final r in await d.query('parties')) {
    acc(r['name'] as String?);
  }

  // دفتر قرض و وام
  for (final r in await d.query('loan_entries', orderBy: 'date DESC, id DESC')) {
    final a = acc(r['party'] as String?);
    final kind = (r['kind'] as String?) ?? '';
    final amount = (r['amount'] as num).toDouble();
    switch (kind) {
      case 'given':
        a.loanGiven += amount;
        break;
      case 'taken':
        a.loanTaken += amount;
        break;
      case 'repay_in':
        a.repaidToUs += amount;
        break;
      case 'repay_out':
        a.repaidByUs += amount;
        break;
      default:
        continue;
    }
    a.loans.add(LoanEntry(
      id: (r['id'] as num).toInt(),
      uid: (r['uid'] as String?) ?? '',
      kind: kind,
      amount: amount,
      date: DateTime.parse(r['date'] as String),
      note: r['note'] as String?,
    ));
  }

  final list = map.values.toList();
  for (final a in list) {
    a.entries.sort((x, y) => y.date.compareTo(x.date));
  }
  list.sort((a, b) => b.totalNet.abs().compareTo(a.totalNet.abs()));
  return list;
}

// ======================= گردش واریزی و برداشت =======================

/// یک حرکت واقعیِ پول: واریزی (به حساب ما) یا برداشت (از حساب ما)
class CashFlow {
  final DateTime date;
  final double amount;
  final bool isIn; // true = واریزی، false = برداشت
  final String party;
  final bool isLoan;
  CashFlow(this.date, this.amount, this.isIn, this.party, this.isLoan);
}

/// فقط تراکنش‌های «انجام‌شده» (تسویه‌شده) در بازهٔ [from, to] (هر دو شامل).
/// واریزی = دریافت از خریدارها (+ قرض دریافتی و بازپرداخت دریافتی در صورت [includeLoans])
/// برداشت = پرداخت به فروشنده‌ها (+ قرض اعطایی و بازپرداخت پرداختی در صورت [includeLoans])
Future<List<CashFlow>> loadCashFlows({
  required DateTime from,
  required DateTime to,
  String? partyKeyFilter,
  bool includeLoans = false,
}) async {
  final out = <CashFlow>[];
  final start = DateTime(from.year, from.month, from.day);
  final endEx = DateTime(to.year, to.month, to.day + 1);
  bool inRange(DateTime d) => !d.isBefore(start) && d.isBefore(endEx);
  bool matches(String name) => partyKeyFilter == null || partyKey(name) == partyKeyFilter;

  final db = AppDb.I;
  for (final r in await db.allReceiptTransactions()) {
    if (((r['paid'] as num?) ?? 0) != 1) continue;
    final dt = DateTime.parse(r['date'] as String);
    final name = '${r['name'] ?? ''}';
    if (!inRange(dt) || !matches(name == '-' ? '' : name)) continue;
    out.add(CashFlow(dt, (r['amount'] as num).toDouble(), true, name, false));
  }
  for (final r in await db.allPaymentTransactions()) {
    if (((r['paid'] as num?) ?? 0) != 1) continue;
    final dt = DateTime.parse(r['date'] as String);
    final name = '${r['name'] ?? ''}';
    if (!inRange(dt) || !matches(name == '-' ? '' : name)) continue;
    out.add(CashFlow(dt, (r['amount'] as num).toDouble(), false, name, false));
  }
  if (includeLoans) {
    for (final r in await db.loanEntries()) {
      final dt = DateTime.parse(r['date'] as String);
      final name = '${r['party'] ?? ''}';
      if (!inRange(dt) || !matches(name)) continue;
      out.add(CashFlow(dt, (r['amount'] as num).toDouble(), loanKindIsIn('${r['kind']}'), name, true));
    }
  }
  return out;
}
