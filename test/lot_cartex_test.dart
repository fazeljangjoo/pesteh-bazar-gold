import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pesteh_bazar/lot_cartex_calc.dart';

// مرحلهٔ ۱۱ — آینهٔ Dart کارتکس لات؛ همان test/lot_cartex_cases.json که lot_cartex_selftest.php (PHP) روی آن اجرا می‌شود.
List<Map<String, dynamic>> _ml(dynamic v) => [for (final x in (v as List)) Map<String, dynamic>.from(x as Map)];

Map<String, dynamic> _project(LotCartexReport r) => {
      'types': [
        for (final t in r.types)
          {
            'type_name': t.typeName,
            'total_kg': t.totalKg,
            'overview': [for (final x in t.overview) [x.party, x.weightKg, x.remainingKg, x.exitLabel]],
            'normal': [for (final x in t.normal) [x.party, x.weightKg, x.remainingKg, x.exitType, x.exitDate, x.ounce, x.gram]],
            'exited': [for (final x in t.exited) [x.party, x.weightKg, x.exitType, x.exitDate]],
            'kot': [
              for (final k in t.kot)
                {
                  'kot_id': k.kotId,
                  'total_kg': k.totalKg,
                  'color_key': k.colorKey,
                  'weight_kg': k.weightKg,
                  'ounce': k.ounce,
                  'gram': k.gram,
                  'items': [for (final x in k.items) [x.party, x.weightKg, x.ounce, x.gram, x.remainingKg]],
                }
            ],
            'processed': [
              for (final g in t.processed)
                {
                  'group_id': g.groupId,
                  'kind': g.kind,
                  'order_id': g.orderId,
                  'color_key': g.colorKey,
                  'in_kg': g.inKg,
                  'out_kg': g.outKg,
                  'items': [for (final x in g.items) [x.party, x.weightKg]],
                  'outputs': [for (final o in g.outputs) [o.code, o.weightKg, o.ounce, o.gram]],
                }
            ],
          }
      ],
    };

bool _eq(Object? a, Object? b, double tol) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !_eq(a[k], b[k], tol)) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_eq(a[i], b[i], tol)) return false;
    }
    return true;
  }
  if (a is num && b is num) return (a - b).abs() < tol;
  return a == b;
}

void main() {
  final doc = jsonDecode(File('test/lot_cartex_cases.json').readAsStringSync()) as Map<String, dynamic>;
  final tol = (doc['tol'] as num?)?.toDouble() ?? 1e-9;
  for (final dynamic c in doc['cases'] as List) {
    final m = c as Map<String, dynamic>;
    test('lot_cartex ${m['name']}', () {
      final o = m['opts'] as Map<String, dynamic>;
      final r = lotCartexBuild(_ml(m['lots']), _ml(m['mix_sources']), _ml(m['proc_inputs']), _ml(m['sale_items']),
          procOutputs: _ml(m['proc_outputs'] ?? const []),
          from: o['from'] as String, to: o['to'] as String, label: (o['label'] as String?) ?? '');
      final got = jsonDecode(jsonEncode(_project(r)));
      expect(_eq(got, m['expect'], tol), isTrue, reason: 'got: ${jsonEncode(got)}\nexp: ${jsonEncode(m['expect'])}');
    });
  }

  test('range_1405', () {
    final r = lotCartexRange(1405, 7, 1);
    expect(r.from, '2026-09-23');
    expect(r.to, '2027-09-22');
    expect(r.label, 'سال پسته‌ای ۱۴۰۵–۱۴۰۶');
  });

  test('start_year_of', () {
    expect(lotCartexStartYearOf('2026-09-23', 7, 1), 1405);
    expect(lotCartexStartYearOf('2026-09-22', 7, 1), 1404);
    expect(lotCartexStartYearOf('2027-09-22', 7, 1), 1405);
  });

  test('persian_sort', () {
    expect(persianCompareName('علي', 'علی'), 0);
    expect(persianCompareName('', 'الف'), greaterThan(0));
    expect(persianCompareName('احمد', 'بهرام'), lessThan(0));
    expect(persianCompareName('پور', 'تقی'), lessThan(0));
  });
}
