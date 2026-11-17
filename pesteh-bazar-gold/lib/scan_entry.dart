// پسته‌بازار — اسکن بارکد در ویندوز.
// ویندوز دوربین ندارد؛ اسکنر USB/بلوتوث مثل کیبورد کد را تایپ و با Enter تمام می‌کند.
// امضای این فایل عیناً همان نسخهٔ اندروید است (scanBarcode(context) → String?)،
// تا home_screen و بقیهٔ صفحه‌ها بدون تغییر کامپایل شوند. این فایل پکیج دوربین را ایمپورت نمی‌کند.

import 'package:flutter/material.dart';

import 'barcode_utils.dart';

/// دیالوگ اسکن. کد معتبر (قابل‌چاپ) را برمی‌گرداند؛ با انصراف یا بستن دیالوگ null.
Future<String?> scanBarcode(BuildContext context) {
  return showDialog<String>(
    context: context,
    barrierDismissible: true,
    builder: (_) => const _ScanDialog(),
  );
}

class _ScanDialog extends StatefulWidget {
  const _ScanDialog();

  @override
  State<_ScanDialog> createState() => _ScanDialogState();
}

class _ScanDialogState extends State<_ScanDialog> {
  final _ctrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit(String raw) {
    final code = normalizeScan(raw);
    if (code == null) {
      // خطای کوتاه؛ ورودی پاک می‌شود تا اسکن بعدی بی‌درنگ ثبت شود.
      setState(() {
        _error = raw.trim().isEmpty ? 'کدی دریافت نشد' : 'این کد معتبر نیست';
      });
      _ctrl.clear();
      return;
    }
    Navigator.pop(context, code);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('اسکن بارکد'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'اسکنر را به رایانه وصل کنید و روی کادر بزنید یا کد را تایپ کنید',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _ctrl,
              autofocus: true,
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.center,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                hintText: 'مثلاً KH1234',
                border: const OutlineInputBorder(),
                errorText: _error,
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: _submit,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('انصراف'),
        ),
      ],
    );
  }
}
