// پسته‌بازار — ابزار بارکد مشترک (اندروید و ویندوز). بدون وابستگی به پلتفرم.
// قرارداد: محتوای بارکد فقط خود «کد پسته» است (KH… / MX…)؛ هیچ داده‌ای دیگر داخلش نیست.
// کد موقت آفلاین (N…) هرگز بارکد نمی‌شود.

import 'package:barcode_widget/barcode_widget.dart' as bw;
import 'package:flutter/material.dart';
import 'package:pdf/widgets.dart' as pw;

/// فقط کدهای واقعی انبار: KH / MX و حداقل ۳ رقم، یا کد خروجی جداسازی (K-…)
final RegExp kPrintableCode = RegExp(r'^((KH|MX)\d{3,}|K-(KH|MX)\d{3,}(-\d+)+|K\d+-\d+)$'); // + separation output codes (K-KH00012-1, K-KH00012-1-2)

bool isPrintableCode(String? c) => c != null && kPrintableCode.hasMatch(c);

/// ارقام فارسی و عربی را به لاتین تبدیل می‌کند
String _toLatinDigits(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    if (r >= 0x06F0 && r <= 0x06F9) {
      b.writeCharCode(0x30 + r - 0x06F0);
    } else if (r >= 0x0660 && r <= 0x0669) {
      b.writeCharCode(0x30 + r - 0x0660);
    } else {
      b.writeCharCode(r);
    }
  }
  return b.toString();
}

/// S31.T31.9: محتوای QR روی لات/فاکتور = «PB:L:<کد پسته>»؛ بارکد Code128 همچنان فقط خود کد است.
const String kQrLotPrefix = 'PB:L:';

/// محتوای QR یک لات؛ null برای کد غیرقابل‌چاپ (مثلاً کد موقت آفلاین).
String? lotQrPayload(String? code) {
  final String? c = code == null ? null : normalizeScan(code);
  return c == null ? null : '$kQrLotPrefix$c';
}

/// پاک‌سازی ورودی اسکن/تایپ. فقط اگر کد قابل‌چاپ باشد برمی‌گرداند؛ وگرنه null.
/// QR با پیشوند «PB:L:» هم پذیرفته می‌شود.
String? normalizeScan(String raw) {
  String r = raw.trim();
  if (r.toUpperCase().startsWith(kQrLotPrefix)) r = r.substring(kQrLotPrefix.length);
  final String up = _toLatinDigits(r.toUpperCase());
  final String withDash = up.replaceAll(RegExp(r'[^A-Z0-9-]'), '');
  if (isPrintableCode(withDash)) return withDash;
  final String plain = up.replaceAll(RegExp(r'[^A-Z0-9]'), '');
  return isPrintableCode(plain) ? plain : null;
}

/// کدهای قابل‌چاپ یک رشته (مثلاً «KH00012، MX00003» برای فروش چندقلمی): یکتا و حداکثر ۴ تا
List<String> printableCodesIn(String? s) {
  final out = <String>[];
  if (s == null || s.isEmpty) return out;
  for (final part in s.split(RegExp('[،,]'))) {
    final c = normalizeScan(part);
    if (c == null || out.contains(c)) continue;
    out.add(c);
    if (out.length >= 4) break;
  }
  return out;
}

/// بارکد Code128 برای PDF (با متن کد زیر میله‌ها، چپ‌به‌راست)
pw.Widget pdfBarcode(String code, {double height = 38, double width = 150}) {
  return pw.Directionality(
    textDirection: pw.TextDirection.ltr,
    child: pw.BarcodeWidget(
      barcode: pw.Barcode.code128(),
      data: code,
      width: width,
      height: height,
      drawText: true,
      textStyle: pw.TextStyle(fontSize: 9),
    ),
  );
}

/// متن کوچک برای کدهای آفلاین (بدون بارکد)
pw.Widget pdfBarcodeNote() => pw.Text(
      'بارکد بعد از همگام‌سازی ساخته می‌شود'.replaceAll('‌', ' '),
      style: pw.TextStyle(fontSize: 8),
    );

/// بارکد روی صفحه (Flutter): روی زمینهٔ سفید با گوشهٔ گرد. کد غیرقابل‌چاپ → متن کم‌رنگ.
/// فقط کد پسته داخل بارکد است.
class BarcodeBox extends StatelessWidget {
  const BarcodeBox(this.code, {super.key, this.height = 64});

  final String code;
  final double height;

  @override
  Widget build(BuildContext context) {
    final printable = isPrintableCode(code);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: printable
          ? Center(
              child: bw.BarcodeWidget(
                barcode: bw.Barcode.code128(),
                data: code,
                drawText: true,
                width: 240,
                height: height,
                style: const TextStyle(color: Colors.black, fontSize: 13),
              ),
            )
          : const Text(
              'بارکد بعد از همگام‌سازی ساخته می‌شود',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black45, fontSize: 12),
            ),
    );
  }
}
