import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'db.dart';
import 'db_crypto.dart';
import 'sync_service.dart';

/// پشتیبان‌گیری محلی (فقط ویندوز؛ روی گوشی هیچ کاری نمی‌کند).
///
/// * خودکار: روزی یک‌بار (و هنگام باز شدن برنامه اگر بیش از ~۲۰ ساعت از آخرین پشتیبان گذشته باشد).
/// * قبل از هر جایگزینی داده‌های محلی با سرور («pre-sync» حداکثر هر ۶ ساعت، «pre-reload»، «pre-restore»).
/// * دستی: از صفحهٔ «پشتیبان‌گیری».
/// فایل‌ها در `Documents\PestehBazar\Backups` هستند تا کاربر بتواند آن‌ها را روی فلش/ابر هم کپی کند.
class LocalBackup {
  LocalBackup._();
  static final LocalBackup I = LocalBackup._();

  static const Map<String, int> _keep = {
    'daily': 30,
    'manual': 200,
    'pre-sync': 5,
    'pre-reload': 10,
    'pre-restore': 10,
  };

  Timer? _timer;
  final Map<String, DateTime> _lastByKind = {};

  bool get supported => Platform.isWindows;

  /// بعد از آماده‌شدن حساب صدا زده می‌شود.
  void start() {
    if (!supported) return;
    _timer ??= Timer.periodic(const Duration(minutes: 30), (_) => maybeDaily());
    maybeDaily();
  }

  Future<Directory> dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(docs.path, 'PestehBazar', 'Backups'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  String _two(int v) => v.toString().padLeft(2, '0');

  String _stamp(DateTime n) =>
      '${n.year}${_two(n.month)}${_two(n.day)}_${_two(n.hour)}${_two(n.minute)}${_two(n.second)}';

  /// نوع پشتیبان از روی نام فایل (daily/manual/pre-…)
  String kindOf(File f) {
    final n = p.basename(f.path);
    final i = n.indexOf('_');
    return i < 0 ? n : n.substring(0, i);
  }

  /// یک نسخهٔ کامل از دیتابیس حساب جاری می‌گیرد. هیچ‌وقت خطا پرتاب نمی‌کند؛ ناموفق = null.
  /// [minGap]: اگر از آخرین پشتیبانِ همین نوع کمتر از این مدت گذشته، چیزی ساخته نمی‌شود.
  Future<File?> snapshot(String kind, {Duration minGap = Duration.zero}) async {
    if (!supported || !AppDb.I.hasAccount) return null;
    File? f;
    try {
      final phone = AppDb.I.phone;
      if (phone == null) return null;
      final last = _lastByKind['$phone|$kind'];
      if (last != null && DateTime.now().difference(last) < minGap) return null;
      final d = await dir();
      final out = File(p.join(d.path, '${kind}_${phone}_${_stamp(DateTime.now())}.db'));
      f = out;
      if (await out.exists()) await out.delete();
      await AppDb.I.vacuumInto(out.path);
      await DbCrypto.ensureEncrypted(out.path); // پشتیبانِ بدون رمز نگه داشته نمی‌شود
      if (!await out.exists() || await out.length() == 0) return null;
      _lastByKind['$phone|$kind'] = DateTime.now();
      await _prune(kind, phone);
      return out;
    } catch (_) {
      // ناقص یا رمزنشده: نگه نمی‌داریم
      try {
        if (f != null && await f.exists()) await f.delete();
      } catch (_) {}
      return null;
    }
  }

  Future<void> maybeDaily() async {
    if (!supported || !AppDb.I.hasAccount) return;
    try {
      final files = await list();
      final daily = files.where((f) => kindOf(f) == 'daily').toList();
      if (daily.isNotEmpty) {
        final age = DateTime.now().difference(daily.first.lastModifiedSync());
        if (age < const Duration(hours: 20)) return;
      }
      await snapshot('daily');
    } catch (_) {}
  }

  /// پشتیبان‌های حساب جاری، جدیدترین اول
  Future<List<File>> list() async {
    if (!AppDb.I.hasAccount) return [];
    final phone = AppDb.I.phone;
    if (phone == null) return [];
    final d = await dir();
    final out = <File>[];
    await for (final e in d.list()) {
      if (e is! File) continue;
      final n = p.basename(e.path);
      if (n.endsWith('.db') && n.contains('_${phone}_')) out.add(e);
    }
    out.sort((a, b) => p.basename(b.path).compareTo(p.basename(a.path)));
    return out;
  }

  Future<void> _prune(String kind, String phone) async {
    final keep = _keep[kind];
    if (keep == null) return;
    try {
      final same = (await list()).where((f) => kindOf(f) == kind).toList();
      for (final f in same.skip(keep)) {
        await f.delete();
      }
    } catch (_) {}
  }

  /// بازگردانی از یک فایل پشتیبان. نیازمند اینترنت است (سرور مرجع است).
  /// قبل از شروع، از وضعیت فعلی یک نسخهٔ «pre-restore» گرفته می‌شود تا بازگردانی قابل برگشت باشد.
  Future<String?> restore(File f) async {
    try {
      final snap = await snapshot('pre-restore');
      if (snap == null) return 'گرفتن نسخهٔ ایمنی از وضعیت فعلی ممکن نشد؛ بازگردانی انجام نشد';
      final tables = await AppDb.I.readBackupTables(f.path);
      return await SyncService.I.importTables(tables);
    } catch (e) {
      return 'بازگردانی ناموفق بود: $e';
    }
  }
}
