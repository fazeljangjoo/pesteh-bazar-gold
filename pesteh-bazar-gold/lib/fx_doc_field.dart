// S27c.T27b.1/T27b.2 — shared foreign-currency fields for the sale and purchase forms.
//
// Rules (docs/FX_CONTRACT.md, "سیاست نرخ"):
//  * There is NO manual dollar-rate field any more. The rate is read from the local cache of `fx_rates`
//    (rial per one unit of the currency, latest rate on or before the document date) and is DISPLAY-ONLY.
//  * The document stores ccy + price_ccy + offline_rate (+ offline_rate_at). The server keeps that rate
//    (fx_rate_source = 'offline'); sync never changes it silently.
//  * No cached rate for the currency on that date => the document cannot be saved (user must sync / register a rate).
import 'package:flutter/material.dart';

import 'db.dart';
import 'fx_local.dart';
import 'utils.dart';
import 'widgets.dart';

/// Rials per ONE stored money unit of the local mirror: 10 while the mirror is still toman (legacy), 1 once rial (S29.T29.3).
/// Always read at use time (never cache): the unit flips when the mirror migrates.
double get kFxRialPerStoredUnit => AppDb.I.moneyUnit == 'rial' ? 1.0 : 10.0;

class FxDocController {
  /// null = rial document (no currency).
  String? ccy;
  final TextEditingController priceCcy = TextEditingController();
  List<Map<String, dynamic>> currencies = <Map<String, dynamic>>[];
  ({double rate, String date})? rate;

  /// Document date used to pick the rate (yyyy-MM-dd).
  String dateIso = fxIsoDate(DateTime.now());

  bool get active => ccy != null;

  double? get priceCcyNum {
    final double? v = parseNum(priceCcy.text);
    return (v == null || v <= 0) ? null : v;
  }

  int get decimals {
    for (final Map<String, dynamic> c in currencies) {
      if (c['code'] == ccy) return (c['decimals'] as num?)?.toInt() ?? 2;
    }
    return 2;
  }

  String get symbol {
    for (final Map<String, dynamic> c in currencies) {
      if (c['code'] == ccy) {
        final String s = (c['symbol'] ?? '').toString();
        return s.isEmpty ? (ccy ?? '') : s;
      }
    }
    return ccy ?? '';
  }

  /// Per-unit price in the local stored unit (toman until S29) = price_ccy * rate / 10, or null when incomplete.
  double? get priceStored {
    final double? p = priceCcyNum;
    final ({double rate, String date})? r = rate;
    if (!active || p == null || r == null) return null;
    return (p * r.rate / kFxRialPerStoredUnit * 100).roundToDouble() / 100;
  }

  int? get rateAgeDays => rate == null ? null : FxLocal.ageDays(rate!.date);

  Future<void> load() async {
    final List<Map<String, dynamic>> all = await FxLocal.loadCurrencies();
    currencies = all.where((Map<String, dynamic> c) => c['active'] == true && c['is_base'] != true).toList();
  }

  Future<void> resolveRate() async {
    final String? c = ccy;
    rate = c == null ? null : await FxLocal.rateAt(c, dateIso);
  }

  /// Restores state from a saved local row (edit view / read-only).
  void setFrom(Map<String, dynamic> row, double netKg) {
    final String? c = row['ccy'] as String?;
    ccy = (c == null || c.isEmpty) ? null : c;
    final double? fr = (row['fx_rate'] as num?)?.toDouble();
    if (ccy != null && fr != null) {
      rate = (rate: fr, date: ((row['fx_rate_entered_at'] ?? '') as String).split('T').first);
    }
    final double? pc = (row['price_ccy'] as num?)?.toDouble() ??
        (((row['total_ccy'] as num?)?.toDouble() != null && netKg > 0) ? (row['total_ccy'] as num).toDouble() / netKg : null);
    if (pc != null) priceCcy.text = plain(pc);
  }

  /// null = OK, otherwise a Persian message to show.
  String? validate() {
    if (!active) return null;
    if (priceCcyNum == null) return 'فی ارزی را وارد کنید';
    if (rate == null) {
      return 'برای $ccy نرخی در دستگاه ثبت نیست؛ نرخ را در «نرخ ارز» ثبت کنید و همگام‌سازی را بزنید';
    }
    return null;
  }

  /// Keys merged into the data map given to AppDb.insertSale/insertPurchase.
  Map<String, dynamic> fields() {
    if (!active) return <String, dynamic>{};
    return <String, dynamic>{
      'ccy': ccy,
      'price_ccy': priceCcyNum,
      'offline_rate': rate?.rate,
      'offline_rate_at': DateTime.now().toIso8601String(),
    };
  }

  void dispose() => priceCcy.dispose();
}

/// Currency picker + foreign unit price + read-only rate line.
class FxDocFields extends StatelessWidget {
  final FxDocController c;
  final String priceLabel;
  final VoidCallback onChanged;
  const FxDocFields({super.key, required this.c, required this.priceLabel, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<Widget> w = <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DropdownButtonFormField<String?>(
          value: c.ccy,
          decoration: const InputDecoration(labelText: 'ارز سند', border: OutlineInputBorder()),
          items: <DropdownMenuItem<String?>>[
            const DropdownMenuItem<String?>(value: null, child: Text('ریال')),
            for (final Map<String, dynamic> cur in c.currencies)
              DropdownMenuItem<String?>(value: cur['code'] as String, child: Text('${cur['name'] ?? ''} (${cur['code']})')),
          ],
          onChanged: (String? v) async {
            c.ccy = v;
            await c.resolveRate();
            onChanged();
          },
        ),
      ),
    ];
    if (c.active) {
      w.add(numField(c.priceCcy, '$priceLabel (${c.symbol})', required: true, onChanged: onChanged));
      final ({double rate, String date})? r = c.rate;
      if (r == null) {
        w.add(Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text('نرخ ${c.ccy} برای این تاریخ در دستگاه نیست؛ ابتدا نرخ را ثبت و همگام کنید.',
              style: TextStyle(color: scheme.error)),
        ));
      } else {
        w.add(infoRow('نرخ سند (فقط نمایش)', '${faNum(r.rate, dec: 0)} ریال'));
        w.add(infoRow('تاریخ نرخ', jalaliDate(r.date)));
        final int age = c.rateAgeDays ?? 0;
        if (age >= FxLocal.staleAfterDays) {
          w.add(Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('هشدار: این نرخ $age روز قدیمی است', style: TextStyle(color: scheme.error)),
          ));
        }
        w.add(const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text('نرخ همین‌جا برای سند ثابت می‌شود و همگام‌سازی آن را تغییر نمی‌دهد.',
              style: TextStyle(color: Colors.black54, fontSize: 12)),
        ));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: w);
  }
}
