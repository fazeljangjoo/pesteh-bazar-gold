import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'license_service.dart';

/// نتیجهٔ یک فراخوانی دستیار: پاسخ موفق (blocks) یا پیام فارسی خطا.
class AssistantResult {
  final bool ok;
  final Map<String, dynamic>? data;
  final String message;
  final bool retryable;
  final bool authExpired;

  const AssistantResult._({
    required this.ok,
    this.data,
    this.message = '',
    this.retryable = false,
    this.authExpired = false,
  });

  factory AssistantResult.success(Map<String, dynamic> data) =>
      AssistantResult._(ok: true, data: data);

  factory AssistantResult.failure(
    String message, {
    bool retryable = false,
    bool authExpired = false,
  }) =>
      AssistantResult._(
        ok: false,
        message: message,
        retryable: retryable,
        authExpired: authExpired,
      );
}

/// فراخوانی `assistant.php` با همان phone/token و base URL و timeout اپ (مثل LicenseService._post).
/// هیچ منطق کسب‌وکاری اینجا نیست؛ همه‌چیز از سرور می‌آید.
class AssistantApi {
  AssistantApi._();

  static const Duration _timeout = Duration(seconds: 20);

  /// پرسش از پسته‌کاو (مدل هوش مصنوعی) کندتر است؛ timeout بلندتر فقط برای همین عمل.
  static const Duration _aiTimeout = Duration(seconds: 60);

  /// [q] نام اکشن (menu, stock_total, …)؛ [step] start | answer | send | poll؛ [params] اختیاری.
  /// [timeout] اختیاری است؛ اگر نشود، برای `ai_ask/answer` ۶۰ ثانیه و در بقیهٔ موارد ۲۰ ثانیه است.
  static Future<AssistantResult> call(
    String q, {
    String step = 'start',
    Map<String, dynamic>? params,
    Duration? timeout,
  }) async {
    final effectiveTimeout =
        timeout ?? (q == 'ai_ask' && step == 'answer' ? _aiTimeout : _timeout);
    final cred = await LicenseService.I.credentials();
    if (cred == null) {
      return AssistantResult.failure('نیاز به ورود مجدد است', authExpired: true);
    }
    final body = <String, dynamic>{
      'phone': cred.$1,
      'token': cred.$2,
      'q': q,
      'step': step,
    };
    if (params != null) body['params'] = params;

    http.Response resp;
    try {
      resp = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/assistant.php'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(effectiveTimeout);
    } on TimeoutException {
      return AssistantResult.failure(
        'سرور در زمان مناسب پاسخ نداد. اینترنت را بررسی کنید و دوباره تلاش کنید.',
        retryable: true,
      );
    } on SocketException {
      return AssistantResult.failure(
        'اتصال به اینترنت برقرار نیست؛ دوباره تلاش کنید',
        retryable: true,
      );
    } on HandshakeException {
      return AssistantResult.failure('خطای SSL/گواهی امنیتی.', retryable: true);
    } on http.ClientException {
      return AssistantResult.failure(
        'اتصال به اینترنت برقرار نیست؛ دوباره تلاش کنید',
        retryable: true,
      );
    } catch (_) {
      return AssistantResult.failure('خطای غیرمنتظره؛ دوباره تلاش کنید', retryable: true);
    }

    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      data = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      data = <String, dynamic>{};
    }
    final serverMsg = data['error'] is String ? data['error'] as String : '';

    if (resp.statusCode == 401) {
      // مثل بقیهٔ اپ: سرور توکن را نپذیرفته؛ صفحهٔ ورود از طریق LicenseGate مدیریت می‌شود
      LicenseService.I.sessionInvalid.value++;
      return AssistantResult.failure(
        serverMsg.isNotEmpty ? serverMsg : 'نیاز به ورود مجدد است',
        authExpired: true,
      );
    }
    if (resp.statusCode == 200 && data['blocks'] is List) {
      return AssistantResult.success(data);
    }
    return AssistantResult.failure(
      serverMsg.isNotEmpty ? serverMsg : 'پاسخ نامعتبر از سرور (کد ${resp.statusCode}).',
      retryable: resp.statusCode >= 500,
    );
  }
}
