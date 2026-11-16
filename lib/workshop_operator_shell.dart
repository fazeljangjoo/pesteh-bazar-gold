import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'crack_ui.dart';
import 'feed_ui.dart' show FeedStockScreen;
import 'license_service.dart';
import 'reports_ui.dart' show WorkshopReportsScreen;
import 'widgets.dart' show confirm;
import 'workshop_ui.dart';

/// کارگاه ۳-ب: پوستهٔ «اپراتور کارگاه». فقط: فرم خط شکست · فهرست خودش · فرم عملیات داخلی · موجودی پستهٔ خرجی (فقط‌مشاهده، ۵-ب) · گزارش‌های کارگاه (کارتکس/مقایسه، ۶-۳) · خروج.
/// هیچ قیمت/بها/موجودی مالی/تب دیگری دیده نمی‌شود (`StaffPerms.isWorkshopOperatorOnly`).
/// ویندوز: NavigationRail + Ctrl+1..5؛ موبایل: NavigationBar. سرور هم مجوزها را جدا چک می‌کند؛ این فقط UI است.
class WorkshopOperatorShell extends StatefulWidget {
  const WorkshopOperatorShell({super.key});

  @override
  State<WorkshopOperatorShell> createState() => _WorkshopOperatorShellState();
}

class _WorkshopOperatorShellState extends State<WorkshopOperatorShell> {
  static const int _kCrack = 0;
  static const int _kList = 1;
  static const int _kInternal = 2;
  static const int _kFeed = 3; // مرحلهٔ ۵: موجودی پستهٔ خرجی (فقط‌مشاهده)
  static const int _kReports = 4; // مرحلهٔ ۶-۳: کارتکس مالک + مقایسه (فقط‌مشاهده، بدون قیمت)
  static const int _kExit = 5;

  int _i = _kCrack;
  int _formRev = 0; // بعد از ثبت، فرم تازه ساخته می‌شود (uid جدید)
  int _listRev = 0;

  Future<void> _select(int v) async {
    if (v == _kExit) {
      if (!await confirm(context, 'از حساب خارج شوید؟')) return;
      await LicenseService.I.signOut();
      LicenseService.I.sessionInvalid.value++;
      return;
    }
    setState(() {
      _i = v;
      if (v == _kList) _listRev++;
    });
  }

  void _saved() => setState(() {
        _formRev++;
        _listRev++;
      });

  @override
  Widget build(BuildContext context) {
    final Widget body = IndexedStack(
      index: _i,
      children: <Widget>[
        CrackFormScreen(key: ValueKey<int>(_formRev), onSaved: _saved),
        CrackListScreen(refreshToken: _listRev),
        const _InternalOpLauncher(),
        const FeedStockScreen(embedded: true),
        const WorkshopReportsScreen(embedded: true),
      ],
    );
    final bool wide = Platform.isWindows || MediaQuery.of(context).size.width >= 720;

    final Map<ShortcutActivator, VoidCallback> keys = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.digit1, control: true): () => _select(_kCrack),
      const SingleActivator(LogicalKeyboardKey.digit2, control: true): () => _select(_kList),
      const SingleActivator(LogicalKeyboardKey.digit3, control: true): () => _select(_kInternal),
      const SingleActivator(LogicalKeyboardKey.digit4, control: true): () => _select(_kFeed),
      const SingleActivator(LogicalKeyboardKey.digit5, control: true): () => _select(_kReports),
    };

    const List<NavigationRailDestination> railDest = <NavigationRailDestination>[
      NavigationRailDestination(icon: Icon(Icons.assignment_add), selectedIcon: Icon(Icons.assignment_add), label: Text('گزارش خط شکست')),
      NavigationRailDestination(icon: Icon(Icons.list_alt_outlined), selectedIcon: Icon(Icons.list_alt), label: Text('گزارش‌های من')),
      NavigationRailDestination(icon: Icon(Icons.precision_manufacturing_outlined), selectedIcon: Icon(Icons.precision_manufacturing), label: Text('عملیات داخلی')),
      NavigationRailDestination(icon: Icon(Icons.inventory_2_outlined), selectedIcon: Icon(Icons.inventory_2), label: Text('موجودی پستهٔ خرجی')),
      NavigationRailDestination(icon: Icon(Icons.assessment_outlined), selectedIcon: Icon(Icons.assessment), label: Text('گزارش‌های کارگاه')),
      NavigationRailDestination(icon: Icon(Icons.logout), label: Text('خروج')),
    ];

    return CallbackShortcuts(
      bindings: keys,
      child: Focus(
        autofocus: true,
        child: wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  NavigationRail(
                    selectedIndex: _i,
                    labelType: NavigationRailLabelType.all,
                    onDestinationSelected: _select,
                    destinations: railDest,
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: body),
                ],
              )
            : Scaffold(
                body: body,
                bottomNavigationBar: NavigationBar(
                  selectedIndex: _i,
                  onDestinationSelected: _select,
                  destinations: const <NavigationDestination>[
                    NavigationDestination(icon: Icon(Icons.assignment_add), label: 'خط شکست'),
                    NavigationDestination(icon: Icon(Icons.list_alt_outlined), selectedIcon: Icon(Icons.list_alt), label: 'گزارش‌های من'),
                    NavigationDestination(icon: Icon(Icons.precision_manufacturing_outlined), selectedIcon: Icon(Icons.precision_manufacturing), label: 'عملیات داخلی'),
                    NavigationDestination(icon: Icon(Icons.inventory_2_outlined), selectedIcon: Icon(Icons.inventory_2), label: 'پستهٔ خرجی'),
                    NavigationDestination(icon: Icon(Icons.assessment_outlined), selectedIcon: Icon(Icons.assessment), label: 'گزارش‌ها'),
                    NavigationDestination(icon: Icon(Icons.logout), label: 'خروج'),
                  ],
                ),
              ),
      ),
    );
  }
}

/// WorkshopFormScreen بعد از ثبت `Navigator.pop` می‌کند؛ پس به‌جای تب مستقیم، با push باز می‌شود تا ریشهٔ پوسته بسته نشود.
class _InternalOpLauncher extends StatelessWidget {
  const _InternalOpLauncher();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('عملیات کارگاه داخلی'), automaticallyImplyLeading: false),
      body: Directionality(
        textDirection: TextDirection.rtl,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Text('ثبت عملیات داخلی (خاک‌گیری، پوست‌گیری، جداسازی، ریزبرداری، شکست)', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute<bool>(builder: (_) => const WorkshopFormScreen())),
                  icon: const Icon(Icons.add),
                  label: const Text('عملیات جدید'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
