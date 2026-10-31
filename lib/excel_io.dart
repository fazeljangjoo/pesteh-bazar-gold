import 'dart:io';

import 'package:excel/excel.dart';
import 'package:file_selector/file_selector.dart' show FileSaveLocation, XTypeGroup, getSaveLocation;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart' as sp;

import 'utils.dart';
import 'widgets.dart';

// S13.T13.1 — Excel export engine.
// Every PDF report builder registers its table here (keyed by the PDF file path), so the PDF
// output sheet (pdf_output.dart) can offer «خروجی اکسل» for every report that has a PDF button.
// Cells holding formatted numbers (Persian digits / separators) are written as real numbers.
class ExcelIo {
  ExcelIo._();

  static final Map<String, _Tbl> _tables = <String, _Tbl>{};

  /// [rows] = full sheet content (first row usually the column headers); strings as shown in the PDF.
  static void register(String pdfPath, String title, List<List<String>> rows) {
    if (_tables.length > 30) _tables.remove(_tables.keys.first);
    _tables[pdfPath] = _Tbl(title, rows);
  }

  static bool has(String pdfPath) => _tables.containsKey(pdfPath);

  /// Parses a displayed number («۱٬۲۳۴٫۵») → num, or null when the text is not a plain number.
  static num? parseCell(String s) {
    var t = toEnDigits(s.trim()).replaceAll('٬', '').replaceAll(',', '').replaceAll('٫', '.');
    t = t.replaceAll('\u200e', '').replaceAll('\u200f', '');
    if (!RegExp(r'^-?\d+(\.\d+)?$').hasMatch(t)) return null;
    final bool neg = t.startsWith('-');
    final String digits = neg ? t.substring(1) : t;
    if (digits.length > 15) return null;
    if (digits.length > 1 && digits.startsWith('0') && !digits.startsWith('0.')) return null; // codes like 00123
    return t.contains('.') ? double.parse(t) : int.parse(t);
  }

  static String _sheetName(String s) {
    var n = s.replaceAll(RegExp(r'[\[\]:*?/\\]'), ' ').trim();
    if (n.isEmpty) n = 'Sheet1';
    return n.length > 31 ? n.substring(0, 31) : n;
  }

  /// Builds an RTL xlsx file in the temp dir. Numbers become numeric cells.
  static Future<File> exportTable({
    required List<String> columns,
    required List<List<String>> rows,
    required String sheetName,
    String filePrefix = 'export',
  }) async {
    return _write(sheetName, <List<String>>[columns, ...rows], filePrefix);
  }

  static Future<File> _write(String sheetName, List<List<String>> all, String filePrefix) async {
    final Excel excel = Excel.createExcel();
    final String name = _sheetName(sheetName);
    final String def = excel.getDefaultSheet() ?? 'Sheet1';
    if (def != name) excel.rename(def, name);
    final Sheet sheet = excel[name];
    sheet.isRTL = true;
    for (final List<String> r in all) {
      final List<CellValue?> cells = <CellValue?>[];
      for (final String c in r) {
        final num? n = parseCell(c);
        if (n == null) {
          cells.add(TextCellValue(c));
        } else if (n is int) {
          cells.add(IntCellValue(n));
        } else {
          cells.add(DoubleCellValue(n.toDouble()));
        }
      }
      sheet.appendRow(cells);
    }
    final List<int>? bytes = excel.encode();
    if (bytes == null) throw Exception('ساخت فایل اکسل ناموفق بود');
    final Directory dir = await getTemporaryDirectory();
    final File f = File(p.join(dir.path, '${filePrefix}_${DateTime.now().millisecondsSinceEpoch}.xlsx'));
    await f.writeAsBytes(bytes);
    return f;
  }

  /// Windows: save dialog; other platforms: share sheet.
  static Future<void> saveOrShare(BuildContext context, File file) async {
    try {
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        final FileSaveLocation? loc = await getSaveLocation(
          suggestedName: p.basename(file.path),
          acceptedTypeGroups: <XTypeGroup>[
            const XTypeGroup(label: 'Excel', extensions: <String>['xlsx']),
          ],
        );
        if (loc == null) return;
        var path = loc.path;
        if (!path.toLowerCase().endsWith('.xlsx')) path = '$path.xlsx';
        await file.copy(path);
        if (context.mounted) snack(context, 'فایل اکسل ذخیره شد');
        return;
      }
      await sp.Share.shareXFiles(<sp.XFile>[
        sp.XFile(file.path, mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'),
      ]);
    } catch (e) {
      if (context.mounted) snack(context, 'خطا در خروجی اکسل: $e');
    }
  }

  /// Exports the table registered for [pdfPath] (the PDF just shown) and saves/shares it.
  static Future<void> exportFor(BuildContext context, String pdfPath) async {
    final _Tbl? t = _tables[pdfPath];
    if (t == null) {
      snack(context, 'برای این خروجی، اکسل در دسترس نیست');
      return;
    }
    try {
      final File f = await _write(t.title, t.rows, 'excel');
      if (context.mounted) await saveOrShare(context, f);
    } catch (e) {
      if (context.mounted) snack(context, 'خطا در ساخت اکسل: $e');
    }
  }
}

class _Tbl {
  final String title;
  final List<List<String>> rows;
  _Tbl(this.title, this.rows);
}
