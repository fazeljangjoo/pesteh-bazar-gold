import 'package:flutter/material.dart';

import 'warehouse_ui.dart';

/// S23.T23.2 — «سلامت داده‌ها»: calls server action audit.run (read-only) and shows the Persian health report.
/// Needs permission audit.view (server enforces; menu hides it otherwise).
class DataHealthScreen extends StatefulWidget {
  const DataHealthScreen({super.key});

  @override
  State<DataHealthScreen> createState() => _DataHealthScreenState();
}

class _DataHealthScreenState extends State<DataHealthScreen> {
  bool _loading = false;
  String? _error;
  Map<String, dynamic>? _report;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> r = await StockApi.call('audit.run');
      if (!mounted) return;
      setState(() {
        _report = r;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'دریافت گزارش انجام نشد. اتصال اینترنت و دسترسی خود را بررسی کنید.';
        _loading = false;
      });
    }
  }

  Color _statusColor(String s) {
    if (s == 'error') return Colors.red.shade700;
    if (s == 'warn') return Colors.orange.shade800;
    return Colors.green.shade700;
  }

  IconData _statusIcon(String s) {
    if (s == 'error') return Icons.error_outline;
    if (s == 'warn') return Icons.warning_amber_outlined;
    return Icons.check_circle_outline;
  }

  Widget _checkTile(Map<String, dynamic> c) {
    final String status = (c['status'] ?? 'ok').toString();
    final List<dynamic> items = c['items'] is List ? (c['items'] as List<dynamic>) : <dynamic>[];
    final int count = c['count'] is num ? (c['count'] as num).toInt() : items.length;
    final String title = (c['title'] ?? '').toString();
    if (items.isEmpty) {
      return ListTile(
        leading: Icon(_statusIcon(status), color: _statusColor(status)),
        title: Text(title),
        subtitle: const Text('سالم'),
      );
    }
    final List<Widget> kids = <Widget>[];
    for (final dynamic it in items) {
      kids.add(ListTile(dense: true, title: Text(it.toString())));
    }
    if (count > items.length) {
      kids.add(ListTile(dense: true, title: Text('و ${count - items.length} مورد دیگر')));
    }
    return ExpansionTile(
      leading: Icon(_statusIcon(status), color: _statusColor(status)),
      title: Text(title),
      subtitle: Text('$count مورد'),
      children: kids,
    );
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic>? r = _report;
    final List<Widget> body = <Widget>[];
    if (_error != null) {
      body.add(Padding(padding: const EdgeInsets.all(16), child: Text(_error!)));
    } else if (r != null) {
      final bool ok = r['ok'] == true;
      final String st = ok ? ((r['warnings'] is num && (r['warnings'] as num) > 0) ? 'warn' : 'ok') : 'error';
      body.add(Card(
        margin: const EdgeInsets.all(12),
        child: ListTile(
          leading: Icon(_statusIcon(st), color: _statusColor(st), size: 32),
          title: Text((r['summary'] ?? '').toString()),
          subtitle: Text('زمان بررسی: ${(r['at'] ?? '').toString()}'),
        ),
      ));
      final dynamic cs = r['checks'];
      if (cs is List) {
        for (final dynamic c in cs) {
          if (c is Map) body.add(_checkTile(Map<String, dynamic>.from(c)));
        }
      }
    }
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('سلامت داده‌ها'),
          actions: <Widget>[
            IconButton(icon: const Icon(Icons.refresh), tooltip: 'بررسی دوباره', onPressed: _loading ? null : _run),
          ],
        ),
        body: _loading && r == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(children: body),
      ),
    );
  }
}
