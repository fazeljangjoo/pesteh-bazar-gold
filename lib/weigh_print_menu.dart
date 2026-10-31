import 'package:flutter/material.dart';

import 'weigh_docs_pdf.dart' show WeighPaper;

/// S35.T35.13c/d: دکمهٔ چاپ با انتخاب قالب (A4 / A5 / رول ۸۰ میلی‌متری) برای رسید باسکول و بارنامه.
Widget weighPrintMenu(BuildContext context, String label, Future<void> Function(WeighPaper) onPick) {
  return PopupMenuButton<WeighPaper>(
    onSelected: (WeighPaper w) => onPick(w),
    itemBuilder: (_) => const <PopupMenuEntry<WeighPaper>>[
      PopupMenuItem<WeighPaper>(value: WeighPaper.a4, child: Text('A4')),
      PopupMenuItem<WeighPaper>(value: WeighPaper.a5, child: Text('A5')),
      PopupMenuItem<WeighPaper>(value: WeighPaper.roll80, child: Text('رول ۸۰ میلی‌متری')),
    ],
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(border: Border.all(color: Colors.grey), borderRadius: BorderRadius.circular(8)),
      child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
        const Icon(Icons.print_outlined, size: 18),
        const SizedBox(width: 6),
        Text('$label ▾'),
      ]),
    ),
  );
}
