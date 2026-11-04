import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import 'db.dart';
import 'sync_service.dart';
import 'utils.dart';
import 'widgets.dart';

/// S31.T31.20 — offline-queue conflict resolution, shown to the user.
/// A queued change the server rejected is parked as `failed` in `sync_ops` (and, while any exists, downloads from the
/// server are paused). This screen explains each one in plain Persian (what it was + why the server refused it) and lets
/// the user retry ONE change or set it aside. Setting aside deletes only that change (and failed changes on the same record);
/// the next full sync replaces the phone's copy with the server's, so nothing half-saved stays behind.

enum ConflictKind { rate, stock, permission, locked, dependency, validation, other }

class ConflictInfo {
  final ConflictKind kind;
  final String title;
  final String hint;
  const ConflictInfo(this.kind, this.title, this.hint);
}

/// Classifies the stored error text (server messages are Persian free text, so keyword based; unknown => other).
ConflictInfo classifyConflict(String err) {
  final String e = err;
  if (e.startsWith(AppDb.rateMissingPrefix)) {
    return const ConflictInfo(ConflictKind.rate, 'نرخ ارز ثبت نشده',
        'بعد از ثبت نرخ همان روز، خودکار دوباره ارسال می‌شود. اگر نرخ را ثبت کرده‌اید «تلاش دوباره» را بزنید.');
  }
  if (e.contains('موجودی') || e.contains('کافی نیست')) {
    return const ConflictInfo(ConflictKind.stock, 'موجودی کافی نیست',
        'روی سرور موجودی کمتر از این تغییر است (شاید دستگاه دیگری قبلاً برداشته). موجودی را بررسی کنید؛ در صورت نیاز تغییر را کنار بگذارید و دوباره ثبت کنید.');
  }
  if (e.contains('دسترسی') || e.contains('مجوز') || e.contains('edition_required') || e.contains('نسخه')) {
    return const ConflictInfo(ConflictKind.permission, 'دسترسی یا نسخه',
        'این حساب اجازهٔ این کار را ندارد. با مالک حساب هماهنگ کنید؛ تا آن موقع این تغییر ارسال نمی‌شود.');
  }
  if (e.contains('قفل') || e.contains('بسته') || e.contains('دورهٔ مالی') || e.contains('دوره مالی')) {
    return const ConflictInfo(ConflictKind.locked, 'دورهٔ مالی بسته است',
        'تاریخ این سند در دورهٔ بسته‌شده است. تاریخ را عوض کنید یا دوره را با مجوز لازم باز کنید.');
  }
  if (e.contains('هنوز') && e.contains('ارسال')) {
    return const ConflictInfo(ConflictKind.dependency, 'وابسته به تغییر دیگر',
        'این تغییر به مورد دیگری وابسته است که ارسال نشده. ابتدا همان را حل کنید.');
  }
  if (e.trim().isEmpty) {
    return const ConflictInfo(ConflictKind.other, 'خطای نامشخص', 'تلاش دوباره را بزنید؛ اگر تکرار شد، تغییر را کنار بگذارید.');
  }
  return const ConflictInfo(ConflictKind.validation, 'سرور تغییر را نپذیرفت',
      'اطلاعات را با پیام سرور مقایسه کنید. اگر قابل اصلاح نیست، تغییر را کنار بگذارید و درست‌شده را دوباره ثبت کنید.');
}

String conflictActionLabel(String a) => switch (a) {
      'categories.create' => 'افزودن دسته',
      'types.create' => 'افزودن نوع',
      'purchases.create' => 'ثبت/ویرایش خرید',
      'purchases.delete' => 'حذف خرید',
      'mixes.create' => 'ثبت مخلوط/جداسازی',
      'mixes.update' => 'ویرایش مخلوط/جداسازی',
      'mixes.delete' => 'حذف مخلوط/جداسازی',
      'payments.save' => 'ثبت پرداخت',
      'receipts.save' => 'ثبت دریافت',
      'sales.create' => 'ثبت فروش',
      'sales.update' => 'ویرایش فروش',
      'sales.delete' => 'حذف فروش',
      'parties.create' => 'افزودن طرف‌حساب',
      'loans.create' => 'ثبت قرض/بازپرداخت',
      'loans.delete' => 'حذف قرض/بازپرداخت',
      'sale_returns.create' => 'ثبت برگشت از فروش',
      'purchase_returns.create' => 'ثبت برگشت از خرید',
      'proformas.save' => 'ثبت پیش‌فاکتور',
      'entity.save' => 'ذخیرهٔ اطلاعات',
      'entity.delete' => 'حذف اطلاعات',
      _ => a,
    };

/// One short line describing the queued change (date, party, weight, amount) — only fields that exist in the payload.
String conflictSummary(Map<String, dynamic> payload) {
  final List<String> parts = <String>[];
  final dynamic date = payload['date'] ?? payload['sale_date'] ?? payload['purchase_date'];
  if (date is String && date.length >= 10) parts.add(toFaDigits(date.substring(0, 10)));
  for (final String k in <String>['buyer', 'seller', 'party_name', 'name', 'title']) {
    final dynamic v = payload[k];
    if (v is String && v.trim().isNotEmpty) {
      parts.add(v.trim().length > 30 ? v.trim().substring(0, 30) : v.trim());
      break;
    }
  }
  final dynamic w = payload['net_weight'] ?? payload['weight'];
  if (w is num && w != 0) parts.add('${faNum(w)} کیلو');
  final dynamic amt = payload['amount'] ?? payload['total'];
  if (amt is num && amt != 0) parts.add('مبلغ ${faNum(amt, dec: 0)}');
  return parts.join(' · ');
}

/// Single-op operations on the queue (kept here so the hot file db.dart stays untouched).
extension ConflictQueueOps on AppDb {
  /// Puts ONE failed change back in the queue.
  Future<bool> retryOneOp(int seq) async {
    final Database d = await db;
    final int n = await d.rawUpdate("UPDATE sync_ops SET state='pending', attempts=0, err=NULL WHERE seq=? AND state='failed'", <Object?>[seq]);
    if (n > 0) version.value++;
    return n > 0;
  }

  /// Sets one failed change aside (plus other FAILED changes on the same local record). Pending ops are never touched.
  Future<int> discardOneOp(int seq) async {
    final Database d = await db;
    final List<Map<String, Object?>> r = await d.query('sync_ops', where: "seq=? AND state='failed'", whereArgs: <Object?>[seq], limit: 1);
    if (r.isEmpty) return 0;
    final String? rk = r.first['ref_kind'] as String?;
    final Object? rid = r.first['ref_id'];
    int n = await d.delete('sync_ops', where: "seq=? AND state='failed'", whereArgs: <Object?>[seq]);
    if (rk != null && rid != null) {
      n += await d.delete('sync_ops', where: "ref_kind=? AND ref_id=? AND state='failed'", whereArgs: <Object?>[rk, rid]);
    }
    if (n > 0) version.value++;
    return n;
  }
}

class ConflictsScreen extends StatefulWidget {
  const ConflictsScreen({super.key});
  @override
  State<ConflictsScreen> createState() => _ConflictsScreenState();
}

class _ConflictsScreenState extends State<ConflictsScreen> {
  List<Map<String, dynamic>> _ops = <Map<String, dynamic>>[];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final List<Map<String, dynamic>> f = await AppDb.I.failedOps();
      if (mounted) setState(() => _ops = f);
    } catch (_) {}
  }

  Map<String, dynamic> _payload(Map<String, dynamic> op) {
    try {
      final dynamic j = jsonDecode(op['payload'] as String);
      return j is Map ? Map<String, dynamic>.from(j) : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<void> _sync(String okMsg) async {
    setState(() => _busy = true);
    await SyncService.I.syncNow(pull: true);
    await _load();
    if (!mounted) return;
    setState(() => _busy = false);
    snack(context, SyncService.I.info.value.error ?? okMsg);
  }

  Future<void> _retry(Map<String, dynamic> op) async {
    await AppDb.I.retryOneOp((op['seq'] as num).toInt());
    await _sync('دوباره ارسال شد');
  }

  Future<void> _discard(Map<String, dynamic> op) async {
    final bool ok = await confirm(context,
        'این تغییر کنار گذاشته می‌شود و به سرور ارسال نخواهد شد.\nبعد از همگام‌سازی، نسخهٔ سرور جای آن روی گوشی می‌نشیند.\n\nادامه می‌دهید؟');
    if (!ok || !mounted) return;
    await AppDb.I.discardOneOp((op['seq'] as num).toInt());
    await _sync('تغییر کنار گذاشته شد');
  }

  Color _color(ConflictKind k) => switch (k) {
        ConflictKind.rate || ConflictKind.dependency => Colors.orange.shade800,
        _ => Colors.red.shade800,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('تغییرات ارسال‌نشده')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          const Text(
            'این تغییرات روی گوشی ثبت شده‌اند ولی سرور نپذیرفته است. تا وقتی حل نشوند، دریافت اطلاعات جدید از سرور متوقف می‌ماند.',
            style: TextStyle(color: Colors.black54),
          ),
          const SizedBox(height: 12),
          if (_ops.isEmpty) const Card(child: ListTile(leading: Icon(Icons.check_circle_outline, color: Colors.green), title: Text('تغییر ارسال‌نشده‌ای نیست'))),
          for (final Map<String, dynamic> op in _ops) _card(op),
        ],
      ),
    );
  }

  Widget _card(Map<String, dynamic> op) {
    final ConflictInfo ci = classifyConflict((op['err'] as String?) ?? '');
    final String sum = conflictSummary(_payload(op));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
          Row(children: <Widget>[
            Icon(Icons.error_outline, color: _color(ci.kind)),
            const SizedBox(width: 8),
            Expanded(child: Text(conflictActionLabel(op['action'] as String), style: const TextStyle(fontWeight: FontWeight.bold))),
          ]),
          if (sum.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(sum)),
          const SizedBox(height: 8),
          Text(ci.title, style: TextStyle(color: _color(ci.kind), fontWeight: FontWeight.w600)),
          Text(ci.hint, style: const TextStyle(color: Colors.black54)),
          if (((op['err'] as String?) ?? '').isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 6), child: Text('پیام سرور: ${op['err']}', style: const TextStyle(fontSize: 12, color: Colors.black45))),
          const SizedBox(height: 8),
          Row(children: <Widget>[
            Expanded(child: FilledButton.icon(onPressed: _busy ? null : () => _retry(op), icon: const Icon(Icons.refresh), label: const Text('تلاش دوباره'))),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(onPressed: _busy ? null : () => _discard(op), icon: const Icon(Icons.delete_outline), label: const Text('کنار گذاشتن'))),
          ]),
        ]),
      ),
    );
  }
}
