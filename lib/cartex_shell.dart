import 'package:flutter/material.dart';

import 'license_service.dart';
import 'lot_cartex_ui.dart' show LotCartexView;
import 'widgets.dart' show confirm;

/// پوستهٔ نقش «کارتکس» (`StaffPerms.isCartexOnly`): فقط «کارتکس لات» (چهار تب: موجود در انبار · کوت‌ریزی‌شده · فراوری‌شده · پسته‌های خارج‌شده)
/// و دکمهٔ خروج. هیچ تب/قیمت/فرم دیگری دیده نمی‌شود؛ سرور هم مجوز را جدا چک می‌کند (cartex.view). فقط‌خواندنی است.
class CartexShell extends StatelessWidget {
  const CartexShell({super.key});

  Future<void> _logout(BuildContext context) async {
    if (!await confirm(context, 'از حساب خارج شوید؟')) return;
    await LicenseService.I.signOut();
    LicenseService.I.sessionInvalid.value++;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('کارتکس'),
        actions: <Widget>[
          IconButton(tooltip: 'خروج', icon: const Icon(Icons.logout), onPressed: () => _logout(context)),
        ],
      ),
      body: const LotCartexView(),
    );
  }
}
