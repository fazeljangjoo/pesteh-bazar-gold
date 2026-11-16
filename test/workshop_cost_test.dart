import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pesteh_bazar/workshop_calc.dart';

// مرحلهٔ ۵ — کیس‌های مشترک بهای کارگاه (همان backend: workshop_selftest.php؛ فایل test/workshop_cost_cases.json).
void main() {
  final Map<String, dynamic> doc = jsonDecode(File('test/workshop_cost_cases.json').readAsStringSync()) as Map<String, dynamic>;
  const double tol = 1e-6;

  for (final dynamic c in doc['cases'] as List<dynamic>) {
    final Map<String, dynamic> m = c as Map<String, dynamic>;
    test(m['name'] as String, () {
      final List<Map<String, Object?>> outs = <Map<String, Object?>>[
        for (final dynamic o in m['outs'] as List<dynamic>)
          <String, Object?>{'grade': (o as Map)['grade'], 'kg': o['kg'], 'price': o['price']},
      ];
      final Map<String, num> byGrade = <String, num>{};
      for (final Map<String, Object?> o in outs) {
        final String g = o['grade'] as String;
        byGrade[g] = (byGrade[g] ?? 0) + (o['kg'] as num);
      }
      final Map<String, dynamic> p = m['prices'] as Map<String, dynamic>;
      final Map<String, num> pr = <String, num>{
        'buy_per_kg': p['buy_per_kg'] as num,
        'wage_per_kg': p['wage_per_kg'] as num,
        'other_cost': p['other_cost'] as num,
      };
      final Map<String, dynamic> e = m['expect'] as Map<String, dynamic>;

      final WsBalance b = wsBalance(inputKg: m['input_kg'] as num, out: byGrade, lossKg: m['loss_kg'] as num);
      expect(b.ok, e['balance_ok'], reason: 'balance');
      expect(b.diffKg, closeTo((e['diff_kg'] as num).toDouble(), tol));

      final WsCost cost = wsCost(inputKg: m['input_kg'] as num, out: byGrade, pr: pr, outs: outs);
      expect(cost.valueIn, closeTo((e['value_in'] as num).toDouble(), tol));
      expect(cost.costTotal, closeTo((e['cost_total'] as num).toDouble(), tol));
      expect(cost.recoveryValue, closeTo((e['recovery_value'] as num).toDouble(), tol));
      expect(cost.costSound, closeTo((e['cost_sound'] as num).toDouble(), tol));
      if (e['cost_per_kg_sound'] == null) {
        expect(cost.costPerKgSound, isNull);
      } else {
        expect(cost.costPerKgSound, closeTo((e['cost_per_kg_sound'] as num).toDouble(), tol));
      }
      expect(cost.warning, e['warning']);

      final List<double> lots = wsAlloc(outs, pr, cost);
      final List<dynamic> want = e['lots'] as List<dynamic>;
      expect(lots.length, want.length);
      for (int i = 0; i < lots.length; i++) {
        expect(lots[i], closeTo((want[i] as num).toDouble(), tol), reason: 'lot $i');
      }

      if (m['legacy_same'] == true) {
        final Map<String, num> legacy = <String, num>{
          ...pr,
          for (final Map<String, Object?> o in outs)
            if (kWsPriceKeys.containsKey(o['grade'])) kWsPriceKeys[o['grade']]!: (o['price'] ?? 0) as num,
        };
        final WsCost old = wsCost(inputKg: m['input_kg'] as num, out: byGrade, pr: legacy);
        expect(old.costSound, closeTo(cost.costSound, tol));
        expect(old.recoveryValue, closeTo(cost.recoveryValue, tol));
      }
    });
  }
}
