import 'package:flutter/material.dart';

import 'perms.dart';
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;

/// S31.T31.2b — monthly period lock screen (online only, gold). Server actions: period_lock.get|close|reopen.
/// Closing locks every month up to the chosen Jalali month; reopening (owner only, reason required) reopens the chosen month and later ones.

class PeriodLockScreen extends StatefulWidget {
  const PeriodLockScreen({super.key});

  @override
  State<PeriodLockScreen> createState() => _PeriodLockScreenState();
}

class _PeriodLockScreenState extends State<PeriodLockScreen> {
  Map<String, dynamic>? _st;
  String? _error;
  bool _loading = false;
  late int _jy;
  int _jm = 1;

  @override
  void initState() {
    super.initState();
    final List<int> j = gregorianToJalali(DateTime.now().year, DateTime.now().month, DateTime.now().day);
    _jy = j[0];
    _jm = j[1];
    _load();
  }

  Future<Map<String, dynamic>?> _call(String action, [Map<String, dynamic> p = const <String, dynamic>{}]) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> r = await StockApi.call(action, p);
      if (!mounted) return null;
      setState(() {
        _st = r;
        _loading = false;
      });
      return r;
    } on StockApiException catch (e) {
      if (!mounted) return null;
      setState(() {
        _error = e.message;
        _loading = false;
      });
      return null;
    }
  }

  Future<void> _load() => _call('period_lock.get');

  Future<void> _close() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('بستن دوره'),
        content: Text('همهٔ اسناد تا پایان ${kJalaliMonthNames[_jm - 1]} ${toFaDigits('$_jy')} قفل می‌شوند و فقط مالک می‌تواند باز کند.'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('بستن')),
        ],
      ),
    );
    if (ok == true) await _call('period_lock.close', <String, dynamic>{'jy': _jy, 'jm': _jm});
  }

  Future<void> _reopen() async {
    final TextEditingController c = TextEditingController();
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('بازگشایی از ${kJalaliMonthNames[_jm - 1]} ${toFaDigits('$_jy')}'),
        content: TextField(controller: c, maxLength: 50, decoration: const InputDecoration(labelText: 'دلیل بازگشایی (الزامی)', border: OutlineInputBorder())),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('بازگشایی')),
        ],
      ),
    );
    if (ok == true) await _call('period_lock.reopen', <String, dynamic>{'jy': _jy, 'jm': _jm, 'reason': c.text.trim()});
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic>? j = _st?['jalali'] is Map ? Map<String, dynamic>.from(_st!['jalali'] as Map) : null;
    final Map<String, dynamic>? last = _st?['last_reopen'] is Map ? Map<String, dynamic>.from(_st!['last_reopen'] as Map) : null;
    final int drafts = (_st?['draft_vouchers_in_locked'] as num?)?.toInt() ?? 0;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('قفل دوره ماهانه')),
        body: ListView(padding: const EdgeInsets.all(12), children: <Widget>[
          if (_loading) const LinearProgressIndicator(),
          if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: const TextStyle(color: Colors.red))),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Text(_st == null ? '…' : (_st!['lock_through'] == null ? 'هیچ دوره‌ای بسته نیست' : 'بسته تا ${toFaDigits('${j?['jy']}/${j?['jm']}/${j?['jd']}')} (${_st!['lock_through']})'), style: const TextStyle(fontWeight: FontWeight.bold)),
                if (drafts > 0) Text('${toFaDigits('$drafts')} سند پیش‌نویس در دورهٔ بسته مانده است', style: const TextStyle(color: Colors.orange, fontSize: 12)),
                if (last != null) Text('آخرین بازگشایی: ${last['at'] ?? ''} — ${last['reason'] ?? ''}', style: const TextStyle(fontSize: 12)),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          Row(children: <Widget>[
            Expanded(
              child: DropdownButtonFormField<int>(
                value: _jm,
                decoration: const InputDecoration(labelText: 'ماه', border: OutlineInputBorder()),
                items: <DropdownMenuItem<int>>[for (int i = 1; i <= 12; i++) DropdownMenuItem<int>(value: i, child: Text(kJalaliMonthNames[i - 1]))],
                onChanged: (int? v) => setState(() => _jm = v ?? _jm),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(onPressed: () => setState(() => _jy--), icon: const Icon(Icons.chevron_right)),
            Text(toFaDigits('$_jy')),
            IconButton(onPressed: () => setState(() => _jy++), icon: const Icon(Icons.chevron_left)),
          ]),
          const SizedBox(height: 12),
          if (StaffPerms.I.can('accounting.post')) FilledButton.icon(onPressed: _loading ? null : _close, icon: const Icon(Icons.lock_outline), label: const Text('بستن تا پایان این ماه')),
          const SizedBox(height: 8),
          if (!StaffPerms.I.isStaff) OutlinedButton.icon(onPressed: _loading ? null : _reopen, icon: const Icon(Icons.lock_open), label: const Text('بازگشایی از این ماه (فقط مالک)')),
        ]),
      ),
    );
  }
}
