import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pesteh_bazar/edit_guard.dart';

// فاز ۳ مجد — test/edit_guard_cases.json = کپی بایت‌به‌بایت backend/api/edit_guard_cases.json (PHP: edit_guard_selftest.php).
void main() {
  final Map<String, dynamic> doc = jsonDecode(File('test/edit_guard_cases.json').readAsStringSync()) as Map<String, dynamic>;

  test('conflict message', () => expect(kEditConflictMsg, doc['conflict_message']));

  test('same', () {
    final List<dynamic> cases = doc['same'] as List<dynamic>;
    for (int i = 0; i < cases.length; i++) {
      final List<dynamic> c = cases[i] as List<dynamic>;
      expect(editGuardSame(c[0], c[1]), c[2], reason: 'same#$i');
      expect(editGuardSame(c[1], c[0]), c[2], reason: 'same#$i swap');
    }
  });

  test('changed', () {
    final List<dynamic> cases = doc['changed'] as List<dynamic>;
    for (int i = 0; i < cases.length; i++) {
      final Map<String, dynamic> c = cases[i] as Map<String, dynamic>;
      expect(
        editGuardChanged(Map<String, Object?>.from(c['before'] as Map), Map<String, Object?>.from(c['after'] as Map), List<String>.from(c['fields'] as List)),
        List<String>.from(c['want'] as List),
        reason: 'changed#$i',
      );
    }
  });

  test('decide', () {
    final List<dynamic> cases = doc['decide'] as List<dynamic>;
    for (int i = 0; i < cases.length; i++) {
      final Map<String, dynamic> c = cases[i] as Map<String, dynamic>;
      expect(
        editGuardDecide(c['used'] as String?, List<String>.from(c['changed'] as List), List<String>.from(c['neutral'] as List),
            Map<String, String>.from(c['labels'] as Map)),
        c['want'],
        reason: 'decide#$i',
      );
    }
  });

  test('version', () {
    final List<dynamic> cases = doc['version'] as List<dynamic>;
    for (int i = 0; i < cases.length; i++) {
      final List<dynamic> c = cases[i] as List<dynamic>;
      expect(editGuardVersionOk(c[0], c[1] as int), c[2], reason: 'version#$i');
    }
  });

  test('conflict detection', () {
    expect(editGuardIsConflict(409, <String, dynamic>{'error': 'edit_conflict'}), isTrue);
    expect(editGuardIsConflict(409, <String, dynamic>{'error': 'در حال پردازش'}), isFalse);
  });
}
