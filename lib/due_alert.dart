import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_lock.dart';
import 'db.dart';
import 'dues_screen.dart';
import 'ledger.dart';
import 'utils.dart';

/// ویندوز اعلان سیستمیِ زمان‌بندی‌شده ندارد؛ به‌جایش هنگام باز بودن برنامه، روزی یک‌بار
/// (و هر بار که برنامه باز می‌شود) سررسیدهای امروز، فردا و عقب‌افتاده را در یک پنجره نشان می‌دهد.
/// روی گوشی هیچ کاری نمی‌کند (آنجا اعلان‌های معمول فعال است).
class DueAlertHost extends StatefulWidget {
  final Widget child;
  const DueAlertHost({super.key, required this.child});
  @override
  State<DueAlertHost> createState() => _DueAlertHostState();
}

class _DueAlertHostState extends State<DueAlertHost> {
  static const _kDayKey = 'due_alert_day';
  Timer? _timer;
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _check());
      _timer = Timer.periodic(const Duration(hours: 1), (_) => _check());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _today() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  Future<void> _check() async {
    if (!mounted || _showing || !AppDb.I.hasAccount || AppLock.I.locked.value) return;
    try {
      final sp = await SharedPreferences.getInstance();
      final key = '$_kDayKey:${AppDb.I.phone}';
      if (sp.getString(key) == _today()) return;
      final dues = await loadDues();
      final soon = dues.where((d) => !d.paid && daysUntil(d.date) <= 1).toList()
        ..sort((a, b) => a.date.compareTo(b.date));
      if (soon.isEmpty || !mounted) return;
      await sp.setString(key, _today());
      _showing = true;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('⏰ سررسیدهای نزدیک'),
          content: SizedBox(
            width: 420,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final d in soon.take(12))
                  ListTile(
                    dense: true,
                    leading: Icon(d.receivable ? Icons.south_west : Icons.north_east,
                        color: d.receivable ? Colors.green.shade700 : Colors.red.shade700),
                    title: Text('${d.kind} ${d.receivable ? 'دریافتی' : 'پرداختی'} — ${faNum(d.amount, dec: 0)} ریال'),
                    subtitle: Text('${d.party.isEmpty ? '' : '${d.party} · '}${dueWhen(d.date)}'),
                  ),
                if (soon.length > 12) Text('و ${faNum(soon.length - 12, dec: 0)} مورد دیگر…'),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('بستن')),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                Navigator.push(context, MaterialPageRoute(builder: (_) => const DuesScreen()));
              },
              child: const Text('مشاهدهٔ سررسیدها'),
            ),
          ],
        ),
      );
    } catch (_) {
      // هشدار اختیاری است؛ خطا نباید برنامه را مختل کند
    } finally {
      _showing = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
