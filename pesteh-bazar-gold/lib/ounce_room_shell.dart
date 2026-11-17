import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'intake_form.dart';
import 'intake_list_screen.dart';
import 'license_service.dart';
import 'widgets.dart' show confirm;

/// S5.T4/T5: پوستهٔ کارکن «اتاق انس». فقط دو صفحهٔ پذیرش + خروج دیده می‌شود؛ هیچ تب مالی نیست.
/// ویندوز: منوی کناری (NavigationRail) + Ctrl+1/Ctrl+2؛ موبایل: NavigationBar پایین.
/// سرور هم مجوزها را جداگانه چک می‌کند (deny-by-default)؛ این فقط UI است.
class OunceRoomShell extends StatefulWidget {
  const OunceRoomShell({super.key});

  @override
  State<OunceRoomShell> createState() => _OunceRoomShellState();
}

class _OunceRoomShellState extends State<OunceRoomShell> {
  static const int _kIntake = 0;
  static const int _kList = 1;
  static const int _kExit = 2;

  int _i = _kIntake;

  Future<void> _select(int v) async {
    if (v == _kExit) {
      if (!await confirm(context, 'از حساب خارج شوید؟')) return;
      await LicenseService.I.signOut();
      LicenseService.I.sessionInvalid.value++;
      return;
    }
    setState(() => _i = v);
  }

  @override
  Widget build(BuildContext context) {
    final Widget body = IndexedStack(
      index: _i,
      children: const <Widget>[IntakeFormScreen(), IntakeListScreen()],
    );
    final bool wide = Platform.isWindows || MediaQuery.of(context).size.width >= 720;

    final Map<ShortcutActivator, VoidCallback> keys = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.digit1, control: true): () => _select(_kIntake),
      const SingleActivator(LogicalKeyboardKey.digit2, control: true): () => _select(_kList),
    };

    const List<NavigationRailDestination> railDest = <NavigationRailDestination>[
      NavigationRailDestination(icon: Icon(Icons.add_box_outlined), selectedIcon: Icon(Icons.add_box), label: Text('پذیرش جدید')),
      NavigationRailDestination(icon: Icon(Icons.list_alt_outlined), selectedIcon: Icon(Icons.list_alt), label: Text('پذیرش‌ها')),
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
                    NavigationDestination(icon: Icon(Icons.add_box_outlined), selectedIcon: Icon(Icons.add_box), label: 'پذیرش جدید'),
                    NavigationDestination(icon: Icon(Icons.list_alt_outlined), selectedIcon: Icon(Icons.list_alt), label: 'پذیرش‌ها'),
                    NavigationDestination(icon: Icon(Icons.logout), label: 'خروج'),
                  ],
                ),
              ),
      ),
    );
  }
}
