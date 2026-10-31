import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pdf_output.dart';
import 'pdf_service.dart';
import 'widgets.dart';

// S12.T12.3 — printer selection (remembered per device), optional silent print where the
// `printing` plugin supports direct print (Windows/macOS/Linux), test print, Persian errors.
// No ESC/POS serial in v1 (Q8): everything goes through PDF (roll 58/80 mm templates from T12.1).
class PrintService {
  PrintService._();
  static const String _kUrl = 'pb_printer_url';
  static const String _kName = 'pb_printer_name';
  static const String _kSilent = 'pb_print_silent';

  /// True when the current platform/plugin can print without the system dialog.
  static Future<bool> directSupported() async {
    if (Platform.isAndroid || Platform.isIOS) return false;
    try {
      final PrintingInfo info = await Printing.info();
      return info.directPrint;
    } catch (_) {
      return false;
    }
  }

  static Future<Printer?> savedPrinter() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      final String? url = sp.getString(_kUrl);
      if (url == null || url.isEmpty) return null;
      return Printer(url: url, name: sp.getString(_kName) ?? url);
    } catch (_) {
      return null;
    }
  }

  static Future<bool> silentEnabled() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      return sp.getBool(_kSilent) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> setSilent(bool v) async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    await sp.setBool(_kSilent, v);
  }

  static Future<void> _remember(Printer? p) async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    if (p == null) {
      await sp.remove(_kUrl);
      await sp.remove(_kName);
    } else {
      await sp.setString(_kUrl, p.url);
      await sp.setString(_kName, p.name);
    }
  }

  /// Persian message for a printing failure.
  static String faError(Object e) {
    final String m = '$e'.toLowerCase();
    if (m.contains('no printer') || m.contains('not found') || m.contains('unavailable')) {
      return 'چاپگر پیدا نشد؛ از روشن بودن و اتصال آن مطمئن شوید یا چاپگر را دوباره انتخاب کنید';
    }
    if (m.contains('access') || m.contains('denied') || m.contains('permission')) {
      return 'دسترسی به چاپگر ممکن نیست';
    }
    if (m.contains('unsupported') || m.contains('not supported') || m.contains('missingplugin')) {
      return 'چاپ مستقیم در این دستگاه پشتیبانی نمی‌شود';
    }
    return 'چاپ ناموفق بود: $e';
  }

  /// Lets the user choose a printer from the system list and remembers it. Null = nothing chosen.
  static Future<Printer?> pickPrinter(BuildContext context) async {
    List<Printer> list;
    try {
      list = await Printing.listPrinters();
    } catch (e) {
      if (context.mounted) snack(context, faError(e));
      return null;
    }
    if (!context.mounted) return null;
    if (list.isEmpty) {
      snack(context, 'هیچ چاپگری روی این دستگاه پیدا نشد');
      return null;
    }
    final Printer? chosen = await showDialog<Printer>(
      context: context,
      builder: (BuildContext c) => SimpleDialog(
        title: const Text('انتخاب چاپگر'),
        children: <Widget>[
          for (final Printer p in list)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, p),
              child: ListTile(
                leading: Icon(p.isDefault ? Icons.print : Icons.print_outlined),
                title: Text(p.name),
                subtitle: p.isDefault ? const Text('پیش‌فرض سیستم') : null,
              ),
            ),
        ],
      ),
    );
    if (chosen != null) await _remember(chosen);
    return chosen;
  }

  /// Main entry for every receipt/invoice PDF: silent print to the remembered printer when enabled
  /// and supported, otherwise (or on failure) the preview + print dialog path.
  static Future<void> printFile(BuildContext context, File file) async {
    try {
      if (await silentEnabled() && await directSupported()) {
        final Printer? pr = await savedPrinter();
        if (pr != null) {
          final List<int> bytes = await file.readAsBytes();
          final bool ok = await Printing.directPrintPdf(
            printer: pr,
            name: file.path.split(Platform.pathSeparator).last,
            onLayout: (_) async => Uint8List.fromList(bytes),
          );
          if (ok) {
            if (context.mounted) snack(context, 'به چاپگر «${pr.name}» ارسال شد');
            return;
          }
          if (context.mounted) snack(context, 'ارسال به چاپگر انجام نشد؛ پیش‌نمایش باز می‌شود');
        } else if (context.mounted) {
          snack(context, 'چاپگری انتخاب نشده؛ پیش‌نمایش باز می‌شود');
        }
      }
    } catch (e) {
      if (context.mounted) snack(context, faError(e));
    }
    if (context.mounted) await PdfOutput.show(context, file);
  }

  /// Small sample receipt in the chosen template (roll 58/80, A5, A4) with barcode + QR.
  static Future<void> testPrint(BuildContext context) async {
    try {
      final File f = await PdfService.buildDocument(
        title: 'چاپ آزمایشی',
        fileTag: 'TEST',
        header: <List<String>>[
          <String>['وضعیت', 'آزمایش چاپگر'],
        ],
        columns: const <String>['شرح', 'وزن (کیلو)', 'فی', 'مبلغ'],
        rows: const <List<String>>[
          <String>['نمونه ۱', '1', '1000', '1000'],
          <String>['نمونه ۲', '2', '500', '1000'],
        ],
        totals: const <List<String>>[
          <String>['جمع کل', '2000'],
        ],
        note: 'اگر این رسید خوانا چاپ شد، تنظیمات درست است.',
        barcodes: const <String>['12345678'],
        qrData: 'PB-TEST-12345678',
      );
      if (context.mounted) await printFile(context, f);
    } catch (e) {
      if (context.mounted) snack(context, faError(e));
    }
  }
}

/// Settings dialog: remembered printer, silent-print switch, test print.
Future<void> showPrintSettings(BuildContext context) async {
  Printer? pr = await PrintService.savedPrinter();
  bool silent = await PrintService.silentEnabled();
  final bool direct = await PrintService.directSupported();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (BuildContext c) => StatefulBuilder(
      builder: (BuildContext c2, StateSetter ss) => AlertDialog(
        title: const Text('تنظیمات چاپ'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.print_outlined),
                title: Text(pr?.name ?? 'چاپگری انتخاب نشده'),
                subtitle: const Text('چاپگر پیش‌فرض این دستگاه'),
                trailing: TextButton(
                  onPressed: () async {
                    final Printer? p = await PrintService.pickPrinter(c2);
                    if (p != null) ss(() => pr = p);
                  },
                  child: const Text('انتخاب'),
                ),
              ),
              if (direct)
                SwitchListTile(
                  title: const Text('چاپ بی‌صدا (بدون پنجرهٔ چاپ)'),
                  value: silent,
                  onChanged: (bool v) async {
                    await PrintService.setSilent(v);
                    ss(() => silent = v);
                  },
                )
              else
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('در این دستگاه چاپ از طریق پنجرهٔ چاپ سیستم انجام می‌شود.'),
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => PrintService.testPrint(c2),
                icon: const Icon(Icons.receipt_long),
                label: const Text('چاپ آزمایشی'),
              ),
              const SizedBox(height: 4),
              const Text('اندازهٔ کاغذ (رول ۵۸/۸۰، A5، A4) از «مشخصات شرکت و قالب فاکتور» انتخاب می‌شود.',
                  style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
        actions: <Widget>[TextButton(onPressed: () => Navigator.pop(c), child: const Text('بستن'))],
      ),
    ),
  );
}
