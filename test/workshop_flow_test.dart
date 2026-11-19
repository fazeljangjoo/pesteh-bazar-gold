import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pesteh_bazar/lot_cartex_calc.dart';
import 'package:pesteh_bazar/workshop_calc.dart';

// فاز ۲ مجد — «کارگاه مرحله‌ای». test/workshop_flow_cases.json = کپی بایت‌به‌بایت backend/api/workshop_flow_cases.json (PHP: workshop_flow_selftest.php).
void main() {
  final Map<String, dynamic> doc = jsonDecode(File('test/workshop_flow_cases.json').readAsStringSync()) as Map<String, dynamic>;
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

  for (final dynamic sc in doc['scenarios'] as List<dynamic>) {
    final Map<String, dynamic> m = sc as Map<String, dynamic>;
    test(m['name'] as String, () {
      Map<String, dynamic> s = <String, dynamic>{};
      final List<dynamic> steps = m['steps'] as List<dynamic>;
      for (int i = 0; i < steps.length; i++) {
        final Map<String, dynamic> step = steps[i] as Map<String, dynamic>;
        if (step['set'] != null) s = <String, dynamic>{...s, ...Map<String, dynamic>.from(step['set'] as Map)};
        final WsFlowStep r = wsFlowApply(s, step['action'] as String, Map<String, dynamic>.from(step['payload'] as Map));
        s = r.state;
        final WsBalance t = wsFlowTotals(s);
        final Map<String, Object?> got = <String, Object?>{
          'error': r.error,
          'status': s['status'],
          'inputs': (s['inputs'] as List<dynamic>).length,
          'outputs': (s['outputs'] as List<dynamic>).length,
          'input_kg': t.inputKg,
          'output_kg': t.inputKg - t.lossKg,
          'loss_kg': t.lossKg,
          'loss_pct': t.lossPct,
          'sound_pct': t.soundPct,
          'over_output': t.overOutput,
        };
        if (r.error != null) expect(kWsFlowErrors.containsKey(r.error), isTrue, reason: 'unknown code ${r.error}');
        for (final MapEntry<String, dynamic> e in (step['expect'] as Map<String, dynamic>).entries) {
          expect(got.containsKey(e.key), isTrue, reason: 'no value for ${e.key}');
          near(got[e.key], e.value, '#$i ${step['action']} ${e.key}');
        }
      }
    });
  }

  test('wsFlowApply ورودی را تغییر نمی‌دهد (نمای آفلاین روی کش)', () {
    final Map<String, dynamic> base = <String, dynamic>{
      'status': 'open',
      'inputs': <Map<String, dynamic>>[<String, dynamic>{'uid': 'a', 'kg': 10}],
      'outputs': <Map<String, dynamic>>[],
    };
    final WsFlowStep r = wsFlowApply(base, 'output_save', <String, dynamic>{'order_uid': 'o', 'uid': 'x', 'grade': 'sound', 'kg': 4, 'owner': 'مجد'});
    expect((base['outputs'] as List<dynamic>).length, 0);
    final Map<String, dynamic> row = (r.state['outputs'] as List<dynamic>).first as Map<String, dynamic>;
    expect(row['owner'], 'مجد');
    expect(row.containsKey('order_uid'), isFalse);
  });

  test('کارتکس لات: عملیات باز = «در کارگاه»', () {
    final Map<String, dynamic> c = doc['cartex_open'] as Map<String, dynamic>;
    final LotCartexReport rep = lotCartexBuild(
      <Map<String, dynamic>>[for (final dynamic x in c['lots'] as List<dynamic>) Map<String, dynamic>.from(x as Map)],
      const <Map<String, dynamic>>[],
      <Map<String, dynamic>>[for (final dynamic x in c['proc_inputs'] as List<dynamic>) Map<String, dynamic>.from(x as Map)],
      const <Map<String, dynamic>>[],
      from: '0000-00-00',
      to: '9999-12-31',
    );
    final Map<String, dynamic> e = c['expect'] as Map<String, dynamic>;
    final LotCartexProcGroup g = rep.types.first.processed.first;
    expect(g.label, e['label']);
    expect(g.inWorkshop, e['in_workshop']);
    near(g.inKg, e['in_kg'], 'in_kg');
    near(g.outKg, e['out_kg'], 'out_kg');
    expect(rep.types.first.overview.first.exitLabel, e['overview_label']);
  });
}
