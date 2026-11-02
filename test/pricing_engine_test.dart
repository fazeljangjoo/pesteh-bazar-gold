import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pesteh_bazar/pricing_engine.dart';

// S6.T1 — همان tests/pricing_cases.json سرور (کپی بایت‌به‌بایت در test/pricing_cases.json).
void main() {
  final List<dynamic> cases = jsonDecode(File('test/pricing_cases.json').readAsStringSync()) as List<dynamic>;

  for (final dynamic c in cases) {
    final Map<String, dynamic> m = c as Map<String, dynamic>;
    test(m['name'] as String, () {
      final PriceBlendResult r = priceBlend(Map<String, dynamic>.from(m['in'] as Map));
      if (m.containsKey('error')) {
        expect(r.ok, isFalse);
        expect(r.error, m['error']);
      } else {
        expect(r.ok, isTrue, reason: r.error);
        expect(r.avgPerKg, m['avg_per_kg']);
        expect(r.total, m['total']);
      }
    });
  }

  test('خطوط خروجی: eff_q حالت گرمی', () {
    final PriceBlendResult r = priceBlend(<String, dynamic>{
      'base_price': 31000000,
      'weight_kg': 100,
      'items': <dynamic>[
        <String, dynamic>{'pct': 20, 'q': 28000000, 'gram_mode': true, 'g': 45},
      ],
    });
    expect(r.lines.single.effQ, closeTo(25200000, 1e-6));
    expect(r.lines.single.gramMode, isTrue);
  });

  test('q رشته‌ای عددی مثل PHP پذیرفته می‌شود', () {
    final PriceBlendResult r = priceBlend(<String, dynamic>{
      'base_price': '31000000',
      'weight_kg': '100',
      'items': <dynamic>[<String, dynamic>{'pct': '20', 'q': '28000000'}],
    });
    expect(r.avgPerKg, 30400000);
  });
}
