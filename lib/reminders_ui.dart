import 'package:flutter/material.dart';

import 'backup_drill_ui.dart' show BackupDrillDueBanner;
import 'fmt.dart' show Fmt;
import 'notify_service.dart';
import 'perms.dart';
import 'utils.dart';
import 'widgets.dart' show snack;
import 'warehouse_ui.dart' show StockApi, StockApiException;

/// S31.T31.14b — reminder center (reminders.due {days, overdue}, perm dues.view, all editions, online).
/// Items: {kind, title, party, amount, due_date, days_left, overdue, ref, note?}. SMS reminders intentionally not done (quota/cost).

const Map<String, String> _kKindFa = <String, String>{
  'cheque_received': 'چک دریافتی',
  'cheque_issued': 'چک پرداختی',
  'receivable_inst': 'قسط مطالبات',
  'payable_inst': 'قسط بدهی',
  'lc': 'اعتبار اسنادی',
};

const Map<String, IconData> _kKindIcon = <String, IconData>{
  'cheque_received': Icons.call_received,
  'cheque_issued': Icons.call_made,
  'receivable_inst': Icons.arrow_circle_down_outlined,
  'payable_inst': Icons.arrow_circle_up_outlined,
  'lc': Icons.description_outlined,
};

/// AppBar bell with the overdue count badge; loads once (silently ignores errors / offline).
class ReminderBell extends StatefulWidget {
  const ReminderBell({super.key});

  @override
  State<ReminderBell> createState() => _ReminderBellState();
}

class _ReminderBellState extends State<ReminderBell> {
  int _overdue = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!StaffPerms.I.can('dues.view')) return;
    try {
      final Map<String, dynamic> r = await StockApi.call('reminders.due', <String, dynamic>{'days': 0, 'overdue': true});
      if (mounted) setState(() => _overdue = (r['overdue_count'] as num?)?.toInt() ?? 0);
    } catch (_) {
      // offline or not allowed: the bell just shows no badge
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!StaffPerms.I.can('dues.view')) return const SizedBox.shrink();
    return IconButton(
      tooltip: 'مرکز یادآوری',
      icon: Badge(isLabelVisible: _overdue > 0, label: Text(toFaDigits('$_overdue')), child: const Icon(Icons.notifications_outlined)),
      onPressed: () async {
        await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const ReminderCenterScreen()));
        _load();
      },
    );
  }
}

class ReminderCenterScreen extends StatefulWidget {
  const ReminderCenterScreen({super.key});

  @override
  State<ReminderCenterScreen> createState() => _ReminderCenterScreenState();
}

class _ReminderCenterScreenState extends State<ReminderCenterScreen> {
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  int _days = 7;
  bool _overdue = true;
  int _overdueCount = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> r = await StockApi.call('reminders.due', <String, dynamic>{'days': _days, 'overdue': _overdue});
      if (!mounted) return;
      setState(() {
        _items = r['items'] is List ? <Map<String, dynamic>>[for (final dynamic e in r['items'] as List) if (e is Map) Map<String, dynamic>.from(e)] : <Map<String, dynamic>>[];
        _overdueCount = (r['overdue_count'] as num?)?.toInt() ?? 0;
        _loading = false;
      });
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _syncNotifications() async {
    try {
      await NotifyService.I.rescheduleAll();
      if (mounted) snack(context, 'یادآوری‌های دستگاه به‌روز شد');
    } catch (e) {
      if (mounted) snack(context, 'خطا در به‌روزرسانی یادآوری‌ها');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('مرکز یادآوری'), actions: <Widget>[
          IconButton(tooltip: 'به‌روزرسانی یادآوری‌های دستگاه', icon: const Icon(Icons.notifications_active_outlined), onPressed: _syncNotifications),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ]),
        body: Column(children: <Widget>[
          if (_loading) const LinearProgressIndicator(),
          const BackupDrillDueBanner(),
          if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: const TextStyle(color: Colors.red))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: <Widget>[
              for (final int d in <int>[7, 14, 30])
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: ChoiceChip(label: Text('${toFaDigits('$d')} روز'), selected: _days == d, onSelected: (_) {
                    _days = d;
                    _load();
                  }),
                ),
              const Spacer(),
              FilterChip(label: const Text('معوق'), selected: _overdue, onSelected: (bool v) {
                _overdue = v;
                _load();
              }),
            ]),
          ),
          if (_overdueCount > 0) Padding(padding: const EdgeInsets.all(6), child: Text('${toFaDigits('$_overdueCount')} مورد معوق', style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w600))),
          Expanded(
            child: _items.isEmpty && !_loading
                ? const Center(child: Text('یادآوری‌ای وجود ندارد'))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView.separated(
                      itemCount: _items.length,
                      separatorBuilder: (BuildContext c, int i) => const Divider(height: 1),
                      itemBuilder: (BuildContext c, int i) {
                        final Map<String, dynamic> it = _items[i];
                        final bool over = it['overdue'] == true;
                        final int left = (it['days_left'] as num?)?.toInt() ?? 0;
                        final String kind = '${it['kind']}';
                        return ListTile(
                          dense: true,
                          leading: Icon(_kKindIcon[kind] ?? Icons.event_note, color: over ? Colors.red : null),
                          title: Text('${_kKindFa[kind] ?? kind} · ${it['title'] ?? ''}'),
                          subtitle: Text(
                            '${it['party'] ?? ''}${'${it['party'] ?? ''}'.isEmpty ? '' : ' · '}${jalaliDate('${it['due_date']}')} (${over ? '${toFaDigits('${-left}')} روز گذشته' : (left == 0 ? 'امروز' : '${toFaDigits('$left')} روز مانده')})'
                            '${'${it['note'] ?? ''}'.isEmpty ? '' : '\n${it['note']}'}',
                            style: TextStyle(color: over ? Colors.red : null),
                          ),
                          trailing: it['amount'] is num ? Text(Fmt.money(it['amount'] as num), style: const TextStyle(fontWeight: FontWeight.w600)) : null,
                        );
                      },
                    ),
                  ),
          ),
        ]),
      ),
    );
  }
}
