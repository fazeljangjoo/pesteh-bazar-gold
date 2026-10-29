import 'dart:convert';
import 'stock_count_local.dart';
import 'form_settings.dart' show FormSettingsLocal;
import 'grade_lines_ui.dart' show GradeLinesLocal;
import 'fx_local.dart'; // S26.T26.1
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'db_crypto.dart';
import 'package:sqflite/sqflite.dart';

import 'barcode_utils.dart';
import 'entity_store.dart';
import 'money_unit.dart'; // S29.T29.3
import 'fx_doc_field.dart' show kFxRialPerStoredUnit;


const List<String> kPresetTypesNormal = ['اکبری', 'احمدآقایی', 'فندقی', 'کله‌قوچی'];
const List<String> kPresetTypesKernel = ['مغز کال', 'مغز درجه یک', 'مغز درجه دو'];

const int kMaxCustomSpecs = 4;
const int kMaxLumpTx = 10;
const int kMaxStagedTx = 50;

/// جدول‌های داده‌ی کاربر و ستون‌هایشان — دقیقاً همان ساختار سرور/وب (`BACKUP_TABLES`
/// در app.php، بدون customer_id). ترتیب = والد ← فرزند.
const List<(String, List<String>)> _kSnapshot = [
  ('categories', ['id', 'name', 'preset_key']),
  ('types', ['id', 'category_id', 'name']),
  (
    'purchases',
    [
      'id', 'code', 'category_id', 'type_name', 'date', 'ounce', 'price', 'total_weight',
      'small_sack_count', 'large_sack_count', 'small_sacks_remaining', 'large_sacks_remaining',
      'net_weight', 'remaining', 'gram', 'pct_dombest',
      'pct_tuchin', 'pct_crooked', 'pct_khandan', 'custom_specs', 'photo', 'seller', 'note',
      'is_mix', 'created_at', 'usd_rate', 'price_usd', 'ccy', 'fx_rate', 'fx_rate_source', 'fx_rate_entered_at', 'price_ccy', 'waste', 'base_type', 'labor_cost', 'transport_cost',
      'warehouse_uid', 'ounce_uid', 'tax_status', 'tax_rate_milli',
      'gross_kg', 'tare_kg', 'quality_deduct_kg', 'weigh_ticket_no', 'vehicle_plate', 'driver_name', // S35.T35.2
      'discount_amount', 'weighbridge_cost', 'side_cost_payer', 'taxable' // S35.T35.6b
    ]
  ),
  ('mix_sources', ['id', 'mix_purchase_id', 'source_purchase_id', 'weight', 'small_sacks', 'large_sacks']),
  ('payments', ['id', 'purchase_id', 'pay_type', 'staged_type']),
  (
    'lump_tx',
    ['id', 'payment_id', 'from_account', 'payer_name', 'to_account', 'seller_name', 'amount', 'date', 'paid', 'ccy', 'ccy_amount', 'fx_rate']
  ),
  (
    'credit_inst',
    ['id', 'payment_id', 'due_date', 'amount', 'from_account', 'payer_name', 'to_account', 'seller_name', 'paid', 'ccy', 'ccy_amount', 'fx_rate']
  ),
  (
    'cheque_inst',
    [
      'id', 'payment_id', 'due_date', 'amount', 'cheque_no', 'bank_name', 'from_account', 'payer_name',
      'to_account', 'seller_name', 'paid', 'ccy', 'ccy_amount', 'fx_rate', 'sayad_id' // S35.T35.7c
    ]
  ),
  (
    'sales',
    [
      'id', 'date', 'price', 'total_weight', 'small_sack_count', 'large_sack_count', 'net_weight',
      'buyer', 'note', 'created_at', 'usd_rate', 'ccy', 'fx_rate', 'fx_rate_source', 'fx_rate_entered_at', 'total_ccy',
      'labor_cost', 'transport_cost', 'tax_status', 'tax_rate_milli',
      'gross_kg', 'tare_kg', 'quality_deduct_kg', 'weigh_ticket_no', 'vehicle_plate', 'driver_name', // S35.T35.2
      'discount_amount', 'weighbridge_cost', 'side_cost_payer', 'taxable' // S35.T35.6b
    ]
  ),
  ('sale_items', ['id', 'sale_id', 'purchase_id', 'weight', 'item_price', 'small_sacks', 'large_sacks']),
  ('receipts', ['id', 'sale_id', 'recv_type', 'staged_type']),
  (
    'receipt_lump_tx',
    ['id', 'receipt_id', 'from_account', 'payer_name', 'to_account', 'receiver_name', 'amount', 'date', 'paid', 'ccy', 'ccy_amount', 'fx_rate']
  ),
  (
    'receipt_credit_inst',
    [
      'id', 'receipt_id', 'due_date', 'amount', 'from_account', 'payer_name', 'to_account',
      'receiver_name', 'paid', 'ccy', 'ccy_amount', 'fx_rate'
    ]
  ),
  (
    'receipt_cheque_inst',
    [
      'id', 'receipt_id', 'due_date', 'amount', 'cheque_no', 'bank_name', 'from_account', 'payer_name',
      'to_account', 'receiver_name', 'paid', 'ccy', 'ccy_amount', 'fx_rate', 'sayad_id' // S35.T35.7c
    ]
  ),
  // طرف‌حساب‌های تعریف‌شده‌ی دستی و دفتر قرض/وام (در سود و زیان حساب نمی‌شوند)
  ('parties', ['id', 'name']),
  ('loan_entries', ['id', 'uid', 'party', 'kind', 'amount', 'date', 'note', 'created_at']),
  ('loan_dues', ['id', 'loan_uid', 'seq', 'due_date', 'amount', 'note', 'paid']),
  // S04.T04.4b: برگشت از خرید/فروش (آینهٔ محلی؛ سرور در backup.export می‌فرستد)
  ('purchase_returns', ['id', 'uid', 'number', 'party', 'date', 'refund_mode', 'refund_amount', 'cheque_no', 'cheque_due', 'note', 'tax_amount', 'created_at']),
  ('purchase_return_items', ['id', 'return_id', 'lot_id', 'warehouse_uid', 'kg', 'small_sacks', 'large_sacks', 'unit_price']),
  ('sale_returns', ['id', 'uid', 'number', 'party', 'date', 'refund_mode', 'refund_amount', 'cheque_no', 'cheque_due', 'note', 'tax_amount', 'created_at']),
  ('sale_return_items', ['id', 'return_id', 'sale_id', 'lot_id', 'warehouse_uid', 'kg', 'small_sacks', 'large_sacks', 'unit_price']),
  ('doc_grade_lines', ['id', 'doc_type', 'doc_id', 'grade_key', 'kg', 'unit_price']), // S35.T35.3b
];

/// پیش‌فاکتورها در backup.export نیستند؛ سرور آن‌ها را در کلید افزودنیِ `docs` می‌فرستد.
const List<(String, List<String>)> _kDocTables = [
  ('proformas', ['id', 'uid', 'number', 'party', 'date', 'valid_until', 'status', 'reserve', 'note', 'terms', 'converted_at', 'tax_amount', 'created_at']),
  ('proforma_items', ['id', 'proforma_id', 'lot_id', 'description', 'kg', 'unit_price', 'discount', 'sale_id']),
];

/// جدول‌هایی که اگر سرور هنوز نفرستاد (سرور قدیمی)، داده‌ی محلی‌شان پاک نمی‌شود
const Set<String> _kOptionalTables = {
  'parties', 'loan_entries', 'loan_dues',
  'purchase_returns', 'purchase_return_items', 'sale_returns', 'sale_return_items', 'doc_grade_lines',
};

/// انواع تراکنش دفتر قرض/وام
const List<String> kLoanKinds = ['given', 'taken', 'repay_in', 'repay_out'];

/// ثبت انجام شد ولی «تأیید قطعی» از دیتابیس گرفته نشد؛ در این حالت کل عملیات برگردانده می‌شود
/// (چیزی نیمه‌کاره ذخیره نمی‌شود) و به کاربر اخطار داده می‌شود.
class SaveNotConfirmed implements Exception {
  final String message;
  SaveNotConfirmed([this.message = 'ثبت تأیید نشد و چیزی ذخیره نشد.']);
  @override
  String toString() => message;
}

const Set<String> _kRealCols = {
  'ounce', 'price', 'total_weight', 'small_sack_count', 'large_sack_count', 'small_sacks_remaining',
  'large_sacks_remaining', 'net_weight', 'remaining',
  'gram', 'pct_dombest', 'pct_tuchin', 'pct_crooked', 'pct_khandan', 'weight', 'small_sacks',
  'large_sacks', 'item_price', 'amount', 'usd_rate', 'price_usd', 'fx_rate', 'ccy_amount', 'price_ccy', 'total_ccy', 'waste',
  'kg', 'unit_price', 'refund_amount', 'discount', 'tax_amount', 'gross_kg', 'tare_kg', 'quality_deduct_kg',
};
const Set<String> _kIntCols = {
  'id', 'category_id', 'mix_purchase_id', 'source_purchase_id', 'purchase_id', 'payment_id', 'sale_id',
  'receipt_id', 'is_mix', 'paid', 'return_id', 'lot_id', 'reserve', 'proforma_id', 'doc_id',
};

/// ستون‌های خرید برای لیست‌ها: عکس (base64 سنگین) عمداً انتخاب نمی‌شود؛ فقط has_photo.
const String _pSel = 'p.id, p.code, p.category_id, p.type_name, p.date, p.ounce, p.price, p.total_weight, '
    'p.small_sack_count, p.large_sack_count, p.small_sacks_remaining, p.large_sacks_remaining, '
    'p.net_weight, p.remaining, p.gram, p.pct_dombest, '
    'p.pct_tuchin, p.pct_crooked, p.pct_khandan, p.custom_specs, p.seller, p.note, p.is_mix, '
    'p.usd_rate, p.price_usd, p.ccy, p.fx_rate, p.price_ccy, p.fx_rate_source, p.waste, p.base_type, p.labor_cost, p.transport_cost, p.warehouse_uid, p.ounce_uid, p.created_at, p.ord, (p.photo IS NOT NULL OR p.photo_pending = 1) AS has_photo';

class _SaleV {
  final Map<String, dynamic> row;
  final Map<String, dynamic> payload;
  final List<Map<String, dynamic>> items;
  _SaleV(this.row, this.payload, this.items);
}

/// دیتابیس محلی اندروید — همان ساختار و قواعد وب/سرور (`app.php`).
///
/// * هر حساب (شماره موبایل) فایل دیتابیس جدا دارد.
/// * همهٔ تغییرات فوراً و بدون اینترنت روی دیتابیس محلی اعمال می‌شوند و همزمان یک «عملیات»
///   (همان اکشن‌های API وب) در صف ارسال (`sync_ops`) ذخیره می‌شود؛ `SyncService` آن‌ها را
///   با کلید یکتا (idem) به سرور می‌فرستد.
/// * رکوردهایی که آفلاین ساخته شده‌اند شناسهٔ موقت منفی می‌گیرند؛ شناسهٔ واقعی سرور در
///   `sync_idmap` نگه داشته می‌شود و فقط هنگام ارسال جایگزین می‌شود.
class AppDb {
  AppDb._();
  static final AppDb I = AppDb._();

  /// با هر تغییر داده زیاد می‌شود تا صفحه‌ها بازخوانی شوند
  final ValueNotifier<int> version = ValueNotifier<int>(0);

  static const int schemaVersion = 28;

  String? _phone;
  Database? _db;

  /// S29.T29.3: unit of the local mirror ('toman' legacy | 'rial'); sent as `unit` on every API call
  String moneyUnit = MoneyUnit.toman;
  Future<Database>? _opening;

  String? get phone => _phone;
  bool get hasAccount => _phone != null;

  Future<Database> get db {
    final cur = _db;
    if (cur != null) return Future.value(cur);
    final ph = _phone;
    if (ph == null) return Future.error(StateError('no_account'));
    return _opening ??= _open(ph).then((d) {
      _db = d;
      return d;
    }).whenComplete(() {
      _opening = null;
    });
  }

  Future<Database> _open(String phone) async {
    final path = join(await getDatabasesPath(), 'pesteh_$phone.db');
    final Database d = await openDatabase(path,
        version: schemaVersion, onConfigure: DbCrypto.configure, onCreate: _onCreate, onUpgrade: _onUpgrade);
    moneyUnit = await MoneyUnit.localUnit(d);
    return d;
  }

  /// S29.T29.3: records the unit of the data now in the mirror (set after every full pull from the server)
  Future<void> setMoneyUnit(String unit) async {
    moneyUnit = MoneyUnit.normalize(unit);
    await metaSet(MoneyUnit.kMetaKey, moneyUnit);
  }

  /// S29.T29.3: x10 on local money columns (only when sync_ops is empty); true = migrated now
  Future<bool> migrateMoneyToRial() async {
    final bool ok = await MoneyUnit.migrateLocal(await db);
    if (ok) {
      moneyUnit = MoneyUnit.rial;
      version.value++;
    }
    return ok;
  }

  /// حساب فعال را تعیین می‌کند (دیتابیس همان حساب باز می‌شود)
  Future<void> useAccount(String phone) async {
    if (_phone == phone) {
      await db;
      return;
    }
    try {
      await _opening;
    } catch (_) {}
    await _db?.close();
    _db = null;
    _opening = null;
    _phone = phone;
    await db;
    version.value++;
  }

  Future<void> closeAccount() async {
    try {
      await _opening;
    } catch (_) {}
    await _db?.close();
    _db = null;
    _opening = null;
    _phone = null;
    version.value++;
  }

  /// فایل دیتابیس حساب فعلی را پاک می‌کند (فقط وقتی همه‌چیز روی سرور رفته است)
  Future<void> deleteAccountData() async {
    final ph = _phone;
    if (ph == null) return;
    final path = join(await getDatabasesPath(), 'pesteh_$ph.db');
    await closeAccount();
    try {
      await deleteDatabase(path);
    } catch (_) {}
  }

  /// مهاجرت دیتابیس‌های قدیمی: دو ستون گونیِ باقی‌مانده به خرید اضافه می‌شود
  /// و مقدار اولیه‌شان = گونی خرید منهای گونی‌هایی که تا امروز صریحاً کم شده‌اند.
  Future<void> _onUpgrade(Database d, int oldV, int newV) async {
    if (oldV < 8) {
      await d.execute('ALTER TABLE purchases ADD COLUMN small_sacks_remaining REAL NOT NULL DEFAULT 0');
      await d.execute('ALTER TABLE purchases ADD COLUMN large_sacks_remaining REAL NOT NULL DEFAULT 0');
      await _backfillSacks(d);
    }
    if (oldV < 9) {
      // پلن ارزی: قیمت دلار هنگام خرید/فروش و فی دلاریِ خرید (داده‌های قدیمی null می‌مانند)
      await d.execute('ALTER TABLE purchases ADD COLUMN usd_rate REAL');
      await d.execute('ALTER TABLE purchases ADD COLUMN price_usd REAL');
      await d.execute('ALTER TABLE sales ADD COLUMN usd_rate REAL');
    }
    if (oldV < 10) {
      // ضایعات/خاکِ مخلوط/جداسازی (مخلوط‌های قدیمی null می‌مانند)
      await d.execute('ALTER TABLE purchases ADD COLUMN waste REAL');
    }
    if (oldV < 11) {
      // طرف‌حساب‌های دستی + دفتر قرض/وام
      await _createLoanTables(d);
    }
    if (oldV < 12) {
      // سررسید/اقساط قرض + نوع زیردستهٔ مخلوط/جداسازی (برای نمودارهای دقیق‌تر)
      await _createLoanTables(d);
      await d.execute('ALTER TABLE purchases ADD COLUMN base_type TEXT');
    }
    if (oldV < 13) {
      // هزینه کارگر و هزینه حمل‌ونقل/باسکول (خرید و فروش) — از سود همان پسته کم می‌شود
      for (final t in ['purchases', 'sales']) {
        await d.execute('ALTER TABLE $t ADD COLUMN labor_cost REAL');
        await d.execute('ALTER TABLE $t ADD COLUMN transport_cost REAL');
      }
    }
    if (oldV < 14) {
      // فقط ایندکس (بدون تغییر ستون/جدول) → فقط سرعت جستجو بیشتر می‌شود
      await _createIndexes(d);
    }
    if (oldV < 15) {
      // موجودیت‌های عمومی (S00.T00.4): جدول جدید، بدون دست‌زدن به جدول‌های قبلی
      await EntityStore.createTable(d);
    }
    if (oldV < 16) {
      // انبار و درجه‌بندی اونس هر بار (S01.T01.3/4): uid موجودیت‌های warehouses/ounces؛ null = «انبار اصلی»
      await d.execute('ALTER TABLE purchases ADD COLUMN warehouse_uid TEXT');
      await d.execute('ALTER TABLE purchases ADD COLUMN ounce_uid TEXT');
    }
    if (oldV < 17) {
      // برگشت از خرید/فروش و پیش‌فاکتور (S04.T04.4b): فقط جدول‌های جدید
      await createDocTables(d);
    }
    if (oldV < 18) {
      // مالیات سند (S17.T17.1b، فقط طلایی): انتخاب وضعیت مالیاتی/نرخ؛ null = رفتار قبلی
      for (final t in ['purchases', 'sales']) {
        await d.execute('ALTER TABLE $t ADD COLUMN tax_status TEXT');
        await d.execute('ALTER TABLE $t ADD COLUMN tax_rate_milli INTEGER');
      }
    }
    if (oldV < 19) {
      // انبارگردانی آفلاین (S19.T19.1b): پیش‌نویس محلی + کش برگهٔ شمارش؛ فقط جدول‌های جدید
      await StockCountLocal.createTables(d);
    }
    if (oldV < 20) {
      // S26.T26.1: کش محلی ارزها و نرخ‌های روزانه (فقط جدول‌های جدید)
      await FxLocal.createTables(d);
    }
    if (oldV < 21) {
      // S27c: ستون‌های سند ارزی (ccy، نرخ سند، منبع نرخ). اسناد قدیمی null می‌مانند.
      for (final String t in <String>['sales', 'purchases']) {
        for (final String c in <String>['ccy TEXT', 'fx_rate REAL', 'fx_rate_source TEXT', 'fx_rate_entered_at TEXT']) {
          try {
            await d.execute('ALTER TABLE $t ADD COLUMN $c');
          } catch (_) {/* ستون از قبل هست */}
        }
      }
      try {
        await d.execute('ALTER TABLE sales ADD COLUMN total_ccy REAL');
      } catch (_) {}
      try {
        await d.execute('ALTER TABLE purchases ADD COLUMN price_ccy REAL');
      } catch (_) {}
    }
    if (oldV < 22) {
      await _addTxFxCols(d); // S28.T28.2b
    }
    if (oldV < 23) {
      // S29.T29.3: no data change here. The x10 happens in MoneyUnit.migrateLocal, only once the server
      // reports money_unit=rial AND sync_ops is empty (queued ops hold toman amounts). Legacy = toman.
      await d.insert('meta', <String, Object?>{'k': MoneyUnit.kMetaKey, 'v': MoneyUnit.toman},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    if (oldV < 24) {
      await FormSettingsLocal.createTables(d); // S35.T35.1: form feature switches mirror
    }
    if (oldV < 25) {
      await _addWeighCols(d); // S35.T35.2: weighing block columns on purchases
    }
    if (oldV < 26) {
      await GradeLinesLocal.createTables(d); // S35.T35.3b: grade lines mirror
    }
    if (oldV < 27) {
      await _addFinCols(d); // S35.T35.6b: financial block columns (purchases, sales)
    }
    if (oldV < 28) {
      await _addSayadCols(d); // S35.T35.7c: sayad id on cheque lines (local mirror)
    }
  }

  /// جدول‌های آینهٔ برگشت‌ها و پیش‌فاکتورها (IF NOT EXISTS ⇒ اجرای دوباره بی‌خطر)
  static Future<void> createDocTables(DatabaseExecutor d) async {
    const ret = 'id INTEGER PRIMARY KEY, uid TEXT, number INTEGER, party TEXT, date TEXT, refund_mode TEXT, '
        'refund_amount REAL, cheque_no TEXT, cheque_due TEXT, note TEXT, tax_amount REAL, created_at TEXT';
    await d.execute('CREATE TABLE IF NOT EXISTS sale_returns($ret)');
    await d.execute('CREATE TABLE IF NOT EXISTS purchase_returns($ret)');
    await d.execute('CREATE TABLE IF NOT EXISTS sale_return_items(id INTEGER PRIMARY KEY, return_id INTEGER NOT NULL, '
        'sale_id INTEGER, lot_id INTEGER, warehouse_uid TEXT, kg REAL NOT NULL DEFAULT 0, small_sacks REAL, large_sacks REAL, unit_price REAL)');
    await d.execute('CREATE TABLE IF NOT EXISTS purchase_return_items(id INTEGER PRIMARY KEY, return_id INTEGER NOT NULL, '
        'lot_id INTEGER, warehouse_uid TEXT, kg REAL NOT NULL DEFAULT 0, small_sacks REAL, large_sacks REAL, unit_price REAL)');
    await d.execute('CREATE TABLE IF NOT EXISTS proformas(id INTEGER PRIMARY KEY, uid TEXT, number INTEGER, party TEXT, date TEXT, '
        'valid_until TEXT, status TEXT, reserve INTEGER, note TEXT, terms TEXT, converted_at TEXT, tax_amount REAL, created_at TEXT)');
    await d.execute('CREATE TABLE IF NOT EXISTS proforma_items(id INTEGER PRIMARY KEY, proforma_id INTEGER NOT NULL, lot_id INTEGER, '
        'description TEXT, kg REAL NOT NULL DEFAULT 0, unit_price REAL NOT NULL DEFAULT 0, discount REAL, sale_id INTEGER)');
    for (final s in const [
      'CREATE INDEX IF NOT EXISTS ix_sri_ret ON sale_return_items(return_id)',
      'CREATE INDEX IF NOT EXISTS ix_sri_sale ON sale_return_items(sale_id)',
      'CREATE INDEX IF NOT EXISTS ix_pri_ret ON purchase_return_items(return_id)',
      'CREATE INDEX IF NOT EXISTS ix_pfi_pf ON proforma_items(proforma_id)',
    ]) {
      await d.execute(s);
    }
  }

  /// ایندکس ستون‌های کلید خارجی؛ بدون اینها هر `WHERE sale_id=?` کل جدول را اسکن می‌کرد.
  /// `IF NOT EXISTS` است، پس اجرای دوباره بی‌خطر است. هیچ تأثیری روی سینک ندارد.
  Future<void> _createIndexes(Database d) async {
    const stmts = [
      'CREATE INDEX IF NOT EXISTS ix_si_sale ON sale_items(sale_id)',
      'CREATE INDEX IF NOT EXISTS ix_si_purchase ON sale_items(purchase_id)',
      'CREATE INDEX IF NOT EXISTS ix_lump_pay ON lump_tx(payment_id)',
      'CREATE INDEX IF NOT EXISTS ix_cred_pay ON credit_inst(payment_id)',
      'CREATE INDEX IF NOT EXISTS ix_chq_pay ON cheque_inst(payment_id)',
      'CREATE INDEX IF NOT EXISTS ix_rlump_rec ON receipt_lump_tx(receipt_id)',
      'CREATE INDEX IF NOT EXISTS ix_rcred_rec ON receipt_credit_inst(receipt_id)',
      'CREATE INDEX IF NOT EXISTS ix_rchq_rec ON receipt_cheque_inst(receipt_id)',
      'CREATE INDEX IF NOT EXISTS ix_mix_src ON mix_sources(source_purchase_id)',
      'CREATE INDEX IF NOT EXISTS ix_mix_mix ON mix_sources(mix_purchase_id)',
      'CREATE INDEX IF NOT EXISTS ix_loan_dues_uid ON loan_dues(loan_uid)',
    ];
    for (final q in stmts) {
      await d.execute(q);
    }
  }

  Future<void> _createLoanTables(Database d) async {
    await d.execute('''
      CREATE TABLE IF NOT EXISTS parties(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL
      )''');
    await d.execute('''
      CREATE TABLE IF NOT EXISTS loan_entries(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        uid TEXT NOT NULL,
        party TEXT NOT NULL,
        kind TEXT NOT NULL,
        amount REAL NOT NULL,
        date TEXT NOT NULL,
        note TEXT,
        created_at TEXT
      )''');
    await d.execute('''
      CREATE TABLE IF NOT EXISTS loan_dues(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        loan_uid TEXT NOT NULL,
        seq INTEGER NOT NULL,
        due_date TEXT NOT NULL,
        amount REAL NOT NULL,
        note TEXT,
        paid INTEGER NOT NULL DEFAULT 0
      )''');
  }

  /// گونی باقی‌ماندهٔ داده‌های قدیمی را مثل backfillSacksRemaining سرور (app.php) حساب می‌کند:
  /// گونی خرید − گونی‌های ثبت‌شده در فروش/مخلوط − سهم تناسبیِ فروش/مخلوط‌هایی که گونی ثبت نکرده‌اند.
  Future<void> _backfillSacks(DatabaseExecutor t) async {
    String sum(String col) => '''
        (COALESCE((SELECT SUM(COALESCE($col, 0)) FROM sale_items WHERE purchase_id = purchases.id), 0)
       + COALESCE((SELECT SUM(COALESCE($col, 0)) FROM mix_sources WHERE source_purchase_id = purchases.id), 0))''';
    const unk = '''
        (COALESCE((SELECT SUM(weight) FROM sale_items WHERE purchase_id = purchases.id
                     AND small_sacks IS NULL AND large_sacks IS NULL), 0)
       + COALESCE((SELECT SUM(weight) FROM mix_sources WHERE source_purchase_id = purchases.id
                     AND small_sacks IS NULL AND large_sacks IS NULL), 0))''';
    const ratio = 'CASE WHEN net_weight > 0 THEN $unk / net_weight ELSE 0 END';
    await t.execute('''
      UPDATE purchases SET
        small_sacks_remaining = MAX(0, ROUND(small_sack_count - ${sum('small_sacks')} - small_sack_count * ($ratio))),
        large_sacks_remaining = MAX(0, ROUND(large_sack_count - ${sum('large_sacks')} - large_sack_count * ($ratio)))''');
  }

  /// S28.T28.2b: foreign-currency columns on the six receipt/payment line tables (NULL = rial line).
  static Future<void> _addTxFxCols(Database d) async {
    for (final String t in <String>[
      'lump_tx',
      'credit_inst',
      'cheque_inst',
      'receipt_lump_tx',
      'receipt_credit_inst',
      'receipt_cheque_inst'
    ]) {
      for (final String c in <String>['ccy TEXT', 'ccy_amount REAL', 'fx_rate REAL']) {
        try {
          await d.execute('ALTER TABLE $t ADD COLUMN $c');
        } catch (_) {/* column already exists */}
      }
    }
  }

  Future<void> _onCreate(Database d, int v) async {
    await d.execute('''
      CREATE TABLE categories(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        preset_key TEXT
      )''');
    await d.execute('''
      CREATE TABLE types(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        category_id INTEGER NOT NULL,
        name TEXT NOT NULL
      )''');
    await d.execute('''
      CREATE TABLE purchases(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        code TEXT UNIQUE,
        category_id INTEGER NOT NULL,
        type_name TEXT NOT NULL,
        date TEXT NOT NULL,
        photo TEXT,
        photo_pending INTEGER NOT NULL DEFAULT 0,
        ounce REAL,
        price REAL NOT NULL,
        total_weight REAL NOT NULL,
        small_sack_count REAL NOT NULL DEFAULT 0,
        large_sack_count REAL NOT NULL DEFAULT 0,
        small_sacks_remaining REAL NOT NULL DEFAULT 0,
        large_sacks_remaining REAL NOT NULL DEFAULT 0,
        net_weight REAL NOT NULL,
        remaining REAL NOT NULL,
        gram REAL,
        pct_dombest REAL,
        pct_tuchin REAL,
        pct_crooked REAL,
        pct_khandan REAL,
        custom_specs TEXT,
        seller TEXT,
        note TEXT,
        is_mix INTEGER NOT NULL DEFAULT 0,
        created_at TEXT,
        usd_rate REAL,
        price_usd REAL,
        ccy TEXT, fx_rate REAL, fx_rate_source TEXT, fx_rate_entered_at TEXT, price_ccy REAL,
        waste REAL,
        base_type TEXT,
        labor_cost REAL,
        transport_cost REAL,
        tax_status TEXT,
        tax_rate_milli INTEGER,
        warehouse_uid TEXT,
        ounce_uid TEXT,
        ord INTEGER NOT NULL DEFAULT 0
      )''');
    await d.execute('''
      CREATE TABLE mix_sources(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        mix_purchase_id INTEGER NOT NULL,
        source_purchase_id INTEGER NOT NULL,
        weight REAL NOT NULL,
        small_sacks REAL,
        large_sacks REAL
      )''');
    await d.execute('''
      CREATE TABLE payments(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        purchase_id INTEGER NOT NULL UNIQUE,
        pay_type TEXT NOT NULL,
        staged_type TEXT
      )''');
    await d.execute('''
      CREATE TABLE lump_tx(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        payment_id INTEGER NOT NULL,
        from_account TEXT,
        payer_name TEXT,
        to_account TEXT,
        seller_name TEXT,
        amount REAL NOT NULL,
        date TEXT NOT NULL,
        paid INTEGER NOT NULL DEFAULT 1
      )''');
    await d.execute('''
      CREATE TABLE credit_inst(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        payment_id INTEGER NOT NULL,
        due_date TEXT NOT NULL,
        amount REAL NOT NULL,
        from_account TEXT,
        payer_name TEXT,
        to_account TEXT,
        seller_name TEXT,
        paid INTEGER NOT NULL DEFAULT 0
      )''');
    await d.execute('''
      CREATE TABLE cheque_inst(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        payment_id INTEGER NOT NULL,
        due_date TEXT NOT NULL,
        amount REAL NOT NULL,
        cheque_no TEXT,
        sayad_id TEXT,
        bank_name TEXT,
        from_account TEXT,
        payer_name TEXT,
        to_account TEXT,
        seller_name TEXT,
        paid INTEGER NOT NULL DEFAULT 0
      )''');
    await d.execute('''
      CREATE TABLE sales(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        date TEXT NOT NULL,
        price REAL NOT NULL,
        total_weight REAL NOT NULL,
        small_sack_count REAL NOT NULL DEFAULT 0,
        large_sack_count REAL NOT NULL DEFAULT 0,
        net_weight REAL NOT NULL,
        buyer TEXT,
        note TEXT,
        created_at TEXT,
        usd_rate REAL,
        ccy TEXT, fx_rate REAL, fx_rate_source TEXT, fx_rate_entered_at TEXT, total_ccy REAL,
        labor_cost REAL,
        transport_cost REAL,
        tax_status TEXT,
        tax_rate_milli INTEGER,
        ord INTEGER NOT NULL DEFAULT 0
      )''');
    await d.execute('''
      CREATE TABLE sale_items(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sale_id INTEGER NOT NULL,
        purchase_id INTEGER NOT NULL,
        weight REAL NOT NULL,
        item_price REAL,
        small_sacks REAL,
        large_sacks REAL
      )''');
    await d.execute('''
      CREATE TABLE receipts(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sale_id INTEGER NOT NULL UNIQUE,
        recv_type TEXT NOT NULL,
        staged_type TEXT
      )''');
    await d.execute('''
      CREATE TABLE receipt_lump_tx(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        receipt_id INTEGER NOT NULL,
        from_account TEXT,
        payer_name TEXT,
        to_account TEXT,
        receiver_name TEXT,
        amount REAL NOT NULL,
        date TEXT NOT NULL,
        paid INTEGER NOT NULL DEFAULT 1
      )''');
    await d.execute('''
      CREATE TABLE receipt_credit_inst(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        receipt_id INTEGER NOT NULL,
        due_date TEXT NOT NULL,
        amount REAL NOT NULL,
        from_account TEXT,
        payer_name TEXT,
        to_account TEXT,
        receiver_name TEXT,
        paid INTEGER NOT NULL DEFAULT 0
      )''');
    await d.execute('''
      CREATE TABLE receipt_cheque_inst(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        receipt_id INTEGER NOT NULL,
        due_date TEXT NOT NULL,
        amount REAL NOT NULL,
        cheque_no TEXT,
        sayad_id TEXT,
        bank_name TEXT,
        from_account TEXT,
        payer_name TEXT,
        to_account TEXT,
        receiver_name TEXT,
        paid INTEGER NOT NULL DEFAULT 0
      )''');
    // ---------- همگام‌سازی ----------
    await d.execute('CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT)');
    await EntityStore.createTable(d); // S00.T00.4 generic entities
    await d.execute('''
      CREATE TABLE sync_ops(
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        action TEXT NOT NULL,
        payload TEXT NOT NULL,
        idem TEXT NOT NULL,
        ref_kind TEXT,
        ref_id INTEGER,
        map_kind TEXT,
        local_id INTEGER,
        state TEXT NOT NULL DEFAULT 'pending',
        err TEXT,
        attempts INTEGER NOT NULL DEFAULT 0,
        rev INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )''');
    await d.execute('''
      CREATE TABLE sync_idmap(
        kind TEXT NOT NULL,
        local_id INTEGER NOT NULL,
        server_id INTEGER NOT NULL,
        PRIMARY KEY(kind, local_id)
      )''');
    await _createLoanTables(d);
    await createDocTables(d);
    await StockCountLocal.createTables(d);
    await FxLocal.createTables(d); // S26.T26.1
    await FormSettingsLocal.createTables(d); // S35.T35.1
    await _addWeighCols(d); // S35.T35.2
    await _addFinCols(d); // S35.T35.6b
    await GradeLinesLocal.createTables(d); // S35.T35.3b
    await _addTxFxCols(d); // S28.T28.2b
    await _createIndexes(d);
    // نکته: دسته‌ها و انواع پیش‌فرض را سرور می‌سازد (bootstrap) و هنگام ورود دریافت می‌شوند.
  }

  // ======================= ابزارهای کمکی (همان قواعد app.php) =======================
  static double _n(dynamic v) {
    if (v == null || v == '') return 0.0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0.0;
  }

  static double? _nn(dynamic v) {
    if (v == null || v == '') return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  static double _r(double v, int dec) {
    final m = math.pow(10, dec).toDouble();
    return (v * m).roundToDouble() / m;
  }

  static double? _rn(double? v, int dec) => v == null ? null : _r(v, dec);

  /// رشتهٔ تمیز و کوتاه‌شده؛ خالی => null
  static String? _s(dynamic v, int max) {
    if (v == null) return null;
    final s = v.toString().trim();
    if (s.isEmpty) return null;
    return s.length > max ? s.substring(0, max) : s;
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
  static String _ymd(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';
  static String _stamp() {
    final n = DateTime.now();
    return '${_ymd(n)} ${_two(n.hour)}:${_two(n.minute)}:${_two(n.second)}';
  }

  /// تاریخ به‌صورت YYYY-MM-DD (مثل ستون DATE سرور)؛ ورودی می‌تواند ISO کامل باشد
  static String _dateOnly(dynamic v) {
    if (v == null) return _ymd(DateTime.now());
    final s = v.toString().trim();
    if (s.isEmpty) return _ymd(DateTime.now());
    final dt = DateTime.tryParse(s);
    if (dt != null) return _ymd(dt);
    if (s.length >= 10 && RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(s)) return s.substring(0, 10);
    return _ymd(DateTime.now());
  }

  static final math.Random _rng = math.Random.secure();
  static String _newIdem() {
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final rnd = List<String>.generate(10, (_) => _rng.nextInt(36).toRadixString(36)).join();
    return 'i$ts$rnd';
  }

  /// شناسهٔ موقت (منفی) برای رکوردی که هنوز سرور شناسهٔ واقعی‌اش را نداده
  Future<int> _tempId(DatabaseExecutor t, String table) async {
    final r = await t.rawQuery('SELECT MIN(id) AS m FROM $table');
    final m = r.isEmpty ? null : r.first['m'] as int?;
    return (m == null || m >= 0) ? -1 : m - 1;
  }

  Future<int> _nextOrd(DatabaseExecutor t, String table) async {
    final r = await t.rawQuery('SELECT COALESCE(MAX(ord), 0) + 1 AS n FROM $table');
    return (r.first['n'] as num).toInt();
  }

  static String _fmt(double v) {
    var s = v.toStringAsFixed(3);
    s = s.replaceFirst(RegExp(r'\.?0+$'), '');
    return s;
  }

  // ======================= ایمنی ثبت: سلامت دیتابیس، تلاش مجدد، محافظ ویرایش =======================
  final Map<Object, DateTime> _editors = {};

  /// فرم/صفحهٔ ثبت باز شد: تا بسته‌شدنش، دریافت خودکار از سرور (که شناسه‌ها را عوض می‌کند) انجام نمی‌شود
  Object beginEdit() {
    final k = Object();
    _editors[k] = DateTime.now();
    return k;
  }

  void endEdit(Object k) => _editors.remove(k);

  /// آیا الان فرمی باز است؟ (صفحه‌ای که بیش از ۳ ساعت باز مانده نادیده گرفته می‌شود تا هیچ‌وقت همگام‌سازی قفل نماند)
  bool get isEditing {
    final cutoff = DateTime.now().subtract(const Duration(hours: 3));
    _editors.removeWhere((_, t) => t.isBefore(cutoff));
    return _editors.isNotEmpty;
  }

  Future<void> _reopen() async {
    final ph = _phone;
    if (ph == null) throw StateError('no_account');
    try {
      await _opening;
    } catch (_) {}
    try {
      await _db?.close();
    } catch (_) {}
    _db = null;
    _opening = null;
    await db;
  }

  /// دیتابیسی که واقعاً باز و سالم است (اگر بسته شده بود، دوباره باز می‌شود)
  Future<Database> _healthyDb() async {
    final d = await db;
    try {
      await d.rawQuery('SELECT 1');
      return d;
    } catch (_) {
      await _reopen();
      return db;
    }
  }

  /// برای وقتی برنامه از پس‌زمینه برمی‌گردد (تماس تلفن، قفل صفحه و…)
  Future<void> ensureHealthy() async {
    if (_phone == null) return;
    try {
      await _healthyDb();
    } catch (_) {}
  }

  static bool _isTransient(Object e) {
    final m = e.toString().toLowerCase();
    return m.contains('database_closed') ||
        m.contains('database is closed') ||
        m.contains('locked') ||
        m.contains('busy') ||
        m.contains('disk i/o') ||
        m.contains('not an error');
  }

  /// اجرای نوشتن روی دیتابیس؛ خطاهای گذرا (بسته‌بودن/قفل‌بودن) بی‌سروصدا و تا ۳ بار دوباره تلاش می‌شوند.
  /// (چون تراکنش اتمیک است، تلاش مجدد باعث ثبت تکراری نمی‌شود.)
  Future<T> _write<T>(Future<T> Function(Database d) body) async {
    Object? last;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final d = await _healthyDb();
        return await body(d);
      } on DatabaseException catch (e) {
        if (!_isTransient(e)) rethrow;
        last = e;
        await _reopen();
        await Future<void>.delayed(Duration(milliseconds: 200 * (attempt + 1)));
      }
    }
    throw last ?? SaveNotConfirmed();
  }

  /// تأیید قطعی داخل همان تراکنش: اگر ردیف خواسته‌شده پیدا نشد، کل تراکنش برگردانده می‌شود
  Future<void> _confirm(DatabaseExecutor t, String sql, List<Object?> args, [String? msg]) async {
    final r = await t.rawQuery(sql, args);
    if (r.isEmpty) throw SaveNotConfirmed(msg ?? 'ثبت تأیید نشد و چیزی ذخیره نشد.');
  }

  // ======================= متادیتا و صف ارسال =======================
  Future<String?> metaGet(String k) async {
    final r = await (await db).query('meta', columns: ['v'], where: 'k=?', whereArgs: [k], limit: 1);
    return r.isEmpty ? null : r.first['v'] as String?;
  }

  Future<void> metaSet(String k, String v) async {
    await (await db).insert('meta', {'k': k, 'v': v}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> _enqueue(DatabaseExecutor t, String action, Map<String, dynamic> payload,
      {String? refKind, int? refId, String? mapKind, int? localId}) async {
    await t.insert('sync_ops', {
      'action': action,
      'payload': jsonEncode(payload),
      'idem': _newIdem(),
      'ref_kind': refKind,
      'ref_id': refId,
      'map_kind': mapKind,
      'local_id': localId,
      'state': 'pending',
      'attempts': 0,
      'rev': 0,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// S04.T04.4b: ابزارهای عمومی برای offline_docs.dart (صف + شناسهٔ موقت + پاک‌کردن صف رکورد حذف‌شده)
  Future<void> docEnqueue(DatabaseExecutor t, String action, Map<String, dynamic> payload,
          {String? refKind, int? refId, String? mapKind, int? localId}) =>
      _enqueue(t, action, payload, refKind: refKind, refId: refId, mapKind: mapKind, localId: localId);
  Future<int> docTempId(DatabaseExecutor t, String table) => _tempId(t, table);
  Future<void> docWrite(Future<void> Function(Database d) body) => _write<void>(body);

  /// موجودی بار را کم/زیاد می‌کند (کیلو و گونی؛ منفی = کم‌شدن) — برای برگشت‌های آفلاین
  Future<void> docStock(DatabaseExecutor t, int lotId, double kg, double small, double large) async {
    await _addRemaining(t, lotId, kg);
    await _addSacks(t, lotId, small, large);
  }

  /// فروش/خریدی که برگشت دارد (محلی) نباید ویرایش/حذف شود؛ سرور هم همین را رد می‌کند
  Future<bool> _hasReturns(DatabaseExecutor t, String col, int id) async {
    final String tbl = col == 'sale_id' ? 'sale_return_items' : 'purchase_return_items';
    final r = await t.rawQuery('SELECT 1 FROM $tbl WHERE ${col == 'sale_id' ? 'sale_id' : 'lot_id'}=? LIMIT 1', [id]);
    return r.isNotEmpty;
  }
  Future<void> docPurgeOps(DatabaseExecutor t, String refKind, int refId) => _purgeOps(t, refKind, refId);

  /// S00.T00.4: صف‌کردن عملیات موجودیت‌های عمومی (entity.save / entity.delete) برای EntityStore
  Future<void> entityEnqueue(DatabaseExecutor t, String action, Map<String, dynamic> payload) =>
      _enqueue(t, action, payload);

  /// به‌روزرسانی محتوای یک عملیات هنوز-ارسال‌نشده (همان جایگاه صف)
  Future<void> entityUpdateOp(DatabaseExecutor t, int seq, Map<String, dynamic> payload) async {
    await t.rawUpdate('UPDATE sync_ops SET payload=?, idem=?, rev=rev+1, attempts=0, err=NULL WHERE seq=?',
        [jsonEncode(payload), _newIdem(), seq]);
  }

  /// برای اکشن‌هایی که «کل وضعیت» را جایگزین می‌کنند (payments.save / receipts.save):
  /// اگر همان مورد هنوز در صف است، فقط محتوایش به‌روز می‌شود (در همان جایگاه صف).
  Future<void> _upsertOp(DatabaseExecutor t, String action, Map<String, dynamic> payload,
      {required String refKind, required int refId}) async {
    final ex = await t.query('sync_ops',
        columns: ['seq'],
        where: "action=? AND ref_kind=? AND ref_id=? AND state='pending'",
        whereArgs: [action, refKind, refId],
        limit: 1);
    if (ex.isNotEmpty) {
      await t.rawUpdate(
          'UPDATE sync_ops SET payload=?, idem=?, rev=rev+1, attempts=0, err=NULL WHERE seq=?',
          [jsonEncode(payload), _newIdem(), ex.first['seq']]);
    } else {
      await _enqueue(t, action, payload, refKind: refKind, refId: refId);
    }
  }

  /// رکوردی که هرگز به سرور نرسیده حذف شد: همهٔ عملیات صف‌شدهٔ مربوط به آن هم حذف می‌شود
  Future<void> _purgeOps(DatabaseExecutor t, String refKind, int refId) async {
    await t.delete('sync_ops', where: 'ref_kind=? AND ref_id=?', whereArgs: [refKind, refId]);
  }

  /// شناسهٔ واقعی سرور برای یک شناسهٔ محلی (null = هنوز ارسال نشده)
  Future<int?> serverIdOf(String kind, int localId) async {
    if (localId >= 0) return localId;
    final r = await (await db).query('sync_idmap',
        columns: ['server_id'], where: 'kind=? AND local_id=?', whereArgs: [kind, localId], limit: 1);
    return r.isEmpty ? null : (r.first['server_id'] as num).toInt();
  }

  /// اگر شناسهٔ موقتِ منفیِ این رکورد در دریافت از سرور به شناسهٔ واقعی تبدیل شده باشد، آن را برمی‌گرداند
  /// (فقط وقتی رکوردی با همین شناسه در گوشی نیست؛ وگرنه null).
  Future<int?> aliasOf(String kind, int id) async {
    if (id >= 0) return null;
    if (await localExists(kind, id)) return null;
    final v = await metaGet('alias:$kind:$id');
    return v == null ? null : int.tryParse(v);
  }

  /// شناسهٔ فعلیِ یک رکورد (برای صفحه‌هایی که از قبل باز بوده‌اند)
  Future<int> currentId(String kind, int id) async => (await aliasOf(kind, id)) ?? id;

  /// بعد از موفقیت یک عملیات «ساخت»: شناسهٔ واقعی را ثبت می‌کند و کد خرید را مثل سرور می‌سازد
  Future<void> recordMapping(String kind, int localId, int serverId) async {
    final d = await db;
    await d.transaction((t) async {
      await t.insert('sync_idmap', {'kind': kind, 'local_id': localId, 'server_id': serverId},
          conflictAlgorithm: ConflictAlgorithm.replace);
      if (kind == 'pur') {
        final r = await t.query('purchases', columns: ['is_mix'], where: 'id=?', whereArgs: [localId]);
        if (r.isNotEmpty) {
          final isMix = ((r.first['is_mix'] as num?) ?? 0) == 1;
          final code = '${isMix ? 'MX' : 'KH'}${serverId.toString().padLeft(5, '0')}';
          await t.update('purchases', {'code': code},
              where: 'id=?', whereArgs: [localId], conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }
    });
    version.value++;
  }

  // ======================= دریافت کامل از سرور =======================
  static dynamic _coerce(String col, dynamic v) {
    if (v == null) return null;
    if (_kRealCols.contains(col)) {
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }
    if (_kIntCols.contains(col)) {
      if (v is bool) return v ? 1 : 0;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString());
    }
    return v.toString();
  }

  /// یک نسخهٔ سازگار و کامل از دیتابیس را در [path] می‌نویسد (VACUUM INTO؛ حتی وقتی برنامه در حال کار است).
  Future<void> vacuumInto(String path) async {
    final d = await db;
    await d.execute("VACUUM INTO '${path.replaceAll("'", "''")}'");
  }

  static const Map<String, String> _refTable = {
    'category_id': 'categories',
    'mix_purchase_id': 'purchases',
    'source_purchase_id': 'purchases',
    'purchase_id': 'purchases',
    'payment_id': 'payments',
    'sale_id': 'sales',
    'receipt_id': 'receipts',
    'lot_id': 'purchases',
  };

  Future<Database> _openBackup(String path) async {
    Database? d;
    try {
      d = await openDatabase(path, readOnly: true, singleInstance: false, onConfigure: DbCrypto.configure);
      await d.rawQuery('SELECT count(*) FROM sqlite_master');
      return d;
    } catch (_) {
      try {
        await d?.close();
      } catch (_) {}
      return openDatabase(path, readOnly: true, singleInstance: false);
    }
  }

  /// فایل پشتیبانِ محلی (.db) را (فقط‌خواندنی) به قالب `tables` سرور تبدیل می‌کند.
  /// ردیف‌هایی که هنوز شناسهٔ موقت (منفی) دارند شناسهٔ مثبت می‌گیرند و ارجاع‌هایشان اصلاح می‌شود.
  Future<Map<String, dynamic>> readBackupTables(String path) async {
    final bd = await _openBackup(path);
    try {
      final raw = <String, List<Map<String, Object?>>>{};
      for (final e in _kSnapshot) {
        final info = await bd.rawQuery('PRAGMA table_info(${e.$1})');
        final have = info.map((r) => r['name'] as String).toSet();
        final cols = e.$2.where(have.contains).toList();
        raw[e.$1] = cols.isEmpty ? <Map<String, Object?>>[] : await bd.query(e.$1, columns: cols);
      }
      final idMaps = <String, Map<int, int>>{};
      final out = <String, dynamic>{};
      for (final e in _kSnapshot) {
        final table = e.$1;
        final rows = raw[table]!;
        var next = 1;
        for (final r in rows) {
          final id = (r['id'] as num?)?.toInt() ?? 0;
          if (id >= next) next = id + 1;
        }
        final m = <int, int>{};
        final fixed = <Map<String, dynamic>>[];
        for (final r in rows) {
          final row = Map<String, dynamic>.from(r);
          final id = (row['id'] as num?)?.toInt() ?? 0;
          final nid = id > 0 ? id : next++;
          m[id] = nid;
          row['id'] = nid;
          for (final k in row.keys.toList()) {
            var rt = _refTable[k];
            if (k == 'return_id') rt = table == 'sale_return_items' ? 'sale_returns' : 'purchase_returns';
            final v = row[k];
            if (rt != null && v is num) row[k] = idMaps[rt]?[v.toInt()] ?? v.toInt();
          }
          fixed.add(row);
        }
        idMaps[table] = m;
        out[table] = fixed;
      }
      return out;
    } finally {
      await bd.close();
    }
  }

  /// همهٔ داده‌های محلی را با خروجی `backup.export` سرور جایگزین می‌کند.
  /// (فقط وقتی صف ارسال خالی است صدا زده می‌شود.) عکس‌هایی که از قبل روی گوشی هست نگه داشته می‌شود.
  ///
  /// [discardQueue]=false: اگر همزمان عملیاتی در صف باشد (کاربر حین دریافت چیزی ثبت کرده)
  /// چیزی جایگزین نمی‌شود و false برمی‌گردد تا هیچ تغییر محلی گم نشود.
  /// [discardQueue]=true: صف (شامل خطاها) دور ریخته می‌شود و سرور مرجع قرار می‌گیرد.
  Future<bool> replaceAllFromServer(Map<String, dynamic> tables,
      {bool discardQueue = false, String? exportedAt, Map<String, dynamic>? entities, Map<String, dynamic>? docs}) async {
    // تا وقتی فرم/صفحهٔ ثبتی باز است، داده‌ها زیر دست کاربر عوض نمی‌شوند (دریافت بعداً انجام می‌شود)
    if (!discardQueue && isEditing) return false;
    final d = await db;
    var applied = false;
    await d.transaction((t) async {
      if (discardQueue) {
        await t.delete('sync_ops');
      } else {
        final n = Sqflite.firstIntValue(await t.rawQuery('SELECT COUNT(*) FROM sync_ops')) ?? 0;
        if (n > 0) return;
        // سپر ایمنی: اگر در ۱۵ دقیقهٔ اخیر پرداخت/دریافت (قسط، چک، تراکنش) به سرور فرستاده‌ایم
        // و سرور ردیف کمتری از گوشی دارد، یعنی آن ارسال روی سرور ثبت نشده. به‌جای پاک‌کردنِ
        // داده‌ی گوشی، وضعیت کامل پرداخت/دریافت‌ها دوباره به صف می‌رود تا دوباره ارسال شود.
        final lp = await t.query('meta', columns: ['v'], where: 'k=?', whereArgs: ['last_tx_push'], limit: 1);
        final lastPush = lp.isEmpty ? null : DateTime.tryParse((lp.first['v'] as String?) ?? '');
        if (lastPush != null && DateTime.now().difference(lastPush) < const Duration(minutes: 15)) {
          var localHasMore = false;
          for (final tb in const [
            'lump_tx',
            'credit_inst',
            'cheque_inst',
            'receipt_lump_tx',
            'receipt_credit_inst',
            'receipt_cheque_inst'
          ]) {
            final localN = Sqflite.firstIntValue(await t.rawQuery('SELECT COUNT(*) FROM $tb')) ?? 0;
            final srv = tables[tb];
            final srvN = srv is List ? srv.length : 0;
            if (localN > srvN) {
              localHasMore = true;
              break;
            }
          }
          if (localHasMore) {
            for (final r in await t.query('receipts', columns: ['sale_id'])) {
              await _queueReceipt(t, (r['sale_id'] as num).toInt());
            }
            for (final r in await t.query('payments', columns: ['purchase_id'])) {
              await _queuePayment(t, (r['purchase_id'] as num).toInt());
            }
            return;
          }
        }
      }
      final idmap = <int, int>{};
      for (final r in await t.query('sync_idmap', where: "kind='pur'")) {
        idmap[(r['local_id'] as num).toInt()] = (r['server_id'] as num).toInt();
      }
      final keepPhoto = <int, String>{};
      for (final r in await t.query('purchases', columns: ['id', 'photo'], where: 'photo IS NOT NULL')) {
        final id = (r['id'] as num).toInt();
        final sid = id > 0 ? id : idmap[id];
        final ph = r['photo'] as String?;
        if (sid != null && ph != null) keepPhoto[sid] = ph;
      }
      for (final e in _kSnapshot.reversed) {
        // سرور قدیمی این جدول‌ها را نمی‌فرستد: داده‌ی محلی‌شان را پاک نکن
        if (_kOptionalTables.contains(e.$1) && tables[e.$1] is! List) continue;
        await t.delete(e.$1);
      }
      // شناسه‌های موقت (منفی) بعد از این دریافت عوض می‌شوند؛ صفحه‌های بازِ قدیمی هنوز شناسهٔ
      // قدیمی را دارند. نگاشت «قدیم ← سرور» را نگه می‌داریم تا همان صفحه‌ها درست ادامه بدهند.
      for (final r in await t.query('sync_idmap')) {
        await t.insert('meta', {'k': 'alias:${r['kind']}:${r['local_id']}', 'v': '${r['server_id']}'},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await t.delete('sync_idmap');
      var needSackBackfill = false;
      for (final e in _kSnapshot) {
        final table = e.$1;
        final cols = e.$2;
        final rows = tables[table];
        if (rows is! List) continue;
        final b = t.batch();
        for (final raw in rows) {
          if (raw is! Map) continue;
          final row = <String, Object?>{};
          for (final c in cols) {
            if (raw.containsKey(c)) row[c] = _coerce(c, raw[c]);
          }
          if (row['id'] == null) continue;
          if (table == 'purchases') {
            final id = row['id'] as int;
            final hv = raw['has_photo'];
            final hasPhotoRemote = row['photo'] != null || hv == true || hv == 1 || hv == '1';
            final photo = (row['photo'] as String?) ?? keepPhoto[id];
            row['photo'] = photo;
            row['photo_pending'] = (photo == null && hasPhotoRemote) ? 1 : 0;
            row['ord'] = id;
            // اگر سرور هنوز ستون‌های گونیِ باقی‌مانده را نمی‌فرستد، بعد از دریافت محاسبه می‌شوند
            for (final k in const ['small_sacks_remaining', 'large_sacks_remaining']) {
              if (row[k] == null) {
                row.remove(k);
                needSackBackfill = true;
              }
            }
          } else if (table == 'sales') {
            row['ord'] = row['id'];
          }
          b.insert(table, row);
        }
        await b.commit(noResult: true);
      }
      if (needSackBackfill) await _backfillSacks(t);
      // S04.T04.4b: پیش‌فاکتورها (کلید افزودنیِ docs؛ سرور قدیمی نمی‌فرستد ⇒ دست نمی‌خورد)
      if (docs != null) {
        for (final e in _kDocTables.reversed) {
          if (docs[e.$1] is List) await t.delete(e.$1);
        }
        for (final e in _kDocTables) {
          final rows = docs[e.$1];
          if (rows is! List) continue;
          final b = t.batch();
          for (final raw in rows) {
            if (raw is! Map) continue;
            final row = <String, Object?>{};
            for (final c in e.$2) {
              if (raw.containsKey(c)) row[c] = _coerce(c, raw[c]);
            }
            if (row['id'] != null) b.insert(e.$1, row);
          }
          await b.commit(noResult: true);
        }
      }
      // S00.T00.4: موجودیت‌های عمومی (کلید افزودنیِ سرور؛ سرور قدیمی نمی‌فرستد ⇒ دست نمی‌خورد)
      if (entities != null) await EntityStore.applySnapshot(t, entities, discardAll: discardQueue);
      await t.insert('meta', {'k': 'initial_done', 'v': '1'}, conflictAlgorithm: ConflictAlgorithm.replace);
      await t.insert('meta', {'k': 'last_pull', 'v': DateTime.now().toIso8601String()},
          conflictAlgorithm: ConflictAlgorithm.replace);
      // STAGE12: ساعت سرور همین دریافتِ اعمال‌شده ⇒ snap_at (برای ادغام تسویهٔ دستیار در سرور).
      // فقط داخل همین تراکنش و بعد از اعمال واقعی. بدون exported_at (سرور قدیمی) متای قبلی پاک می‌شود
      // تا snap_at کهنه فرستاده نشود (سرور آن را پنجرهٔ legacy حساب می‌کند).
      if (exportedAt != null && exportedAt.isNotEmpty && exportedAt.length <= 40) {
        await t.insert('meta', {'k': 'snap_at', 'v': exportedAt}, conflictAlgorithm: ConflictAlgorithm.replace);
      } else {
        await t.delete('meta', where: "k='snap_at'");
      }
      applied = true;
    });
    if (applied) version.value++;
    return applied;
  }

  /// (تعداد در انتظار ارسال، تعداد خطادار)
  Future<(int, int)> queueCounts() async {
    final d = await db;
    final r = await d.rawQuery('SELECT state, COUNT(*) AS n FROM sync_ops GROUP BY state');
    var p = 0, f = 0;
    for (final e in r) {
      final n = (e['n'] as num).toInt();
      if (e['state'] == 'failed') {
        f = n;
      } else {
        p += n;
      }
    }
    return (p, f);
  }

  Future<Map<String, dynamic>?> nextOp() async {
    final r = await (await db).query('sync_ops', where: "state='pending'", orderBy: 'seq', limit: 1);
    return r.isEmpty ? null : r.first;
  }

  Future<List<Map<String, dynamic>>> failedOps() async =>
      (await db).query('sync_ops', where: "state='failed'", orderBy: 'seq');

  Future<void> failOp(int seq, String err) async {
    await (await db).update('sync_ops', {'state': 'failed', 'err': err}, where: 'seq=?', whereArgs: [seq]);
  }

  /// S27c: سند ارزیِ صف‌شده که نرخش در سرور نبود؛ از صف جدا (failed) می‌شود تا بقیه صف بماند،
  /// با پیشوند ثابت تا بعد از ثبت نرخ خودکار دوباره تلاش شود.
  static const String rateMissingPrefix = 'نرخ ثبت نشده';

  Future<void> failOpRateMissing(int seq, String ccy, String date) async {
    await failOp(seq, '$rateMissingPrefix: نرخ $ccy برای $date در سرور ثبت نشده؛ بعد از ثبت نرخ خودکار دوباره ارسال می‌شود');
  }

  /// بعد از ثبت/همگام‌سازی نرخ‌ها: فقط عملیات «نرخ ثبت نشده» دوباره در صف قرار می‌گیرند
  Future<int> retryRateMissingOps() async {
    final int n = await (await db).rawUpdate(
        "UPDATE sync_ops SET state='pending', attempts=0, err=NULL WHERE state='failed' AND err LIKE ?",
        <Object?>['$rateMissingPrefix%']);
    if (n > 0) version.value++;
    return n;
  }

  Future<void> bumpAttempt(int seq, String err) async {
    await (await db).rawUpdate('UPDATE sync_ops SET attempts=attempts+1, err=? WHERE seq=?', [err, seq]);
  }

  /// عملیات خطادار دوباره در صف قرار می‌گیرد
  Future<void> retryFailedOps() async {
    await (await db).rawUpdate("UPDATE sync_ops SET state='pending', attempts=0, err=NULL WHERE state='failed'");
    version.value++;
  }

  /// عملیات موفق را حذف می‌کند، مگر اینکه حین ارسال ویرایش شده باشد (rev عوض شده)
  Future<void> finishOp(int seq, int rev) async {
    await (await db).delete('sync_ops', where: 'seq=? AND rev=?', whereArgs: [seq, rev]);
  }

  /// آیا رکورد محلی هنوز وجود دارد؟ (kind: pur | sale | cat)
  Future<bool> localExists(String kind, int id) async {
    final table = switch (kind) {
      'pur' => 'purchases',
      'sale' => 'sales',
      'sret' => 'sale_returns',
      'pret' => 'purchase_returns',
      'pf' => 'proformas',
      _ => 'categories',
    };
    final r = await (await db).query(table, columns: ['id'], where: 'id=?', whereArgs: [id], limit: 1);
    return r.isNotEmpty;
  }

  /// حذفِ رکوردی که وسط ارسال «ساخت» آن، در گوشی حذف شده بود
  /// (action: purchases.delete | mixes.delete | sales.delete)
  Future<void> enqueueServerDelete(String action, int serverId) async {
    final d = await db;
    await d.transaction((t) async {
      await _enqueue(t, action, {'id': serverId});
    });
  }

  /// عکس رسید یک خرید (data-URL)؛ در لیست‌ها بارگذاری نمی‌شود چون سنگین است
  Future<String?> localPhoto(int id) async {
    final r = await (await db).query('purchases', columns: ['photo'], where: 'id=?', whereArgs: [id]);
    return r.isEmpty ? null : r.first['photo'] as String?;
  }

  // ======================= دسته‌ها و انواع =======================
  Future<List<Map<String, dynamic>>> categories() async =>
      (await db).query('categories', orderBy: 'id');

  Future<int> addCategory(String name) async {
    final n = _s(name, 100);
    if (n == null) throw Exception('نام دسته را (حداکثر ۱۰۰ حرف) وارد کنید');
    final d = await db;
    late int id;
    await d.transaction((t) async {
      id = await _tempId(t, 'categories');
      await t.insert('categories', {'id': id, 'name': n, 'preset_key': null});
      await _enqueue(t, 'categories.create', {'name': n}, refKind: 'cat', refId: id, mapKind: 'cat', localId: id);
    });
    version.value++;
    return id;
  }

  Future<List<Map<String, dynamic>>> typesOf(int categoryId) async =>
      (await db).query('types', where: 'category_id=?', whereArgs: [categoryId], orderBy: 'id');

  Future<int> addType(int categoryId, String name) async {
    final n = _s(name, 100);
    if (n == null) throw Exception('اطلاعات نوع ناقص است');
    final d = await db;
    late int id;
    await d.transaction((t) async {
      id = await t.insert('types', {'category_id': categoryId, 'name': n});
      await _enqueue(t, 'types.create', {'category_id': categoryId, 'name': n});
    });
    version.value++;
    return id;
  }

  // ======================= خرید =======================
  /// فقط خریدهای واقعی (بارهای مخلوط/کوت‌ریزی اینجا نمایش داده نمی‌شوند)
  Future<List<Map<String, dynamic>>> purchases() async {
    final d = await db;
    final rows = await d.rawQuery('''
        SELECT $_pSel, c.name AS category_name, c.preset_key AS category_preset
        FROM purchases p JOIN categories c ON c.id = p.category_id
        WHERE p.is_mix = 0
        ORDER BY p.ord DESC, p.id DESC''');
    return _withMixInfo(d, await _withSacksLeft(d, rows));
  }

  /// یک خرید با همهٔ ستون‌ها (شامل عکس)
  Future<Map<String, dynamic>?> purchaseById(int id) async {
    final rows = await (await db).rawQuery('''
        SELECT p.*, (p.photo IS NOT NULL OR p.photo_pending = 1) AS has_photo,
               c.name AS category_name, c.preset_key AS category_preset
        FROM purchases p JOIN categories c ON c.id = p.category_id
        WHERE p.id = ?''', [id]);
    return rows.isEmpty ? null : rows.first;
  }

  /// S35.T35.6b: financial block columns (nullable; additive). Mirrors server v50/v51 + side_cost_payer/taxable.
  Future<void> _addFinCols(DatabaseExecutor d) async {
    for (final String t in <String>['purchases', 'sales']) {
      for (final String c in <String>['discount_amount REAL', 'weighbridge_cost REAL', 'side_cost_payer TEXT', 'taxable INTEGER']) {
        try {
          await d.execute('ALTER TABLE $t ADD COLUMN $c');
        } catch (_) {}
      }
    }
  }

  /// S35.T35.7c: sayad_id column on the local cheque-line mirrors (nullable; server v52).
  Future<void> _addSayadCols(DatabaseExecutor d) async {
    for (final String t in <String>['cheque_inst', 'receipt_cheque_inst']) {
      try {
        await d.execute('ALTER TABLE $t ADD COLUMN sayad_id TEXT');
      } catch (_) {}
    }
  }

  /// اعتبارسنجی و گرد کردن مقادیر خرید (همان قواعد purchases.create در app.php)
  /// S35.T35.2: provenance columns of the weighing block (nullable; only filled when the form's «توزین» switch is on).
  Future<void> _addWeighCols(DatabaseExecutor d) async {
    for (final String t in <String>['purchases', 'sales']) {
      for (final String c in <String>['gross_kg REAL', 'tare_kg REAL', 'quality_deduct_kg REAL', 'weigh_ticket_no TEXT', 'vehicle_plate TEXT', 'driver_name TEXT']) {
        try {
          await d.execute('ALTER TABLE $t ADD COLUMN $c');
        } catch (_) {}
      }
    }
  }

  Map<String, dynamic> _purchaseValues(Map<String, dynamic> p) {
    final total = _n(p['total_weight']);
    final small = _n(p['small_sack_count']);
    final large = _n(p['large_sack_count']);
    if (total <= 0 || total > 1e9) throw Exception('وزن باید بزرگ‌تر از صفر باشد');
    if (small < 0 || large < 0 || small > 1e7 || large > 1e7) throw Exception('تعداد گونی نامعتبر است');
    // S35.T35.2: with a weighing block, net = gross - tare - quality deduction (tare may be a manual value)
    final double? grossKg = _nn(p['gross_kg']);
    double? tareKg;
    double? deductKg;
    double net = _r(total - (small * 0.1 + large * 0.2), 3);
    if (grossKg != null) {
      if (grossKg <= 0 || grossKg > 1e9) throw Exception('وزن کل باید بزرگ‌تر از صفر باشد');
      tareKg = _nn(p['tare_kg']) ?? (small * 0.1 + large * 0.2);
      deductKg = _nn(p['quality_deduct_kg']) ?? 0.0;
      if (tareKg < 0 || deductKg < 0) throw Exception('تارا و کسر کیفیت نمی‌توانند منفی باشند');
      net = _r(grossKg - tareKg - deductKg, 3);
    }
    if (net <= 0) throw Exception('وزن خالص باید بزرگ‌تر از صفر باشد');
    final catId = (p['category_id'] as num?)?.toInt() ?? 0;
    if (catId == 0) throw Exception('دسته را انتخاب کنید');
    final price = _n(p['price']);
    if (price < 0 || price > 1e13) throw Exception('قیمت نامعتبر است');
    double? spec(String k, {bool pct = false}) {
      final v = _nn(p[k]);
      if (v == null) return null;
      if (v < 0 || v > 1e9) throw Exception('مقدار مشخصات کیفی نامعتبر است');
      if (pct && v > 100) throw Exception('درصدها نباید از ۱۰۰ بیشتر باشند');
      return v;
    }

    String? specsJson;
    final cs = p['custom_specs'];
    if (cs is String && cs.isNotEmpty) {
      specsJson = cs;
    } else if (cs is List && cs.isNotEmpty) {
      specsJson = jsonEncode(cs);
    }
    if (specsJson != null && specsJson.length > 4000) throw Exception('مشخصات دلخواه بیش از حد بزرگ است');
    // پلن ارزی: قیمت دلار (تومان) و فی دلاری هر کیلو = فی تومانی ÷ قیمت دلار
    final fx = _fxDoc(p, 'price_ccy');
    // نرخ دستی دلار حذف شده؛ برای دلار، usd_rate قدیمی از نرخ سند (تومان = ریال/۱۰) پر می‌شود
    final double? usdRate = fx.local['ccy'] == 'USD'
        ? _r((fx.local['fx_rate'] as double) / kFxRialPerStoredUnit, 2)
        : (fx.local.isEmpty ? _usdRate(p['usd_rate']) : null);
    final priceR = _r(price, 2);
    return {
      'usd_rate': usdRate,
      'price_usd': usdRate == null ? null : _r(priceR / usdRate, 4),
      ...fx.local,
      'category_id': catId,
      'type_name': _s(p['type_name'], 100) ?? '',
      'date': _dateOnly(p['date']),
      'ounce': _rn(spec('ounce'), 3),
      'price': _r(price, 2),
      'total_weight': grossKg != null ? _r(grossKg, 3) : _r(total, 3),
      'small_sack_count': _r(small, 2),
      'large_sack_count': _r(large, 2),
      'net_weight': net,
      'gross_kg': grossKg == null ? null : _r(grossKg, 3),
      'tare_kg': tareKg == null ? null : _r(tareKg, 3),
      'quality_deduct_kg': deductKg == null ? null : _r(deductKg, 3),
      'weigh_ticket_no': grossKg == null ? null : _s(p['weigh_ticket_no'], 40),
      'vehicle_plate': grossKg == null ? null : _s(p['vehicle_plate'], 20),
      'driver_name': grossKg == null ? null : _s(p['driver_name'], 80),
      'gram': _rn(spec('gram'), 2),
      'pct_dombest': _rn(spec('pct_dombest', pct: true), 2),
      'pct_tuchin': _rn(spec('pct_tuchin', pct: true), 2),
      'pct_crooked': _rn(spec('pct_crooked', pct: true), 2),
      'pct_khandan': _rn(spec('pct_khandan', pct: true), 2),
      'custom_specs': specsJson,
      'seller': _s(p['seller'], 150),
      'note': _s(p['note'], 500),
      'labor_cost': _cost(p['labor_cost']),
      'transport_cost': _cost(p['transport_cost']),
      if (p.containsKey('tax_status')) 'tax_status': _taxStatus(p['tax_status']),
      if (p.containsKey('tax_status')) 'tax_rate_milli': _taxStatus(p['tax_status']) == null ? null : _taxRate(p['tax_rate_milli']),
      if (p.containsKey('warehouse_uid')) 'warehouse_uid': _uidOrNull(p['warehouse_uid']),
      if (p.containsKey('ounce_uid')) 'ounce_uid': _uidOrNull(p['ounce_uid']),
      ..._finCols(p), // S35.T35.6b
    };
  }

  /// uid انبار/اونس (رشتهٔ خالی یا غیررشته = null)
  String? _uidOrNull(dynamic v) {
    if (v is! String) return null;
    final s = v.trim();
    return s.isEmpty || s.length > 40 ? null : s;
  }

  /// قیمت دلار. فرم‌های پلن ریالی هیچ‌وقت این فیلد را نمی‌فرستند، پس رکورد جدید null می‌ماند؛
  /// ولی در ویرایش، مقدار قدیمیِ ذخیره‌شده (از merged) دست‌نخورده حفظ می‌شود.
  /// هزینهٔ جانبی (کارگر / حمل‌ونقل-باسکول): خالی = null، منفی یا بیش‌ازحد = خطا
  double? _cost(dynamic raw) {
    final v = _nn(raw);
    if (v == null || v == 0) return null;
    if (v < 0 || v > 1e13) throw Exception('مبلغ هزینه نامعتبر است');
    return _r(v, 2);
  }

  /// S35.T35.6b: پرداخت‌کنندهٔ هزینه‌های جانبی (us|party)؛ خالی/نامعتبر = null
  String? _payer(dynamic raw) {
    final String s = raw is String ? raw.trim() : '';
    return (s == 'us' || s == 'party') ? s : null;
  }

  /// S35.T35.6b: مشمول مالیات بودن سند → 1 / 0؛ نامشخص = null
  int? _taxableFlag(dynamic raw) {
    if (raw == null || raw == '') return null;
    return (raw == true || raw == 1 || raw == '1') ? 1 : 0;
  }

  /// S35.T35.6b: ستون‌های بلوک مالی. فقط وقتی یکی از کلیدها در ورودی باشد؛ وگرنه خالی (ویرایش‌های قدیمی دست‌نخورده).
  Map<String, dynamic> _finCols(Map<String, dynamic> p) {
    const keys = ['discount_amount', 'weighbridge_cost', 'side_cost_payer', 'taxable'];
    if (!keys.any(p.containsKey)) return <String, dynamic>{};
    return <String, dynamic>{
      'discount_amount': _cost(p['discount_amount']),
      'weighbridge_cost': _cost(p['weighbridge_cost']),
      'side_cost_payer': _payer(p['side_cost_payer']),
      'taxable': _taxableFlag(p['taxable']),
    };
  }

  /// S17.T17.1b: وضعیت مالیاتی سند (taxable|exempt|zero)؛ خالی/نامعتبر = null (رفتار قبلی)
  String? _taxStatus(dynamic raw) {
    final v = raw?.toString();
    return (v == 'taxable' || v == 'exempt' || v == 'zero') ? v : null;
  }

  /// نرخ مالیات به هزارم درصد (۹٪ = ۹۰۰۰)؛ خالی = null (نرخ سال مالی در سرور)
  int? _taxRate(dynamic raw) {
    final v = _nn(raw);
    if (v == null) return null;
    if (v < 0 || v > 100000) throw Exception('نرخ مالیات نامعتبر است');
    return v.round();
  }

  Map<String, dynamic>? _taxPayload(dynamic status, dynamic rate) {
    final st = _taxStatus(status);
    if (st == null) return null;
    final r = _taxRate(rate);
    return <String, dynamic>{'status': st, if (r != null) 'rate_milli': r};
  }

  /// S27c: فیلدهای سند ارزی از ورودی فرم. فقط وقتی ccy داده شده باشد؛ نرخ دستی دلار وجود ندارد.
  /// نرخ (`offline_rate`) = ریال به‌ازای یک واحد ارز، از کش دستگاه؛ سرور آن را بی‌صدا عوض نمی‌کند.
  /// [fxLocal]: ستون‌های محلی؛ [fxPayload]: کلیدهای ارسال به سرور.
  ({Map<String, dynamic> local, Map<String, dynamic> payload}) _fxDoc(Map<String, dynamic> src, String priceKey) {
    final String ccy = ((src['ccy'] as String?) ?? '').trim().toUpperCase();
    if (ccy.isEmpty || ccy == 'IRT') {
      return (local: <String, dynamic>{}, payload: <String, dynamic>{});
    }
    final double? pc = _nn(src['price_ccy']);
    if (pc == null || pc <= 0 || pc > 1e9) throw Exception('فی ارزی نامعتبر است');
    final double? rate = _nn(src['offline_rate']);
    if (rate == null || rate <= 0 || rate > 1e12) throw Exception('نرخ این ارز در دستگاه ثبت نشده؛ ابتدا نرخ‌ها را همگام کنید');
    final String at = ((src['offline_rate_at'] as String?) ?? DateTime.now().toIso8601String());
    final Map<String, dynamic> local = <String, dynamic>{
      'ccy': ccy,
      'fx_rate': rate,
      'fx_rate_source': 'offline',
      'fx_rate_entered_at': at,
      priceKey: pc,
    };
    final Map<String, dynamic> payload = <String, dynamic>{
      'ccy': ccy,
      'price_ccy': pc,
      'offline_rate': rate,
      'offline_rate_at': at,
    };
    return (local: local, payload: payload);
  }

  double? _usdRate(dynamic raw) {
    final u = _nn(raw);
    if (u == null) return null;
    if (u <= 0 || u > 1e9) throw Exception('قیمت دلار نامعتبر است');
    return _r(u, 2);
  }

  /// S35.T35.3b: clean grade lines [{grade_key,kg,unit_price}] from a form list; null = key absent (feature off => leave untouched).
  List<Map<String, dynamic>>? _gradePayload(dynamic lines) {
    if (lines is! List) return null;
    final List<Map<String, dynamic>> o = <Map<String, dynamic>>[];
    for (final dynamic l in lines) {
      if (l is! Map) continue;
      final String k = '${l['grade_key'] ?? ''}'.trim();
      final double? kg = _nn(l['kg']);
      final double? up = _nn(l['unit_price']);
      if (k.isEmpty || kg == null || kg <= 0 || up == null || up < 0) throw Exception('ردیف درجه نامعتبر است');
      o.add(<String, dynamic>{'grade_key': k, 'kg': _r(kg, 3), 'unit_price': up.round()});
    }
    return o;
  }

  Future<void> _saveGradeLocal(DatabaseExecutor t, String docType, int docId, List<Map<String, dynamic>>? lines) async {
    if (lines == null) return;
    await t.delete('doc_grade_lines', where: 'doc_type=? AND doc_id=?', whereArgs: <Object?>[docType, docId]);
    for (final Map<String, dynamic> l in lines) {
      final int id = await _tempId(t, 'doc_grade_lines');
      await t.insert('doc_grade_lines', <String, Object?>{'id': id, 'doc_type': docType, 'doc_id': docId, ...l});
    }
  }

  Map<String, dynamic> _purchasePayload(Map<String, dynamic> v) {
    Object? specs;
    final js = v['custom_specs'];
    if (js is String && js.isNotEmpty) {
      try {
        specs = jsonDecode(js);
      } catch (_) {}
    }
    return {
      'category_id': v['category_id'],
      'type_name': v['type_name'],
      'date': v['date'],
      'ounce': v['ounce'],
      'price': v['price'],
      'total_weight': v['total_weight'],
      'small_sack_count': v['small_sack_count'],
      'large_sack_count': v['large_sack_count'],
      'gram': v['gram'],
      'pct_dombest': v['pct_dombest'],
      'pct_tuchin': v['pct_tuchin'],
      'pct_crooked': v['pct_crooked'],
      'pct_khandan': v['pct_khandan'],
      'custom_specs': specs,
      'seller': v['seller'],
      'note': v['note'],
      if (v['ccy'] == null) 'usd_rate': v['usd_rate'],
      if (v['ccy'] != null) ...<String, dynamic>{
        'ccy': v['ccy'],
        'price_ccy': v['price_ccy'],
        'offline_rate': v['fx_rate'],
        'offline_rate_at': v['fx_rate_entered_at'],
      },
      'labor_cost': v['labor_cost'],
      'transport_cost': v['transport_cost'],
      if (v['gross_kg'] != null) ...<String, dynamic>{ // S35.T35.2: weighing block (server recomputes and verifies the net)
        'gross_kg': v['gross_kg'],
        'tare_kg': v['tare_kg'],
        'quality_deduct_kg': v['quality_deduct_kg'],
        'net_weight': v['net_weight'],
        'weigh_ticket_no': v['weigh_ticket_no'],
        'vehicle_plate': v['vehicle_plate'],
        'driver_name': v['driver_name'],
      },
      if (_taxPayload(v['tax_status'], v['tax_rate_milli']) != null) 'tax': _taxPayload(v['tax_status'], v['tax_rate_milli']),
      if (v['warehouse_uid'] is String) 'warehouse_uid': v['warehouse_uid'],
      if (v.containsKey('ounce_uid')) 'ounce_uid': v['ounce_uid'],
      'discount_amount': v['discount_amount'], // S35.T35.6b: financial block (server ignores when form.fin_block is off)
      'weighbridge_cost': v['weighbridge_cost'],
      'side_cost_payer': v['side_cost_payer'],
      'taxable': v['taxable'] == null ? null : v['taxable'] == 1,
    };
  }

  static String? _cleanPhoto(dynamic p) {
    if (p is! String) return null;
    return p.startsWith('data:image/') ? p : null;
  }

  Future<int> insertPurchase(Map<String, dynamic> p) async {
    // اگر فرم از قبل باز بوده و شناسهٔ موقتِ دسته در این بین به شناسهٔ سرور تبدیل شده، اصلاح می‌شود
    final catId = (p['category_id'] as num?)?.toInt();
    if (catId != null) p = {...p, 'category_id': await currentId('cat', catId)};
    late int id;
    await _write((d) => d.transaction((t) async {
          final v = _purchaseValues(p);
          final photo = _cleanPhoto(p['photo']);
          id = await _tempId(t, 'purchases');
          final ord = await _nextOrd(t, 'purchases');
          await t.insert('purchases', {
            ...v,
            'id': id,
            'code': 'N${-id}', // کد موقت؛ بعد از ارسال به سرور کد واقعی (KH…) جایگزین می‌شود
            'remaining': v['net_weight'],
            'small_sacks_remaining': v['small_sack_count'],
            'large_sacks_remaining': v['large_sack_count'],
            'is_mix': 0,
            'photo': photo,
            'photo_pending': 0,
            'created_at': _stamp(),
            'ord': ord,
          });
          final payload = _purchasePayload(v);
          if (photo != null) payload['photo'] = photo;
          final List<Map<String, dynamic>>? gl = _gradePayload(p['grade_lines']); // S35.T35.3b
          if (gl != null) payload['grade_lines'] = gl;
          await _saveGradeLocal(t, 'purchase', id, gl);
          await _enqueue(t, 'purchases.create', payload, refKind: 'pur', refId: id, mapKind: 'pur', localId: id);
          // تأیید قطعی (داخل همان تراکنش): خرید در لیست دیده می‌شود و در صف ارسال به سرور هم هست
          await _confirm(t, 'SELECT 1 FROM purchases p JOIN categories c ON c.id = p.category_id WHERE p.id = ?', [id],
              'خرید ثبت نشد؛ دستهٔ انتخاب‌شده دیگر وجود ندارد. صفحه را ببندید و دوباره امتحان کنید.');
          await _confirm(t, "SELECT 1 FROM sync_ops WHERE ref_kind='pur' AND ref_id=?", [id]);
        }));
    version.value++;
    return id;
  }

  /// ویرایش خرید. مثل سرور: اگر بخشی از آن فروخته شده باشد وزن قابل تغییر نیست.
  /// اگر کلید `photo` در p نباشد یعنی عکس تغییری نکرده است.
  Future<void> updatePurchase(int id, Map<String, dynamic> p) async {
    await _write((d) => d.transaction((t) async {
      final rows = await t.query('purchases', where: 'id=?', whereArgs: [id]);
      if (rows.isEmpty) throw Exception('این خرید یافت نشد');
      final cur = rows.first;
      final merged = <String, dynamic>{};
      cur.forEach((k, v) => merged[k] = v);
      p.forEach((k, v) => merged[k] = v);
      final v = _purchaseValues(merged);
      final oldNet = (cur['net_weight'] as num).toDouble();
      final oldRem = (cur['remaining'] as num).toDouble();
      final sold = oldNet - oldRem;
      final net = v['net_weight'] as double;
      if (sold > 1e-6 && (net - oldNet).abs() > 1e-6) {
        throw Exception('چون بخشی از این خرید فروخته شده، وزن آن قابل تغییر نیست');
      }
      // گونی‌هایی که تا حالا مصرف شده ثابت می‌ماند؛ فقط سقف جدید (تعداد خرید) عوض می‌شود
      final usedSmall = (cur['small_sack_count'] as num).toDouble() - (cur['small_sacks_remaining'] as num).toDouble();
      final usedLarge = (cur['large_sack_count'] as num).toDouble() - (cur['large_sacks_remaining'] as num).toDouble();
      final newSmallRem = (v['small_sack_count'] as double) - usedSmall;
      final newLargeRem = (v['large_sack_count'] as double) - usedLarge;
      if (newSmallRem < -1e-6 || newLargeRem < -1e-6) {
        throw Exception('تعداد گونی نمی‌تواند از گونیِ تاکنون مصرف‌شدهٔ این خرید کمتر باشد');
      }
      final upd = <String, Object?>{
        ...v,
        'remaining': _r(net - sold, 3),
        'small_sacks_remaining': math.max(0.0, _r(newSmallRem, 2)),
        'large_sacks_remaining': math.max(0.0, _r(newLargeRem, 2)),
      };
      final photoChanged = p.containsKey('photo');
      String? photo;
      if (photoChanged) {
        photo = _cleanPhoto(p['photo']);
        upd['photo'] = photo;
        upd['photo_pending'] = 0;
      }
      await t.update('purchases', upd, where: 'id=?', whereArgs: [id]);
      final payload = _purchasePayload(v);
      payload['id'] = id;
      if (photoChanged) payload['photo'] = photo;
      final List<Map<String, dynamic>>? gl = _gradePayload(p['grade_lines']); // S35.T35.3b
      if (gl != null) payload['grade_lines'] = gl;
      await _saveGradeLocal(t, 'purchase', id, gl);
      await _enqueue(t, 'purchases.create', payload, refKind: 'pur', refId: id);
    }));
    version.value++;
  }

  /// اگر از این خرید فروشی انجام شده یا در ساخت یک مخلوط استفاده شده باشد حذف نمی‌شود؛
  /// اگر خودش نتیجه‌ی یک مخلوط باشد هم باید با deleteMix حذف شود، نه این متد
  Future<bool> deletePurchase(int id) async {
    final d = await db;
    final used = await d.query('sale_items', where: 'purchase_id=?', whereArgs: [id], limit: 1);
    if (used.isNotEmpty) return false;
    final usedAsMixSource =
        await d.query('mix_sources', where: 'source_purchase_id=?', whereArgs: [id], limit: 1);
    if (usedAsMixSource.isNotEmpty) return false;
    final isMixResult =
        await d.query('mix_sources', where: 'mix_purchase_id=?', whereArgs: [id], limit: 1);
    if (isMixResult.isNotEmpty) return false;
    // S04.T04.4b: خریدی که برگشت (از خرید یا از فروشِ همین بار) دارد حذف نمی‌شود (مثل سرور)
    for (final String rt in const ['purchase_return_items', 'sale_return_items']) {
      if ((await d.query(rt, where: 'lot_id=?', whereArgs: [id], limit: 1)).isNotEmpty) return false;
    }
    var ok = true;
    await d.transaction((t) async {
      final cur = await t.query('purchases', columns: ['net_weight', 'remaining'], where: 'id=?', whereArgs: [id]);
      if (cur.isEmpty) {
        ok = false;
        return;
      }
      final diff = (cur.first['net_weight'] as num).toDouble() - (cur.first['remaining'] as num).toDouble();
      if (diff.abs() > 1e-6) {
        ok = false;
        return;
      }
      final pay = await t.query('payments', where: 'purchase_id=?', whereArgs: [id]);
      if (pay.isNotEmpty) {
        final payId = pay.first['id'] as int;
        await t.delete('lump_tx', where: 'payment_id=?', whereArgs: [payId]);
        await t.delete('credit_inst', where: 'payment_id=?', whereArgs: [payId]);
        await t.delete('cheque_inst', where: 'payment_id=?', whereArgs: [payId]);
        await t.delete('payments', where: 'id=?', whereArgs: [payId]);
      }
      await t.delete('doc_grade_lines', where: 'doc_type=? AND doc_id=?', whereArgs: <Object?>['purchase', id]); // S35.T35.3b
      await t.delete('purchases', where: 'id=?', whereArgs: [id]);
      if (id < 0) {
        await _purgeOps(t, 'pur', id); // هرگز به سرور نرسیده بود
      } else {
        await _enqueue(t, 'purchases.delete', {'id': id}, refKind: 'pur', refId: id);
      }
    });
    if (ok) version.value++;
    return ok;
  }


  static List<Map<String, String>> decodeCustomSpecs(String? json) {
    if (json == null || json.isEmpty) return [];
    try {
      final list = jsonDecode(json) as List;
      return list
          .map((e) => {'label': (e['label'] ?? '').toString(), 'value': (e['value'] ?? '').toString()})
          .toList();
    } catch (_) {
      return [];
    }
  }

  static String encodeCustomSpecs(List<Map<String, String>> specs) => jsonEncode(specs);

  // ---------- موجودی ----------
  Future<List<Map<String, dynamic>>> lots() async {
    final d = await db;
    final rows = await d.rawQuery('''
        SELECT $_pSel, c.name AS category_name, c.preset_key AS category_preset
        FROM purchases p JOIN categories c ON c.id = p.category_id
        WHERE p.remaining > 0.0005
        ORDER BY c.name, p.type_name, p.id''');
    return _withSacksLeft(d, rows);
  }

  Future<List<Map<String, dynamic>>> searchLots(String query) async {
    final q = query.trim();
    if (q.isEmpty) return lots();
    final d = await db;
    final rows = await d.rawQuery('''
        SELECT $_pSel, c.name AS category_name, c.preset_key AS category_preset
        FROM purchases p JOIN categories c ON c.id = p.category_id
        WHERE p.remaining > 0.0005
          AND (p.code LIKE ? OR p.type_name LIKE ? OR c.name LIKE ?)
        ORDER BY c.name, p.type_name, p.id''', ['%$q%', '%$q%', '%$q%']);
    return _withSacksLeft(d, rows);
  }

  Future<Map<String, dynamic>?> lotByCode(String raw) async {
    final code = normalizeScan(raw);
    if (code == null) return null;
    final d = await db;
    final rows = await d.rawQuery('''
        SELECT $_pSel, c.name AS category_name, c.preset_key AS category_preset
        FROM purchases p JOIN categories c ON c.id = p.category_id
        WHERE p.code = ?
        LIMIT 1''', [code]);
    if (rows.isEmpty) return null;
    final out = await _withMixInfo(d, await _withSacksLeft(d, rows));
    return out.isEmpty ? null : out.first;
  }

  /// برای هر ردیف: آیا مقداری از آن هنوز داخل مخلوطی است که کامل فروش نرفته؟
  /// (in_mix_stock / in_mix_codes — بازگشتی برای مخلوطِ مخلوط؛ دقیقاً مثل attachSacksLeft در app.php)
  Future<List<Map<String, dynamic>>> _withMixInfo(DatabaseExecutor d, List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return rows;
    final links = await d.rawQuery('SELECT source_purchase_id AS src, mix_purchase_id AS mix_id FROM mix_sources');
    final childrenOf = <int, List<int>>{};
    for (final r in links) {
      childrenOf.putIfAbsent((r['src'] as num).toInt(), () => []).add((r['mix_id'] as num).toInt());
    }
    final alive = <int, String>{};
    if (childrenOf.isNotEmpty) {
      for (final r in await d.rawQuery('SELECT id, code FROM purchases WHERE is_mix = 1 AND remaining > 0.000001')) {
        alive[(r['id'] as num).toInt()] = (r['code'] as String?) ?? '';
      }
    }
    return [
      for (final r in rows)
        () {
          final codes = <String>[];
          final seen = <int>{};
          final stack = <int>[...(childrenOf[(r['id'] as num).toInt()] ?? const <int>[])];
          while (stack.isNotEmpty) {
            final m = stack.removeLast();
            if (!seen.add(m)) continue;
            if (alive.containsKey(m)) codes.add(alive[m]!);
            stack.addAll(childrenOf[m] ?? const <int>[]);
          }
          return <String, dynamic>{...r, 'in_mix_codes': codes, 'in_mix_stock': codes.isNotEmpty};
        }()
    ];
  }

  /// «موجود» مثل وب: هنوز وزنی از خودش مانده، یا مقداری از آن داخل مخلوطِ فروش‌نرفته است
  static bool isAvailable(Map<String, dynamic> p) =>
      ((p['remaining'] as num?) ?? 0).toDouble() > 1e-6 || p['in_mix_stock'] == true;

  /// همهٔ خریدها و مخلوط‌ها (موجود + فروش‌رفته) با گونی باقی‌مانده و اطلاعات مخلوط — برای صفحهٔ انبار
  Future<List<Map<String, dynamic>>> inventoryAll() async {
    final d = await db;
    final rows = await d.rawQuery('''
        SELECT $_pSel, c.name AS category_name, c.preset_key AS category_preset
        FROM purchases p JOIN categories c ON c.id = p.category_id
        ORDER BY c.name, p.type_name, p.id''');
    return _withMixInfo(d, await _withSacksLeft(d, rows));
  }

  /// گونی باقی‌مانده‌ی هر خرید مستقیماً از دو ستون ذخیره‌شده خوانده می‌شود
  /// (small_sacks_remaining / large_sacks_remaining) و مستقل از وزن باقی‌مانده است.
  /// کلیدهای small_left / large_left برای سازگاری با صفحه‌ها نگه داشته شده‌اند.
  Future<List<Map<String, dynamic>>> _withSacksLeft(
      Database d, List<Map<String, Object?>> rows) async {
    return [
      for (final r in rows)
        {
          ...r,
          'small_left': ((r['small_sacks_remaining'] as num?) ?? 0).toDouble(),
          'large_left': ((r['large_sacks_remaining'] as num?) ?? 0).toDouble(),
          'sacks_estimated': false,
        }
    ];
  }

  /// مثل lots() اما برای ویرایش یک فروش موجود: مانده‌ی هر خرید را طوری برمی‌گرداند
  /// که انگار سهم این فروش هنوز کسر نشده (تا بتوان همان مقدار قبلی را هم نشان داد
  /// و هم امکان افزایش/کاهش آن را فراهم کرد). فیلد اضافه‌ی sale_weight مقدار
  /// فعلیِ این فروش از آن خرید را نشان می‌دهد.
  Future<List<Map<String, dynamic>>> lotsForSaleEdit(int saleId) async {
    final d = await db;
    final items = await d.query('sale_items', where: 'sale_id=?', whereArgs: [saleId]);
    final used = <int, double>{};
    final usedSmall = <int, double>{};
    final usedLarge = <int, double>{};
    for (final it in items) {
      final pid = it['purchase_id'] as int;
      used[pid] = (used[pid] ?? 0) + (it['weight'] as num).toDouble();
      usedSmall[pid] = (usedSmall[pid] ?? 0) + ((it['small_sacks'] as num?) ?? 0).toDouble();
      usedLarge[pid] = (usedLarge[pid] ?? 0) + ((it['large_sacks'] as num?) ?? 0).toDouble();
    }
    final rows = await d.rawQuery('''
        SELECT $_pSel, c.name AS category_name, c.preset_key AS category_preset
        FROM purchases p JOIN categories c ON c.id = p.category_id
        ORDER BY c.name, p.type_name, p.id''');
    final out = <Map<String, dynamic>>[];
    for (final r in rows) {
      final id = r['id'] as int;
      final saleWeight = used[id] ?? 0;
      final adjustedRemaining = (r['remaining'] as num).toDouble() + saleWeight;
      if (adjustedRemaining > 0.0005) {
        final sSmall = usedSmall[id] ?? 0;
        final sLarge = usedLarge[id] ?? 0;
        final small = math.min((r['small_sack_count'] as num).toDouble(),
            ((r['small_sacks_remaining'] as num?) ?? 0).toDouble() + sSmall);
        final large = math.min((r['large_sack_count'] as num).toDouble(),
            ((r['large_sacks_remaining'] as num?) ?? 0).toDouble() + sLarge);
        out.add({
          ...r,
          'remaining': adjustedRemaining,
          'sale_weight': saleWeight,
          'sale_small': sSmall,
          'sale_large': sLarge,
          'small_left': small,
          'large_left': large,
          'sacks_estimated': false,
        });
      }
    }
    return out;
  }

  /// مثل lotsForSaleEdit اما برای ویرایش یک بار «مخلوط» موجود: مانده‌ی هر خریدِ
  /// مبدأ طوری برگردانده می‌شود که انگار سهمِ همین مخلوط هنوز از آن کم نشده
  /// (بر پایه‌ی mix_sources، نه sale_items). خودِ ردیفِ مخلوط از لیست کنار گذاشته
  /// می‌شود تا نتوان یک مخلوط را به‌عنوان مبدأ خودش انتخاب کرد.
  Future<List<Map<String, dynamic>>> lotsForMixEdit(int mixPurchaseId) async {
    final d = await db;
    final items =
        await d.query('mix_sources', where: 'mix_purchase_id=?', whereArgs: [mixPurchaseId]);
    final used = <int, double>{};
    final usedSmall = <int, double>{};
    final usedLarge = <int, double>{};
    for (final it in items) {
      final pid = it['source_purchase_id'] as int;
      used[pid] = (used[pid] ?? 0) + (it['weight'] as num).toDouble();
      usedSmall[pid] = (usedSmall[pid] ?? 0) + ((it['small_sacks'] as num?) ?? 0).toDouble();
      usedLarge[pid] = (usedLarge[pid] ?? 0) + ((it['large_sacks'] as num?) ?? 0).toDouble();
    }
    final rows = await d.rawQuery('''
        SELECT $_pSel, c.name AS category_name, c.preset_key AS category_preset
        FROM purchases p JOIN categories c ON c.id = p.category_id
        WHERE p.id != ?
        ORDER BY c.name, p.type_name, p.id''', [mixPurchaseId]);
    final out = <Map<String, dynamic>>[];
    for (final r in rows) {
      final id = r['id'] as int;
      final usedWeight = used[id] ?? 0;
      final adjustedRemaining = (r['remaining'] as num).toDouble() + usedWeight;
      if (adjustedRemaining > 0.0005) {
        final small = math.min((r['small_sack_count'] as num).toDouble(),
            ((r['small_sacks_remaining'] as num?) ?? 0).toDouble() + (usedSmall[id] ?? 0));
        final large = math.min((r['large_sack_count'] as num).toDouble(),
            ((r['large_sacks_remaining'] as num?) ?? 0).toDouble() + (usedLarge[id] ?? 0));
        out.add({
          ...r,
          'remaining': adjustedRemaining,
          'small_left': small,
          'large_left': large,
          'sacks_estimated': false,
        });
      }
    }
    return out;
  }


  // ======================= مخلوط‌کردن (کوت‌ریزی) =======================
  /// مبدأهای مخلوط: وزن منفی مجاز نیست و ردیف‌های تکراری یک خرید ادغام می‌شوند
  List<Map<String, dynamic>> _normMixSources(List<Map<String, dynamic>> sources) {
    if (sources.isEmpty) throw Exception('حداقل یک جنس مبدأ را انتخاب کنید');
    final m = <int, Map<String, dynamic>>{};
    for (final s in sources) {
      final pid = (s['purchase_id'] as num).toInt();
      final w = _n(s['weight']);
      final ss = _nn(s['small_sacks']);
      final ls = _nn(s['large_sacks']);
      if (w < 0 || w > 1e9 || (ss != null && ss < 0) || (ls != null && ls < 0)) {
        throw Exception('وزن یا گونی مبدأ نامعتبر است');
      }
      final r = m.putIfAbsent(
          pid, () => <String, dynamic>{'purchase_id': pid, 'weight': 0.0, 'small_sacks': null, 'large_sacks': null});
      r['weight'] = (r['weight'] as double) + w;
      if (ss != null) r['small_sacks'] = ((r['small_sacks'] as num?) ?? 0) + ss;
      if (ls != null) r['large_sacks'] = ((r['large_sacks'] as num?) ?? 0) + ls;
    }
    return m.values.toList();
  }

  /// موجودی را با گرد کردن ۳ رقمی کم/زیاد می‌کند (مثل ستون DECIMAL(12,3) سرور)
  Future<void> _addRemaining(DatabaseExecutor t, int purchaseId, double delta) async {
    await t.rawUpdate('UPDATE purchases SET remaining = ROUND(remaining + ?, 3) WHERE id = ?', [delta, purchaseId]);
  }

  /// گونی باقی‌مانده‌ی یک خرید را کم/زیاد می‌کند (delta منفی = کم شدن).
  /// نتیجه بین ۰ و تعداد گونی خرید نگه داشته می‌شود؛ کوچک و بزرگ کاملاً جدا هستند.
  Future<void> _addSacks(DatabaseExecutor t, int purchaseId, double small, double large) async {
    if (small == 0 && large == 0) return;
    await t.rawUpdate('''
        UPDATE purchases SET
          small_sacks_remaining = MAX(0, MIN(small_sack_count, ROUND(small_sacks_remaining + ?, 2))),
          large_sacks_remaining = MAX(0, MIN(large_sack_count, ROUND(large_sacks_remaining + ?, 2)))
        WHERE id = ?''', [small, large, purchaseId]);
  }

  /// همه‌ی بارهای مخلوط‌شده (برای نمایش در انبار)
  Future<List<Map<String, dynamic>>> mixes() async {
    final d = await db;
    final rows = await d.rawQuery('''
        SELECT $_pSel, c.name AS category_name, c.preset_key AS category_preset
        FROM purchases p JOIN categories c ON c.id = p.category_id
        WHERE p.is_mix = 1
        ORDER BY p.ord DESC, p.id DESC''');
    return rows;
  }

  /// ترکیب‌سازها (منابع) یک بار مخلوط: از کدام بارها و چقدر برداشته شده
  Future<List<Map<String, dynamic>>> mixSourcesOf(int mixPurchaseId) async {
    final d = await db;
    return d.rawQuery('''
        SELECT ms.*, p.type_name AS type_name, p.code AS code, p.date AS source_date, c.name AS category_name
        FROM mix_sources ms
        JOIN purchases p ON p.id = ms.source_purchase_id
        JOIN categories c ON c.id = p.category_id
        WHERE ms.mix_purchase_id = ?
        ORDER BY ms.id''', [mixPurchaseId]);
  }

  /// بررسی مبدأها (موجودی کافی) و محاسبهٔ فی میانگین وزنی؛ خروجی: [avgPrice]
  Future<(double, double?)> _checkMixSources(DatabaseExecutor t, List<Map<String, dynamic>> srcs) async {
    var sumW = 0.0;
    var sumVal = 0.0;
    var sumUsd = 0.0;
    var usdMissing = false;
    for (final s in srcs) {
      final pid = s['purchase_id'] as int;
      final w = s['weight'] as double;
      if (w <= 0) continue;
      final rows = await t.rawQuery('''
          SELECT p.remaining, p.price, p.price_usd, p.type_name, p.small_sacks_remaining, p.large_sacks_remaining,
                 c.name AS category_name
          FROM purchases p JOIN categories c ON c.id = p.category_id
          WHERE p.id = ?''', [pid]);
      if (rows.isEmpty) throw Exception('یکی از مبدأها یافت نشد');
      final rem = (rows.first['remaining'] as num).toDouble();
      final price = (rows.first['price'] as num).toDouble();
      final label = '${rows.first['type_name']} (${rows.first['category_name']})';
      if (w > rem + 1e-6) {
        throw Exception('موجودی «$label» کافی نیست؛ فقط ${_fmt(rem)} کیلو باقی مانده');
      }
      // گونیِ مصرف‌شده از یک جنسِ انبار نباید از گونیِ باقی‌مانده‌ی همان جنس بیشتر باشد
      // (گونیِ مخلوطِ جدید جداست و محدودیتی ندارد)
      final ss = _nn(s['small_sacks']) ?? 0.0;
      final ls = _nn(s['large_sacks']) ?? 0.0;
      final smallLeft = ((rows.first['small_sacks_remaining'] as num?) ?? 0).toDouble();
      final largeLeft = ((rows.first['large_sacks_remaining'] as num?) ?? 0).toDouble();
      if (ss > smallLeft + 1e-6) {
        throw Exception('گونی کوچک مصرفی از «$label» بیشتر از موجودی است؛ فقط ${_fmt(smallLeft)} عدد مانده');
      }
      if (ls > largeLeft + 1e-6) {
        throw Exception('گونی بزرگ مصرفی از «$label» بیشتر از موجودی است؛ فقط ${_fmt(largeLeft)} عدد مانده');
      }
      sumW += w;
      sumVal += w * price;
      final pu = (rows.first['price_usd'] as num?)?.toDouble();
      if (pu == null) {
        usdMissing = true; // مبدأیی که قبل از پلن ارزی خریداری شده فی دلاری ندارد
      } else {
        sumUsd += w * pu;
      }
    }
    if (sumW <= 0) throw Exception('حداقل از یک جنس مبدأ وزن بردارید');
    // فی دلاریِ مخلوط = میانگین وزنیِ فی دلاریِ مبدأها (همان منطق فی تومانی)
    final avgUsd = !usdMissing ? sumUsd / sumW : null;
    return (sumVal / sumW, avgUsd);
  }

  Future<void> _applyMixSources(DatabaseExecutor t, int mixId, List<Map<String, dynamic>> srcs) async {
    for (final s in srcs) {
      final pid = s['purchase_id'] as int;
      final w = _r(s['weight'] as double, 3);
      if (w <= 0) continue;
      await _addRemaining(t, pid, -w);
      final ms = _rn(_nn(s['small_sacks']), 2);
      final ml = _rn(_nn(s['large_sacks']), 2);
      await _addSacks(t, pid, -(ms ?? 0.0), -(ml ?? 0.0));
      await t.insert('mix_sources', {
        'mix_purchase_id': mixId,
        'source_purchase_id': pid,
        'weight': w,
        'small_sacks': ms,
        'large_sacks': ml,
      });
    }
  }

  List<Map<String, dynamic>> _mixSourcesPayload(List<Map<String, dynamic>> srcs) => [
        for (final s in srcs)
          if ((s['weight'] as double) > 0)
            {
              'purchase_id': s['purchase_id'],
              'weight': _r(s['weight'] as double, 3),
              'small_sacks': _rn(_nn(s['small_sacks']), 2),
              'large_sacks': _rn(_nn(s['large_sacks']), 2),
            }
      ];

  double _takenOf(List<Map<String, dynamic>> srcs) {
    var t = 0.0;
    for (final s in srcs) {
      final w = _r(s['weight'] as double, 3);
      if (w > 0) t += w;
    }
    return t;
  }

  /// ضایعات/خاکِ مخلوط یا جداسازی. قاعده (مثل سرور): وزن برداشته‌شده = وزن خالصِ بار تازه + ضایعات.
  /// [waste] == null یعنی بررسی انجام نمی‌شود (سازگاری با نسخه‌های قدیمی).
  double? _checkWaste(List<Map<String, dynamic>> srcs, double net, double? waste) {
    if (waste == null) return null;
    if (waste < 0 || waste > 1e9) throw Exception('وزن ضایعات نامعتبر است');
    var taken = 0.0;
    for (final s in srcs) {
      taken += _r(s['weight'] as double, 3);
    }
    final diff = taken - net - waste;
    if (diff.abs() > 0.0015) {
      if (diff > 0) {
        throw Exception('وزن برداشته‌شده ${_fmt(taken)} کیلو است ولی وزن خالص + ضایعات فقط ${_fmt(net + waste)} کیلو می‌شود؛ '
            '${_fmt(diff)} کیلو اختلاف ثبت‌نشده دارید. اگر خاک یا ضایعات بوده، در «ضایعات» وارد کنید');
      }
      throw Exception('وزن خالص + ضایعات (${_fmt(net + waste)} کیلو) از وزن برداشته‌شده (${_fmt(taken)} کیلو) بیشتر است');
    }
    return _r(waste, 3);
  }

  /// یک بار مخلوط (کوت‌ریزی) جدید می‌سازد: وزن دلخواه از چند بار موجود در انبار
  /// کم می‌شود و یک بار تازه با وزن خالص و تعداد گونیِ واردشده به انبار اضافه می‌شود.
  /// فی خرید بار جدید میانگین وزنیِ فی بارهای مبدأ است.
  ///
  /// sources: هرکدام {'purchase_id': int, 'weight': double, 'small_sacks': double?, 'large_sacks': double?}
  Future<int> createMix({
    required int categoryId,
    required String typeName,
    String? baseType,
    required List<Map<String, dynamic>> sources,
    required double netWeight,
    required double smallSackCount,
    required double largeSackCount,
    double? ounce,
    double? gram,
    double? waste,
    String? note,
    String? warehouseUid,
    String? ounceUid,
    bool uidsGiven = false,
  }) async {
    if (categoryId == 0) throw Exception('دسته را انتخاب کنید');
    if (netWeight <= 0 || netWeight > 1e9) throw Exception('وزن نهایی مخلوط (طبق ترازو) را وارد کنید');
    if (smallSackCount < 0 || largeSackCount < 0) throw Exception('تعداد گونی نامعتبر است');
    if ((ounce != null && (ounce < 0 || ounce > 1e9)) || (gram != null && (gram < 0 || gram > 1e9))) {
      throw Exception('مقدار انس یا گرم نامعتبر است');
    }
    final srcs = _normMixSources(sources);
    final wasteV = _checkWaste(srcs, _r(netWeight, 3), waste);
    late int mixId;
    await _write((d) => d.transaction((t) async {
      final (avgPrice0, avgUsd0) = await _checkMixSources(t, srcs);
      // فی = هزینهٔ کل ÷ وزن خالص: هزینهٔ ضایعات هم در فی لحاظ می‌شود (بدون ضایعات = همان میانگین وزنی)
      final feeFactor = wasteV == null ? 1.0 : _takenOf(srcs) / _r(netWeight, 3);
      final avgPrice = avgPrice0 * feeFactor;
      final avgUsd = avgUsd0 == null ? null : avgUsd0 * feeFactor;
      final mixUsd = avgUsd == null ? null : _r(avgUsd, 4);
      final mixRate = (mixUsd != null && mixUsd > 0) ? _r(avgPrice / mixUsd, 2) : null;
      final net = _r(netWeight, 3);
      final name = _s(typeName, 100) ?? 'مخلوط';
      final baseTypeV = _s(baseType, 100);
      final nt = _s(note, 500);
      mixId = await _tempId(t, 'purchases');
      final ord = await _nextOrd(t, 'purchases');
      await t.insert('purchases', {
        'id': mixId,
        'code': 'N${-mixId}',
        'category_id': categoryId,
        'type_name': name,
        'base_type': baseTypeV,
        'date': _ymd(DateTime.now()),
        'price': _r(avgPrice, 2),
        'usd_rate': mixRate,
        'price_usd': mixUsd,
        'total_weight': net,
        'small_sack_count': _r(smallSackCount, 2),
        'large_sack_count': _r(largeSackCount, 2),
        'small_sacks_remaining': _r(smallSackCount, 2),
        'large_sacks_remaining': _r(largeSackCount, 2),
        'net_weight': net,
        'remaining': net,
        'ounce': _rn(ounce, 3),
        'gram': _rn(gram, 2),
        'waste': wasteV,
        'is_mix': 1,
        'note': nt,
        if (_uidOrNull(warehouseUid) != null) 'warehouse_uid': _uidOrNull(warehouseUid),
        if (_uidOrNull(ounceUid) != null) 'ounce_uid': _uidOrNull(ounceUid),
        'photo_pending': 0,
        'created_at': _stamp(),
        'ord': ord,
      });
      await _applyMixSources(t, mixId, srcs);
      await _enqueue(
          t,
          'mixes.create',
          {
            'category_id': categoryId,
            'type_name': name,
        'base_type': baseTypeV,
            'sources': _mixSourcesPayload(srcs),
            'net_weight': net,
            'small_sack_count': _r(smallSackCount, 2),
            'large_sack_count': _r(largeSackCount, 2),
            'ounce': _rn(ounce, 3),
            'gram': _rn(gram, 2),
            if (wasteV != null) 'waste': wasteV,
            'note': nt,
            if (_uidOrNull(warehouseUid) != null) 'warehouse_uid': _uidOrNull(warehouseUid),
            if (_uidOrNull(ounceUid) != null) 'ounce_uid': _uidOrNull(ounceUid),
          },
          refKind: 'pur',
          refId: mixId,
          mapKind: 'pur',
          localId: mixId);
      await _confirm(t, 'SELECT 1 FROM purchases p JOIN categories c ON c.id = p.category_id WHERE p.id = ?', [mixId]);
      await _confirm(t, "SELECT 1 FROM sync_ops WHERE ref_kind='pur' AND ref_id=?", [mixId]);
    }));
    version.value++;
    return mixId;
  }

  /// حذف یک بار مخلوط: اگر چیزی از آن فروخته نشده باشد، وزن و گونیِ برداشته‌شده
  /// به بارهای مبدأ برمی‌گردد. اگر فروخته شده باشد حذف نمی‌شود.
  Future<bool> deleteMix(int mixPurchaseId) async {
    final d = await db;
    final used = await d.query('sale_items', where: 'purchase_id=?', whereArgs: [mixPurchaseId], limit: 1);
    if (used.isNotEmpty) return false;
    var ok = true;
    await d.transaction((t) async {
      final cur = await t.query('purchases',
          columns: ['net_weight', 'remaining'], where: 'id=? AND is_mix=1', whereArgs: [mixPurchaseId]);
      if (cur.isEmpty) {
        ok = false;
        return;
      }
      final diff = (cur.first['net_weight'] as num).toDouble() - (cur.first['remaining'] as num).toDouble();
      if (diff.abs() > 1e-6) {
        ok = false;
        return;
      }
      final sources = await t.query('mix_sources', where: 'mix_purchase_id=?', whereArgs: [mixPurchaseId]);
      for (final s in sources) {
        final sp = (s['source_purchase_id'] as num).toInt();
        await _addRemaining(t, sp, (s['weight'] as num).toDouble());
        await _addSacks(t, sp, ((s['small_sacks'] as num?) ?? 0).toDouble(),
            ((s['large_sacks'] as num?) ?? 0).toDouble());
      }
      await t.delete('mix_sources', where: 'mix_purchase_id=?', whereArgs: [mixPurchaseId]);
      await t.delete('purchases', where: 'id=?', whereArgs: [mixPurchaseId]);
      if (mixPurchaseId < 0) {
        await _purgeOps(t, 'pur', mixPurchaseId);
      } else {
        await _enqueue(t, 'mixes.delete', {'id': mixPurchaseId}, refKind: 'pur', refId: mixPurchaseId);
      }
    });
    if (ok) version.value++;
    return ok;
  }

  Future<bool> updateMix({
    required int mixPurchaseId,
    required int categoryId,
    required String typeName,
    String? baseType,
    required List<Map<String, dynamic>> sources,
    required double netWeight,
    required double smallSackCount,
    required double largeSackCount,
    double? ounce,
    double? gram,
    double? waste,
    String? note,
    String? warehouseUid,
    String? ounceUid,
    bool uidsGiven = false,
  }) async {
    if (categoryId == 0) throw Exception('دسته را انتخاب کنید');
    if (netWeight <= 0 || netWeight > 1e9) throw Exception('وزن نهایی مخلوط (طبق ترازو) را وارد کنید');
    if (smallSackCount < 0 || largeSackCount < 0) throw Exception('تعداد گونی نامعتبر است');
    if ((ounce != null && (ounce < 0 || ounce > 1e9)) || (gram != null && (gram < 0 || gram > 1e9))) {
      throw Exception('مقدار انس یا گرم نامعتبر است');
    }
    final srcs = _normMixSources(sources);
    final wasteV = _checkWaste(srcs, _r(netWeight, 3), waste);
    final d = await db;
    var updated = false;
    await d.transaction((t) async {
      final old = await t.query('purchases', where: 'id=? AND is_mix=1', whereArgs: [mixPurchaseId]);
      if (old.isEmpty) return;
      final sold = (old.first['net_weight'] as num).toDouble() - (old.first['remaining'] as num).toDouble();
      if (sold > 0.0005) throw Exception('چون بخشی از مخلوط فروخته شده، ویرایش آن ممکن نیست');
      // اول وزن مبدأهای قبلی به موجودی برمی‌گردد، بعد مبدأهای تازه بررسی می‌شوند
      final oldSources = await t.query('mix_sources', where: 'mix_purchase_id=?', whereArgs: [mixPurchaseId]);
      for (final s in oldSources) {
        final sp = (s['source_purchase_id'] as num).toInt();
        await _addRemaining(t, sp, (s['weight'] as num).toDouble());
        await _addSacks(t, sp, ((s['small_sacks'] as num?) ?? 0).toDouble(),
            ((s['large_sacks'] as num?) ?? 0).toDouble());
      }
      final (avgPrice0, avgUsd0) = await _checkMixSources(t, srcs);
      // فی = هزینهٔ کل ÷ وزن خالص: هزینهٔ ضایعات هم در فی لحاظ می‌شود (بدون ضایعات = همان میانگین وزنی)
      final feeFactor = wasteV == null ? 1.0 : _takenOf(srcs) / _r(netWeight, 3);
      final avgPrice = avgPrice0 * feeFactor;
      final avgUsd = avgUsd0 == null ? null : avgUsd0 * feeFactor;
      final mixUsd = avgUsd == null ? null : _r(avgUsd, 4);
      final mixRate = (mixUsd != null && mixUsd > 0) ? _r(avgPrice / mixUsd, 2) : null;
      final net = _r(netWeight, 3);
      final name = _s(typeName, 100) ?? 'مخلوط';
      final baseTypeV = _s(baseType, 100);
      final nt = _s(note, 500);
      await t.update(
          'purchases',
          {
            'category_id': categoryId,
            'type_name': name,
        'base_type': baseTypeV,
            'price': _r(avgPrice, 2),
            'usd_rate': mixRate,
            'price_usd': mixUsd,
            'total_weight': net,
            'small_sack_count': _r(smallSackCount, 2),
            'large_sack_count': _r(largeSackCount, 2),
            'small_sacks_remaining': _r(smallSackCount, 2),
            'large_sacks_remaining': _r(largeSackCount, 2),
            'net_weight': net,
            'remaining': net,
            'ounce': _rn(ounce, 3),
            'gram': _rn(gram, 2),
            'waste': wasteV,
            'note': nt,
            if (uidsGiven) 'warehouse_uid': _uidOrNull(warehouseUid),
            if (uidsGiven) 'ounce_uid': _uidOrNull(ounceUid),
          },
          where: 'id=?',
          whereArgs: [mixPurchaseId]);
      await t.delete('mix_sources', where: 'mix_purchase_id=?', whereArgs: [mixPurchaseId]);
      await _applyMixSources(t, mixPurchaseId, srcs);
      await _enqueue(
          t,
          'mixes.update',
          {
            'id': mixPurchaseId,
            'category_id': categoryId,
            'type_name': name,
        'base_type': baseTypeV,
            'sources': _mixSourcesPayload(srcs),
            'net_weight': net,
            'small_sack_count': _r(smallSackCount, 2),
            'large_sack_count': _r(largeSackCount, 2),
            'ounce': _rn(ounce, 3),
            'gram': _rn(gram, 2),
            if (wasteV != null) 'waste': wasteV,
            'note': nt,
            if (uidsGiven && _uidOrNull(warehouseUid) != null) 'warehouse_uid': _uidOrNull(warehouseUid),
            if (uidsGiven) 'ounce_uid': _uidOrNull(ounceUid),
          },
          refKind: 'pur',
          refId: mixPurchaseId);
      updated = true;
    });
    if (updated) version.value++;
    return updated;
  }

  // ======================= پرداخت (خرید) و دریافت (فروش) =======================
  /// جدول تراکنش => (ستون والد، آیا مربوط به دریافت است)
  static const Map<String, (String, bool)> _txMeta = {
    'lump_tx': ('payment_id', false),
    'credit_inst': ('payment_id', false),
    'cheque_inst': ('payment_id', false),
    'receipt_lump_tx': ('receipt_id', true),
    'receipt_credit_inst': ('receipt_id', true),
    'receipt_cheque_inst': ('receipt_id', true),
  };

  Map<String, dynamic> _txRow(Map<String, dynamic> row) {
    final out = <String, dynamic>{};
    row.forEach((k, v) => out[k] = v);
    if (out.containsKey('amount')) {
      final a = _n(out['amount']);
      if (a < 0 || a > 1e13) throw Exception('مبلغ نامعتبر است');
      out['amount'] = _r(a, 2);
    }
    for (final k in const ['date', 'due_date']) {
      if (out.containsKey(k) && out[k] != null) out[k] = _dateOnly(out[k]);
    }
    for (final k in const ['from_account', 'payer_name', 'to_account', 'seller_name', 'receiver_name']) {
      if (out.containsKey(k)) out[k] = _s(out[k], 150);
    }
    if (out.containsKey('cheque_no')) out['cheque_no'] = _s(out['cheque_no'], 60);
    if (out.containsKey('bank_name')) out['bank_name'] = _s(out['bank_name'], 100);
    if (out.containsKey('sayad_id')) out['sayad_id'] = _s(out['sayad_id'], 16); // S35.T35.7c
    if (out.containsKey('paid')) out['paid'] = (out['paid'] == true || out['paid'] == 1) ? 1 : 0;
    return out;
  }

  Map<String, dynamic> _txPayload(Map<String, Object?> r) {
    final m = <String, dynamic>{};
    r.forEach((k, v) {
      if (k != 'id' && k != 'payment_id' && k != 'receipt_id') m[k] = v;
    });
    return m;
  }

  /// وضعیت کامل پرداخت یک خرید را (مثل وب) در صف می‌گذارد: payments.save
  Future<void> _queuePayment(DatabaseExecutor t, int purchaseId) async {
    final pay = await t.query('payments', where: 'purchase_id=?', whereArgs: [purchaseId]);
    final payment = <String, dynamic>{};
    if (pay.isNotEmpty) {
      final pid = pay.first['id'] as int;
      final type = pay.first['pay_type'] as String;
      final staged = pay.first['staged_type'] as String?;
      payment['pay_type'] = type;
      payment['staged_type'] = staged;
      if (type == 'mixed') {
        // S35.T35.7h: three line kinds of one document (server payments.save pay_type 'mixed')
        payment['lump_lines'] = (await t.query('lump_tx', where: 'payment_id=?', whereArgs: [pid], orderBy: 'id')).map(_txPayload).toList();
        payment['credit_lines'] = (await t.query('credit_inst', where: 'payment_id=?', whereArgs: [pid], orderBy: 'id')).map(_txPayload).toList();
        payment['cheque_lines'] = (await t.query('cheque_inst', where: 'payment_id=?', whereArgs: [pid], orderBy: 'id')).map(_txPayload).toList();
      } else if (type == 'lump') {
        payment['lump'] = (await t.query('lump_tx', where: 'payment_id=?', whereArgs: [pid], orderBy: 'id'))
            .map(_txPayload)
            .toList();
      } else if (staged == 'credit') {
        payment['installments'] =
            (await t.query('credit_inst', where: 'payment_id=?', whereArgs: [pid], orderBy: 'id'))
                .map(_txPayload)
                .toList();
      } else if (staged == 'cheque') {
        payment['installments'] =
            (await t.query('cheque_inst', where: 'payment_id=?', whereArgs: [pid], orderBy: 'id'))
                .map(_txPayload)
                .toList();
      }
    }
    await _upsertOp(t, 'payments.save', {'purchase_id': purchaseId, 'payment': payment},
        refKind: 'pur', refId: purchaseId);
  }

  Future<void> _queueReceipt(DatabaseExecutor t, int saleId) async {
    final rec = await t.query('receipts', where: 'sale_id=?', whereArgs: [saleId]);
    final receipt = <String, dynamic>{};
    if (rec.isNotEmpty) {
      final rid = rec.first['id'] as int;
      final type = rec.first['recv_type'] as String;
      final staged = rec.first['staged_type'] as String?;
      receipt['recv_type'] = type;
      receipt['staged_type'] = staged;
      if (type == 'lump') {
        receipt['lump'] =
            (await t.query('receipt_lump_tx', where: 'receipt_id=?', whereArgs: [rid], orderBy: 'id'))
                .map(_txPayload)
                .toList();
      } else if (staged == 'credit') {
        receipt['installments'] =
            (await t.query('receipt_credit_inst', where: 'receipt_id=?', whereArgs: [rid], orderBy: 'id'))
                .map(_txPayload)
                .toList();
      } else if (staged == 'cheque') {
        receipt['installments'] =
            (await t.query('receipt_cheque_inst', where: 'receipt_id=?', whereArgs: [rid], orderBy: 'id'))
                .map(_txPayload)
                .toList();
      }
    }
    await _upsertOp(t, 'receipts.save', {'sale_id': saleId, 'receipt': receipt}, refKind: 'sale', refId: saleId);
  }

  /// از روی «شناسهٔ پرداخت/دریافت» به خرید/فروش می‌رسد و وضعیتش را در صف می‌گذارد
  Future<void> _queueByParent(DatabaseExecutor t, bool isReceipt, int parentId) async {
    if (isReceipt) {
      final r = await t.query('receipts', columns: ['sale_id'], where: 'id=?', whereArgs: [parentId]);
      if (r.isNotEmpty) await _queueReceipt(t, (r.first['sale_id'] as num).toInt());
    } else {
      final r = await t.query('payments', columns: ['purchase_id'], where: 'id=?', whereArgs: [parentId]);
      if (r.isNotEmpty) await _queuePayment(t, (r.first['purchase_id'] as num).toInt());
    }
  }

  /// جمع مبالغ «پرداخت‌شده» یک خرید (isSale=false) یا «دریافت‌شده» یک فروش (isSale=true) برای فاکتور.
  /// هر پرداخت/دریافت فقط در یکی از سه جدول (یک‌جا، اقساط اعتباری، اقساط چکی) رکورد دارد و
  /// فقط ردیف‌هایی که paid=1 هستند جمع زده می‌شوند. اگر پرداختی ثبت نشده باشد صفر برمی‌گردد.
  Future<double> paidAmount({required bool isSale, required int id}) async {
    final d = await db;
    final head = await d.query(isSale ? 'receipts' : 'payments',
        where: isSale ? 'sale_id=?' : 'purchase_id=?', whereArgs: [id], limit: 1);
    if (head.isEmpty) return 0;
    final hid = head.first['id'];
    final type = (head.first[isSale ? 'recv_type' : 'pay_type'] as String?) ?? 'lump';
    final staged = head.first['staged_type'] as String?;
    final fk = isSale ? 'receipt_id' : 'payment_id';
    final tbl = isSale
        ? (type == 'lump' ? 'receipt_lump_tx' : (staged == 'credit' ? 'receipt_credit_inst' : 'receipt_cheque_inst'))
        : (type == 'lump' ? 'lump_tx' : (staged == 'credit' ? 'credit_inst' : 'cheque_inst'));
    final r = await d.rawQuery('SELECT COALESCE(SUM(amount),0) AS s FROM $tbl WHERE $fk=? AND paid=1', [hid]);
    return (r.first['s'] as num).toDouble();
  }

  Future<Map<String, dynamic>?> paymentOf(int purchaseId) async {
    final rows = await (await db).query('payments', where: 'purchase_id=?', whereArgs: [purchaseId]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<int> setPaymentType(int purchaseId, String payType, String? stagedType) async {
    if (!const ['lump', 'staged', 'mixed'].contains(payType) || !const [null, 'credit', 'cheque'].contains(stagedType)) { // S35.T35.7h: mixed = cash+credit+cheque lines in one payment
      throw Exception('نوع پرداخت نامعتبر است');
    }
    late int payId;
    await _write((d) => d.transaction((t) async {
      final rows = await t.query('payments', where: 'purchase_id=?', whereArgs: [purchaseId]);
      if (rows.isEmpty) {
        payId = await t.insert('payments', {'purchase_id': purchaseId, 'pay_type': payType, 'staged_type': stagedType});
      } else {
        payId = rows.first['id'] as int;
        if (rows.first['pay_type'] != payType || rows.first['staged_type'] != stagedType) {
          // تغییر نوع پرداخت: همهٔ اطلاعات پرداخت قبلی حذف می‌شود
          for (final tb in const ['lump_tx', 'credit_inst', 'cheque_inst']) {
            await t.delete(tb, where: 'payment_id=?', whereArgs: [payId]);
          }
        }
        await t.update('payments', {'pay_type': payType, 'staged_type': stagedType},
            where: 'id=?', whereArgs: [payId]);
      }
      await _queuePayment(t, purchaseId);
      await _confirm(t, 'SELECT 1 FROM payments WHERE id = ? AND purchase_id = ?', [payId, purchaseId],
          'ثبت نوع پرداخت تأیید نشد؛ این خرید دیگر وجود ندارد.');
    }));
    version.value++;
    return payId;
  }

  Future<int?> _addTx(String table, int parentId, Map<String, dynamic> row, int max) async {
    final meta = _txMeta[table]!;
    final parentTable = meta.$2 ? 'receipts' : 'payments';
    int? id;
    await _write((d) => d.transaction((t) async {
          // والد (پرداخت/دریافت) باید واقعاً وجود داشته باشد؛ وگرنه ردیف یتیم و نادیدنی ساخته می‌شد
          await _confirm(t, 'SELECT 1 FROM $parentTable WHERE id = ?', [parentId],
              'این ${meta.$2 ? 'دریافت' : 'پرداخت'} دیگر وجود ندارد؛ صفحه را ببندید و دوباره باز کنید.');
          final count =
              Sqflite.firstIntValue(await t.rawQuery('SELECT COUNT(*) FROM $table WHERE ${meta.$1}=?', [parentId])) ?? 0;
          if (count >= max) throw Exception('حداکثر تعداد مجاز برای این بخش ($max) ثبت شده است');
          final r = _txRow(row);
          r[meta.$1] = parentId;
          if (table == 'lump_tx' || table == 'receipt_lump_tx') r.putIfAbsent('paid', () => 1);
          id = await t.insert(table, r);
          await _queueByParent(t, meta.$2, parentId);
          // تأیید قطعی داخل همان تراکنش: ردیف خوانده می‌شود و به والدش وصل است
          await _confirm(t, 'SELECT 1 FROM $table x JOIN $parentTable pr ON pr.id = x.${meta.$1} WHERE x.id = ?', [id]);
        }));
    version.value++;
    return id;
  }

  Future<void> _updateTx(String table, int id, Map<String, dynamic> row) async {
    final meta = _txMeta[table]!;
    await _write((d) => d.transaction((t) async {
          final cur = await t.query(table, columns: [meta.$1], where: 'id=?', whereArgs: [id]);
          if (cur.isEmpty) {
            throw SaveNotConfirmed('این ردیف دیگر وجود ندارد (اطلاعات در این بین به‌روز شده). صفحه را ببندید و دوباره باز کنید.');
          }
          final n = await t.update(table, _txRow(row), where: 'id=?', whereArgs: [id]);
          if (n < 1) throw SaveNotConfirmed();
          await _queueByParent(t, meta.$2, (cur.first[meta.$1] as num).toInt());
        }));
    version.value++;
  }

  Future<void> _deleteTx(String table, int id) async {
    final meta = _txMeta[table]!;
    await _write((d) => d.transaction((t) async {
          final cur = await t.query(table, columns: [meta.$1], where: 'id=?', whereArgs: [id]);
          if (cur.isEmpty) return; // قبلاً حذف شده؛ همان نتیجهٔ دلخواه است
          await t.delete(table, where: 'id=?', whereArgs: [id]);
          await _queueByParent(t, meta.$2, (cur.first[meta.$1] as num).toInt());
          await _confirm(t, 'SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM $table WHERE id = ?)', [id]);
        }));
    version.value++;
  }

  Future<List<Map<String, dynamic>>> lumpTxList(int paymentId) async =>
      (await db).query('lump_tx', where: 'payment_id=?', whereArgs: [paymentId], orderBy: 'id');
  Future<int?> addLumpTx(int paymentId, Map<String, dynamic> row) => _addTx('lump_tx', paymentId, row, kMaxLumpTx);
  Future<void> updateLumpTx(int id, Map<String, dynamic> row) => _updateTx('lump_tx', id, row);
  Future<void> deleteLumpTx(int id) => _deleteTx('lump_tx', id);

  Future<List<Map<String, dynamic>>> creditInstList(int paymentId) async =>
      (await db).query('credit_inst', where: 'payment_id=?', whereArgs: [paymentId], orderBy: 'due_date');
  Future<int?> addCreditInst(int paymentId, Map<String, dynamic> row) =>
      _addTx('credit_inst', paymentId, row, kMaxStagedTx);
  Future<void> updateCreditInst(int id, Map<String, dynamic> row) => _updateTx('credit_inst', id, row);
  Future<void> deleteCreditInst(int id) => _deleteTx('credit_inst', id);

  Future<List<Map<String, dynamic>>> chequeInstList(int paymentId) async =>
      (await db).query('cheque_inst', where: 'payment_id=?', whereArgs: [paymentId], orderBy: 'due_date');
  Future<int?> addChequeInst(int paymentId, Map<String, dynamic> row) =>
      _addTx('cheque_inst', paymentId, row, kMaxStagedTx);
  Future<void> updateChequeInst(int id, Map<String, dynamic> row) => _updateTx('cheque_inst', id, row);
  Future<void> deleteChequeInst(int id) => _deleteTx('cheque_inst', id);

  /// همه اقساط/چک‌های پرداخت‌نشده (برای زمان‌بندی نوتیفیکیشن هنگام باز شدن برنامه)
  Future<List<Map<String, dynamic>>> unpaidCreditInst() async =>
      (await db).query('credit_inst', where: 'paid=0');

  Future<List<Map<String, dynamic>>> unpaidChequeInst() async =>
      (await db).query('cheque_inst', where: 'paid=0');

  // ---------- وصول مطالبات (دریافت وجه فروش) ----------
  Future<Map<String, dynamic>?> receiptOf(int saleId) async {
    final rows = await (await db).query('receipts', where: 'sale_id=?', whereArgs: [saleId]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<int> setReceiptType(int saleId, String recvType, String? stagedType) async {
    if (!const ['lump', 'staged'].contains(recvType) || !const [null, 'credit', 'cheque'].contains(stagedType)) {
      throw Exception('نوع دریافت نامعتبر است');
    }
    late int rid;
    await _write((d) => d.transaction((t) async {
      final rows = await t.query('receipts', where: 'sale_id=?', whereArgs: [saleId]);
      if (rows.isEmpty) {
        rid = await t.insert('receipts', {'sale_id': saleId, 'recv_type': recvType, 'staged_type': stagedType});
      } else {
        rid = rows.first['id'] as int;
        if (rows.first['recv_type'] != recvType || rows.first['staged_type'] != stagedType) {
          // تغییر نوع دریافت: همهٔ اطلاعات دریافت قبلی حذف می‌شود
          for (final tb in const ['receipt_lump_tx', 'receipt_credit_inst', 'receipt_cheque_inst']) {
            await t.delete(tb, where: 'receipt_id=?', whereArgs: [rid]);
          }
        }
        await t.update('receipts', {'recv_type': recvType, 'staged_type': stagedType},
            where: 'id=?', whereArgs: [rid]);
      }
      await _queueReceipt(t, saleId);
      await _confirm(t, 'SELECT 1 FROM receipts WHERE id = ? AND sale_id = ?', [rid, saleId],
          'ثبت نوع دریافت تأیید نشد؛ این فروش دیگر وجود ندارد.');
    }));
    version.value++;
    return rid;
  }

  Future<List<Map<String, dynamic>>> receiptLumpTxList(int receiptId) async => (await db)
      .query('receipt_lump_tx', where: 'receipt_id=?', whereArgs: [receiptId], orderBy: 'id');
  Future<int?> addReceiptLumpTx(int receiptId, Map<String, dynamic> row) =>
      _addTx('receipt_lump_tx', receiptId, row, kMaxLumpTx);
  Future<void> updateReceiptLumpTx(int id, Map<String, dynamic> row) => _updateTx('receipt_lump_tx', id, row);
  Future<void> deleteReceiptLumpTx(int id) => _deleteTx('receipt_lump_tx', id);

  Future<List<Map<String, dynamic>>> receiptCreditInstList(int receiptId) async => (await db).query(
      'receipt_credit_inst', where: 'receipt_id=?', whereArgs: [receiptId], orderBy: 'due_date');
  Future<int?> addReceiptCreditInst(int receiptId, Map<String, dynamic> row) =>
      _addTx('receipt_credit_inst', receiptId, row, kMaxStagedTx);
  Future<void> updateReceiptCreditInst(int id, Map<String, dynamic> row) =>
      _updateTx('receipt_credit_inst', id, row);
  Future<void> deleteReceiptCreditInst(int id) => _deleteTx('receipt_credit_inst', id);

  Future<List<Map<String, dynamic>>> receiptChequeInstList(int receiptId) async => (await db).query(
      'receipt_cheque_inst', where: 'receipt_id=?', whereArgs: [receiptId], orderBy: 'due_date');
  Future<int?> addReceiptChequeInst(int receiptId, Map<String, dynamic> row) =>
      _addTx('receipt_cheque_inst', receiptId, row, kMaxStagedTx);
  Future<void> updateReceiptChequeInst(int id, Map<String, dynamic> row) =>
      _updateTx('receipt_cheque_inst', id, row);
  Future<void> deleteReceiptChequeInst(int id) => _deleteTx('receipt_cheque_inst', id);

  Future<List<Map<String, dynamic>>> unpaidReceiptCreditInst() async =>
      (await db).query('receipt_credit_inst', where: 'paid=0');

  Future<List<Map<String, dynamic>>> unpaidReceiptChequeInst() async =>
      (await db).query('receipt_cheque_inst', where: 'paid=0');

  // ======================= فروش =======================
  Future<List<Map<String, dynamic>>> sales() async {
    final d = await db;
    final rows = await d.query('sales', orderBy: 'ord DESC, id DESC');
    // یک کوئری برای همهٔ اقلام (قبلاً برای هر فروش یک کوئری جدا بود)
    final all = await d.rawQuery('''
        SELECT si.sale_id AS _sid, si.weight, si.item_price, si.small_sacks, si.large_sacks, si.purchase_id AS purchase_id,
               p.code AS code, p.price AS cost_price, p.price_usd AS cost_price_usd, p.type_name AS type_name, p.base_type AS base_type, p.labor_cost AS p_labor_cost, p.transport_cost AS p_transport_cost, p.net_weight AS p_net_weight, c.name AS category_name
        FROM sale_items si
        JOIN purchases p ON p.id = si.purchase_id
        JOIN categories c ON c.id = p.category_id
        ORDER BY si.id''');
    final bySale = <int, List<Map<String, dynamic>>>{};
    for (final r in all) {
      final m = Map<String, dynamic>.of(r);
      final sid = (m.remove('_sid') as num).toInt();
      (bySale[sid] ??= <Map<String, dynamic>>[]).add(m);
    }
    return [
      for (final s in rows) {...s, 'items': bySale[(s['id'] as num).toInt()] ?? <Map<String, dynamic>>[]},
    ];
  }

  /// اقلام یک فروش (فروش‌های جدید همیشه یک قلم دارند؛ فروش‌های قدیمیِ چندقلمی ممکن است بیشتر داشته باشند)
  Future<List<Map<String, dynamic>>> saleItemsOf(int saleId) async =>
      (await db).query('sale_items', where: 'sale_id=?', whereArgs: [saleId], orderBy: 'id');

  /// کد/کدهای پستهٔ یک فروش (برای رسید و گزارش)
  Future<String> saleCodes(int saleId) async {
    final rows = await (await db).rawQuery(
        'SELECT p.code AS code FROM sale_items si JOIN purchases p ON p.id = si.purchase_id WHERE si.sale_id = ?',
        [saleId]);
    final codes = rows.map((r) => '${r['code'] ?? ''}').where((c) => c.isNotEmpty).toList();
    return codes.isEmpty ? '-' : codes.join('، ');
  }

  Future<Map<String, dynamic>?> saleById(int id) async {
    final rows = await (await db).query('sales', where: 'id=?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first;
  }

  /// اقلام فروش: وزن باید مثبت باشد و ردیف‌های تکراری یک خرید ادغام می‌شوند
  /// (وزن و گونی جمع، فی میانگین وزنی) — همان normalizeSaleItems در app.php
  List<Map<String, dynamic>> _normSaleItems(List<Map<String, dynamic>> items, double fallback) {
    if (items.isEmpty) throw Exception('یک قلم از انبار انتخاب کنید');
    if (items.length != 1) {
      throw Exception('هر فروش فقط از یک قلم انبار ثبت می‌شود؛ برای چند جنس، چند فروش جدا ثبت کنید');
    }
    final m = <int, Map<String, dynamic>>{};
    for (final it in items) {
      final pid = (it['purchase_id'] as num).toInt();
      final w = _n(it['weight']);
      if (w <= 0 || w > 1e9) throw Exception('وزن هر قلم فروش باید بزرگ‌تر از صفر باشد');
      final hasPrice = it['item_price'] != null && it['item_price'] != '';
      final price = hasPrice ? _n(it['item_price']) : fallback;
      if (price <= 0 || price > 1e13) throw Exception('فی فروش نامعتبر است');
      final ss = _nn(it['small_sacks']);
      final ls = _nn(it['large_sacks']);
      if ((ss != null && ss < 0) || (ls != null && ls < 0)) throw Exception('تعداد گونی نامعتبر است');
      final r = m.putIfAbsent(
          pid,
          () => <String, dynamic>{
                'purchase_id': pid,
                'weight': 0.0,
                'val': 0.0,
                'hasPrice': false,
                'small_sacks': null,
                'large_sacks': null,
              });
      r['weight'] = (r['weight'] as double) + w;
      r['val'] = (r['val'] as double) + w * price;
      if (hasPrice) r['hasPrice'] = true;
      if (ss != null) r['small_sacks'] = ((r['small_sacks'] as num?) ?? 0) + ss;
      if (ls != null) r['large_sacks'] = ((r['large_sacks'] as num?) ?? 0) + ls;
    }
    return [
      for (final r in m.values)
        {
          'purchase_id': r['purchase_id'],
          'weight': _r(r['weight'] as double, 3),
          'item_price': (r['hasPrice'] as bool) ? _r((r['val'] as double) / (r['weight'] as double), 2) : null,
          'small_sacks': _rn(_nn(r['small_sacks']), 2),
          'large_sacks': _rn(_nn(r['large_sacks']), 2),
        }
    ];
  }

  _SaleV _saleValues(Map<String, dynamic> sale, List<Map<String, dynamic>> items) {
    final fallback = _n(sale['price']);
    if (fallback < 0 || fallback > 1e13) throw Exception('فی فروش نامعتبر است');
    final norm = _normSaleItems(items, fallback);
    final total = _n(sale['total_weight']);
    final small = _n(sale['small_sack_count']);
    final large = _n(sale['large_sack_count']);
    if (total <= 0 || total > 1e9) throw Exception('وزن باید بزرگ‌تر از صفر باشد');
    if (small < 0 || large < 0 || small > 1e7 || large > 1e7) throw Exception('تعداد گونی نامعتبر است');
    // S35.T35.2b: weighing block: net = gross - tare - quality deduction
    final double? grossKg = _nn(sale['gross_kg']);
    double? tareKg;
    double? deductKg;
    double net = _r(total - (small * 0.1 + large * 0.2), 3);
    if (grossKg != null) {
      if (grossKg <= 0 || grossKg > 1e9) throw Exception('وزن کل باید بزرگ‌تر از صفر باشد');
      tareKg = _nn(sale['tare_kg']) ?? (small * 0.1 + large * 0.2);
      deductKg = _nn(sale['quality_deduct_kg']) ?? 0.0;
      if (tareKg < 0 || deductKg < 0) throw Exception('تارا و کسر کیفیت نمی‌توانند منفی باشند');
      net = _r(grossKg - tareKg - deductKg, 3);
    }
    if (net <= 0) throw Exception('وزن خالص باید بزرگ‌تر از صفر باشد');
    final Map<String, dynamic> weighCols = grossKg == null
        ? <String, dynamic>{'gross_kg': null, 'tare_kg': null, 'quality_deduct_kg': null, 'weigh_ticket_no': null, 'vehicle_plate': null, 'driver_name': null}
        : <String, dynamic>{
            'gross_kg': _r(grossKg, 3),
            'tare_kg': _r(tareKg!, 3),
            'quality_deduct_kg': _r(deductKg!, 3),
            'weigh_ticket_no': _s(sale['weigh_ticket_no'], 40),
            'vehicle_plate': _s(sale['vehicle_plate'], 20),
            'driver_name': _s(sale['driver_name'], 80),
          };
    var sumW = 0.0;
    var sumVal = 0.0;
    for (final it in norm) {
      final w = it['weight'] as double;
      sumW += w;
      sumVal += w * (_nn(it['item_price']) ?? fallback);
    }
    final avg = sumW > 0 ? sumVal / sumW : fallback;
    final date = _dateOnly(sale['date']);
    final buyer = _s(sale['buyer'], 150);
    final note = _s(sale['note'], 500);
    final fx = _fxDoc(sale, 'price_ccy');
    final Map<String, dynamic> fxLocal = Map<String, dynamic>.from(fx.local);
    if (fxLocal.containsKey('price_ccy')) {
      fxLocal['total_ccy'] = _r((fxLocal.remove('price_ccy') as double) * net, 4);
    }
    // نرخ دستی دلار حذف شده؛ برای دلار، usd_rate قدیمی از نرخ سند (تومان = ریال/۱۰) پر می‌شود تا گزارش‌های قبلی کار کنند
    final double? usdRate = fx.local['ccy'] == 'USD'
        ? _r((fx.local['fx_rate'] as double) / kFxRialPerStoredUnit, 2)
        : (fx.local.isEmpty ? _usdRate(sale['usd_rate']) : null);
    final laborCost = _cost(sale['labor_cost']);
    final Map<String, dynamic> finLocal = _finCols(sale); // S35.T35.6b
    final transportCost = _cost(sale['transport_cost']);
    final row = <String, dynamic>{
      'usd_rate': usdRate,
      ...fxLocal,
      'date': date,
      'price': _r(avg, 2),
      'total_weight': _r(total, 3),
      'small_sack_count': _r(small, 2),
      'large_sack_count': _r(large, 2),
      'net_weight': net,
      ...weighCols,
      'buyer': buyer,
      'note': note,
      'labor_cost': laborCost,
      'transport_cost': transportCost,
      if (sale.containsKey('tax_status')) 'tax_status': _taxStatus(sale['tax_status']),
      if (sale.containsKey('tax_status')) 'tax_rate_milli': _taxStatus(sale['tax_status']) == null ? null : _taxRate(sale['tax_rate_milli']),
      ...finLocal, // S35.T35.6b
    };
    final payload = <String, dynamic>{
      if (fx.payload.isEmpty) 'usd_rate': usdRate,
      ...fx.payload,
      'date': date,
      'price': fallback,
      'total_weight': _r(total, 3),
      'small_sack_count': _r(small, 2),
      'large_sack_count': _r(large, 2),
      if (grossKg != null) ...<String, dynamic>{...weighCols, 'net_weight': net}, // S35.T35.2b (server verifies the net)
      'buyer': buyer,
      'note': note,
      'labor_cost': laborCost,
      'transport_cost': transportCost,
      if (_taxPayload(sale['tax_status'], sale['tax_rate_milli']) != null) 'tax': _taxPayload(sale['tax_status'], sale['tax_rate_milli']),
      if (_uidOrNull(sale['warehouse_uid']) != null) 'warehouse_uid': _uidOrNull(sale['warehouse_uid']),
      if (finLocal.isNotEmpty) ...<String, dynamic>{ // S35.T35.6b
        'discount_amount': finLocal['discount_amount'],
        'weighbridge_cost': finLocal['weighbridge_cost'],
        'side_cost_payer': finLocal['side_cost_payer'],
        'taxable': finLocal['taxable'] == null ? null : finLocal['taxable'] == 1,
      },
      'items': norm,
    };
    return _SaleV(row, payload, norm);
  }

  /// وزن و (در صورت واردشدن) گونی هر قلم از موجودی همان خرید کم می‌شود.
  /// اعتبارسنجی مستقل از فرم است: وزن ≤ remaining، و گونی کوچک و بزرگ هرکدام جداگانه ≤ گونی باقی‌مانده.
  /// اگر گونی وارد نشده باشد (null یا ۰) ستون‌های گونیِ باقی‌مانده دست‌نخورده می‌مانند.
  Future<void> _applySaleItems(DatabaseExecutor t, int saleId, List<Map<String, dynamic>> items) async {
    for (final it in items) {
      final rows = await t.rawQuery('''
          SELECT p.remaining, p.small_sacks_remaining, p.large_sacks_remaining, p.type_name, c.name AS category_name
          FROM purchases p JOIN categories c ON c.id = p.category_id
          WHERE p.id = ?''', [it['purchase_id']]);
      if (rows.isEmpty) throw Exception('یکی از اقلام انبار یافت نشد');
      final label = '${rows.first['type_name']} (${rows.first['category_name']})';
      final rem = (rows.first['remaining'] as num).toDouble();
      final w = (it['weight'] as num).toDouble();
      if (w > rem + 1e-6) {
        throw Exception('موجودی «$label» کافی نیست؛ فقط ${_fmt(rem)} کیلو باقی مانده');
      }
      final ss = _nn(it['small_sacks']) ?? 0.0;
      final ls = _nn(it['large_sacks']) ?? 0.0;
      final smallLeft = (rows.first['small_sacks_remaining'] as num).toDouble();
      final largeLeft = (rows.first['large_sacks_remaining'] as num).toDouble();
      if (ss > smallLeft + 1e-6) {
        throw Exception('گونی کوچک درخواستی از گونی کوچک باقی‌مانده‌ی «$label» بیشتر است؛ فقط ${_fmt(smallLeft)} عدد مانده');
      }
      if (ls > largeLeft + 1e-6) {
        throw Exception('گونی بزرگ درخواستی از گونی بزرگ باقی‌مانده‌ی «$label» بیشتر است؛ فقط ${_fmt(largeLeft)} عدد مانده');
      }
      await t.insert('sale_items', {
        'sale_id': saleId,
        'purchase_id': it['purchase_id'],
        'weight': w,
        'item_price': it['item_price'],
        'small_sacks': it['small_sacks'],
        'large_sacks': it['large_sacks'],
      });
      await t.update('purchases', {'remaining': math.max(0.0, _r(rem - w, 3))},
          where: 'id=?', whereArgs: [it['purchase_id']]);
      await _addSacks(t, it['purchase_id'] as int, -ss, -ls);
    }
  }

  /// برگرداندن وزن و گونیِ اقلام یک فروش به انبار (برای ویرایش و حذف)
  Future<void> _restoreSaleItems(DatabaseExecutor t, int saleId) async {
    final oldItems = await t.query('sale_items', where: 'sale_id=?', whereArgs: [saleId]);
    for (final it in oldItems) {
      final pid = (it['purchase_id'] as num).toInt();
      await _addRemaining(t, pid, (it['weight'] as num).toDouble());
      await _addSacks(t, pid, ((it['small_sacks'] as num?) ?? 0).toDouble(),
          ((it['large_sacks'] as num?) ?? 0).toDouble());
    }
  }

  /// S04.T04.4c: تبدیل آفلاین پیش‌فاکتور به فروش (یک فروش برای هر قلم، مثل سرور) + عملیات اتصال.
  /// همه‌چیز در یک تراکنش؛ برمی‌گرداند شناسه‌های (موقت) فروش‌ها.
  Future<List<int>> convertProformaLocal(int pfId, String date) async {
    final ids = <int>[];
    await _write((d) => d.transaction((t) async {
          final pfRows = await t.query('proformas', where: 'id=?', whereArgs: [pfId], limit: 1);
          if (pfRows.isEmpty) throw Exception('پیش‌فاکتور یافت نشد');
          final pf = pfRows.first;
          final st = '${pf['status']}';
          if (st == 'converted') throw Exception('این پیش‌فاکتور قبلاً به فروش تبدیل شده است');
          if (st == 'cancelled') throw Exception('پیش‌فاکتور لغوشده قابل تبدیل نیست');
          final vu = '${pf['valid_until'] ?? ''}';
          if ((st == 'draft' || st == 'sent') && vu.isNotEmpty && vu.compareTo(_ymd(DateTime.now())) < 0) {
            throw Exception('مهلت اعتبار این پیش‌فاکتور گذشته است؛ ابتدا آن را ویرایش و تمدید کنید');
          }
          var items = await t.query('proforma_items', where: 'proforma_id=?', whereArgs: [pfId], orderBy: 'id');
          // ردیف‌های ساخته‌شدهٔ آفلاین شناسهٔ منفیِ نزولی دارند؛ ترتیب ثبت = id نزولی (مثل ترتیب id صعودی روی سرور)
          if (items.isNotEmpty && (items.first['id'] as num).toInt() < 0) items = items.reversed.toList();
          if (items.isEmpty) throw Exception('پیش‌فاکتور قلمی ندارد');
          final links = <Map<String, dynamic>>[];
          for (var pos = 0; pos < items.length; pos++) {
            final it = items[pos];
            if (it['lot_id'] == null) throw Exception('همهٔ اقلام باید به لات انبار وصل باشند تا تبدیل ممکن شود');
            final lot = await currentId('pur', (it['lot_id'] as num).toInt());
            final kg = (it['kg'] as num).toDouble();
            final net = kg * (it['unit_price'] as num).toDouble() - ((it['discount'] as num?) ?? 0).toDouble();
            final price = _r(net / kg, 2);
            if (price <= 0) throw Exception('مبلغ قلم پس از تخفیف باید مثبت باشد');
            final lr = await t.query('purchases', columns: ['remaining'], where: 'id=?', whereArgs: [lot], limit: 1);
            if (lr.isEmpty) throw Exception('خرید (لات) قلم در انبار یافت نشد');
            if (kg - (lr.first['remaining'] as num).toDouble() > 1e-6) throw Exception('وزن فروش از موجودی این قلم بیشتر است');
            final v = _saleValues({
              'date': date, 'price': price, 'total_weight': kg, 'small_sack_count': 0, 'large_sack_count': 0,
              'buyer': pf['party'], 'note': 'پیش‌فاکتور شمارهٔ ${pf['number']}',
            }, [
              {'purchase_id': lot, 'weight': kg, 'item_price': price}
            ]);
            final sid = await _tempId(t, 'sales');
            final ord = await _nextOrd(t, 'sales');
            await _applySaleItems(t, sid, v.items);
            await t.insert('sales', {...v.row, 'id': sid, 'created_at': _stamp(), 'ord': ord});
            await _enqueue(t, 'sales.create', v.payload, refKind: 'sale', refId: sid, mapKind: 'sale', localId: sid);
            await t.update('proforma_items', {'sale_id': sid}, where: 'id=?', whereArgs: [it['id']]);
            links.add({'pos': pos, 'sale_id': sid});
            ids.add(sid);
          }
          await t.update('proformas', {'status': 'converted', 'converted_at': _ymd(DateTime.now())}, where: 'id=?', whereArgs: [pfId]);
          await _enqueue(t, 'proformas.link_sales', {'id': pfId, 'links': links}, refKind: 'pf', refId: pfId);
        }));
    version.value++;
    return ids;
  }

  /// شناسهٔ (موقتِ) فروش ثبت‌شده را برمی‌گرداند (POS برای ثبت دریافت لازم دارد)؛ بقیهٔ فراخوان‌ها نادیده می‌گیرند.
  Future<int> insertSale(Map<String, dynamic> sale, List<Map<String, dynamic>> items) async {
    late int newSaleId;
    // شناسهٔ موقتِ خرید ممکن است بعد از دریافت از سرور عوض شده باشد؛ اصلاحش می‌کنیم
    final fixed = <Map<String, dynamic>>[];
    for (final it in items) {
      final m = Map<String, dynamic>.from(it);
      final pid = (m['purchase_id'] as num?)?.toInt();
      if (pid != null) m['purchase_id'] = await currentId('pur', pid);
      fixed.add(m);
    }
    await _write((d) => d.transaction((t) async {
          final v = _saleValues(sale, fixed);
          final sid = await _tempId(t, 'sales');
          newSaleId = sid;
          final ord = await _nextOrd(t, 'sales');
          await _applySaleItems(t, sid, v.items);
          await t.insert('sales', {...v.row, 'id': sid, 'created_at': _stamp(), 'ord': ord});
          final List<Map<String, dynamic>>? gl = _gradePayload(sale['grade_lines']); // S35.T35.3b
          if (gl != null) v.payload['grade_lines'] = gl;
          await _saveGradeLocal(t, 'sale', sid, gl);
          await _enqueue(t, 'sales.create', v.payload, refKind: 'sale', refId: sid, mapKind: 'sale', localId: sid);
          // تأیید قطعی داخل همان تراکنش
          await _confirm(t, 'SELECT 1 FROM sales WHERE id = ?', [sid]);
          await _confirm(t,
              'SELECT 1 FROM sale_items si JOIN purchases p ON p.id = si.purchase_id WHERE si.sale_id = ?', [sid],
              'فروش ثبت نشد؛ جنس انتخاب‌شده در انبار پیدا نشد.');
          await _confirm(t, "SELECT 1 FROM sync_ops WHERE ref_kind='sale' AND ref_id=?", [sid]);
        }));
    version.value++;
    return newSaleId;
  }

  /// ویرایش فروش: وزن و گونیِ قبلی به همان خرید برمی‌گردد، سپس مقادیر جدید (دوباره اعتبارسنجی‌شده) اعمال می‌شود
  Future<void> updateSale(int saleId, Map<String, dynamic> sale, List<Map<String, dynamic>> items) async {
    await _write((d) => d.transaction((t) async {
      final curRows = await t.query('sales', where: 'id=?', whereArgs: [saleId]);
      if (curRows.isEmpty) throw Exception('این فروش یافت نشد');
      if (await _hasReturns(t, 'sale_id', saleId)) throw Exception('این فروش برگشت ثبت‌شده دارد؛ ابتدا برگشت‌ها را حذف کنید');
      final merged = <String, dynamic>{};
      curRows.first.forEach((k, v) => merged[k] = v);
      sale.forEach((k, v) => merged[k] = v);
      final v = _saleValues(merged, items);
      await _restoreSaleItems(t, saleId);
      await t.delete('sale_items', where: 'sale_id=?', whereArgs: [saleId]);
      await _applySaleItems(t, saleId, v.items);
      await t.update('sales', v.row, where: 'id=?', whereArgs: [saleId]);
      final List<Map<String, dynamic>>? gl = _gradePayload(sale['grade_lines']); // S35.T35.3b
      if (gl != null) v.payload['grade_lines'] = gl;
      await _saveGradeLocal(t, 'sale', saleId, gl);
      await _enqueue(t, 'sales.update', {'id': saleId, ...v.payload}, refKind: 'sale', refId: saleId);
    }));
    version.value++;
  }

  /// حذف فروش و برگرداندن وزن و گونی به انبار
  Future<void> deleteSale(int id) async {
    await _write((d) => d.transaction((t) async {
      if (await _hasReturns(t, 'sale_id', id)) throw Exception('این فروش برگشت ثبت‌شده دارد؛ ابتدا برگشت‌ها را حذف کنید');
      await _restoreSaleItems(t, id);
      await t.delete('sale_items', where: 'sale_id=?', whereArgs: [id]);
      await t.delete('doc_grade_lines', where: 'doc_type=? AND doc_id=?', whereArgs: <Object?>['sale', id]); // S35.T35.3b
      await t.delete('sales', where: 'id=?', whereArgs: [id]);
      final r = await t.query('receipts', where: 'sale_id=?', whereArgs: [id]);
      if (r.isNotEmpty) {
        final rid = r.first['id'] as int;
        await t.delete('receipt_lump_tx', where: 'receipt_id=?', whereArgs: [rid]);
        await t.delete('receipt_credit_inst', where: 'receipt_id=?', whereArgs: [rid]);
        await t.delete('receipt_cheque_inst', where: 'receipt_id=?', whereArgs: [rid]);
        await t.delete('receipts', where: 'id=?', whereArgs: [rid]);
      }
      if (id < 0) {
        await _purgeOps(t, 'sale', id);
      } else {
        await _enqueue(t, 'sales.delete', {'id': id}, refKind: 'sale', refId: id);
      }
    }));
    version.value++;
  }

  // ======================= سررسید و حساب طرف‌ها =======================
  static const Set<String> _paidTables = {
    'lump_tx',
    'credit_inst',
    'cheque_inst',
    'receipt_lump_tx',
    'receipt_credit_inst',
    'receipt_cheque_inst',
  };

  /// وضعیت «پرداخت/دریافت شد» یک تراکنش (یکجا، قسط یا چک) را عوض می‌کند
  Future<void> setPaid(String table, int id, bool paid) async {
    if (table == 'loan_dues') {
      if (paid) await payLoanDue(id);
      return;
    }
    if (!_paidTables.contains(table)) throw ArgumentError('جدول نامعتبر');
    final meta = _txMeta[table]!;
    await _write((d) => d.transaction((t) async {
      final cur = await t.query(table, columns: [meta.$1], where: 'id=?', whereArgs: [id]);
      if (cur.isEmpty) throw SaveNotConfirmed('این مورد دیگر وجود ندارد؛ صفحه را ببندید و دوباره باز کنید.');
      await t.update(table, {'paid': paid ? 1 : 0}, where: 'id=?', whereArgs: [id]);
      await _queueByParent(t, meta.$2, (cur.first[meta.$1] as num).toInt());
    }));
    version.value++;
  }


  /// نام همه‌ی فروشنده‌ها و خریدارهای ثبت‌شده (برای پیشنهاد خودکار هنگام تایپ)
  Future<List<String>> partyNames() async {
    final rows = await (await db).rawQuery(
        "SELECT TRIM(seller) AS n FROM purchases WHERE seller IS NOT NULL AND TRIM(seller) <> '' "
        "UNION SELECT TRIM(buyer) FROM sales WHERE buyer IS NOT NULL AND TRIM(buyer) <> '' "
        "UNION SELECT TRIM(name) FROM parties WHERE TRIM(name) <> '' "
        "ORDER BY 1");
    return rows.map((r) => (r['n'] as String)).toList();
  }


  // ======================= طرف‌حساب‌ها و دفتر قرض/وام =======================
  // نکته: مبالغ قرض/وام هرگز در سود و زیان حساب نمی‌شوند (جدولشان از فروش/خرید جداست).
  // هر ردیف یک «uid» یکتا دارد تا ارسال تکراری به سرور (اینترنت ضعیف) دوبار ثبت نشود.

  static String _partyNorm(String? name) => (name ?? '')
      .replaceAll('ي', 'ی')
      .replaceAll('ك', 'ک')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  Future<List<Map<String, dynamic>>> partyRecords() async => (await db).query('parties', orderBy: 'name');

  Future<List<Map<String, dynamic>>> loanEntries() async =>
      (await db).query('loan_entries', orderBy: 'date DESC, id DESC');

  /// تعریف طرف‌حساب جدید (بدون نیاز به خرید یا فروش)
  Future<int> addParty(String name) async {
    final n = _partyNorm(name);
    if (n.isEmpty) throw Exception('نام طرف‌حساب را وارد کنید');
    if (n.length > 100) throw Exception('نام طرف‌حساب حداکثر ۱۰۰ حرف باشد');
    final existing = (await partyNames()).map(_partyNorm).toSet();
    if (existing.contains(n)) throw Exception('طرف‌حسابی با این نام از قبل وجود دارد');
    late int id;
    await _write((d) => d.transaction((t) async {
          id = await _tempId(t, 'parties');
          await t.insert('parties', {'id': id, 'name': n});
          await _enqueue(t, 'parties.create', {'name': n}, refKind: 'party', refId: id);
          await _confirm(t, 'SELECT 1 FROM parties WHERE id = ? AND name = ?', [id, n]);
          await _confirm(t, "SELECT 1 FROM sync_ops WHERE ref_kind='party' AND ref_id=?", [id]);
        }));
    version.value++;
    return id;
  }

  /// مانده قرضِ باز یک طرف‌حساب: [base] = 'given' (طلب ما) یا 'taken' (بدهی ما)
  Future<double> _loanOutstanding(DatabaseExecutor t, String party, String base) async {
    final rep = base == 'given' ? 'repay_in' : 'repay_out';
    final r = await t.rawQuery(
        "SELECT COALESCE(SUM(CASE WHEN kind=? THEN amount WHEN kind=? THEN -amount ELSE 0 END), 0) AS v "
        'FROM loan_entries WHERE party=?',
        [base, rep, party]);
    return (r.first['v'] as num).toDouble();
  }

  /// ثبت یک تراکنش دفتر قرض/وام:
  ///  given = قرض اعطایی (ما به او داده‌ایم)    taken = قرض دریافتی (از او گرفته‌ایم)
  ///  repay_in = بازپرداخت دریافتی (او پس داد)   repay_out = بازپرداخت پرداختی (ما پس دادیم)
  /// [dues]: برای اعطا/دریافت قرض، تا ۲۰ سررسید {due_date, amount, note}؛ مبلغ و تاریخ سررسید الزامی است
  /// و جمع مبلغ‌ها باید با مبلغ قرض برابر باشد. سررسیدها در صفحهٔ «سررسیدها» یادآوری می‌شوند.
  Future<int> addLoanEntry({
    required String party,
    required String kind,
    required double amount,
    required DateTime date,
    String? note,
    List<Map<String, dynamic>> dues = const [],
  }) async {
    final p = _partyNorm(party);
    if (p.isEmpty) throw Exception('طرف‌حساب مشخص نیست');
    if (!kLoanKinds.contains(kind)) throw Exception('نوع تراکنش نامعتبر است');
    if (amount <= 0 || amount > 1e13) throw Exception('مبلغ را درست وارد کنید');
    final isRepay = kind == 'repay_in' || kind == 'repay_out';
    if (isRepay && dues.isNotEmpty) throw Exception('برای بازپرداخت سررسید ثبت نمی‌شود');
    if (dues.length > 20) throw Exception('حداکثر ۲۰ سررسید می‌توانید ثبت کنید');
    final uid = _newIdem();
    final dt = _dateOnly(date.toIso8601String());
    final nt = _s(note, 500);
    final amt = _r(amount, 2);
    final cleanDues = <Map<String, dynamic>>[];
    var sum = 0.0;
    for (var i = 0; i < dues.length; i++) {
      final a = _r((dues[i]['amount'] as num?)?.toDouble() ?? 0, 2);
      if (a <= 0) throw Exception('مبلغ هر سررسید را وارد کنید');
      final dd = dues[i]['due_date'];
      if (dd == null) throw Exception('تاریخ هر سررسید را وارد کنید');
      cleanDues.add({'seq': i + 1, 'due_date': _dateOnly('$dd'), 'amount': a, 'note': _s(dues[i]['note'], 200)});
      sum += a;
    }
    if (cleanDues.isNotEmpty && (sum - amt).abs() > 0.5) {
      throw Exception('جمع مبلغ سررسیدها (${_fmt(sum)}) باید برابر مبلغ قرض (${_fmt(amt)}) باشد');
    }
    late int id;
    await _write((d) => d.transaction((t) async {
          if (isRepay) {
            final owed = await _loanOutstanding(t, p, kind == 'repay_in' ? 'given' : 'taken');
            if (owed <= 0.5) throw Exception('بدهی برای بازپرداخت وجود ندارد');
            if (amt > owed + 0.5) {
              throw Exception('مبلغ بازپرداخت (${_fmt(amt)}) از مانده (${_fmt(owed)}) بیشتر است');
            }
          }
          id = await _tempId(t, 'loan_entries');
          await t.insert('loan_entries', {
            'id': id,
            'uid': uid,
            'party': p,
            'kind': kind,
            'amount': amt,
            'date': dt,
            'note': nt,
            'created_at': _stamp(),
          });
          for (final du in cleanDues) {
            final did = await _tempId(t, 'loan_dues');
            await t.insert('loan_dues', {'id': did, 'loan_uid': uid, ...du, 'paid': 0});
          }
          await _enqueue(
              t,
              'loans.create',
              {
                'uid': uid,
                'party': p,
                'kind': kind,
                'amount': amt,
                'date': dt,
                'note': nt,
                if (cleanDues.isNotEmpty) 'dues': cleanDues,
              },
              refKind: 'loan',
              refId: id);
          await _confirm(t, 'SELECT 1 FROM loan_entries WHERE id = ? AND uid = ? AND amount = ?', [id, uid, amt]);
          final dc = Sqflite.firstIntValue(await t.rawQuery('SELECT COUNT(*) FROM loan_dues WHERE loan_uid = ?', [uid])) ?? 0;
          if (dc != cleanDues.length) throw SaveNotConfirmed();
          await _confirm(t, "SELECT 1 FROM sync_ops WHERE ref_kind='loan' AND ref_id=?", [id]);
        }));
    version.value++;
    return id;
  }

  Future<void> deleteLoanEntry(int id) async {
    await _write((d) => d.transaction((t) async {
          final cur = await t.query('loan_entries', columns: ['uid'], where: 'id=?', whereArgs: [id]);
          if (cur.isEmpty) return; // قبلاً حذف شده
          final uid = cur.first['uid'] as String;
          await t.delete('loan_dues', where: 'loan_uid=?', whereArgs: [uid]);
          await t.delete('loan_entries', where: 'id=?', whereArgs: [id]);
          // اگر ارسالِ «ثبت» هنوز در صف است، اول آن را بردار؛ حذف سمت سرور همیشه (idempotent) در صف می‌رود
          await t.delete('sync_ops',
              where: "action='loans.create' AND ref_kind='loan' AND ref_id=? AND state='pending'", whereArgs: [id]);
          await _enqueue(t, 'loans.delete', {'uid': uid}, refKind: 'loan', refId: id);
          await _confirm(t, 'SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM loan_entries WHERE id = ?)', [id]);
        }));
    version.value++;
  }

  /// سررسیدهای قرض (برای صفحهٔ سررسیدها و اعلان‌ها). پیش‌فرض: فقط پرداخت‌نشده‌هایی که قرضشان هنوز باز است.
  Future<List<Map<String, dynamic>>> loanDueRows({bool includePaid = false}) async {
    final d = await db;
    final rows = await d.rawQuery(
        'SELECT x.id AS id, x.seq AS seq, x.due_date AS due_date, x.amount AS amount, x.note AS note, x.paid AS paid, '
        'l.kind AS kind, l.party AS party, l.date AS loan_date '
        'FROM loan_dues x JOIN loan_entries l ON l.uid = x.loan_uid '
        '${includePaid ? '' : 'WHERE x.paid = 0 '}'
        'ORDER BY x.due_date, x.id');
    final cache = <String, double>{};
    final out = <Map<String, dynamic>>[];
    for (final r in rows) {
      final paid = ((r['paid'] as num?) ?? 0) == 1;
      if (!paid) {
        final key = '${r['kind']}|${r['party']}';
        cache[key] ??= await _loanOutstanding(d, r['party'] as String, r['kind'] as String);
        if (cache[key]! <= 0.5) continue; // قرض کاملاً تسویه شده؛ یادآوری لازم نیست
      }
      out.add(r);
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> unpaidLoanDues() => loanDueRows();

  /// «پرداخت/دریافت شد» برای یک سررسید قرض: سررسید بسته می‌شود و بازپرداخت متناظر
  /// (حداکثر تا مانده‌ی قرض) خودکار در دفتر ثبت می‌شود.
  Future<void> payLoanDue(int dueId) async {
    await _write((d) => d.transaction((t) async {
          final dr = await t.query('loan_dues', where: 'id=?', whereArgs: [dueId]);
          if (dr.isEmpty) throw SaveNotConfirmed('این سررسید دیگر وجود ندارد؛ صفحه را ببندید و دوباره باز کنید.');
          final due = dr.first;
          if (((due['paid'] as num?) ?? 0) == 1) return;
          final lr = await t.query('loan_entries', where: 'uid=?', whereArgs: [due['loan_uid']]);
          if (lr.isEmpty) throw SaveNotConfirmed('قرضِ مربوط به این سررسید دیگر وجود ندارد.');
          final loan = lr.first;
          final kind = loan['kind'] as String;
          final party = loan['party'] as String;
          final owed = await _loanOutstanding(t, party, kind);
          final pay = math.min((due['amount'] as num).toDouble(), owed);
          await t.update('loan_dues', {'paid': 1}, where: 'id=?', whereArgs: [dueId]);
          await _enqueue(t, 'loans.due_paid', {'loan_uid': due['loan_uid'], 'seq': due['seq']},
              refKind: 'loandue', refId: dueId);
          if (pay > 0.5) {
            final uid = _newIdem();
            final rid = await _tempId(t, 'loan_entries');
            final repayKind = kind == 'given' ? 'repay_in' : 'repay_out';
            final dt = _ymd(DateTime.now());
            final nt = 'تسویهٔ سررسید ${due['seq']}';
            final amt = _r(pay, 2);
            await t.insert('loan_entries', {
              'id': rid,
              'uid': uid,
              'party': party,
              'kind': repayKind,
              'amount': amt,
              'date': dt,
              'note': nt,
              'created_at': _stamp(),
            });
            await _enqueue(t, 'loans.create',
                {
                  'uid': uid, 'party': party, 'kind': repayKind, 'amount': amt, 'date': dt, 'note': nt,
                  // STAGE12: اگر سرور همین سررسید را قبلاً (دستیار/وب) تسویه کرده، ردیف موجود برمی‌گردد (بدون دوبل)
                  'due_ref': {'loan_uid': due['loan_uid'], 'seq': due['seq']},
                },
                refKind: 'loan', refId: rid);
          }
          await _confirm(t, 'SELECT 1 FROM loan_dues WHERE id = ? AND paid = 1', [dueId]);
        }));
    version.value++;
  }

  /// آیا هنوز هیچ خرید یا فروشی ثبت نشده؟
  Future<bool> isEmpty() async {
    final n = Sqflite.firstIntValue(await (await db).rawQuery(
            'SELECT (SELECT COUNT(*) FROM purchases) + (SELECT COUNT(*) FROM sales)')) ??
        0;
    return n == 0;
  }

  // ---------- گزارش کلی تراکنش‌ها (برای خروجی PDF) ----------
  Future<List<Map<String, dynamic>>> allPaymentTransactions({DateTime? from, DateTime? to}) async {
    final d = await db;
    final out = <Map<String, dynamic>>[];
    final lumps = await d.rawQuery('''
        SELECT lt.date AS date, lt.amount AS amount, lt.paid AS paid,
               p.type_name AS type_name, c.name AS category_name, p.seller AS seller, p.code AS code
        FROM lump_tx lt
        JOIN payments pay ON pay.id = lt.payment_id
        JOIN purchases p ON p.id = pay.purchase_id
        JOIN categories c ON c.id = p.category_id''');
    for (final r in lumps) {
      out.add({
        'kind': 'یکجا',
        'date': r['date'],
        'amount': r['amount'],
        'paid': (r['paid'] as int?) ?? 1,
        'label': '${r['type_name']} (${r['category_name']})',
        'name': (r['seller'] as String?)?.trim().isNotEmpty == true ? r['seller'] : '-',
        'code': (r['code'] as String?) ?? '-',
      });
    }
    final credits = await d.rawQuery('''
        SELECT ci.due_date AS date, ci.amount AS amount, ci.paid AS paid,
               p.type_name AS type_name, c.name AS category_name, p.seller AS seller, p.code AS code
        FROM credit_inst ci
        JOIN payments pay ON pay.id = ci.payment_id
        JOIN purchases p ON p.id = pay.purchase_id
        JOIN categories c ON c.id = p.category_id''');
    for (final r in credits) {
      out.add({
        'kind': 'قسط',
        'date': r['date'],
        'amount': r['amount'],
        'paid': r['paid'],
        'label': '${r['type_name']} (${r['category_name']})',
        'name': (r['seller'] as String?)?.trim().isNotEmpty == true ? r['seller'] : '-',
        'code': (r['code'] as String?) ?? '-',
      });
    }
    final cheques = await d.rawQuery('''
        SELECT chi.due_date AS date, chi.amount AS amount, chi.paid AS paid,
               p.type_name AS type_name, c.name AS category_name, p.seller AS seller, p.code AS code
        FROM cheque_inst chi
        JOIN payments pay ON pay.id = chi.payment_id
        JOIN purchases p ON p.id = pay.purchase_id
        JOIN categories c ON c.id = p.category_id''');
    for (final r in cheques) {
      out.add({
        'kind': 'چک',
        'date': r['date'],
        'amount': r['amount'],
        'paid': r['paid'],
        'label': '${r['type_name']} (${r['category_name']})',
        'name': (r['seller'] as String?)?.trim().isNotEmpty == true ? r['seller'] : '-',
        'code': (r['code'] as String?) ?? '-',
      });
    }
    return _filterAndSort(out, from, to);
  }

  Future<List<Map<String, dynamic>>> allReceiptTransactions({DateTime? from, DateTime? to}) async {
    final d = await db;
    final out = <Map<String, dynamic>>[];
    final lumps = await d.rawQuery('''
        SELECT lt.date AS date, lt.amount AS amount, lt.paid AS paid, s.buyer AS buyer,
               (SELECT GROUP_CONCAT(pp.code, '، ') FROM sale_items si JOIN purchases pp ON pp.id = si.purchase_id WHERE si.sale_id = s.id) AS codes
        FROM receipt_lump_tx lt
        JOIN receipts rec ON rec.id = lt.receipt_id
        JOIN sales s ON s.id = rec.sale_id''');
    for (final r in lumps) {
      out.add({
        'kind': 'یکجا',
        'date': r['date'],
        'amount': r['amount'],
        'paid': (r['paid'] as int?) ?? 1,
        'label': (r['buyer'] as String?) ?? '-',
        'name': (r['buyer'] as String?)?.trim().isNotEmpty == true ? r['buyer'] : '-',
        'code': (r['codes'] as String?) ?? '-',
      });
    }
    final credits = await d.rawQuery('''
        SELECT ci.due_date AS date, ci.amount AS amount, ci.paid AS paid, s.buyer AS buyer,
               (SELECT GROUP_CONCAT(pp.code, '، ') FROM sale_items si JOIN purchases pp ON pp.id = si.purchase_id WHERE si.sale_id = s.id) AS codes
        FROM receipt_credit_inst ci
        JOIN receipts rec ON rec.id = ci.receipt_id
        JOIN sales s ON s.id = rec.sale_id''');
    for (final r in credits) {
      out.add({
        'kind': 'قسط',
        'date': r['date'],
        'amount': r['amount'],
        'paid': r['paid'],
        'label': (r['buyer'] as String?) ?? '-',
        'name': (r['buyer'] as String?)?.trim().isNotEmpty == true ? r['buyer'] : '-',
        'code': (r['codes'] as String?) ?? '-',
      });
    }
    final cheques = await d.rawQuery('''
        SELECT chi.due_date AS date, chi.amount AS amount, chi.paid AS paid, s.buyer AS buyer,
               (SELECT GROUP_CONCAT(pp.code, '، ') FROM sale_items si JOIN purchases pp ON pp.id = si.purchase_id WHERE si.sale_id = s.id) AS codes
        FROM receipt_cheque_inst chi
        JOIN receipts rec ON rec.id = chi.receipt_id
        JOIN sales s ON s.id = rec.sale_id''');
    for (final r in cheques) {
      out.add({
        'kind': 'چک',
        'date': r['date'],
        'amount': r['amount'],
        'paid': r['paid'],
        'label': (r['buyer'] as String?) ?? '-',
        'name': (r['buyer'] as String?)?.trim().isNotEmpty == true ? r['buyer'] : '-',
        'code': (r['codes'] as String?) ?? '-',
      });
    }
    return _filterAndSort(out, from, to);
  }

  List<Map<String, dynamic>> _filterAndSort(
      List<Map<String, dynamic>> rows, DateTime? from, DateTime? to) {
    var filtered = rows;
    if (from != null || to != null) {
      filtered = rows.where((r) {
        final dt = DateTime.parse(r['date'] as String);
        if (from != null && dt.isBefore(from)) return false;
        if (to != null && dt.isAfter(to)) return false;
        return true;
      }).toList();
    }
    filtered.sort((a, b) => (a['date'] as String).compareTo(b['date'] as String));
    return filtered;
  }
}
