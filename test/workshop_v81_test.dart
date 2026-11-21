import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pesteh_bazar/workshop_calc.dart';

// v81 — شکست (نشکن/پوست/ضایعات)، تقسیم بهای تولید و آبخندان، درجهٔ خروجی از دسته/نوع.
// test/workshop_v81_cases.json = خروجی مستقیم توابع PHP (backend/api/workshop_v81_cases.json، همان فایل).
void main() {
  final Map<String, dynamic> doc = jsonDecode(File('test/workshop_v81_cases.json').readAsStringSync()) as Map<String, dynamic>;
  const double tol = 1e-6;

  void near(Object? got, Object? want, String what) {
    if (want == null) {
      expect(got, isNull, reason: what);
    } else {
      expect(got, isA<num>(), reason: what);
      expect((got! as num).toDouble(), closeTo((want as num).toDouble(), tol), reason: what);
    }
  }

  num? n(dynamic v) => v as num?;

  for (final dynamic c in doc['crack'] as List<dynamic>) {
    final Map<String, dynamic> m = c as Map<String, dynamic>;
    test('crack: ${m['name']}', () {
      final Map<String, dynamic> i = m['input'] as Map<String, dynamic>;
      final Map<String, dynamic> e = m['expect'] as Map<String, dynamic>;
      final WsCrackResult r = wsCrackResult(
        inKg: n(i['in'])!,
        gram: n(i['gram']),
        kernelKg: n(i['kernel'])!,
        buyPerKg: n(i['buy']),
        crackCost: n(i['crack'])!,
        lineLoss: n(i['line']),
        uncrackedKg: n(i['uncr'])!,
        hullValue: n(i['hull'])!,
        outKg: n(i['out']),
      );
      near(r.initGram, e['init_gram'], 'init_gram');
      near(r.recvGram, e['recv_gram'], 'recv_gram');
      near(r.lossGram, e['loss_gram'], 'loss_gram');
      near(r.lossPct, e['loss_pct'], 'loss_pct');
      near(r.unitCost, e['unit_cost'], 'unit_cost');
      near(r.expectedKernelKg, e['expected_kernel_kg'], 'expected_kernel_kg');
      near(r.crackedKg, e['cracked_kg'], 'cracked_kg');
      near(r.lossKg, e['loss_kg'], 'loss_kg');
      near(r.expectedLossKg, e['expected_loss_kg'], 'expected_loss_kg');
      near(r.gramVsLine, e['gram_vs_line'], 'gram_vs_line');
      near(r.wasteKg, e['waste_kg'], 'waste_kg');
      near(r.uncrackedCost, e['uncracked_cost'], 'uncracked_cost');
    });
  }

  for (final dynamic c in doc['split'] as List<dynamic>) {
    final Map<String, dynamic> m = c as Map<String, dynamic>;
    test('split: ${m['name']}', () {
      final Map<String, dynamic> i = m['input'] as Map<String, dynamic>;
      final Map<String, dynamic> e = m['expect'] as Map<String, dynamic>;
      final WsSplit r = wsSplitCost(<Map<String, num?>>[
        for (final dynamic row in i['rows'] as List<dynamic>) <String, num?>{'kg': n((row as Map<String, dynamic>)['kg']), 'price': n(row['price'])},
      ], n(i['total'])!);
      final List<dynamic> lots = e['lots'] as List<dynamic>;
      expect(r.lots.length, lots.length);
      for (int k = 0; k < lots.length; k++) {
        near(r.lots[k], lots[k], 'lot $k');
      }
      near(r.residual, e['residual'], 'residual');
      near(r.priced, e['priced'], 'priced');
      near(r.unit, e['unit'], 'unit');
    });
  }

  test('grade from category/kind', () {
    for (final dynamic c in doc['grades'] as List<dynamic>) {
      final Map<String, dynamic> m = c as Map<String, dynamic>;
      expect(wsGradeFor(m['preset'] as String?, m['kind'] as String?), m['expect'], reason: '${m['preset']} / ${m['kind']}');
    }
  });
}
