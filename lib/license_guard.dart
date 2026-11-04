import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// کلید عمومی امضای اشتراک (Ed25519، base64). جفتِ آن (کلید خصوصی) فقط روی سرور است.
/// اگر کلید سرور را عوض کردید، فقط همین مقدار را عوض کنید.
const String kLicensePublicKeyB64 = 'yJIcf36ObarEC9K6mj51zSvMMUzcZ2lkYbP5b/7qDk0=';

/// حداکثر روزهایی که برنامه می‌تواند بدون هیچ تأییدِ آنلاین کار کند.
/// (بعد از آن یک‌بار اتصال به اینترنت لازم است؛ تمدید/لغو اشتراک هم همان موقع اعمال می‌شود.)
const int kMaxOfflineDays = 45;

/// نسخهٔ ویندوز از «مجوز امضادار» استفاده می‌کند (روی گوشی رفتار قبلی حفظ شده است).
bool get kStrictLicense => Platform.isWindows;

enum GuardVerdict {
  ok,
  noLicense, // هنوز مجوزی ذخیره نشده (نیاز به اتصال)
  invalid, // امضا/شماره/دستگاه نمی‌خواند (دستکاری یا کپی از دستگاه دیگر)
  clockBack, // ساعت سیستم به عقب برگشته
  offlineTooLong, // بیش از حد مجاز بدون تأیید آنلاین
  inactive, // اشتراک غیرفعال شده
  expired, // اشتراک تمام شده
}

class GuardResult {
  final GuardVerdict verdict;
  final DateTime? expiry; // روزِ انقضا (تاریخ، به وقت ایران)
  final String? plan;
  final int? daysToOnlineCheck;
  // S22.T22.2: از خود مجوز امضاشده (نه از JSON سرور)
  final String? tier; // 'green' | 'gold'؛ null = مجوز معتبری نبود
  final List<String>? features; // null = مجوز قدیمی بدون فهرست
  final bool exportOnly; // طلایی منقضی: فقط خروجی
  const GuardResult(this.verdict,
      {this.expiry, this.plan, this.daysToOnlineCheck, this.tier, this.features, this.exportOnly = false});
}

class _Lic {
  final String phone;
  final bool active;
  final DateTime? expDate;
  final String plan;
  final DateTime iat; // زمان سرور هنگام صدور (UTC)
  final String dev;
  final String tier; // توکن قدیمی بدون tier = green (محافظه‌کارانه)
  final List<String>? features; // null = توکن قدیمی بدون فهرست قابلیت
  final bool exportOnly;
  _Lic(this.phone, this.active, this.expDate, this.plan, this.iat, this.dev,
      {this.tier = 'green', this.features, this.exportOnly = false});

  /// پایان روز انقضا به وقت ایران (UTC+3:30، بدون ساعت تابستانی)، به‌صورت UTC
  DateTime? get expEndUtc => expDate == null
      ? null
      : DateTime.utc(expDate!.year, expDate!.month, expDate!.day, 23, 59, 59)
          .subtract(const Duration(hours: 3, minutes: 30));
}

/// بررسی و نگهداری مجوز امضادارِ اشتراک (فقط ویندوز).
///
/// ایمنی:
///  * امضای Ed25519: تاریخ انقضا/فعال‌بودن/نوع پلن را نمی‌شود دستی عوض کرد.
///  * اتصال به دستگاه: مجوزِ کپی‌شده روی کامپیوتر دیگر کار نمی‌کند.
///  * ضد برگرداندن ساعت: آخرین زمانِ دیده‌شده (فایل + دیتابیس) و زمان سرور در مجوز.
///  * سقف کار آفلاین ([kMaxOfflineDays]) تا لغو/تمدید اشتراک حتماً اعمال شود.
class LicenseGuard {
  LicenseGuard._();
  static final LicenseGuard I = LicenseGuard._();

  /// چند روز تا الزام بعدیِ اتصال آنلاین (برای هشدار)؛ null = نامشخص
  final ValueNotifier<int?> daysToOnlineCheck = ValueNotifier<int?>(null);

  String? _device;

  Future<File> _file(String name) async {
    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) await dir.create(recursive: true);
    return File(p.join(dir.path, name));
  }

  /// شناسهٔ ثابت این کامپیوتر (SHA-256 هگز). از MachineGuid ویندوز؛ اگر نشد یک شناسهٔ تصادفی ذخیره می‌شود.
  Future<String> deviceId() async {
    if (_device != null) return _device!;
    String? guid;
    try {
      final r = await Process.run('reg', [
        'query',
        r'HKLM\SOFTWARE\Microsoft\Cryptography',
        '/v',
        'MachineGuid',
      ]);
      final m = RegExp(r'MachineGuid\s+REG_SZ\s+([0-9A-Za-z\-]+)').firstMatch('${r.stdout}');
      guid = m?.group(1);
    } catch (_) {}
    if (guid == null || guid.length < 8) {
      try {
        final f = await _file('install_id.txt');
        if (await f.exists()) {
          guid = (await f.readAsString()).trim();
        }
        if (guid == null || guid.length < 8) {
          final rnd = math.Random.secure();
          guid = List.generate(32, (_) => rnd.nextInt(16).toRadixString(16)).join();
          await f.writeAsString(guid);
        }
      } catch (_) {
        guid = 'unknown-device';
      }
    }
    _device = crypto.sha256.convert(utf8.encode('pesteh-bazar|$guid')).toString();
    return _device!;
  }

  // ------------------------- امضا -------------------------
  Uint8List _b64u(String s) {
    var t = s.replaceAll('-', '+').replaceAll('_', '/');
    while (t.length % 4 != 0) {
      t += '=';
    }
    return base64.decode(t);
  }

  _Lic? _verify(String token, String phone, String device) {
    try {
      final parts = token.split('.');
      if (parts.length != 2) return null;
      final sig = _b64u(parts[1]);
      if (sig.length != 64) return null;
      final pub = ed.PublicKey(base64.decode(kLicensePublicKeyB64));
      final msg = Uint8List.fromList(utf8.encode(parts[0]));
      if (!ed.verify(pub, msg, sig)) return null;
      final j = jsonDecode(utf8.decode(_b64u(parts[0])));
      if (j is! Map || j['v'] != 1) return null;
      if (j['phone'] != phone) return null;
      if ((j['dev'] ?? '') != device) return null;
      final exp = j['exp'] is String && (j['exp'] as String).isNotEmpty ? DateTime.tryParse(j['exp'] as String) : null;
      final iatSec = (j['iat'] as num).toInt();
      final featRaw = j['feat'];
      return _Lic(
        phone,
        j['active'] == true,
        exp,
        (j['plan'] as String?) ?? 'rial',
        DateTime.fromMillisecondsSinceEpoch(iatSec * 1000, isUtc: true),
        (j['dev'] ?? '') as String,
        tier: j['tier'] == 'gold' ? 'gold' : 'green',
        features: featRaw is List ? featRaw.whereType<String>().toList() : null,
        exportOnly: j['mode'] == 'export_only',
      );
    } catch (_) {
      return null;
    }
  }

  // ------------------------- ذخیره‌سازی -------------------------
  Future<Map<String, dynamic>> _load() async {
    try {
      final f = await _file('license_state.json');
      if (!await f.exists()) return {};
      final j = jsonDecode(await f.readAsString());
      return j is Map<String, dynamic> ? j : {};
    } catch (_) {
      return {};
    }
  }

  Future<void> _save(Map<String, dynamic> m) async {
    final f = await _file('license_state.json');
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(m), flush: true);
    if (await f.exists()) await f.delete();
    await tmp.rename(f.path);
  }

  /// مجوز تازهٔ سرور را (اگر امضایش درست بود) ذخیره می‌کند. true = پذیرفته شد.
  Future<bool> accept(String phone, String token) async {
    final dev = await deviceId();
    if (_verify(token, phone, dev) == null) return false;
    final m = await _load();
    final now = DateTime.now().toUtc();
    final prev = DateTime.tryParse('${m['lastSeen'] ?? ''}');
    m['phone'] = phone;
    m['lic'] = token;
    m['lastSeen'] = ((prev != null && prev.isAfter(now)) ? prev : now).toIso8601String();
    try {
      await _save(m);
    } catch (_) {
      return false;
    }
    return true;
  }

  /// S22.T22.2: سطح و قابلیت‌های مجوز امضاشدهٔ ذخیره‌شده، بدون بررسی زمان (برای ورود آنلاین).
  /// null اگر مجوزی نیست یا امضایش درست نیست.
  Future<GuardResult?> signedEdition(String phone) async {
    final dev = await deviceId();
    final m = await _load();
    final token = m['lic'];
    if (token is! String || token.isEmpty) return null;
    final lic = _verify(token, phone, dev);
    if (lic == null) return null;
    return GuardResult(GuardVerdict.ok,
        plan: lic.plan, tier: lic.tier, features: lic.features, exportOnly: lic.exportOnly);
  }

  Future<void> clear() async {
    try {
      final f = await _file('license_state.json');
      if (await f.exists()) await f.delete();
    } catch (_) {}
    daysToOnlineCheck.value = null;
  }

  /// وضعیت اشتراک را فقط از روی مجوز امضادارِ ذخیره‌شده و ساعت سیستم می‌سنجد.
  /// [dbFloor] آخرین زمانی که در دیتابیس ثبت شده (ضد برگرداندن ساعت).
  Future<GuardResult> evaluate(String phone, {DateTime? dbFloor}) async {
    final dev = await deviceId();
    final m = await _load();
    final token = m['lic'];
    if (token is! String || token.isEmpty) return const GuardResult(GuardVerdict.noLicense);
    final lic = _verify(token, phone, dev);
    if (lic == null) return const GuardResult(GuardVerdict.invalid);

    final now = DateTime.now().toUtc();
    final lastSeen = DateTime.tryParse('${m['lastSeen'] ?? ''}');
    final localFloor = [lastSeen, dbFloor].whereType<DateTime>().fold<DateTime?>(
        null, (a, b) => a == null || b.isAfter(a) ? b : a);
    if ((localFloor != null && now.isBefore(localFloor.subtract(const Duration(minutes: 10)))) ||
        now.isBefore(lic.iat.subtract(const Duration(hours: 36)))) {
      return GuardResult(GuardVerdict.clockBack, expiry: lic.expDate);
    }

    final offlineAge = now.difference(lic.iat);
    final left = kMaxOfflineDays - offlineAge.inDays;
    daysToOnlineCheck.value = left < 0 ? 0 : left;
    final end = lic.expEndUtc;
    if (!lic.active) {
      return GuardResult(GuardVerdict.inactive,
          expiry: lic.expDate, plan: lic.plan, tier: lic.tier, features: lic.features, exportOnly: lic.exportOnly);
    }
    if (end == null || now.isAfter(end)) {
      return GuardResult(GuardVerdict.expired,
          expiry: lic.expDate, plan: lic.plan, tier: lic.tier, features: lic.features, exportOnly: lic.exportOnly);
    }
    if (offlineAge > const Duration(days: kMaxOfflineDays)) {
      return GuardResult(GuardVerdict.offlineTooLong,
          expiry: lic.expDate,
          plan: lic.plan,
          daysToOnlineCheck: 0,
          tier: lic.tier,
          features: lic.features,
          exportOnly: lic.exportOnly);
    }

    // پیش‌روی «آخرین زمان دیده‌شده» (حداکثر دقیقه‌ای یک‌بار نوشته می‌شود)
    if (lastSeen == null || now.difference(lastSeen).inMinutes >= 1) {
      m['lastSeen'] = now.toIso8601String();
      try {
        await _save(m);
      } catch (_) {}
    }
    return GuardResult(GuardVerdict.ok,
        expiry: lic.expDate,
        plan: lic.plan,
        daysToOnlineCheck: left < 0 ? 0 : left,
        tier: lic.tier,
        features: lic.features,
        exportOnly: lic.exportOnly);
  }
}
