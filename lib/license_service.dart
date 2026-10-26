import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'db.dart';
import 'edition.dart';
import 'perms.dart';
import 'dpapi.dart';
import 'license_guard.dart';
import 'sync_service.dart';
import 'utils.dart';

/// اطلاعات تماس شما برای فعال‌سازی/تمدید اشتراک — حتماً این‌ها را با اطلاعات
/// واقعی خودتان جایگزین کنید.
class SupportContact {
  /// شماره‌ای که به کاربر نمایش داده می‌شود
  static const String displayPhone = '۰۹۱۳۴۹۷۰۴۸۳';

  /// همان شماره با کد کشور و بدون صفر، برای دکمه «تماس» (tel:)
  static const String callNumber = '+989134970483';

  /// همان شماره با کد کشور، بدون + و بدون صفر ابتدایی، برای دکمه واتس‌اپ
  static const String whatsappNumber = '989134970483';
}

/// آدرس سرور خودتان (همان بک‌اند PHP که روی هاست آپلود کردید).
/// حتماً «https://» و بدون اسلش انتهایی وارد کنید.
/// مثال: 'https://example.com/backend' یا 'https://api.example.com'
class ApiConfig {
  static const String baseUrl = 'https://pesteh-bazar.ir/backend/api';
}

enum LicenseState {
  /// هنوز وارد حساب نشده (نیاز به شماره + کد پیامکی، یا شماره + رمز عبور)
  loggedOut,

  /// وارد شده اما نه اینترنت داریم و نه سابقهٔ تاییدشدهٔ قبلی از اشتراک
  needsInternet,

  /// اشتراک فعال نیست / هنوز فعال نشده / منقضی شده
  blocked,

  /// اشتراک معتبر است
  valid,
}

/// نتیجهٔ درخواست ارسال کد پیامکی
class OtpSendResult {
  /// کد ارسال شد
  final bool ok;

  /// پیام خطای قابل‌نمایش (اگر ok نباشد)
  final String? error;

  /// ثانیه‌های باقی‌مانده تا امکان ارسال دوبارهٔ کد
  final int resendIn;
  const OtpSendResult({required this.ok, this.error, this.resendIn = 0});

  /// اگر کد قبلاً فرستاده شده و فقط مهلت ارسال دوباره باقی است، کاربر باید به مرحلهٔ وارد کردن کد برود
  bool get canEnterCode => ok || resendIn > 0;
}

/// نتیجهٔ تأیید کد پیامکی
class OtpVerifyResult {
  final String? error;

  /// کاربر جدید است و باید نامش را وارد کند (کد هنوز مصرف نشده)
  final bool needName;

  /// حساب همین الان ساخته شد (اشتراک آزمایشی فعال شد)
  final bool isNew;
  final int daysLeft;
  const OtpVerifyResult({this.error, this.needName = false, this.isNew = false, this.daysLeft = 0});

  bool get ok => error == null && !needName;
}

/// اطلاعات حساب از سرور (account.status): نام و اینکه کاربر رمز عبور گذاشته یا نه
class AccountInfo {
  final String? name;
  final bool hasPassword;
  const AccountInfo({this.name, this.hasPassword = false});
}

/// نتیجهٔ عملیات حساب (ذخیرهٔ نام / رمز)؛ error=null یعنی موفق
class AccountOpResult {
  final String? error;
  const AccountOpResult([this.error]);
  bool get ok => error == null;
}

class _ApiResp {
  final int status;
  final Map<String, dynamic> data;
  final String? netError;
  _ApiResp(this.status, this.data, [this.netError]);
}

class LicenseResult {
  final LicenseState state;
  final String? phone;
  final String? name;
  final DateTime? expiry;

  /// پیام توضیحی برای کاربر (نسخهٔ ویندوز: دلیل نیاز به اتصال/مسدودی)
  final String? message;
  /// S22.T22.2: طلایی منقضی — فقط خروجی
  final bool readOnlyExport;

  LicenseResult(this.state, {this.phone, this.name, this.expiry, this.message, this.readOnlyExport = false});

  int get remainingDays {
    if (expiry == null) return 0;
    final now = DateTime.now();
    final end = DateTime(expiry!.year, expiry!.month, expiry!.day, 23, 59, 59);
    final diff = end.difference(now).inHours / 24;
    return diff < 0 ? 0 : diff.ceil();
  }
}

/// مدیریت ورود (شماره موبایل + کد پیامکی، یا شماره + رمز عبور) و بررسی اعتبار اشتراک،
/// از طریق سرور PHP خودتان (به‌جای Firebase) — دقیقاً مثل نسخهٔ وب.
///
/// جریان ورود: ۱) otp_send.php کد را می‌فرستد ۲) otp_verify.php کد را تأیید می‌کند.
/// اگر شماره جدید باشد، سرور {need_name: true} برمی‌گرداند (کد مصرف نمی‌شود)؛
/// برنامه نام را می‌پرسد و همان کد را همراه نام دوباره می‌فرستد؛ حساب جدید با
/// اشتراک آزمایشی ساخته می‌شود.
///
/// بعد از ورود موفق، سرور یک «توکن» طولانی‌مدت می‌سازد که روی گوشی ذخیره می‌شود؛
/// دفعات بعد همان توکن برای بررسی اعتبار اشتراک استفاده می‌شود.
class LicenseService {
  LicenseService._();
  static final LicenseService I = LicenseService._();

  static const _kPhoneKey = 'license_phone';
  static const _kTokenKey = 'license_token';
  static const _kActiveKey = 'license_active';
  static const _kExpiryKey = 'license_expiry';
  static const _kNameKey = 'license_name';
  static const _kPlanKey = 'license_plan';

  /// آیا اشتراک این کاربر «پلن ارزی» است؟ (فقط وقتی true است قیمت دلار، سود دلاری و فاکتور ارزی دیده می‌شود)
  /// مرجع تصمیم سرور است؛ آخرین مقدار روی گوشی ذخیره می‌شود تا آفلاین هم کار کند.
  final ValueNotifier<bool> isFx = ValueNotifier<bool>(false);

  Future<void> _setPlan(dynamic raw) async {
    final fx = raw == 'fx';
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kPlanKey, fx ? 'fx' : 'rial');
    if (isFx.value != fx) isFx.value = fx;
  }

  Future<void> _loadPlan() async {
    final sp = await SharedPreferences.getInstance();
    final fx = sp.getString(_kPlanKey) == 'fx';
    if (isFx.value != fx) isFx.value = fx;
  }

  /// پیام خوش‌آمدگویی کاربر جدید؛ یک‌بار توسط LicenseGate نمایش داده می‌شود
  String? _pendingWelcome;
  String? takeWelcome() {
    final w = _pendingWelcome;
    _pendingWelcome = null;
    return w;
  }

  /// دقیقاً مثل normalize_phone در سرور: 0098912... و 098912... و 0912... همه به 98912... تبدیل می‌شوند
  String normalizePhone(String raw) {
    var s = toEnDigits(raw.trim()).replaceAll(RegExp(r'[^0-9]'), '');
    if (s.startsWith('0098')) {
      s = s.substring(2);
    } else if (s.startsWith('0')) {
      s = '98${s.substring(1)}';
    }
    if (!s.startsWith('98')) s = '98$s';
    return s;
  }

  /// فقط شمارهٔ موبایل ایران (989xxxxxxxxx) معتبر است (مثل is_valid_mobile در سرور)
  bool isValidPhone(String raw) => RegExp(r'^989\d{9}$').hasMatch(normalizePhone(raw));

  /// حداقل طول رمز عبور (مثل PASSWORD_MIN_LEN در سرور)
  static const int passwordMinLen = 6;

  /// با هر پاسخ ۴۰۱ از سرور داده‌ها (یعنی توکن دیگر معتبر نیست) زیاد می‌شود تا LicenseGate
  /// وضعیت را دوباره بررسی کند و در صورت نیاز کاربر را به صفحهٔ ورود ببرد (مثل وب).
  final ValueNotifier<int> sessionInvalid = ValueNotifier<int>(0);

  /// تاریخ انقضای آخرین وضعیت شناخته‌شده؛ برای نوار یادآوری تمدید
  final ValueNotifier<DateTime?> expiry = ValueNotifier<DateTime?>(null);

  // در فاصلهٔ تغییر رمز، توکن روی سرور عوض شده ولی هنوز توکن جدید ذخیره نشده؛
  // در این فاصله ۴۰۱ ناشی از همین تغییر است و نباید کاربر را خارج کند.
  bool _tokenChanging = false;

  Future<String?> savedPhone() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_kPhoneKey);
  }

  Future<String?> savedName() async {
    final sp = await SharedPreferences.getInstance();
    final n = sp.getString(_kNameKey);
    return (n == null || n.trim().isEmpty) ? null : n;
  }

  Future<String?> _savedToken() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kTokenKey);
    if (raw == null) return null;
    return kStrictLicense ? TokenVault.open(raw) : raw;
  }

  /// برای پشتیبان‌گیری: شماره و توکن ذخیره‌شده (اگر کاربر وارد شده باشد)
  Future<(String, String)?> credentials() async {
    final phone = await savedPhone();
    final token = await _savedToken();
    if (phone == null || token == null || phone.isEmpty || token.isEmpty) return null;
    return (phone, token);
  }

  bool get isSignedIn => _signedInCache;
  bool _signedInCache = false;

  Future<void> _restoreSignedInFlag() async {
    final phone = await savedPhone();
    final token = await _savedToken();
    _signedInCache = phone != null && token != null;
  }

  /// یک درخواست POST به API؛ خطاهای شبکه را به پیام فارسی تبدیل می‌کند.
  Future<_ApiResp> _post(String path, Map<String, dynamic> body, {int timeoutSec = 20}) async {
    try {
      final resp = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/$path'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(Duration(seconds: timeoutSec));
      Map<String, dynamic> data;
      try {
        data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      } on FormatException {
        // سرور جواب JSON نداده (مثلاً صفحهٔ خطا/ریدایرکت/فایروال هاست)
        return _ApiResp(resp.statusCode, {}, 'پاسخ نامعتبر از سرور (کد ${resp.statusCode}).');
      }
      return _ApiResp(resp.statusCode, data);
    } on TimeoutException {
      return _ApiResp(0, {}, 'سرور در زمان مناسب پاسخ نداد. اینترنت/VPN را بررسی کنید و دوباره تلاش کنید.');
    } on SocketException catch (e) {
      return _ApiResp(0, {}, 'اتصال به سرور برقرار نشد.\n${e.message}');
    } on HandshakeException catch (e) {
      return _ApiResp(0, {}, 'خطای SSL/گواهی امنیتی.\n${e.message}');
    } on http.ClientException catch (e) {
      return _ApiResp(0, {}, 'اتصال به سرور برقرار نشد.\n${e.message}');
    } catch (e) {
      return _ApiResp(0, {}, 'خطای غیرمنتظره:\n$e');
    }
  }

  /// مرحلهٔ ۱ ورود: ارسال کد پیامکی به شماره.
  /// سقف‌ها (۴ کد در ساعت و ۱۰ کد در روز برای هر شماره/دستگاه) سمت سرور اعمال می‌شود
  /// و پیام فارسی خطا (کد 429) همان‌طور که هست نمایش داده می‌شود.
  Future<OtpSendResult> sendOtp(String phone) async {
    if (!isValidPhone(phone)) return const OtpSendResult(ok: false, error: 'شماره موبایل را درست وارد کنید');
    final r = await _post('otp_send.php', {'phone': normalizePhone(phone)});
    if (r.netError != null) return OtpSendResult(ok: false, error: r.netError);
    final resendIn = (r.data['resend_in'] is num) ? (r.data['resend_in'] as num).toInt() : 0;
    if (r.status == 200 && r.data['ok'] == true) {
      return OtpSendResult(ok: true, resendIn: resendIn > 0 ? resendIn : 60);
    }
    return OtpSendResult(
      ok: false,
      error: (r.data['error'] as String?) ?? 'ارسال کد ناموفق بود؛ دوباره تلاش کنید.',
      resendIn: resendIn,
    );
  }

  /// مرحلهٔ ۲ ورود: تأیید کد. برای کاربر جدید ابتدا بدون [name] صدا زده می‌شود؛
  /// اگر needName برگشت، نام گرفته می‌شود و دوباره با همان کد و نام صدا زده می‌شود.
  Future<OtpVerifyResult> verifyOtp(String phone, String code, {String? name, String? password}) async {
    if (!isValidPhone(phone)) return const OtpVerifyResult(error: 'شماره موبایل را درست وارد کنید');
    final cleanCode = toEnDigits(code.trim()).replaceAll(RegExp(r'[^0-9]'), '');
    if (cleanCode.isEmpty) return const OtpVerifyResult(error: 'کد پیامکی را وارد کنید');
    final n = normalizePhone(phone);
    final cleanName = name?.trim().replaceAll(RegExp(r'\s+'), ' ');

    final body = <String, dynamic>{'phone': n, 'code': cleanCode};
    if (cleanName != null && cleanName.isNotEmpty) body['name'] = cleanName;
    if (password != null && password.isNotEmpty) body['password'] = password; // فقط برای ثبت‌نام کاربر جدید
    if (kStrictLicense) body['device'] = await LicenseGuard.I.deviceId();
    final r = await _post('otp_verify.php', body);
    if (r.netError != null) return OtpVerifyResult(error: r.netError);
    if (r.status != 200) {
      return OtpVerifyResult(error: (r.data['error'] as String?) ?? 'ورود ناموفق بود؛ دوباره تلاش کنید.');
    }
    if (r.data['need_name'] == true) return const OtpVerifyResult(needName: true);

    final err = await _finishLogin(n, r.data);
    if (err != null) return OtpVerifyResult(error: err);

    final isNew = r.data['is_new'] == true;
    final daysLeft = (r.data['days_left'] is num) ? (r.data['days_left'] as num).toInt() : 0;
    if (isNew) {
      _pendingWelcome =
          'خوش آمدید! ${faNum(daysLeft > 0 ? daysLeft : 20, dec: 0)} روز اشتراک آزمایشی رایگان برای شما فعال شد';
    }
    return OtpVerifyResult(isNew: isNew, daysLeft: daysLeft);
  }

  /// ذخیرهٔ نتیجهٔ ورود موفق (مشترک بین ورود با پیامک و ورود با رمز)؛ در خطا پیام برمی‌گرداند
  Future<String?> _finishLogin(String normalizedPhone, Map<String, dynamic> data) async {
    final token = data['token'];
    if (token is! String || token.isEmpty) return 'پاسخ نامعتبر از سرور.';
    if (kStrictLicense) {
      // نسخهٔ ویندوز: بدون مجوز امضادارِ معتبر وارد نمی‌شویم
      final lic = data['lic'];
      if (lic is! String || !await LicenseGuard.I.accept(normalizedPhone, lic)) {
        return 'مجوز اشتراک از سرور دریافت نشد یا معتبر نیست. اگر این پیام تکرار شد با پشتیبانی تماس بگیرید.';
      }
    }
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kPhoneKey, normalizedPhone);
    await sp.setString(_kTokenKey, kStrictLicense ? TokenVault.seal(token) : token);
    final srvName = data['name'];
    if (srvName is String && srvName.trim().isNotEmpty) {
      await sp.setString(_kNameKey, srvName.trim());
    } else {
      await sp.remove(_kNameKey);
    }
    await _saveCache(data['active'] == true, _parseDate(data['expiry_date']));
    await _setPlan(data['plan']);
    await EditionService.I.apply(data['edition'], data['plan']);
    if (kStrictLicense) {
      // S22.T22.2: سطح از مجوز امضادار؛ JSON سرور نمی‌تواند طلایی را جای آن بنشاند
      final se = await LicenseGuard.I.signedEdition(normalizedPhone);
      if (se != null) await _applySigned(se);
    }
    await StaffPerms.I.apply(data['staff']); // T02.2: کارکن → مجوزها؛ مالک → null
    _signedInCache = true;
    return null;
  }

  /// ورود با شماره + رمز عبور (راه جایگزین وقتی پیامک نمی‌رسد). فقط برای حساب‌هایی که رمز دارند.
  /// خطاها (شماره/رمز اشتباه، محدودیت تلاش) با پیام فارسی خود سرور برمی‌گردند.
  /// نتیجه: null = موفق، وگرنه متن خطا.
  Future<String?> signInWithPassword(String phone, String password) async {
    if (phone.trim().isEmpty) return 'شماره موبایل را وارد کنید';
    if (!isValidPhone(phone)) return 'شماره موبایل را درست وارد کنید (مثال: 09123456789)';
    if (password.isEmpty) return 'رمز عبور را وارد کنید';
    final n = normalizePhone(phone);
    final loginBody = <String, dynamic>{'phone': n, 'password': password};
    if (kStrictLicense) loginBody['device'] = await LicenseGuard.I.deviceId();
    final r = await _post('login.php', loginBody);
    if (r.netError != null) return r.netError;
    if (r.status != 200) {
      return (r.data['error'] as String?) ?? 'ورود ناموفق بود؛ دوباره تلاش کنید.';
    }
    return _finishLogin(n, r.data);
  }

  /// ورود کارکن: شمارهٔ مالک + نام کاربری + رمز (staff_login.php). نتیجه: null = موفق، وگرنه متن خطا.
  Future<String?> signInStaff(String ownerPhone, String username, String password) async {
    if (ownerPhone.trim().isEmpty) return 'شماره موبایل مالک را وارد کنید';
    if (!isValidPhone(ownerPhone)) return 'شماره موبایل مالک را درست وارد کنید (مثال: 09123456789)';
    if (username.trim().isEmpty) return 'نام کاربری کارکن را وارد کنید';
    if (password.isEmpty) return 'رمز عبور را وارد کنید';
    final n = normalizePhone(ownerPhone);
    final body = <String, dynamic>{'phone': n, 'username': username.trim(), 'password': password};
    if (kStrictLicense) body['device'] = await LicenseGuard.I.deviceId();
    final r = await _post('staff_login.php', body);
    if (r.netError != null) return r.netError;
    if (r.status != 200) {
      return (r.data['error'] as String?) ?? 'ورود کارکن ناموفق بود؛ دوباره تلاش کنید.';
    }
    return _finishLogin(n, r.data);
  }

  // ======================= حساب کاربری (نام / رمز عبور) =======================

  /// فراخوانی app.php با شماره و توکن ذخیره‌شده (برای account.*)
  Future<_ApiResp> _appCall(String action, Map<String, dynamic> payload) async {
    final cred = await credentials();
    if (cred == null) return _ApiResp(401, {'error': 'نیاز به ورود مجدد است'});
    return _post('app.php', {'phone': cred.$1, 'token': cred.$2, 'action': action, 'payload': payload});
  }

  /// نام و وضعیت «رمز دارد/ندارد» را از سرور می‌خواند؛ در خطا (آفلاین و ...) null
  Future<AccountInfo?> fetchAccountInfo() async {
    final r = await _appCall('account.status', {});
    if (r.netError != null || r.status != 200) {
      if (r.status == 401 && !_tokenChanging) sessionInvalid.value++;
      return null;
    }
    final item = r.data['item'];
    if (item is! Map) return null;
    final name = item['name'];
    final n = (name is String && name.trim().isNotEmpty) ? name.trim() : null;
    final sp = await SharedPreferences.getInstance();
    if (n != null) {
      await sp.setString(_kNameKey, n);
    } else {
      await sp.remove(_kNameKey);
    }
    await StaffPerms.I.apply(item['staff']); // T02.2: مجوزهای تازه (کارکن) یا پاک‌کردن (مالک)
    return AccountInfo(name: n, hasPassword: item['has_password'] == true);
  }

  /// ذخیرهٔ نام (۲ تا ۶۰ حرف)
  Future<AccountOpResult> setName(String rawName) async {
    final name = rawName.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (name.length < 2) return const AccountOpResult('نام را وارد کنید (حداقل ۲ حرف)');
    final r = await _appCall('account.set_name', {'name': name});
    if (r.netError != null) return AccountOpResult(r.netError);
    if (r.status == 401 && !_tokenChanging) sessionInvalid.value++;
    if (r.status != 200) return AccountOpResult((r.data['error'] as String?) ?? 'ذخیرهٔ نام ناموفق بود');
    final saved = r.data['name'];
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kNameKey, (saved is String && saved.isNotEmpty) ? saved : name);
    return const AccountOpResult();
  }

  /// تعیین/تغییر رمز عبور توسط خود کاربر. [currentPassword] فقط وقتی لازم است که کاربر قبلاً رمز گذاشته باشد.
  /// با هر تغییر، سرور توکن را عوض می‌کند: همین دستگاه با توکن جدید (new_token) وارد می‌ماند و
  /// بقیهٔ دستگاه‌ها در اولین بررسی خارج می‌شوند.
  Future<AccountOpResult> setPassword({String currentPassword = '', required String newPassword}) async {
    if (newPassword.length < passwordMinLen) {
      return const AccountOpResult('رمز جدید باید حداقل ۶ کاراکتر باشد');
    }
    _tokenChanging = true;
    try {
      final r = await _appCall('account.set_password', {
        'current_password': currentPassword,
        'new_password': newPassword,
      });
      if (r.netError != null) return AccountOpResult(r.netError);
      if (r.status != 200) {
        if (r.status == 401) sessionInvalid.value++;
        return AccountOpResult((r.data['error'] as String?) ?? 'ذخیرهٔ رمز عبور ناموفق بود');
      }
      final newToken = r.data['new_token'];
      if (newToken is String && newToken.isNotEmpty) {
        final sp = await SharedPreferences.getInstance();
        await sp.setString(_kTokenKey, kStrictLicense ? TokenVault.seal(newToken) : newToken);
      }
      return const AccountOpResult();
    } finally {
      _tokenChanging = false;
    }
  }

  Future<void> signOut() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kPhoneKey);
    await sp.remove(_kTokenKey);
    await sp.remove(_kActiveKey);
    await sp.remove(_kExpiryKey);
    await sp.remove(_kNameKey);
    await sp.remove(_kPlanKey);
    isFx.value = false;
    await EditionService.I.clear();
    await StaffPerms.I.clear();
    _signedInCache = false;
    expiry.value = null;
    if (kStrictLicense) await LicenseGuard.I.clear();
    // دیتابیس هر حساب جداست و روی گوشی می‌ماند؛ فقط بسته می‌شود. اگر عملیات ارسال‌نشده
    // داشته باشد، با ورود دوباره به همان حساب ارسال می‌شود.
    SyncService.I.stop();
    await AppDb.I.closeAccount();
  }

  Future<void> _saveCache(bool active, DateTime? expiry) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kActiveKey, active);
    if (expiry != null) {
      await sp.setString(_kExpiryKey, expiry.toIso8601String());
    } else {
      await sp.remove(_kExpiryKey);
    }
    this.expiry.value = (active && expiry != null) ? expiry : null;
  }

  Future<(bool, DateTime?)> _loadCache() async {
    final sp = await SharedPreferences.getInstance();
    final active = sp.getBool(_kActiveKey) ?? false;
    final expStr = sp.getString(_kExpiryKey);
    final expiry = expStr == null ? null : DateTime.tryParse(expStr);
    return (active, expiry);
  }

  DateTime? _parseDate(dynamic raw) {
    if (raw == null) return null;
    if (raw is String) return DateTime.tryParse(raw);
    return null;
  }

  // ======================= نسخهٔ ویندوز: مجوز امضادار =======================

  /// آخرین زمانی که در دیتابیس محلی ثبت شده (ضد برگرداندن ساعت)؛ خطا = null
  Future<DateTime?> _dbFloor(String phone) async {
    try {
      await AppDb.I.useAccount(phone);
      final v = await AppDb.I.metaGet('clock_floor');
      return v == null ? null : DateTime.tryParse(v);
    } catch (_) {
      return null;
    }
  }

  Future<void> _bumpDbFloor() async {
    try {
      if (!AppDb.I.hasAccount) return;
      final v = await AppDb.I.metaGet('clock_floor');
      final prev = v == null ? null : DateTime.tryParse(v);
      final now = DateTime.now().toUtc();
      if (prev == null || now.difference(prev).inMinutes >= 5) {
        await AppDb.I.metaSet('clock_floor', now.toIso8601String());
      }
    } catch (_) {}
  }

  Future<LicenseResult> _checkStrict(String phone, String token) async {
    final device = await LicenseGuard.I.deviceId();
    try {
      final resp = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/check.php'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'phone': phone, 'token': token, 'device': device}),
          )
          .timeout(const Duration(seconds: 10));

      if (resp.statusCode == 401) {
        if (!_tokenChanging) {
          await signOut();
          return LicenseResult(LicenseState.loggedOut);
        }
      } else if (resp.statusCode == 200) {
        final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
        final lic = data['lic'];
        if (lic is! String || !await LicenseGuard.I.accept(phone, lic)) {
          return LicenseResult(LicenseState.needsInternet,
              phone: phone,
              message: 'مجوز اشتراک از سرور دریافت نشد (سرور هنوز برای نسخهٔ ویندوز به‌روز نشده است). '
                  'با پشتیبانی تماس بگیرید.');
        }
        final sp = await SharedPreferences.getInstance();
        final srvName = data['name'];
        if (srvName is String && srvName.trim().isNotEmpty) {
          await sp.setString(_kNameKey, srvName.trim());
        }
      }
      // سایر کدها (۵۰۰ و ...) مثل آفلاین رفتار می‌کنند و از مجوز ذخیره‌شده استفاده می‌شود
    } catch (_) {
      // آفلاین: فقط با مجوز امضادار ذخیره‌شده
    }
    return _strictFromGuard(phone);
  }

  /// S22.T22.2: سطح و قابلیت‌ها فقط از مجوز امضادار
  Future<void> _applySigned(GuardResult g) async {
    await EditionService.I.applySigned(
      tier: g.tier ?? 'green',
      plan: g.plan ?? 'rial',
      features: g.features,
      exportOnly: g.exportOnly,
    );
  }

  Future<LicenseResult> _strictFromGuard(String phone) async {
    final g = await LicenseGuard.I.evaluate(phone, dbFloor: await _dbFloor(phone));
    final name = await savedName();
    if (g.expiry != null) {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kExpiryKey, g.expiry!.toIso8601String());
    }
    if (g.plan != null) await _setPlan(g.plan);
    if (g.tier != null) await _applySigned(g);
    expiry.value = g.verdict == GuardVerdict.ok ? g.expiry : null;
    switch (g.verdict) {
      case GuardVerdict.ok:
        await _bumpDbFloor();
        return LicenseResult(LicenseState.valid, phone: phone, name: name, expiry: g.expiry);
      case GuardVerdict.noLicense:
        return LicenseResult(LicenseState.needsInternet,
            phone: phone,
            name: name,
            message: 'برای تأیید اشتراک روی این کامپیوتر، یک‌بار باید به اینترنت وصل شوید.');
      case GuardVerdict.invalid:
        return LicenseResult(LicenseState.needsInternet,
            phone: phone,
            name: name,
            message: 'مجوز ذخیره‌شده روی این کامپیوتر معتبر نیست. برای دریافت دوبارهٔ آن به اینترنت وصل شوید.');
      case GuardVerdict.clockBack:
        return LicenseResult(LicenseState.needsInternet,
            phone: phone,
            name: name,
            message: 'تاریخ/ساعت کامپیوتر نادرست است (به عقب برگشته). ساعت را درست کنید و به اینترنت وصل شوید.');
      case GuardVerdict.offlineTooLong:
        return LicenseResult(LicenseState.needsInternet,
            phone: phone,
            name: name,
            message: 'بیش از $kMaxOfflineDays روز است اشتراک آنلاین تأیید نشده. یک‌بار به اینترنت وصل شوید '
                '(اطلاعات شما سالم است).');
      case GuardVerdict.inactive:
        return LicenseResult(LicenseState.blocked, phone: phone, name: name, expiry: g.expiry);
      case GuardVerdict.expired:
        // طلایی منقضی: فقط حالت خروجی (Q3)؛ بقیهٔ نسخه‌ها مثل قبل مسدود
        return LicenseResult(LicenseState.blocked,
            phone: phone, name: name, expiry: g.expiry, readOnlyExport: g.exportOnly);
    }
  }

  /// وضعیت اشتراک را برمی‌گرداند. اول تلاش می‌کند از سرور (آنلاین) بخواند؛
  /// اگر اینترنت نبود، بر اساس آخرین وضعیتِ تاییدشده‌ای که روی گوشی ذخیره شده
  /// تصمیم می‌گیرد (چون تاریخ انقضا ثابت است، با آفلاین‌ماندن قابل دور زدن نیست).
  Future<LicenseResult> check() async {
    await _restoreSignedInFlag();
    if (!isSignedIn) return LicenseResult(LicenseState.loggedOut);
    final phone = await savedPhone();
    final token = await _savedToken();
    if (phone == null || token == null) return LicenseResult(LicenseState.loggedOut);
    if (kStrictLicense) return _checkStrict(phone, token);

    try {
      final resp = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/check.php'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'phone': phone, 'token': token}),
          )
          .timeout(const Duration(seconds: 10));

      if (resp.statusCode == 401) {
        if (_tokenChanging) {
          // وسط تغییر رمز خودِ کاربر هستیم؛ این ۴۰۱ کاذب است و نباید خارج شود
          final (active, expiry) = await _loadCache();
          final valid = active && expiry != null && DateTime.now().isBefore(DateTime(expiry.year, expiry.month, expiry.day, 23, 59, 59));
          return LicenseResult(valid ? LicenseState.valid : LicenseState.blocked, phone: phone, name: await savedName(), expiry: expiry);
        }
        // توکن دیگر معتبر نیست (مثلاً رمز از دستگاه دیگر عوض شده)؛ کاربر باید دوباره وارد شود.
        await signOut();
        return LicenseResult(LicenseState.loggedOut);
      }

      final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final active = data['active'] == true;
      final expiry = _parseDate(data['expiry_date']);

      await _saveCache(active, expiry);
      await _setPlan(data['plan']);
      await EditionService.I.apply(data['edition'], data['plan']);
      // نام کاربر (برای نمایش در صفحهٔ اشتراک) هر بار از سرور تازه می‌شود
      final srvName = data['name'];
      final sp = await SharedPreferences.getInstance();
      if (srvName is String && srvName.trim().isNotEmpty) {
        await sp.setString(_kNameKey, srvName.trim());
      } else if (data.containsKey('name')) {
        await sp.remove(_kNameKey);
      }
      final name = await savedName();
      final valid = active &&
          expiry != null &&
          DateTime.now()
              .isBefore(DateTime(expiry.year, expiry.month, expiry.day, 23, 59, 59));
      return LicenseResult(valid ? LicenseState.valid : LicenseState.blocked,
          phone: phone, name: name, expiry: expiry);
    } catch (_) {
      final (active, expiry) = await _loadCache();
      await _loadPlan();
      await EditionService.I.load();
      final name = await savedName();
      this.expiry.value = (active && expiry != null) ? expiry : null;
      if (expiry == null) {
        return LicenseResult(LicenseState.needsInternet, phone: phone, name: name);
      }
      final valid = active &&
          DateTime.now()
              .isBefore(DateTime(expiry.year, expiry.month, expiry.day, 23, 59, 59));
      return LicenseResult(valid ? LicenseState.valid : LicenseState.blocked,
          phone: phone, name: name, expiry: expiry);
    }
  }
}
