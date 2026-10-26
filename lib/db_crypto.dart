import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'dpapi.dart';

/// رمزگذاری فایل دیتابیس روی ویندوز (SQLite3 Multiple Ciphers).
///
/// * کلید: ۳۲ بایت تصادفی، که با DPAPI ویندوز محافظت و در پوشهٔ داده‌های برنامه نگه‌داری می‌شود.
///   فقط همین کاربرِ ویندوز روی همین کامپیوتر می‌تواند آن را باز کند.
/// * وضعیت (db_mode.txt): `enc` = رمزگذاری‌شده، `plain` = ساخت بدون موتور رمزگذاری (فقط برای توسعه).
///   اگر دیتابیس رمزگذاری‌شده باشد ولی موتور یا کلید نباشد، برنامه **باز نمی‌شود** (به‌جای ساختن
///   دیتابیس خالیِ جدید یا نوشتن بدون رمز).
/// * پشتیبان‌ها هم رمزگذاری می‌شوند؛ اگر نشد، پشتیبان نگه داشته نمی‌شود (fail-closed).
class DbCrypto {
  DbCrypto._();

  static String? _key; // null = بدون رمز
  static String? initError;
  static bool _ready = false;

  static bool get encrypted => _key != null;

  static Future<File> _file(String name) async {
    final d = await getApplicationSupportDirectory();
    if (!await d.exists()) await d.create(recursive: true);
    return File(p.join(d.path, name));
  }

  /// آیا موتور SQLite همین برنامه از رمزگذاری پشتیبانی می‌کند؟
  static Future<bool> _engineSupportsCipher() async {
    Database? t;
    try {
      t = await databaseFactory.openDatabase(inMemoryDatabasePath);
      try {
        final r = await t.rawQuery('SELECT sqlite3mc_version() AS v');
        if (r.isNotEmpty) return true;
      } catch (_) {}
      try {
        final r = await t.rawQuery('PRAGMA cipher');
        if (r.isNotEmpty) return true;
      } catch (_) {}
      return false;
    } catch (_) {
      return false;
    } finally {
      try {
        await t?.close();
      } catch (_) {}
    }
  }

  static Future<String?> _loadKey() async {
    final f = await _file('db_key.bin');
    if (!await f.exists()) return null;
    final dec = Dpapi.unprotect(await f.readAsBytes());
    if (dec == null) return null;
    final k = utf8.decode(dec);
    return RegExp(r'^[0-9a-f]{64}$').hasMatch(k) ? k : null;
  }

  static Future<String> _createKey() async {
    final rnd = math.Random.secure();
    final k = List.generate(32, (_) => rnd.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final enc = Dpapi.protect(Uint8List.fromList(utf8.encode(k)));
    if (enc == null) throw StateError('ذخیرهٔ امن کلید رمزگذاری در ویندوز ممکن نشد');
    final f = await _file('db_key.bin');
    await f.writeAsBytes(enc, flush: true);
    return k;
  }

  /// قبل از باز شدن هر دیتابیسی صدا زده شود (بعد از تنظیم مسیر دیتابیس‌ها).
  static Future<void> init() async {
    if (_ready) return;
    _ready = true;
    if (!Platform.isWindows) return;
    try {
      final marker = await _file('db_mode.txt');
      var mode = await marker.exists() ? (await marker.readAsString()).trim() : '';
      final supported = await _engineSupportsCipher();

      if (mode.isEmpty) {
        // اولین اجرا: اگر از قبل دیتابیسی هست (نسخهٔ بدون رمز)، همان حالت حفظ می‌شود
        final dbDir = Directory(await databaseFactory.getDatabasesPath());
        var hasDb = false;
        if (await dbDir.exists()) {
          await for (final e in dbDir.list()) {
            if (e.path.endsWith('.db')) {
              hasDb = true;
              break;
            }
          }
        }
        mode = (supported && !hasDb) ? 'enc' : 'plain';
        if (mode == 'enc') _key = await _createKey();
        await marker.writeAsString(mode, flush: true);
        return;
      }
      if (mode == 'plain') return;
      // mode == 'enc'
      if (!supported) {
        initError = 'این نسخهٔ برنامه موتور رمزگذاری ندارد، ولی اطلاعات شما رمزگذاری‌شده است. '
            'نسخهٔ درست برنامه را نصب کنید (اطلاعات شما سالم است).';
        return;
      }
      final k = await _loadKey();
      if (k == null) {
        initError = 'کلید رمزگشایی این کامپیوتر/کاربر ویندوز پیدا نشد. '
            'اگر ویندوز را عوض کرده‌اید، پوشهٔ داده‌های برنامه را پاک کنید و دوباره وارد شوید؛ '
            'اطلاعات شما از روی سرور برمی‌گردد.';
        return;
      }
      _key = k;
    } catch (e) {
      initError = 'راه‌اندازی رمزگذاری ناموفق بود: $e';
    }
  }

  /// برای onConfigure دیتابیس‌ها: کلید را قبل از هر دستور دیگری اعمال می‌کند.
  static Future<void> configure(Database db) async {
    final k = _key;
    if (k == null) return;
    await db.execute("PRAGMA key = '$k'");
  }

  static Future<bool> _isPlainFile(String path) async {
    final raf = await File(path).open();
    try {
      final head = await raf.read(16);
      return utf8.decode(head, allowMalformed: true).startsWith('SQLite format 3');
    } finally {
      await raf.close();
    }
  }

  /// مطمئن می‌شود فایل پشتیبانِ ساخته‌شده رمزگذاری است؛ وگرنه رمزگذاری می‌کند یا حذفش می‌کند و خطا می‌دهد.
  static Future<void> ensureEncrypted(String path) async {
    final k = _key;
    if (k == null) return;
    if (!await _isPlainFile(path)) return;
    final d = await databaseFactory.openDatabase(path, options: OpenDatabaseOptions(singleInstance: false));
    try {
      await d.execute("PRAGMA rekey = '$k'");
    } finally {
      await d.close();
    }
    if (await _isPlainFile(path)) {
      try {
        await File(path).delete();
      } catch (_) {}
      throw StateError('پشتیبان رمزگذاری نشد');
    }
  }

  /// متن وضعیت برای نمایش به کاربر
  static String get statusText => encrypted
      ? 'رمزگذاری دیتابیس: فعال ✅ (کلید در محافظ ویندوز)'
      : 'رمزگذاری دیتابیس: غیرفعال ⚠️ (این ساخت برنامه موتور رمزگذاری ندارد)';
}
