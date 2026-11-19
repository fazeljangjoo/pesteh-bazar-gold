import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pesteh_bazar/workshop_calc.dart';

// کیس‌های مشترک کارگاه داخلی (تراز + بها؛ فاز ۱ مجد: افت خودکار، V از لات‌های ورودی، چفت/دهنبست).
// test/workshop_cases.json = کپی بایت‌به‌بایت backend/api/workshop_cases.json (PHP: workshop_selftest.php).
// کلیدهای expect که غایب‌اند بررسی نمی‌شوند؛ کیس بدون prices فقط تراز را می‌سنجد.
void main() {
  final Map<String, dynamic> doc = jsonDecode(File('test/workshop_cases.json').readAsStringSync()) as Map<String, dynamic>;
  const double tol = 1e-6;

  void near(Object? got, Object? want, String what) {
    if (want == null) {
      expect(got, isNull, reason: what);
    } else if (want is num) {
      expect(got, isA<num>(), reason: what);
      expect((got! as num).toDouble(), closeTo(want.toDouble(), tol), reason: what);
    } else {
      expect(got, want, reason: what);
    }
  }

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
      final Map<String, dynamic> e = m['expect'] as Map<String, dynamic>;
      final Map<String, Object?> got = <String, Object?>{};

      // افت همیشه خودکار است؛ payload_loss_kg عمداً داده نمی‌شود.
      final WsBalance b = wsBalance(inputKg: m['input_kg'] as num, out: byGrade, initialKg: m['initial_kg'] as num?);
      expect(wsAutoLossGrams(inputKg: m['input_kg'] as num, out: byGrade), wsGrams(b.lossKg), reason: 'auto loss grams');
      got.addAll(<String, Object?>{
        'balance_ok': b.ok,
        'over_output': b.overOutput,
        'diff_kg': b.diffKg,
        'loss_kg': b.lossKg,
        'loss_pct': b.lossPct,
        'sound_pct': b.soundPct,
        'undelivered_kg': b.undeliveredKg,
        'label': b.label,
      });

      Map<String, num>? pr;
      if (m['prices'] != null) {
        final Map<String, dynamic> p = m['prices'] as Map<String, dynamic>;
        pr = <String, num>{for (final MapEntry<String, dynamic> x in p.entries) x.key: x.value as num};
      }
      if (m['input_lots'] != null) {
        final WsInputCost ic = wsInputCost(<Map<String, Object?>>[
          for (final dynamic l in m['input_lots'] as List<dynamic>) Map<String, Object?>.from(l as Map),
        ]);
        got['buy_per_kg'] = ic.buyPerKg;
        got['input_cost_warning'] = ic.warning;
        if (pr != null) pr['buy_per_kg'] = ic.buyPerKg ?? 0;
      }

      if (pr != null) {
        final WsCost cost = wsCost(inputKg: m['input_kg'] as num, out: byGrade, pr: pr, outs: outs);
        got.addAll(<String, Object?>{
          'value_in': cost.valueIn,
          'cost_total': cost.costTotal,
          'recovery_value': cost.recoveryValue,
          'cost_sound': cost.costSound,
          'cost_per_kg_sound': cost.costPerKgSound,
          'warning': cost.warning,
        });
        if (e['lots'] != null) {
          final List<double> lots = wsAlloc(outs, pr, cost);
          final List<dynamic> want = e['lots'] as List<dynamic>;
          expect(lots.length, want.length, reason: 'lots count');
          for (int i = 0; i < lots.length; i++) {
            near(lots[i], want[i], 'lot $i');
          }
        }
        if (m['legacy_same'] == true) {
          final Map<String, num> legacy = <String, num>{
            ...pr,
            for (final Map<String, Object?> o in outs)
              if (kWsPriceKeys.containsKey(o['grade'])) kWsPriceKeys[o['grade']]!: (o['price'] ?? 0) as num,
          };
          final WsCost old = wsCost(inputKg: m['input_kg'] as num, out: byGrade, pr: legacy);
          expect(old.costSound, closeTo(cost.costSound, tol), reason: 'legacy cost_sound');
          expect(old.recoveryValue, closeTo(cost.recoveryValue, tol), reason: 'legacy recovery_value');
        }
      }

      for (final MapEntry<String, dynamic> x in e.entries) {
        if (x.key == 'lots') continue;
        expect(got.containsKey(x.key), isTrue, reason: 'no value for ${x.key}');
        near(got[x.key], x.value, x.key);
      }
    });
  }

  test('wsumInternal: چفت، دهنبست و سایر جزو P (تراز با افت ذخیره‌شده)', () {
    final Map<String, double?> s = wsumInternal(<Map<String, dynamic>>[
      <String, dynamic>{'input_kg': 1000, 'loss_kg': 20, 'sound_kg': 800, 'chaft_kg': 60, 'dombest_kg': 40, 'hull_kg': 50, 'kernel_kg': 20, 'soil_kg': 10},
      <String, dynamic>{'input_kg': 100, 'loss_kg': 6, 'sound_kg': 75, 'deformed_fine_kg': 5, 'hull_kg': 6, 'kernel_kg': 3, 'soil_kg': 1, 'other_kg': 4},
    ]);
    expect(s['diff_kg'], closeTo(0, tol));
    expect(s['check_count'], 0);
    expect(s['chaft_kg'], closeTo(60, tol));
    expect(s['dombest_kg'], closeTo(40, tol));
    expect(s['other_kg'], closeTo(4, tol));
    expect(s['waste_total_kg'], closeTo(225, tol));
  });
}
