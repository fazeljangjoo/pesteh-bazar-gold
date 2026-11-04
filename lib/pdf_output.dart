import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:printing/printing.dart';

import 'excel_io.dart';

/// خروجی PDF: کاربر انتخاب می‌کند فایل را ببیند (پیش‌نمایش)، مستقیم ارسال کند یا در حافظهٔ گوشی ذخیره کند.
class PdfOutput {
  PdfOutput._();

  static Future<void> show(BuildContext context, File file) async {
    if (Platform.isWindows) {
      // ویندوز: پیش‌نمایش داخل برنامه؛ دکمهٔ چاپ، پنجرهٔ چاپ ویندوز را باز می‌کند
      // (پرینتر یا «Microsoft Print to PDF» برای ذخیره‌کردن فایل PDF در هر مسیری که بخواهید)
      final bytes = await file.readAsBytes();
      if (!context.mounted) return;
      await Navigator.push(context,
          MaterialPageRoute<void>(
              builder: (_) => _PdfPreviewScreen(bytes: bytes, filename: p.basename(file.path), srcPath: file.path)));
      return;
    }
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('خروجی PDF', style: Theme.of(ctx).textTheme.titleMedium),
          ),
          ListTile(
            leading: const Icon(Icons.visibility_outlined),
            title: const Text('پیش‌نمایش'),
            subtitle: const Text('قبل از ارسال یا ذخیره، فایل را ببینید'),
            onTap: () => Navigator.pop(ctx, 'preview'),
          ),
          ListTile(
            leading: const Icon(Icons.share_outlined),
            title: const Text('ارسال'),
            subtitle: const Text('مستقیم برای واتس‌اپ، ایتا، ایمیل و…'),
            onTap: () => Navigator.pop(ctx, 'share'),
          ),
          if (ExcelIo.has(file.path))
            ListTile(
              leading: const Icon(Icons.table_chart_outlined),
              title: const Text('خروجی اکسل'),
              subtitle: const Text('همین جدول به‌صورت فایل Excel'),
              onTap: () => Navigator.pop(ctx, 'excel'),
            ),
          ListTile(
            leading: const Icon(Icons.save_alt_outlined),
            title: const Text('ذخیره در حافظهٔ گوشی'),
            subtitle: const Text('در پنجرهٔ بعد گزینهٔ «Save as PDF» را بزنید و محل ذخیره را انتخاب کنید'),
            onTap: () => Navigator.pop(ctx, 'save'),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (choice == null || !context.mounted) return;
    final bytes = await file.readAsBytes();
    final name = p.basename(file.path);
    switch (choice) {
      case 'excel':
        await ExcelIo.exportFor(context, file.path);
        break;
      case 'share':
        await Printing.sharePdf(bytes: bytes, filename: name);
        break;
      case 'save':
        await Printing.layoutPdf(name: name, onLayout: (_) async => bytes);
        break;
      case 'preview':
        await Navigator.push(
            context, MaterialPageRoute<void>(builder: (_) => _PdfPreviewScreen(bytes: bytes, filename: name, srcPath: file.path)));
        break;
    }
  }
}

class _PdfPreviewScreen extends StatelessWidget {
  final Uint8List bytes;
  final String filename;
  final String? srcPath;
  const _PdfPreviewScreen({required this.bytes, required this.filename, this.srcPath});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('پیش‌نمایش PDF'),
        actions: <Widget>[
          if (srcPath != null && ExcelIo.has(srcPath!))
            IconButton(
              tooltip: 'خروجی اکسل',
              icon: const Icon(Icons.table_chart_outlined),
              onPressed: () => ExcelIo.exportFor(context, srcPath!),
            ),
        ],
      ),
      body: PdfPreview(
        build: (_) async => bytes,
        pdfFileName: filename,
        canChangePageFormat: false,
        canChangeOrientation: false,
        canDebug: false,
        allowSharing: !Platform.isWindows,
        allowPrinting: true,
      ),
    );
  }
}
