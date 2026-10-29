import 'broker_ui.dart';
import 'cheque_ui.dart';
import 'payroll_ui.dart'; // T11.4
import 'dart:async';
import 'perms.dart'; // T02.2
import 'staff_screens.dart'; // T02.2
import 'audit_screen.dart'; // T02.3
import 'data_health_screen.dart'; // T23.2
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app_lock.dart';
import 'backup_screen.dart';
import 'due_alert.dart';
import 'edition.dart';
import 'entity_screens.dart';
import 'entity_store.dart';
import 'warehouse_ui.dart';
import 'company_profile.dart';
import 'company_settings_ui.dart';
import 'accounts_ui.dart';
import 'vouchers_ui.dart';
import 'fx_currencies_ui.dart'; // S26.T26.2
import 'fx_rates_ui.dart'; // S26.T26.2
import 'form_settings.dart' show FormSettingsScreen; // S35.T35.1
import 'fx_mismatch_ui.dart'; // S27c.T27b.8
import 'fiscal_ui.dart';
import 'integrity_ui.dart'; // S16.T16.6b
import 'vat_report_ui.dart'; // S17.T17.2b
import 'ebooks_ui.dart';
import 'fy_close_ui.dart';
import 'fy_wizard_ui.dart';
import 'upgrade_ui.dart';
import 'stock_count_ui.dart';
import 'ledger_reports_ui.dart'; // S18.T18.1
import 'trial_balance_ui.dart'; // S18.T18.2
import 'treasury_balances_ui.dart'; // S28.T28.1
import 'statements_ui.dart'; // S18.T18.3
import 'official_invoice.dart'; // S17.T17.3
import 'pos_screen.dart';
import 'import_screen.dart';
import 'print_service.dart';
import 'returns_ui.dart';
import 'proforma_ui.dart';
import 'db_crypto.dart';
import 'dues_screen.dart';
import 'home_screen.dart';
import 'inventory_screen.dart';
import 'license_gate_screen.dart';
import 'live_query.dart';
import 'notify_service.dart';
import 'parties_screen.dart';
import 'purchases_screen.dart';
import 'renew_banner.dart';
import 'reports_screen.dart';
import 'sales_screen.dart';
import 'subscription_screen.dart';
import 'sync_service.dart';

void main() {
  // چترِ ایمنیِ سراسری: اگر جایی خطایی بدون try/catch رها شود (مثلاً یک استثنای
  // پیش‌بینی‌نشده‌ی دیتابیس)، به‌جای گم‌شدنِ بی‌صدا یا کرش کل اپ، حداقل لاگ می‌شود
  // و در حالت دیباگ روی کنسول دیده می‌شود.
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await EditionService.I.load(); // آخرین نسخهٔ ذخیره‌شده (آفلاین هم همان می‌ماند)
    await StaffPerms.I.loadSaved(); // T02.2: مجوزهای کارکن (اگر وارد شده باشد)

    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
      debugPrint('FlutterError: ${details.exceptionAsString()}');
    };

    if (Platform.isWindows || Platform.isLinux) {
      // دسکتاپ: دیتابیس SQLite از طریق FFI، و فایل‌ها در پوشهٔ داده‌های کاربر (نه کنار برنامه)
      databaseFactory = databaseFactoryFfi;
      final support = await getApplicationSupportDirectory();
      final dbDir = Directory(p.join(support.path, 'databases'));
      if (!await dbDir.exists()) await dbDir.create(recursive: true);
      await databaseFactory.setDatabasesPath(dbDir.path);
    }
    await DbCrypto.init();
    if (DbCrypto.initError != null) {
      runApp(_FatalApp(DbCrypto.initError!));
      return;
    }

    await AppLock.I.load();
    await NotifyService.I.init();
    // همگام‌سازی خودکار با سرور (ارسال تغییرات آفلاین + دریافت تغییرات سایر دستگاه‌ها)
    // نکته: یادآوری‌های سررسید بعد از ورود/باز شدن دیتابیس حساب در LicenseGate زمان‌بندی می‌شود.
    SyncService.I.start();
    runApp(const PestehApp());
  }, (error, stack) {
    debugPrint('Uncaught zone error: $error\n$stack');
  });
}

/// خطای راه‌اندازیِ غیرقابل‌ادامه (مثلاً نبودن کلید رمزگشایی) — به‌جای ساختن دیتابیس خالی
class _FatalApp extends StatelessWidget {
  final String message;
  const _FatalApp(this.message);
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text('پسته بازار\n\n$message', textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, height: 1.8)),
              ),
            ),
          ),
        ),
      );
}

class PestehApp extends StatelessWidget {
  const PestehApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'پسته بازار',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF5B7F2A), useMaterial3: true),
      builder: (context, child) {
        final body = Directionality(textDirection: TextDirection.rtl, child: child!);
        if (!Platform.isWindows) return body;
        // ویندوز: صفحه‌ها برای عرض گوشی طراحی شده‌اند؛ روی مانیتور بزرگ وسط و با عرض مناسب نمایش داده می‌شوند
        return ColoredBox(
          color: const Color(0xFFE9EDE6),
          child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1280), child: body)),
        );
      },
      home: const LicenseGate(child: RenewBannerHost(child: DueAlertHost(child: AppLockHost(child: HomeShell())))),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _i = activeTab.value;
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  static const _pages = [
    HomeScreen(),
    PurchasesScreen(),
    SalesScreen(),
    InventoryScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      body: IndexedStack(index: _i, children: _pages),
      floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
      floatingActionButton: FloatingActionButton.small(
        heroTag: 'moreMenu',
        tooltip: 'بیشتر (سررسید، طرف‌حساب، گزارش، اشتراک)',
        onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        child: const Icon(Icons.menu),
      ),
      drawer: Drawer(
        child: SafeArea(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text('پسته بازار', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Align(alignment: AlignmentDirectional.centerStart, child: EditionBadge()),
              ),
              const Divider(height: 1),
              if (StaffPerms.I.can('settings.manage'))
                ListTile( // S35.T35.1
                  leading: const Icon(Icons.tune_outlined),
                  title: const Text('تنظیمات فرم‌ها'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const FormSettingsScreen()));
                  },
                ),
              if (StaffPerms.I.can('users.manage'))
                ListTile(
                  leading: const Icon(Icons.manage_accounts_outlined),
                  title: const Text('کارکنان و نقش‌ها'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const StaffUsersScreen()));
                  },
                ),
              if (StaffPerms.I.can('audit.view'))
                ListTile(
                  leading: const Icon(Icons.fact_check_outlined),
                  title: const Text('گزارش ممیزی'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const AuditLogScreen()));
                  },
                ),
              if (StaffPerms.I.can('audit.view'))
                ListTile(
                  leading: const Icon(Icons.health_and_safety_outlined),
                  title: const Text('سلامت داده‌ها'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const DataHealthScreen()));
                  },
                ),
              ListTile(
                leading: const Icon(Icons.event_note_outlined),
                title: const Text('سررسیدها'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const DuesScreen()));
                },
              ),
              if (StaffPerms.I.can('payroll.view'))
                ListTile(
                  leading: const Icon(Icons.payments_outlined),
                  title: const Text('حقوق و دستمزد'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const PayrollHomeScreen()));
                  },
                ),
              ListTile(
                leading: const Icon(Icons.people_alt_outlined),
                title: const Text('طرف‌حساب‌ها'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const PartiesScreen()));
                },
              ),
              // S00.T00.4 scaffold: generic entities the server exposes to this account (none for normal accounts)
              FutureBuilder<List<String>>(
                future: EntityStore.I.visibleNames(),
                builder: (BuildContext ctx, AsyncSnapshot<List<String>> snap) {
                  final names = snap.data ?? const <String>[];
                  return Column(
                    children: [
                      for (final n in names)
                        if (!kHiddenEntityMenu.contains(n))
                        ListTile(
                          leading: const Icon(Icons.list_alt_outlined),
                          title: Text(kEntityRegistry[n]?.label ?? n),
                          onTap: () {
                            Navigator.pop(ctx);
                            Navigator.push(
                                ctx, MaterialPageRoute<void>(builder: (_) => EntityListScreen(entity: n)));
                          },
                        ),
                    ],
                  );
                },
              ),
              if (StaffPerms.I.can('pos.use') && StaffPerms.I.can('sales.create'))
                ListTile(
                  leading: const Icon(Icons.point_of_sale),
                  title: const Text('صندوق فروش (POS)'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const PosScreen()));
                  },
                ),
              if (StaffPerms.I.can('parties.create'))
                ListTile(
                  leading: const Icon(Icons.upload_file),
                  title: const Text('ورود اطلاعات از اکسل'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const ImportScreen()));
                  },
                ),
              ListTile(
                leading: const Icon(Icons.print_outlined),
                title: const Text('تنظیمات چاپ'),
                onTap: () {
                  Navigator.pop(context);
                  showPrintSettings(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.business_outlined),
                title: const Text('مشخصات شرکت و قالب فاکتور'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const CompanySettingsScreen()));
                },
              ),
              ListTile(
                leading: const Icon(Icons.request_quote_outlined),
                title: const Text('پیش‌فاکتورها'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const ProformaListScreen()));
                },
              ),
              ListTile(
                leading: const Icon(Icons.receipt_outlined),
                title: const Text('مدیریت چک'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const ChequeListScreen()));
                },
              ),
              ListTile(
                leading: const Icon(Icons.handshake_outlined),
                title: const Text('دلال‌ها و کمیسیون'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const BrokerScreen()));
                },
              ),
              ListTile(
                leading: const Icon(Icons.assignment_return_outlined),
                title: const Text('برگشت‌ها'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const ReturnsListScreen()));
                },
              ),
              if (StaffPerms.I.can('stock.view'))
                ListTile(
                  leading: const Icon(Icons.inventory_2_outlined),
                  title: const Text('انبارگردانی'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const StockCountListScreen()));
                  },
                ),
              ListTile(
                leading: const Icon(Icons.swap_horiz),
                title: const Text('انتقال بین انبارها'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const StockTransferScreen()));
                },
              ),
              ListTile(
                leading: const Icon(Icons.assessment_outlined),
                title: const Text('گزارش سود و زیان'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const ReportsScreen()));
                },
              ),
              if (Platform.isWindows) ...[
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.backup_outlined),
                  title: const Text('پشتیبان‌گیری'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const BackupScreen()));
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: const Text('قفل برنامه'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const SecurityScreen()));
                  },
                ),
              ],
              FeatureGate(
                feature: 'fx.rates',
                child: ListTile(
                  leading: const Icon(Icons.currency_exchange_outlined),
                  title: const Text('ارزها'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const FxCurrenciesScreen()));
                  },
                ),
              ),
              FeatureGate(
                feature: 'fx.rates',
                child: ListTile(
                  leading: const Icon(Icons.trending_up_outlined),
                  title: const Text('نرخ روزانه ارز'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const FxRatesScreen()));
                  },
                ),
              ),
              FeatureGate(
                feature: 'fx.documents',
                child: ListTile(
                  leading: const Icon(Icons.compare_arrows_outlined),
                  title: const Text('مغایرت نرخ اسناد ارزی'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const FxMismatchScreen()));
                  },
                ),
              ),
              FeatureGate(
                feature: 'gold.coa',
                child: ListTile(
                  leading: const Icon(Icons.account_tree_outlined),
                  title: const Text('سرفصل حساب‌ها'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const AccountsScreen()));
                  },
                ),
              ),
              FeatureGate(
                feature: 'gold.vouchers',
                child: ListTile(
                  leading: const Icon(Icons.receipt_long_outlined),
                  title: const Text('اسناد حسابداری'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const VouchersScreen()));
                  },
                ),
              ),
              if (StaffPerms.I.can('accounting.view'))
                FeatureGate(
                  feature: 'gold.vouchers',
                  child: ListTile(
                    leading: const Icon(Icons.assessment_outlined),
                    title: const Text('سود و زیان، ترازنامه، مراکز هزینه'),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const StatementsScreen()));
                    },
                  ),
                ),
              if (StaffPerms.I.can('accounting.view'))
                FeatureGate(
                  feature: 'gold.vouchers',
                  child: ListTile(
                    leading: const Icon(Icons.balance_outlined),
                    title: const Text('تراز آزمایشی'),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const TrialBalanceScreen()));
                    },
                  ),
                ),
              if (StaffPerms.I.can('accounting.view'))
                FeatureGate(
                  feature: 'gold.vouchers',
                  child: ListTile(
                    leading: const Icon(Icons.account_balance_wallet_outlined),
                    title: const Text('موجودی صندوق و بانک'),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const TreasuryBalancesScreen()));
                    },
                  ),
                ),
              if (StaffPerms.I.can('accounting.view'))
                FeatureGate(
                  feature: 'gold.vouchers',
                  child: ListTile(
                    leading: const Icon(Icons.menu_book_outlined),
                    title: const Text('روزنامه، کل، معین و تفصیلی'),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const LedgerReportsScreen()));
                    },
                  ),
                ),
              if (StaffPerms.I.can('accounting.close'))
                FeatureGate(
                  feature: 'gold.vouchers',
                  child: ListTile(
                    leading: const Icon(Icons.event_available_outlined),
                    title: const Text('پایان سال مالی'),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const FyCloseScreen()));
                    },
                  ),
                ),
              if (StaffPerms.I.can('accounting.close'))
                FeatureGate(
                  feature: 'gold.vouchers',
                  child: ListTile(
                    leading: const Icon(Icons.checklist_rtl),
                    title: const Text('ویزارد پایان سال'),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const FyWizardScreen()));
                    },
                  ),
                ),
              if (StaffPerms.I.can('settings.manage'))
                ValueListenableBuilder<Edition>(
                  valueListenable: EditionService.I.current,
                  builder: (BuildContext _, Edition ed, Widget? __) => FutureBuilder<bool>(
                    future: upgradePending(),
                    builder: (BuildContext _, AsyncSnapshot<bool> snap) {
                      if (ed.isGold && snap.data != true) return const SizedBox.shrink();
                      return ListTile(
                        leading: const Icon(Icons.workspace_premium_outlined),
                        title: Text(ed.isGold ? 'گزارش ارتقا به طلایی' : 'ارتقا به نسخهٔ طلایی'),
                        onTap: () {
                          Navigator.pop(context);
                          Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const UpgradeScreen()));
                        },
                      );
                    },
                  ),
                ),
              if (StaffPerms.I.can('accounting.view'))
                FeatureGate(
                  feature: 'gold.vouchers',
                  child: ListTile(
                    leading: const Icon(Icons.import_contacts_outlined),
                    title: const Text('دفاتر الکترونیک'),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const EBooksScreen()));
                    },
                  ),
                ),
              FeatureGate(
                feature: 'gold.vouchers',
                child: ListTile(
                  leading: const Icon(Icons.fact_check_outlined),
                  title: const Text('کنترل صحت حسابداری'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const IntegrityScreen()));
                  },
                ),
              ),
              if (StaffPerms.I.can('tax.view'))
                FeatureGate(
                  feature: 'gold.vat',
                  child: ListTile(
                    leading: const Icon(Icons.percent),
                    title: const Text('گزارش مالیات بر ارزش افزوده'),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const VatReportScreen()));
                    },
                  ),
                ),
              if (StaffPerms.I.can('tax.view'))
                FeatureGate(
                  feature: 'gold.invoices',
                  child: ListTile(
                    leading: const Icon(Icons.request_quote_outlined),
                    title: const Text('فاکتور رسمی فروش'),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const OfficialInvoicesScreen()));
                    },
                  ),
                ),
              FeatureGate(
                feature: 'gold.fiscal_years',
                child: ListTile(
                  leading: const Icon(Icons.calendar_month),
                  title: const Text('سال مالی و مالیات'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const FiscalSettingsScreen()));
                  },
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.verified_user_outlined),
                title: const Text('اشتراک من'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                      context, MaterialPageRoute(builder: (_) => const SubscriptionScreen()));
                },
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _i,
        onDestinationSelected: (v) {
          activeTab.value = v; // تب جدید در صورت نیاز داده‌هایش را تازه می‌کند
          setState(() => _i = v);
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: 'خانه'),
          NavigationDestination(icon: Icon(Icons.shopping_cart_outlined), label: 'خرید'),
          NavigationDestination(icon: Icon(Icons.sell_outlined), label: 'فروش'),
          NavigationDestination(icon: Icon(Icons.warehouse_outlined), label: 'موجودی'),
        ],
      ),
    );
  }
}
