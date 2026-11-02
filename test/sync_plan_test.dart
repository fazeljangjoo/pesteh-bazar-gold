import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pesteh_bazar/sync_plan.dart';

// S7.T4 — منطق خالصِ همگام‌سازی لحظه‌ای (همان test/sync_plan_cases.json که معادل JS هم روی آن اجرا شده).
void main() {
  final Map<String, dynamic> j = jsonDecode(File('test/sync_plan_cases.json').readAsStringSync()) as Map<String, dynamic>;
  final Set<String> known = (j['known'] as List<dynamic>).map((dynamic e) => e as String).toSet();

  for (final dynamic c in j['plans'] as List<dynamic>) {
    final Map<String, dynamic> m = c as Map<String, dynamic>;
    test(m['name'] as String, () {
      final SyncPlan p = SyncPlanner.plan(
        changes: (m['changes'] as List<dynamic>).map((dynamic e) => SyncChange.fromJson(e as Map<dynamic, dynamic>)).toList(),
        reset: m['reset'] as bool,
        ownKeys: (m['own'] as List<dynamic>).map((dynamic e) => e as String).toList(),
        isKnownEntity: known.contains,
      );
      expect(p.fullPull, m['full']);
      expect(p.entities.toList()..sort(), (m['entities'] as List<dynamic>).cast<String>());
      expect(p.consumedOwn.length, m['consumed']);
      expect(p.foreignCount, m['foreign']);
    });
  }

  for (final dynamic c in j['backoff'] as List<dynamic>) {
    final Map<String, dynamic> m = c as Map<String, dynamic>;
    test('backoff poll=${m['poll']} fail=${m['fail']}', () {
      expect(SyncPlanner.nextDelaySec(pollSec: m['poll'] as int, failStreak: m['fail'] as int), m['expect']);
    });
  }

  test('keyOf / entityOfOwn follow the server rule', () {
    expect(SyncPlanner.entityOfOwn('entity.save', <String, dynamic>{'entity': 'warehouses'}), 'warehouses');
    expect(SyncPlanner.entityOfOwn('intake.submit', <String, dynamic>{}), 'lot_intakes');
    expect(SyncPlanner.entityOfOwn('purchases.create', <String, dynamic>{}), 'purchases');
    expect(SyncPlanner.keyOf('sales.create', 'sales'), 'sales.create|sales');
  });
}
