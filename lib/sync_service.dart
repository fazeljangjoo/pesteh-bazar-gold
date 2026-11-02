import 'pay_approval_ui.dart' show PayApprovalNotice; // S31.T31.3b
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver, WidgetsFlutterBinding;
import 'package:http/http.dart' as http;

import 'db.dart';
import 'entity_store.dart';
import 'fx_local.dart';
import 'license_service.dart';
import 'money_unit.dart'; // S29.T29.3
import 'local_backup.dart';
import 'sync_plan.dart'; // S7

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

  /// S7: نشانگر وضعیت کاربر
  SyncStatus get status => offline
      ? SyncStatus.offline
      : (running || pending > 0)
          ? SyncStatus.syncing
          : SyncStatus.synced;
}

/// S7: «همگام / در حال همگام‌سازی / آفلاین»
enum SyncStatus { synced, syncing, offline }

class _Life with WidgetsBindingObserver {
  final void Function(AppLifecycleState) cb;
  _Life(this.cb);
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => cb(state);
}

class _PingResult {
  final int ver;
  final int pollSec;
  final List<SyncChange> changes;
  final bool reset;
  _PingResult(this.ver, this.pollSec, this.changes, this.reset);
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
  bool _unitProbed = false; // S29.T29.3: server money_unit checked once per app run (and again after a unit error)
  DateTime _lastFxTry = DateTime.fromMillisecondsSinceEpoch(0); // S27c: آخرین تازه‌سازی کش ارز/نرخ
  // آخرین تغییر محلی/ارسال موفق؛ تا ۹۰ ثانیه بعدش دریافتِ خودکار از سرور انجام نمی‌شود
  DateTime _lastActivity = DateTime.fromMillisecondsSinceEpoch(0);

  // ---- S7: همگام‌سازی لحظه‌ای (poll سبک + دلتا) ----
  /// «به‌روزرسانی جدید» از دستگاه دیگر آمده ولی چون فرمی باز است هنوز اعمال نشده (نوار «اعمال»)
  final ValueNotifier<bool> remotePending = ValueNotifier<bool>(false);

  int? _ver; // آخرین ver سرور که کاملاً اعمال شده (مبنای since_ver)
  String? _verPhone;
  int _pollSec = 4;
  Timer? _pollTimer;
  Timer? _pendingWatch;
  bool _polling = false;
  bool _fg = true;
  int _fail = 0;
  bool _pingOk = true; // sync_ping.php در دسترس است؛ وگرنه از app.php `sync.version`
  bool _rtSupported = true; // سرور sync.* را می‌شناسد؛ وگرنه روش قدیمی (دریافت هر ۳ دقیقه)
  bool _applyingRemote = false;
  _Life? _life;
  DateTime _lastFullPull = DateTime.fromMillisecondsSinceEpoch(0);
  final List<(String, DateTime)> _own = <(String, DateTime)>[]; // اکشن‌های ارسال‌شدهٔ همین دستگاه

  static const _settle = Duration(seconds: 90);
  static const _minFullGap = Duration(seconds: 8); // حداقل فاصلهٔ دو دریافت کاملِ خودکار
  Duration get _pullEvery => (_rtSupported && _fail == 0) ? const Duration(minutes: 10) : const Duration(minutes: 3);

  String get _url => '${ApiConfig.baseUrl}/app.php';

  /// یک‌بار در main صدا زده می‌شود
  void start() {
    if (_started) return;
    _started = true;
    AppDb.I.version.addListener(_onChanged);
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_fg) syncNow();
    });
    // S7: چرخهٔ حیات (توقف در پس‌زمینه، poll فوری هنگام بازگشت)
    try {
      WidgetsFlutterBinding.ensureInitialized();
      _life = _Life(_onLifecycle);
      WidgetsBinding.instance.addObserver(_life!);
    } catch (_) {}
    _schedulePoll(const Duration(seconds: 2));
  }

  void stop() {
    _debounce?.cancel();
    _pollTimer?.cancel();
    _pendingWatch?.cancel();
  }

  void _onChanged() {
    if (!AppDb.I.hasAccount) return;
    if (_applyingRemote) return; // تغییرِ ناشی از دریافت، «فعالیت کاربر» نیست
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
    if (!_unitProbed && p == 0 && f == 0 && !AppDb.I.isEditing) {
      if (await _probeMoneyUnit(cred.$1, cred.$2)) pull = true; // server turned rial: x10 done locally, now reload
    }
    final due = DateTime.now().difference(_lastPullTry) >= _pullEvery;
    final settled = DateTime.now().difference(_lastActivity) >= _settle;
    // تا وقتی فرم/صفحهٔ ثبتی باز است دریافت از سرور انجام نمی‌شود (شناسه‌ها زیر دست کاربر عوض نشوند)
    if (p == 0 && f == 0 && !AppDb.I.isEditing && (pull == true || (pull == null && due && settled))) {
      _lastPullTry = DateTime.now();
      _lastFullPull = _lastPullTry;
      await _pull(cred.$1, cred.$2);
    }
    // S27c: کش ارز/نرخ (پلن ارزی) مستقل از وضعیت صف تازه می‌شود تا سند «نرخ ثبت نشده» بعد از ثبت نرخ دوباره ارسال شود
    if (LicenseService.I.isFx.value && DateTime.now().difference(_lastFxTry) >= const Duration(minutes: 10)) {
      _lastFxTry = DateTime.now();
      await FxLocal.refresh();
    }
    _error = null;
    _lastOk = DateTime.now();
  }

  // ======================= S7: همگام‌سازی لحظه‌ای =======================
  // هاست cPanel ⇒ بدون WebSocket. هر `poll_interval` ثانیه (پیش‌فرض ۴) یک ping سبک (`sync_ping.php`) می‌زنیم؛
  // اگر ver عوض شده بود فهرست تغییرات می‌آید: entityها دلتا (`entity.changes`)، سایر نواحی دریافت کامل.
  // قواعد: ۱) صف ارسال همیشه قبل از دریافت ۲) وسط ویرایش فرم، تغییر منتظر می‌ماند (نوار «اعمال») ۳) در پس‌زمینه poll نیست.

  void _onLifecycle(AppLifecycleState s) {
    final bg = s == AppLifecycleState.paused || s == AppLifecycleState.hidden || s == AppLifecycleState.detached;
    if (bg) {
      _fg = false;
      _pollTimer?.cancel();
    } else if (!_fg) {
      _fg = true;
      _fail = 0;
      _schedulePoll(Duration.zero); // بازگشت به foreground = poll فوری
      syncNow(pull: false);
    }
  }

  void _schedulePoll(Duration d) {
    _pollTimer?.cancel();
    if (!_fg || !_rtSupported) return;
    _pollTimer = Timer(d, _pollOnce);
  }

  /// دکمهٔ «اعمال» نوار به‌روزرسانی / فراخوانی دستی: همین حالا poll کن
  Future<void> pollNow() async {
    _fail = 0;
    _pollTimer?.cancel();
    await _pollOnce();
  }

  Future<void> _loadVer() async {
    final ph = AppDb.I.phone;
    if (_ver != null && _verPhone == ph) return;
    _ver = null;
    _verPhone = ph;
    final raw = await AppDb.I.metaGet('sync_ver'); // «phone:ver»
    if (raw == null) return;
    final i = raw.lastIndexOf(':');
    if (i <= 0 || raw.substring(0, i) != ph) return;
    _ver = int.tryParse(raw.substring(i + 1));
  }

  Future<void> _setVer(int v) async {
    _ver = v;
    _verPhone = AppDb.I.phone;
    try {
      await AppDb.I.metaSet('sync_ver', '${AppDb.I.phone}:$v');
    } catch (_) {}
  }

  Future<_PingResult> _ping(String phone, String token, int? since) async {
    if (_pingOk) {
      final resp = await http
          .post(Uri.parse('${ApiConfig.baseUrl}/sync_ping.php'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'phone': phone, 'token': token, if (since != null) 'since_ver': since}))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 404 || resp.statusCode == 405) {
        _pingOk = false; // سرور endpoint سبک را ندارد ⇒ از app.php
      } else {
        Map<String, dynamic>? j;
        try {
          final d = jsonDecode(utf8.decode(resp.bodyBytes));
          if (d is Map<String, dynamic>) j = d;
        } catch (_) {}
        return _parsePing(_ApiResult(resp.statusCode, j), viaApp: false);
      }
    }
    return _parsePing(await _call(phone, token, 'sync.version', {if (since != null) 'since_ver': since}, timeoutSec: 10), viaApp: true);
  }

  _PingResult _parsePing(_ApiResult r, {required bool viaApp}) {
    if (r.code == 401) {
      LicenseService.I.sessionInvalid.value++; // LicenseGate وضعیت را دوباره بررسی می‌کند
      throw _ServerError('نشست ورود منقضی شده', 401);
    }
    if (r.code == 403) throw _ServerError(r.error, 403);
    if (viaApp && (r.code == 400 || r.code == 404)) {
      // سرور قدیمی: اکشن sync.version را نمی‌شناسد ⇒ حالت قدیمی (دریافت دوره‌ای)
      _rtSupported = false;
      throw _ServerError('همگام‌سازی لحظه‌ای روی سرور نیست', r.code);
    }
    final d = r.data;
    if (r.code != 200 || d == null || d['ver'] == null) throw _ServerError(r.error, r.code);
    final ch = <SyncChange>[];
    final raw = d['changes'];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) ch.add(SyncChange.fromJson(e));
      }
    }
    return _PingResult(int.tryParse('${d['ver']}') ?? 0, int.tryParse('${d['poll_interval']}') ?? _pollSec, ch, d['reset'] == true);
  }

  Future<void> _pollOnce() async {
    if (_polling) return;
    _polling = true;
    try {
      if (!AppDb.I.hasAccount) return;
      final cred = await LicenseService.I.credentials();
      if (cred == null) return;
      await _loadVer();
      final (p0, _) = await AppDb.I.queueCounts();
      if (p0 > 0 && !_running) unawaited(syncNow(pull: false)); // صف ارسال همیشه قبل از دریافت
      final r = await _ping(cred.$1, cred.$2, _ver);
      _pollSec = r.pollSec < 2 ? 2 : (r.pollSec > 60 ? 60 : r.pollSec);
      if (_fail > 0 || _offline) {
        // آفلاین → آنلاین: اول ارسال صف، بعد دریافت
        _fail = 0;
        if (_offline) {
          _offline = false;
          _emit();
          unawaited(syncNow(pull: false));
        }
      }
      await _decide(cred.$1, cred.$2, r);
    } catch (e) {
      _fail++;
      if (e is SocketException || e is TimeoutException || e is http.ClientException) {
        if (!_offline) {
          _offline = true;
          _emit();
        }
      }
    } finally {
      _polling = false;
      if (_rtSupported) {
        _schedulePoll(Duration(seconds: SyncPlanner.nextDelaySec(pollSec: _pollSec, failStreak: _fail)));
      }
    }
  }

  Future<void> _decide(String phone, String token, _PingResult r) async {
    final base = _ver;
    if (base == r.ver && !r.reset) {
      if (remotePending.value && !AppDb.I.isEditing) remotePending.value = false;
      return; // بدون تغییر
    }
    _own.removeWhere((e) => DateTime.now().difference(e.$2) > const Duration(minutes: 2));
    final known = (await EntityStore.I.visibleNames()).toSet();
    final plan = base == null
        ? const SyncPlan(entities: <String>{}, fullPull: true, consumedOwn: <String>[], foreignCount: 0) // مبنا نداریم ⇒ کامل
        : SyncPlanner.plan(
            changes: r.changes,
            reset: r.reset,
            ownKeys: _own.map((e) => e.$1).toList(),
            isKnownEntity: known.contains,
          );
    if (!plan.hasWork) {
      // همهٔ تغییرات مالِ همین دستگاه بود (یا برای این اپ بی‌اهمیت): فقط مبنا جلو می‌رود
      for (final k in plan.consumedOwn) {
        final i = _own.indexWhere((e) => e.$1 == k);
        if (i >= 0) _own.removeAt(i);
      }
      await _setVer(r.ver);
      if (remotePending.value && !AppDb.I.isEditing) remotePending.value = false;
      return;
    }
    // --- تغییر واقعی از دستگاه دیگر ---
    final (p, f) = await AppDb.I.queueCounts();
    if (AppDb.I.isEditing) {
      _setPending(true); // هیچ‌وقت فرم در حال تایپ دست نمی‌خورد؛ بعد از بستن فرم خودکار اعمال می‌شود
      return;
    }
    if (p > 0 || f > 0 || _running) return; // ارسال صف اول؛ poll بعدی دوباره تصمیم می‌گیرد
    if (plan.fullPull && DateTime.now().difference(_lastFullPull) < _minFullGap) return; // کنترل بار
    await _apply(phone, token, plan, r.ver);
  }

  void _setPending(bool v) {
    if (remotePending.value != v) remotePending.value = v;
    if (v) {
      _pendingWatch ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (!AppDb.I.isEditing) {
          _pendingWatch?.cancel();
          _pendingWatch = null;
          unawaited(pollNow()); // فرم بسته شد ⇒ فوراً اعمال
        }
      });
    } else {
      _pendingWatch?.cancel();
      _pendingWatch = null;
    }
  }

  Future<void> _apply(String phone, String token, SyncPlan plan, int newVer) async {
    _running = true;
    _applyingRemote = true;
    _emit();
    try {
      var ok = true;
      var full = plan.fullPull;
      if (!full) {
        for (final e in plan.entities) {
          if (!await _pullEntity(phone, token, e)) {
            full = true; // صفحه‌های زیاد/خطا ⇒ دریافت کامل
            break;
          }
        }
      }
      if (full) {
        _lastFullPull = DateTime.now();
        ok = await _pull(phone, token, baselineVer: newVer); // _pull خودش مبنا را ثبت می‌کند
      } else {
        await _setVer(newVer);
        for (final k in plan.consumedOwn) {
          final i = _own.indexWhere((e) => e.$1 == k);
          if (i >= 0) _own.removeAt(i);
        }
      }
      if (ok) {
        _setPending(false);
        _error = null;
        _lastOk = DateTime.now();
      }
    } catch (e) {
      _error = _friendly(e);
      rethrow;
    } finally {
      _applyingRemote = false;
      _running = false;
      await _refreshCounts();
      _emit();
      if (_again) {
        _again = false;
        unawaited(syncNow(pull: false)); // کاربر حین دریافت چیزی ثبت کرده بود
      }
    }
  }

  /// دلتای یک entity با `entity.changes`؛ false = باید دریافت کامل انجام شود
  Future<bool> _pullEntity(String phone, String token, String entity) async {
    var since = await EntityStore.I.cursorOf(entity);
    for (var page = 0; page < 20; page++) {
      final r = await _call(phone, token, 'entity.changes', {'entity': entity, 'since_rev': since, 'limit': 500}, timeoutSec: 30);
      if (r.code == 403 || r.code == 404) return true; // دسترسی/entity نیست: چیزی برای آینه‌کردن نیست
      if (r.code != 200 || r.data == null) throw _ServerError(r.error, r.code);
      final items = r.data!['items'];
      final maxRev = int.tryParse('${r.data!['max_rev']}') ?? since;
      if (items is List && items.isNotEmpty) await EntityStore.I.applyDelta(entity, items, maxRev);
      if (r.data!['has_more'] != true || maxRev <= since) return true;
      since = maxRev;
    }
    return false;
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
    final body = <String, dynamic>{'phone': phone, 'token': token, 'action': action, 'payload': payload, 'unit': AppDb.I.moneyUnit};
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
          // اگر وسط ارسال، کاربر همین رکورد را در سیستم حذف کرده باشد، روی سرور هم حذف شود
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
        _own.add((SyncPlanner.keyOf(action, SyncPlanner.entityOfOwn(action, payload)), DateTime.now())); // S7
        if (action == 'payments.save' && r.data?['pending_approval'] == true) {
          PayApprovalNotice.I.report((r.data?['amount_rial'] as num?) ?? 0); // S31.T31.3b
        }
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
      final String ue = (r.data?['error'] ?? '').toString();
      if (ue == 'upgrade_required' || ue == 'unit_mismatch') {
        // S29.T29.3: the op carries amounts in another unit than the server stores: never retry it blindly
        _unitProbed = false;
        _error = ue == 'upgrade_required'
            ? 'واحد پول سرور ریال شده و مبلغ‌های صف با واحد قدیمی‌اند؛ از «بازخوانی کامل» در صفحهٔ همگام‌سازی استفاده کنید یا برنامه را به‌روز کنید'
            : r.error;
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
      if (r.data?['error'] == 'rate_missing') {
        // S27c: نرخ ارز در سرور نیست؛ سند از صف جدا می‌شود و بعد از ثبت نرخ خودکار دوباره ارسال می‌شود
        await AppDb.I.failOpRateMissing(seq, (r.data?['ccy'] ?? '').toString(), (r.data?['rate_date'] ?? '').toString());
        continue;
      }
      // خطای قطعی (اعتبارسنجی/موجودی/…): این مورد ارسال‌شدنی نیست
      await AppDb.I.failOp(seq, r.error);
    }
  }

  /// S29.T29.3: asks the server for its money unit (bootstrap is idempotent). Server rial + local toman +
  /// empty queue => x10 on the local mirror. Returns true when a migration happened (caller reloads).
  Future<bool> _probeMoneyUnit(String phone, String token) async {
    try {
      final _ApiResult b = await _call(phone, token, 'bootstrap', {}, timeoutSec: 30);
      if (b.code != 200 || b.data == null) return false;
      _unitProbed = true;
      final String serverUnit = MoneyUnit.normalize(b.data!['money_unit']);
      if (serverUnit == MoneyUnit.rial && AppDb.I.moneyUnit != MoneyUnit.rial) {
        return await AppDb.I.migrateMoneyToRial();
      }
    } catch (_) {}
    return false;
  }

  // ======================= دریافت =======================
  Future<bool> _pull(String phone, String token, {bool discardQueue = false, int? baselineVer}) async {
    // S7: ver «قبل از» دریافت ثبت می‌شود؛ تغییری که حین دریافت رخ دهد بعداً دوباره دیده می‌شود (کم‌دریافت‌کردن ممنوع)
    int? v0 = baselineVer;
    if (v0 == null && _rtSupported) {
      try {
        v0 = (await _ping(phone, token, null)).ver;
      } catch (_) {}
    }
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
    final String srvUnit = MoneyUnit.normalize(r.data!['money_unit']); // S29.T29.3
    final bool applied = await AppDb.I.replaceAllFromServer(Map<String, dynamic>.from(tables),
        discardQueue: discardQueue,
        exportedAt: exp is String ? exp : null,
        entities: ents is Map ? Map<String, dynamic>.from(ents) : null,
        docs: r.data!['docs'] is Map ? Map<String, dynamic>.from(r.data!['docs'] as Map) : null);
    if (applied) await AppDb.I.setMoneyUnit(srvUnit); // mirror now holds exactly the server's unit
    if (applied) {
      if (v0 != null) await _setVer(v0);
      _own.clear();
      remotePending.value = false;
    }
    return applied;
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
      if (LicenseService.I.isFx.value) await FxLocal.refresh();
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
      return 'اینترنت وصل نیست؛ اطلاعات روی سیستم ذخیره است و بعد از اتصال خودکار ارسال می‌شود';
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
