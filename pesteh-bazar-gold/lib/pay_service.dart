import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'license_service.dart';

/// خطای قابل‌نمایش از pay.php (متن فارسی از سرور)
class PayException implements Exception {
  final String message;
  final String? code;
  final int status;
  PayException(this.message, {this.code, this.status = 0});
  @override
  String toString() => message;
}

/// ارتباط با pay.php (تمدید، پرداخت، قرارداد). هیچ تصمیم مالی اینجا گرفته نمی‌شود؛
/// مبلغ و تخفیف و فعال‌سازی همه روی سرور است.
class PayService {
  PayService._();
  static final PayService I = PayService._();

  static const _kPendingKey = 'pay_pending_order';

  Future<Map<String, dynamic>> call(String action, [Map<String, dynamic> payload = const {}, String? idem]) async {
    final cred = await LicenseService.I.credentials();
    if (cred == null) throw PayException('نیاز به ورود مجدد است', code: 'no_session', status: 401);
    final body = <String, dynamic>{
      'phone': cred.$1,
      'token': cred.$2,
      'action': action,
      'payload': payload,
    };
    if (idem != null) body['idem'] = idem;

    http.Response resp;
    try {
      resp = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/pay.php'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw PayException('سرور در زمان مناسب پاسخ نداد. دوباره تلاش کنید.');
    } catch (_) {
      throw PayException('اتصال به سرور برقرار نشد. اینترنت را بررسی کنید.');
    }

    Map<String, dynamic> data;
    try {
      data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw PayException('پاسخ نامعتبر از سرور (کد ${resp.statusCode}).', status: resp.statusCode);
    }
    if (resp.statusCode != 200) {
      // توکن دیگر معتبر نیست: محافظ اصلی (LicenseGate) تصمیم می‌گیرد
      if (resp.statusCode == 401) LicenseService.I.sessionInvalid.value++;
      throw PayException(
        (data['error'] as String?) ?? 'خطای ارتباط با سرور',
        code: data['code'] as String?,
        status: resp.statusCode,
      );
    }
    return data;
  }

  // ---------------- سفارش‌های درگاه (برای پیگیری بعد از برگشت از مرورگر)

  Future<String?> pendingOrderId() async {
    final sp = await SharedPreferences.getInstance();
    final v = sp.getString(_kPendingKey);
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> setPendingOrder(String id) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kPendingKey, id);
  }

  Future<void> clearPendingOrder() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kPendingKey);
  }

  // ---------------- قرارداد

  /// null یعنی لازم نیست (قراردادی نیست یا همین نسخه پذیرفته شده)؛ وگرنه متن قرارداد.
  Future<Map<String, dynamic>?> pendingContract() async {
    final d = await call('contract.get');
    if (d['accepted'] == true) return null;
    final item = d['item'];
    if (item is! Map) return null;
    return Map<String, dynamic>.from(item);
  }

  Future<void> acceptContract(int version) async {
    final device = '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    await call('contract.accept', {
      'version': version,
      'platform': Platform.isWindows ? 'windows' : 'android',
      'device': device.length > 200 ? device.substring(0, 200) : device,
    });
  }

  /// شناسهٔ یکتا برای idem (هر انتخاب یک بار ساخته می‌شود و تا تغییر انتخاب ثابت می‌ماند)
  static String newIdem() {
    final r = Random();
    return '${DateTime.now().microsecondsSinceEpoch}-${r.nextInt(1 << 31)}';
  }
}
