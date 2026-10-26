import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'db.dart';
import 'entity_store.dart';
import 'license_service.dart';
import 'local_backup.dart';

/// وضعیت همگام‌سازی برای نمایش در صفحه‌ها
class SyncInfo {
  final int pending;
  final int failed;
  final bool running;
  final bool offline;
  final String? error;
  final DateTime? lastOk;
  const SyncInfo({
    this.pending = 0,
    this.failed = 0,
    this.running = false,
    this.offline = false,
    this.error,
    this.lastOk,
  });
}

class _Unresolved implements Exception {
  final String what;
  _Unresolved(this.what);
}

class _ApiResult {
  final int code;
  final Map<String, dynamic>? data;
  _ApiResult(this.code, this.data);
  String get error => (data?['error'] ?? 'خطای سرور (کد $code)').toString();
}

/// همگام‌سازی دیتابیس محلی با سرور (همان API نسخهٔ وب: `app.php`).
///
/// * ارسال: عملیات صف‌شده (`sync_ops`) به‌ترتیب، با کلید یکتای idem ارسال می‌شود؛
///   ارسال تکراری (اینترنت ضعیف) دوباره ثبت نمی‌شود.
/// * دریافت: `backup.export` سرور کل داده‌های حساب را می‌آورد (فقط وقتی صف خالی است).
/// * ورود روی دستگاه جدید: [initialSync] همهٔ داده‌های حساب را از سرور می‌آورد.
class SyncService {
  SyncService._();
  static final SyncService I = SyncService._();

  final ValueNotifier<SyncInfo> info = ValueNotifier<SyncInfo>(const SyncInfo());

  bool _started = false;
  bool _running = false;
  bool _again = false;
  bool _offline = false;
  String? _error;
  DateTime? _lastOk;
  Timer? _debounce;
  Timer? _tick;
  DateTime _lastPullTry = DateTime.fromMillisecondsSinceEpoch(0);
  // آخرین تغییر محلی/ارسال موفق؛ تا ۹۰ ثانیه بعدش دریافتِ خودکار از سرور انجام نمی‌شود
  DateTime _lastActivity = DateTime.fromMillisecondsSinceEpoch(0);

  static const _pullEvery = Duration(minutes: 3);
  static const _settle = Duration(seconds: 90);

  String get _url => '${ApiConfig.baseUrl}/app.php';

  /// یک‌بار در main صدا زده می‌شود
  void start() {
    if (_started) return;
    _started = true;
    AppDb.I.version.addListener(_onChanged);
    _tick = Timer.periodic(const Duration(seconds: 30), (_) => syncNow());
  }

  void stop() {
    _debounce?.cancel();
  }

  void _onChanged() {
    if (!AppDb.I.hasAccount) return;
    _lastActivity = DateTime.now();
    _refreshCounts();
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), () => syncNow(pull: false));
  }

  Future<void> _refreshCounts() async {
    try {
      final (p, f) = await AppDb.I.queueCounts();
      _emit(pending: p, failed: f);
    } catch (_) {}
  }

  void _emit({int? pending, int? failed}) {
    final cur = info.value;
    info.value = SyncInfo(
      pending: pending ?? cur.pending,
      failed: failed ?? cur.failed,
      running: _running,
      offline: _offline,
      error: _error,
      lastOk: _lastOk,
    );
  }

  /// ارسال صف و (در صورت نیاز) دریافت تغییرات سرور. [pull]=null یعنی هر چند دقیقه یک‌بار.
  Future<void> syncNow({bool? pull}) async {
    if (!AppDb.I.hasAccount) return;
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    _emit();
    try {
      do {
        _again = false;
        await _cycle(pull);
      } while (_again);
    } catch (e) {
      _error = _friendly(e);
    } finally {
      _running = false;
      await _refreshCounts();
      _emit();
    }
  }

  Future<void> _cycle(bool? pull) async {
    final cred = await LicenseService.I.credentials();
    if (cred == null) return;
    final ok = await _push(cred.$1, cred.$2);
    if (!ok) return;
    final (p, f) = await AppDb.I.queueCounts();
    _emit(pending: p, failed: f);
    final due = DateTime.now().difference(_lastPullTry) >= _pullEvery;
    final settled = DateTime.now().difference(_lastActivity) >= _settle;
    // تا وقتی فرم/صفحهٔ ثبتی باز است دریافت از سرور انجام نمی‌شود (شناسه‌ها زیر دست کاربر عوض نشوند)
    if (p == 0 && f == 0 && !AppDb.I.isEditing && (pull == true || (pull == null && due && settled))) {
      _lastPullTry = DateTime.now();
      await _pull(cred.$1, cred.$2);
    }
    _error = null;
    _lastOk = DateTime.now();
  }

  // ======================= ارسال =======================
  Future<int?> _res(String kind, dynamic v) async {
    if (v == null) return null;
    final id = (v as num).toInt();
    if (id >= 0) return id;
    final sid = await AppDb.I.serverIdOf(kind, id) ?? await AppDb.I.aliasOf(kind, id);
    if (sid == null) throw _Unresolved('وابسته به موردی است که به سرور نرسیده');
    return sid;
  }

  /// شناسه‌های موقت محلی را با شناسهٔ واقعی سرور جایگزین می‌کند
  Future<Map<String, dynamic>> _resolve(String action, Map<String, dynamic> p) async {
    final o = Map<String, dynamic>.from(p);
    Future<void> one(String key, String kind) async {
      if (o.containsKey(key) && o[key] != null) o[key] = await _res(kind, o[key]);
    }

    Future<void> list(String key, String idKey, String kind) async {
      final l = o[key];
      if (l is! List) return;
      final out = <Map<String, dynamic>>[];
      for (final e in l) {
        final m = Map<String, dynamic>.from(e as Map);
        m[idKey] = await _res(kind, m[idKey]);
        out.add(m);
      }
      o[key] = out;
    }

    switch (action) {
      case 'types.create':
        await one('category_id', 'cat');
        break;
      case 'purchases.create':
        await one('category_id', 'cat');
        await one('id', 'pur');
        break;
      case 'mixes.create':
        await one('category_id', 'cat');
        await list('sources', 'purchase_id', 'pur');
        break;
      case 'mixes.update':
        await one('category_id', 'cat');
        await one('id', 'pur');
        await list('sources', 'purchase_id', 'pur');
        break;
      case 'mixes.delete':
      case 'purchases.delete':
        await one('id', 'pur');
        break;
      case 'payments.save':
        await one('purchase_id', 'pur');
        await _addSnap(o);
        break;
      case 'receipts.save':
        await one('sale_id', 'sale');
        await _addSnap(o);
        break;
      case 'sales.create':
        await list('items', 'purchase_id', 'pur');
        break;
      case 'sales.update':
        await one('id', 'sale');
        await list('items', 'purchase_id', 'pur');
        break;
      case 'sales.delete':
        await one('id', 'sale');
        break;
      // S04.T04.4b: برگشت‌ها و پیش‌فاکتورها
      case 'sale_returns.create':
        await list('items', 'sale_id', 'sale');
        await list('items', 'lot_id', 'pur');
        break;
      case 'purchase_returns.create':
        await list('items', 'lot_id', 'pur');
        break;
      case 'sale_returns.delete':
        await one('id', 'sret');
        break;
      case 'purchase_returns.delete':
        await one('id', 'pret');
        break;
      case 'proformas.save':
        await one('id', 'pf');
        await list('items', 'lot_id', 'pur');
        break;
      case 'proformas.link_sales':
        await one('id', 'pf');
        await list('links', 'sale_id', 'sale');
        break;
      case 'proformas.set_status':
      case 'proformas.delete':
        await one('id', 'pf');
        break;
    }
    return o;
  }

  Future<_ApiResult> _call(String phone, String token, String action, Map<String, dynamic> payload,
      {String? idem, int timeoutSec = 30}) async {
    final body = <String, dynamic>{'phone': phone, 'token': token, 'action': action, 'payload': payload};
    if (idem != null) body['idem'] = idem;
    final resp = await http
        .post(Uri.parse(_url), headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
        .timeout(Duration(seconds: timeoutSec));
    Map<String, dynamic>? data;
    try {
      final j = jsonDecode(utf8.decode(resp.bodyBytes));
      if (j is Map<String, dynamic>) data = j;
    } catch (_) {}
    return _ApiResult(resp.statusCode, data);
  }

  /// STAGE12: آخرین snap_at (ساعت سرور در آخرین دریافتِ اعمال‌شده) را به ثبت پرداخت/دریافت می‌افزاید.
  /// اگر نباشد (سرور قدیمی یا هنوز دریافت اعمال‌نشده) چیزی نمی‌فرستد ⇒ رفتار قبلی.
  Future<void> _addSnap(Map<String, dynamic> o) async {
    final s = await AppDb.I.metaGet('snap_at');
    if (s != null && s.isNotEmpty) o['snap_at'] = s;
  }

  /// true = صف کاملاً پردازش شد (یا فقط موارد خطادار مانده)؛ false = باید بعداً دوباره تلاش شود
  Future<bool> _push(String phone, String token) async {
    while (true) {
      final op = await AppDb.I.nextOp();
      if (op == null) {
        _offline = false;
        return true;
      }
      final seq = (op['seq'] as num).toInt();
      final rev = (op['rev'] as num).toInt();
      final action = op['action'] as String;
      Map<String, dynamic> payload;
      try {
        payload = await _resolve(action, Map<String, dynamic>.from(jsonDecode(op['payload'] as String) as Map));
      } on _Unresolved catch (e) {
        await AppDb.I.failOp(seq, e.what);
        continue;
      }

      _ApiResult r;
      try {
        r = await _call(phone, token, action, payload, idem: op['idem'] as String);
      } catch (e) {
        _offline = e is SocketException || e is TimeoutException || e is http.ClientException;
        _error = _friendly(e);
        return false;
      }
      _offline = false;

      if (r.code == 200 && r.data != null) {
        final mk = op['map_kind'] as String?;
        final lid = (op['local_id'] as num?)?.toInt();
        final sid = (r.data?['id'] as num?)?.toInt();
        if (mk != null && lid != null && sid != null) {
          await AppDb.I.recordMapping(mk, lid, sid);
          // اگر وسط ارسال، کاربر همین رکورد را در گوشی حذف کرده باشد، روی سرور هم حذف شود
          if (!await AppDb.I.localExists(mk, lid)) {
            final del = switch (action) {
              'mixes.create' => 'mixes.delete',
              'sales.create' => 'sales.delete',
              'purchases.create' => 'purchases.delete',
              'sale_returns.create' => 'sale_returns.delete',
              'purchase_returns.create' => 'purchase_returns.delete',
              'proformas.save' => 'proformas.delete',
              _ => null,
            };
            if (del != null) await AppDb.I.enqueueServerDelete(del, sid);
          }
        }
        if (action == 'entity.save') await EntityStore.I.onSaved(payload, r.data);
        await AppDb.I.finishOp(seq, rev);
        _lastActivity = DateTime.now();
        if (action == 'receipts.save' || action == 'payments.save') {
          await AppDb.I.metaSet('last_tx_push', DateTime.now().toIso8601String());
        }
        continue;
      }
      if (r.code == 401) {
        _error = 'نشست ورود منقضی شده؛ از حساب خارج و دوباره وارد شوید';
        // LicenseGate وضعیت را دوباره بررسی می‌کند و اگر توکن واقعاً نامعتبر باشد، صفحهٔ ورود را نشان می‌دهد
        LicenseService.I.sessionInvalid.value++;
        return false;
      }
      if (action == 'entity.delete' && r.code == 404) {
        // already gone on the server
        await AppDb.I.finishOp(seq, rev);
        continue;
      }
      if (r.code == 403 && action.startsWith('entity.')) {
        final ec = (r.data?['error'] ?? '').toString();
        if (ec == 'edition_required' || ec.contains('دسترسی')) {
          // this entity is not allowed for the account: park the op so it does not block the whole queue
          await AppDb.I.failOp(seq, r.error);
          continue;
        }
      }
      if (r.code == 403) {
        _error = r.error;
        return false;
      }
      final retryable = r.code == 409 || r.code == 429 || r.code >= 500 || r.data == null;
      if (retryable) {
        final att = ((op['attempts'] as num?) ?? 0).toInt() + 1;
        if (att >= 8) {
          await AppDb.I.failOp(seq, r.error);
          continue;
        }
        await AppDb.I.bumpAttempt(seq, r.error);
        _error = r.error;
        return false;
      }
      // خطای قطعی (اعتبارسنجی/موجودی/…): این مورد ارسال‌شدنی نیست
      await AppDb.I.failOp(seq, r.error);
    }
  }

  // ======================= دریافت =======================
  Future<bool> _pull(String phone, String token, {bool discardQueue = false}) async {
    final r = await _call(phone, token, 'backup.export', {}, timeoutSec: 120);
    if (r.code != 200 || r.data == null) throw _ServerError(r.error, r.code);
    final tables = r.data!['tables'];
    if (tables is! Map) throw _ServerError('پاسخ نامعتبر از سرور', r.code);
    // ویندوز: قبل از جایگزینی داده‌های محلی با داده‌های سرور یک نسخهٔ محلی می‌گیریم (برگشت‌پذیری)
    await LocalBackup.I.snapshot(discardQueue ? 'pre-reload' : 'pre-sync',
        minGap: discardQueue ? Duration.zero : const Duration(hours: 6));
    // STAGE12: exported_at = ساعت سرور همین خروجی؛ فقط در صورت اعمال واقعی به‌عنوان snap_at ذخیره می‌شود
    final exp = r.data!['exported_at'];
    final ents = r.data!['entities'];
    return AppDb.I.replaceAllFromServer(Map<String, dynamic>.from(tables),
        discardQueue: discardQueue,
        exportedAt: exp is String ? exp : null,
        entities: ents is Map ? Map<String, dynamic>.from(ents) : null,
        docs: r.data!['docs'] is Map ? Map<String, dynamic>.from(r.data!['docs'] as Map) : null);
  }

  /// ورود روی این دستگاه (یا نصب مجدد): همهٔ داده‌های حساب را از سرور می‌آورد.
  /// در موفقیت null، در خطا پیام فارسی برمی‌گرداند.
  Future<String?> initialSync() async {
    final cred = await LicenseService.I.credentials();
    if (cred == null) return 'ابتدا وارد حساب شوید';
    try {
      // bootstrap: دسته‌ها و انواع پیش‌فرض را برای حساب تازه می‌سازد
      final b = await _call(cred.$1, cred.$2, 'bootstrap', {}, timeoutSec: 30);
      if (b.code != 200) return b.error;
      final ok = await _pull(cred.$1, cred.$2);
      if (!ok) return 'همگام‌سازی انجام نشد؛ دوباره تلاش کنید';
      _lastOk = DateTime.now();
      _error = null;
      _emit(pending: 0, failed: 0);
      return null;
    } catch (e) {
      return _friendly(e);
    }
  }

  /// «بازخوانی کامل از سرور»: تغییرات ارسال‌نشده و خطادار دور ریخته می‌شود
  Future<String?> reloadFromServer() async {
    final cred = await LicenseService.I.credentials();
    if (cred == null) return 'ابتدا وارد حساب شوید';
    try {
      await _pull(cred.$1, cred.$2, discardQueue: true);
      _lastOk = DateTime.now();
      _error = null;
      await _refreshCounts();
      return null;
    } catch (e) {
      return _friendly(e);
    }
  }

  /// بازگردانی: کل داده‌های حساب روی سرور با [tables] جایگزین می‌شود (سرور قبل از حذف هر چیز اعتبارسنجی می‌کند)
  /// و سپس همان داده از سرور به این دستگاه می‌آید. نیازمند اینترنت است. در موفقیت null.
  Future<String?> importTables(Map<String, dynamic> tables) async {
    final cred = await LicenseService.I.credentials();
    if (cred == null) return 'ابتدا وارد حساب شوید';
    try {
      final r = await _call(cred.$1, cred.$2, 'backup.import', {'tables': tables}, timeoutSec: 180);
      if (r.code != 200) return r.error;
      return await reloadFromServer();
    } catch (e) {
      return _friendly(e);
    }
  }

  String _friendly(Object e) {
    if (e is _ServerError) return e.message;
    if (e is TimeoutException) return 'سرور دیر جواب داد؛ بعداً خودکار دوباره تلاش می‌شود';
    if (e is SocketException || e is http.ClientException) {
      return 'اینترنت وصل نیست؛ اطلاعات روی گوشی ذخیره است و بعد از اتصال خودکار ارسال می‌شود';
    }
    if (e is HandshakeException) return 'خطای گواهی امنیتی (SSL)';
    return 'خطا: $e';
  }
}

class _ServerError implements Exception {
  final String message;
  final int code;
  _ServerError(this.message, this.code);
  @override
  String toString() => message;
}
