import 'package:flutter/material.dart';

import 'perms.dart';
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;
import 'widgets.dart' show snack;

/// S31.T31.15b — restore drill UI (server actions backup_drill.run / .list / .status, perm settings.manage, online).
/// Non-destructive: the server validates a snapshot of the live data and stores a report.
/// Drilling a user-picked backup file (payload `tables`) is not offered: no file picker dependency in the app.

bool _canDrill() => StaffPerms.I.can('settings.manage');

String _fmtRun(dynamic v) {
  final String s = '${v ?? ''}';
  if (s.length < 10) return s;
  return '${jalaliDate(s.substring(0, 10))} ${toFaDigits(s.length >= 16 ? s.substring(11, 16) : '')}';
}

/// Orange banner shown when the monthly drill is due; tap opens [BackupDrillScreen]. Silent when offline/not allowed.
class BackupDrillDueBanner extends StatefulWidget {
  const BackupDrillDueBanner({super.key});

  @override
  State<BackupDrillDueBanner> createState() => _BackupDrillDueBannerState();
}

class _BackupDrillDueBannerState extends State<BackupDrillDueBanner> {
  bool _due = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_canDrill()) return;
    try {
      final Map<String, dynamic> r = await StockApi.call('backup_drill.status');
      if (mounted) setState(() => _due = r['due'] == true);
    } catch (_) {
      // offline or not allowed: no banner
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_due) return const SizedBox.shrink();
    return Card(
      color: Colors.orange.shade50,
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.warning_amber_rounded, color: Colors.orange),
        title: const Text('تمرین بازیابی پشتیبان این ماه انجام نشده است'),
        trailing: const Icon(Icons.chevron_left),
        onTap: () async {
          await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const BackupDrillScreen()));
          _load();
        },
      ),
    );
  }
}

class BackupDrillScreen extends StatefulWidget {
  const BackupDrillScreen({super.key});

  @override
  State<BackupDrillScreen> createState() => _BackupDrillScreenState();
}

class _BackupDrillScreenState extends State<BackupDrillScreen> {
  Map<String, dynamic> _status = <String, dynamic>{};
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  bool _busy = false;
  String? _error;
  Map<String, dynamic>? _last;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> st = await StockApi.call('backup_drill.status');
      final Map<String, dynamic> li = await StockApi.call('backup_drill.list', <String, dynamic>{'limit': 12});
      if (!mounted) return;
      setState(() {
        _status = st;
        _items = li['items'] is List ? <Map<String, dynamic>>[for (final dynamic e in li['items'] as List) if (e is Map) Map<String, dynamic>.from(e)] : <Map<String, dynamic>>[];
        _busy = false;
      });
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> r = await StockApi.call('backup_drill.run');
      if (!mounted) return;
      _last = r;
      snack(context, r['ok'] == true ? 'تمرین بازیابی موفق بود' : 'تمرین بازیابی ناموفق بود');
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final bool due = _status['due'] == true;
    final dynamic days = _status['days_since'];
    final Map<String, dynamic>? last = _last;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('تمرین بازیابی پشتیبان'), actions: <Widget>[IconButton(icon: const Icon(Icons.refresh), onPressed: _busy ? null : _load)]),
        body: ListView(padding: const EdgeInsets.all(12), children: <Widget>[
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: const TextStyle(color: Colors.red))),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                const Text('این تمرین از اطلاعات فعلی حساب یک نسخهٔ پشتیبان می‌سازد، سالم‌بودن و تطابق تعداد ردیف‌ها را بررسی می‌کند و گزارش ذخیره می‌کند. هیچ داده‌ای تغییر نمی‌کند. توصیه می‌شود ماهی یک‌بار انجام شود.'),
                const SizedBox(height: 8),
                Text(_status['last_run'] == null ? 'تا به حال انجام نشده است' : 'آخرین تمرین: ${_fmtRun(_status['last_run'])}${days is num ? ' (${toFaDigits('${days.toInt()}')} روز پیش)' : ''}',
                    style: TextStyle(fontWeight: FontWeight.w600, color: due ? Colors.orange.shade800 : null)),
                if (due) const Text('زمان تمرین ماهانه رسیده است', style: TextStyle(color: Colors.orange)),
              ]),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(onPressed: _busy || !_canDrill() ? null : _run, icon: const Icon(Icons.verified_outlined), label: const Text('اجرای تمرین بازیابی')),
          if (last != null)
            Card(
              color: last['ok'] == true ? Colors.green.shade50 : Colors.red.shade50,
              child: ListTile(
                leading: Icon(last['ok'] == true ? Icons.check_circle : Icons.error, color: last['ok'] == true ? Colors.green : Colors.red),
                title: Text(last['ok'] == true ? 'موفق' : 'ناموفق'),
                subtitle: Text('${toFaDigits('${last['total_rows'] ?? 0}')} ردیف در ${toFaDigits('${last['tables_count'] ?? 0}')} جدول'
                    '${last['error'] == null ? '' : '\n${last['error']}'}'),
              ),
            ),
          const SizedBox(height: 8),
          const Text('تاریخچه', style: TextStyle(fontWeight: FontWeight.w700)),
          if (_items.isEmpty && !_busy) const Padding(padding: EdgeInsets.all(16), child: Center(child: Text('هنوز گزارشی ثبت نشده'))),
          for (final Map<String, dynamic> it in _items)
            Card(
              child: ListTile(
                dense: true,
                leading: Icon((it['ok'] == 1 || it['ok'] == true || it['ok_bool'] == true) ? Icons.check_circle_outline : Icons.error_outline,
                    color: (it['ok_bool'] == true) ? Colors.green : Colors.red),
                title: Text(_fmtRun(it['run_at'])),
                subtitle: Text('${toFaDigits('${it['total_rows'] ?? 0}')} ردیف · ${toFaDigits('${it['tables_count'] ?? 0}')} جدول · ${toFaDigits('${it['duration_ms'] ?? 0}')} میلی‌ثانیه'
                    '${'${it['error'] ?? ''}'.isEmpty ? '' : '\n${it['error']}'}'),
              ),
            ),
        ]),
      ),
    );
  }
}
