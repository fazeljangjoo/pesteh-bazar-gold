import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'db.dart';
import 'edition.dart';
import 'perms.dart';
import 'utils.dart';
import 'widgets.dart';
import 'vouchers_ui.dart';
import 'warehouse_ui.dart' show StockApi;

/// S16.T16.7 — document <-> voucher links (gold) + offline cache of synced vouchers.
/// Everything here is hidden outside the gold.vouchers feature (green unchanged).

const String _kCacheKey = 'voucher_cache_v1';
const int _kCacheMax = 150;

/// Small SharedPreferences cache so vouchers already fetched stay viewable offline.
/// Stores list heads (id -> head) and full details (id -> detail JSON), newest-first, capped.
class VoucherCache {
  VoucherCache._();

  static Future<Map<String, dynamic>> _read() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      final String? raw = sp.getString(_kCacheKey);
      if (raw == null || raw.isEmpty) return <String, dynamic>{};
      final dynamic d = jsonDecode(raw);
      if (d is Map) return Map<String, dynamic>.from(d);
    } catch (_) {}
    return <String, dynamic>{};
  }

  static Future<void> _write(Map<String, dynamic> m) async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      await sp.setString(_kCacheKey, jsonEncode(m));
    } catch (_) {}
  }

  /// Remember list heads (as returned by vouchers.list `items`).
  static Future<void> saveHeads(List<Map<String, dynamic>> heads) async {
    final Map<String, dynamic> m = await _read();
    final Map<String, dynamic> h = m['heads'] is Map ? Map<String, dynamic>.from(m['heads'] as Map) : <String, dynamic>{};
    for (final Map<String, dynamic> r in heads) {
      h[r['id'].toString()] = r;
    }
    if (h.length > _kCacheMax) {
      final List<String> keys = h.keys.toList();
      keys.sort((String a, String b) => (int.tryParse(b) ?? 0).compareTo(int.tryParse(a) ?? 0));
      for (final String k in keys.skip(_kCacheMax)) {
        h.remove(k);
      }
    }
    m['heads'] = h;
    await _write(m);
  }

  /// Cached heads, optionally filtered by status / free text; newest first.
  static Future<List<Map<String, dynamic>>> heads({String status = '', String q = ''}) async {
    final Map<String, dynamic> m = await _read();
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    if (m['heads'] is Map) {
      for (final dynamic v in (m['heads'] as Map).values) {
        if (v is Map) out.add(Map<String, dynamic>.from(v));
      }
    }
    final String qq = q.trim();
    final List<Map<String, dynamic>> res = out.where((Map<String, dynamic> r) {
      if (status.isNotEmpty && r['status'] != status) return false;
      if (qq.isNotEmpty) {
        final String hay = '${r['number'] ?? ''} ${r['description'] ?? ''}';
        if (!hay.contains(qq)) return false;
      }
      return true;
    }).toList();
    res.sort((Map<String, dynamic> a, Map<String, dynamic> b) {
      final int c = (b['date'] ?? '').toString().compareTo((a['date'] ?? '').toString());
      if (c != 0) return c;
      return (int.tryParse(b['id'].toString()) ?? 0).compareTo(int.tryParse(a['id'].toString()) ?? 0);
    });
    return res;
  }

  static Future<void> saveDetail(int id, Map<String, dynamic> detail) async {
    final Map<String, dynamic> m = await _read();
    final Map<String, dynamic> d = m['details'] is Map ? Map<String, dynamic>.from(m['details'] as Map) : <String, dynamic>{};
    d[id.toString()] = detail;
    if (d.length > _kCacheMax) {
      final List<String> keys = d.keys.toList();
      keys.sort((String a, String b) => (int.tryParse(b) ?? 0).compareTo(int.tryParse(a) ?? 0));
      for (final String k in keys.skip(_kCacheMax)) {
        d.remove(k);
      }
    }
    m['details'] = d;
    await _write(m);
  }

  static Future<Map<String, dynamic>?> detail(int id) async {
    final Map<String, dynamic> m = await _read();
    if (m['details'] is Map) {
      final dynamic v = (m['details'] as Map)[id.toString()];
      if (v is Map) return Map<String, dynamic>.from(v);
    }
    return null;
  }

  /// Source -> voucher id lookup (filled when a link was resolved online).
  static Future<void> saveLink(String type, String id, int voucherId) async {
    final Map<String, dynamic> m = await _read();
    final Map<String, dynamic> l = m['links'] is Map ? Map<String, dynamic>.from(m['links'] as Map) : <String, dynamic>{};
    l['$type:$id'] = voucherId;
    m['links'] = l;
    await _write(m);
  }

  static Future<int?> link(String type, String id) async {
    final Map<String, dynamic> m = await _read();
    if (m['links'] is Map) {
      final dynamic v = (m['links'] as Map)['$type:$id'];
      if (v is num) return v.toInt();
    }
    return null;
  }

  static Future<void> clear() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      await sp.remove(_kCacheKey);
    } catch (_) {}
  }
}

const Map<String, String> _kStatusFa = <String, String>{
  'draft': 'پیش‌نویس',
  'temporary': 'موقت',
  'final': 'قطعی',
};

bool _goldVouchers() => EditionService.I.current.value.has('gold.vouchers');

/// Looks up the auto voucher of a document. Returns the voucher head or null (none posted / offline w/o cache).
/// `fromCache` is true when the answer came from the offline cache.
class VoucherLookup {
  VoucherLookup(this.head, this.fromCache, this.error);
  final Map<String, dynamic>? head;
  final bool fromCache;
  final String? error;

  static Future<VoucherLookup> find(String sourceType, String sourceId) async {
    try {
      final Map<String, dynamic> r = await StockApi.call('vouchers.list', <String, dynamic>{
        'source_type': sourceType,
        'source_id': sourceId,
        'limit': 1,
      });
      final dynamic items = r['items'];
      if (items is List && items.isNotEmpty && items.first is Map) {
        final Map<String, dynamic> h = Map<String, dynamic>.from(items.first as Map);
        await VoucherCache.saveHeads(<Map<String, dynamic>>[h]);
        final dynamic idv = h['id'];
        final int vid = idv is num ? idv.toInt() : (int.tryParse(idv?.toString() ?? '') ?? 0);
        if (vid > 0) await VoucherCache.saveLink(sourceType, sourceId, vid);
        return VoucherLookup(h, false, null);
      }
      return VoucherLookup(null, false, null);
    } catch (e) {
      final int? vid = await VoucherCache.link(sourceType, sourceId);
      if (vid != null) {
        final List<Map<String, dynamic>> hs = await VoucherCache.heads();
        for (final Map<String, dynamic> h in hs) {
          if (h['id'].toString() == vid.toString()) return VoucherLookup(h, true, null);
        }
      }
      return VoucherLookup(null, true, e.toString());
    }
  }
}

/// «سند مربوطه» button for a document detail screen. Pass the posting doc type (rules `doc_type`,
/// e.g. sale, purchase, sep, cons_in, cons_out, proc_send, proc_recv, proc_toll, orch_cost, payroll)
/// and the server id of the document. Renders nothing outside gold or without accounting.view.
class VoucherLinkButton extends StatefulWidget {
  const VoucherLinkButton({super.key, required this.sourceType, required this.sourceId, this.label = 'سند مربوطه'});
  final String sourceType;
  final String sourceId;
  final String label;

  @override
  State<VoucherLinkButton> createState() => _VoucherLinkButtonState();
}

class _VoucherLinkButtonState extends State<VoucherLinkButton> {
  bool _busy = false;

  Future<void> _open() async {
    setState(() => _busy = true);
    final VoucherLookup r = await VoucherLookup.find(widget.sourceType, widget.sourceId);
    if (!mounted) return;
    setState(() => _busy = false);
    final Map<String, dynamic>? h = r.head;
    if (h == null) {
      snack(context, r.error != null ? 'اتصال برقرار نیست و این سند هنوز در حافظهٔ آفلاین نیست' : 'برای این سند هنوز سندی ثبت نشده است');
      return;
    }
    final dynamic idv = h['id'];
    final int vid = idv is num ? idv.toInt() : (int.tryParse(idv?.toString() ?? '') ?? 0);
    if (vid <= 0) return;
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => VoucherDetailScreen(id: vid)));
  }

  @override
  Widget build(BuildContext context) {
    if (!_goldVouchers() || !StaffPerms.I.can('accounting.view')) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: OutlinedButton.icon(
          onPressed: _busy ? null : _open,
          icon: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.receipt_long_outlined),
          label: Text(widget.label),
        ),
      ),
    );
  }
}

/// Post-status badge for a document: «سند ندارد» / «موقت» / «قطعی» / «پیش‌نویس» (+ voucher number).
class VoucherStatusChip extends StatefulWidget {
  const VoucherStatusChip({super.key, required this.sourceType, required this.sourceId});
  final String sourceType;
  final String sourceId;

  @override
  State<VoucherStatusChip> createState() => _VoucherStatusChipState();
}

class _VoucherStatusChipState extends State<VoucherStatusChip> {
  VoucherLookup? _r;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_goldVouchers() || !StaffPerms.I.can('accounting.view')) return;
    final VoucherLookup r = await VoucherLookup.find(widget.sourceType, widget.sourceId);
    if (mounted) setState(() => _r = r);
  }

  @override
  Widget build(BuildContext context) {
    final VoucherLookup? r = _r;
    if (r == null || !_goldVouchers()) return const SizedBox.shrink();
    String label;
    Color color;
    final Map<String, dynamic>? h = r.head;
    if (h == null) {
      if (r.error != null) return const SizedBox.shrink();
      label = 'سند ندارد';
      color = Colors.grey;
    } else {
      final String st = (h['status'] ?? '').toString();
      final String no = h['number'] == null ? '' : ' ${faNum(h['number'] is num ? (h['number'] as num).toInt() : (int.tryParse(h['number'].toString()) ?? 0), dec: 0)}';
      label = 'سند$no: ${_kStatusFa[st] ?? st}${r.fromCache ? ' (آفلاین)' : ''}';
      color = st == 'final' ? Colors.green : (st == 'temporary' ? Colors.orange : Colors.blueGrey);
    }
    return Chip(
      avatar: Icon(Icons.receipt_long_outlined, size: 16, color: color),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      visualDensity: VisualDensity.compact,
      side: BorderSide(color: color),
    );
  }
}

/// Status chip + «سند مربوطه» for a LOCAL document (sale `sale`, purchase `pur`): resolves the server id first.
/// Shows nothing outside gold, or when the document has not reached the server yet (no server id).
class LocalDocVoucherLinks extends StatefulWidget {
  const LocalDocVoucherLinks({super.key, required this.mapKind, required this.localId, required this.sourceType});
  final String mapKind; // sync_idmap kind: 'sale' | 'pur'
  final int localId;
  final String sourceType; // posting doc_type: 'sale' | 'purchase'

  @override
  State<LocalDocVoucherLinks> createState() => _LocalDocVoucherLinksState();
}

class _LocalDocVoucherLinksState extends State<LocalDocVoucherLinks> {
  int? _sid;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    int? sid;
    try {
      sid = await AppDb.I.serverIdOf(widget.mapKind, widget.localId) ?? await AppDb.I.aliasOf(widget.mapKind, widget.localId);
    } catch (_) {}
    if (mounted) {
      setState(() {
        _sid = sid;
        _done = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_goldVouchers() || !StaffPerms.I.can('accounting.view') || !_done) return const SizedBox.shrink();
    final int? sid = _sid;
    if (sid == null || sid <= 0) return const SizedBox.shrink();
    return Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: <Widget>[
      VoucherStatusChip(sourceType: widget.sourceType, sourceId: '$sid'),
      VoucherLinkButton(sourceType: widget.sourceType, sourceId: '$sid'),
    ]);
  }
}
