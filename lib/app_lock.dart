import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'license_service.dart';
import 'widgets.dart';

/// قفل اختیاری برنامه با رمز (فقط ویندوز). رمز به‌صورت هش نمکی ذخیره می‌شود، نه خودِ رمز.
/// بعد از ۱۰ دقیقه بی‌حرکتی، برنامه دوباره قفل می‌شود. پس از ۵ رمز اشتباه، تلاش بعدی با تأخیر است.
class AppLock {
  AppLock._();
  static final AppLock I = AppLock._();

  static const _kHash = 'applock_hash';
  static const _kSalt = 'applock_salt';
  static const idleLimit = Duration(minutes: 10);

  final ValueNotifier<bool> locked = ValueNotifier<bool>(false);
  bool enabled = false;
  int _fails = 0;
  DateTime? _blockedUntil;

  Future<void> load() async {
    if (!Platform.isWindows) return;
    final sp = await SharedPreferences.getInstance();
    enabled = (sp.getString(_kHash) ?? '').isNotEmpty;
    locked.value = enabled;
  }

  String _hash(String pin, String salt) {
    List<int> h = utf8.encode('$salt|$pin');
    for (var i = 0; i < 20000; i++) {
      h = crypto.sha256.convert(h).bytes;
    }
    return base64.encode(h);
  }

  Future<bool> check(String pin) async {
    final sp = await SharedPreferences.getInstance();
    final salt = sp.getString(_kSalt) ?? '';
    final want = sp.getString(_kHash) ?? '';
    return want.isNotEmpty && _hash(pin, salt) == want;
  }

  /// null = باز شد؛ در غیر این صورت پیام خطا
  Future<String?> tryUnlock(String pin) async {
    final until = _blockedUntil;
    if (until != null && DateTime.now().isBefore(until)) {
      return 'چند لحظه صبر کنید (${until.difference(DateTime.now()).inSeconds + 1} ثانیه)';
    }
    if (await check(pin)) {
      _fails = 0;
      _blockedUntil = null;
      locked.value = false;
      return null;
    }
    _fails++;
    if (_fails >= 5) _blockedUntil = DateTime.now().add(Duration(seconds: 15 * (_fails - 4)));
    return 'رمز اشتباه است';
  }

  Future<void> setPin(String pin) async {
    final rnd = math.Random.secure();
    final salt = base64.encode(List<int>.generate(16, (_) => rnd.nextInt(256)));
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kSalt, salt);
    await sp.setString(_kHash, _hash(pin, salt));
    enabled = true;
  }

  Future<void> clear() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kHash);
    await sp.remove(_kSalt);
    enabled = false;
    locked.value = false;
  }

  void lockNow() {
    if (enabled) locked.value = true;
  }
}

/// قفل‌کردن بعد از بی‌حرکتی + نمایش صفحهٔ رمز روی همهٔ صفحه‌ها (به‌صورت route روی Navigator اصلی).
class AppLockHost extends StatefulWidget {
  final Widget child;
  const AppLockHost({super.key, required this.child});
  @override
  State<AppLockHost> createState() => _AppLockHostState();
}

class _AppLockHostState extends State<AppLockHost> {
  DateTime _last = DateTime.now();
  Timer? _idle;
  NavigatorState? _nav;
  Route<void>? _route;

  bool _onKey(KeyEvent e) {
    _last = DateTime.now();
    return false;
  }

  @override
  void initState() {
    super.initState();
    if (!Platform.isWindows) return;
    AppLock.I.locked.addListener(_sync);
    HardwareKeyboard.instance.addHandler(_onKey);
    _idle = Timer.periodic(const Duration(seconds: 20), (_) {
      if (AppLock.I.enabled && !AppLock.I.locked.value && DateTime.now().difference(_last) > AppLock.idleLimit) {
        AppLock.I.lockNow();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  void _sync() {
    if (!mounted) return;
    if (AppLock.I.locked.value) {
      if (_route != null) return;
      _nav = Navigator.of(context);
      final r = MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => const _PinScreen());
      _route = r;
      _nav!.push(r);
    } else {
      _removeRoute();
      _last = DateTime.now();
    }
  }

  void _removeRoute() {
    final r = _route;
    final nav = _nav;
    if (r != null) {
      _route = null;
      // بعد از پایان فریمِ جاری (ممکن است از dispose صدا زده شود)
      scheduleMicrotask(() {
        try {
          nav?.removeRoute(r);
        } catch (_) {}
      });
    }
  }

  @override
  void dispose() {
    if (Platform.isWindows) {
      AppLock.I.locked.removeListener(_sync);
      HardwareKeyboard.instance.removeHandler(_onKey);
      _idle?.cancel();
      _removeRoute();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) return widget.child;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _last = DateTime.now(),
      onPointerMove: (_) => _last = DateTime.now(),
      onPointerSignal: (_) => _last = DateTime.now(),
      child: widget.child,
    );
  }
}

class _PinScreen extends StatefulWidget {
  const _PinScreen();
  @override
  State<_PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<_PinScreen> {
  final _c = TextEditingController();
  String? _err;
  bool _busy = false;

  Future<void> _go() async {
    if (_busy) return;
    setState(() => _busy = true);
    final e = await AppLock.I.tryUnlock(_c.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _err = e;
    });
    if (e != null) _c.clear();
  }

  Future<void> _forgot() async {
    final ok = await confirm(
        context,
        'برای حذف رمز باید از حساب خارج شوید و دوباره با پیامک وارد شوید. '
        'اطلاعات شما پاک نمی‌شود. ادامه می‌دهید؟');
    if (!ok) return;
    await LicenseService.I.signOut();
    await AppLock.I.clear();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.lock_outline, size: 48),
                  const SizedBox(height: 8),
                  const Text('پسته بازار قفل است', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _c,
                    obscureText: true,
                    autofocus: true,
                    textAlign: TextAlign.center,
                    decoration: InputDecoration(labelText: 'رمز', errorText: _err, border: const OutlineInputBorder()),
                    onSubmitted: (_) => _go(),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(width: double.infinity, child: FilledButton(onPressed: _busy ? null : _go, child: const Text('باز کردن'))),
                  TextButton(onPressed: _forgot, child: const Text('رمز را فراموش کرده‌ام')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// تنظیم/تغییر/حذف رمز قفل
class SecurityScreen extends StatefulWidget {
  const SecurityScreen({super.key});
  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  final _cur = TextEditingController();
  final _a = TextEditingController();
  final _b = TextEditingController();
  String? _err;

  @override
  void dispose() {
    _cur.dispose();
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (AppLock.I.enabled && !await AppLock.I.check(_cur.text)) {
      setState(() => _err = 'رمز فعلی اشتباه است');
      return;
    }
    if (_a.text.length < 4) {
      setState(() => _err = 'رمز حداقل ۴ کاراکتر باشد');
      return;
    }
    if (_a.text != _b.text) {
      setState(() => _err = 'تکرار رمز یکسان نیست');
      return;
    }
    await AppLock.I.setPin(_a.text);
    if (!mounted) return;
    snack(context, 'قفل برنامه فعال شد');
    Navigator.pop(context);
  }

  Future<void> _remove() async {
    if (!await AppLock.I.check(_cur.text)) {
      setState(() => _err = 'رمز فعلی اشتباه است');
      return;
    }
    await AppLock.I.clear();
    if (!mounted) return;
    snack(context, 'قفل برنامه غیرفعال شد');
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final on = AppLock.I.enabled;
    return Scaffold(
      appBar: AppBar(title: const Text('قفل برنامه')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(on
              ? 'قفل فعال است؛ بعد از ۱۰ دقیقه بی‌حرکتی و هر بار باز شدن برنامه رمز خواسته می‌شود.'
              : 'با رمز، کسی که پشت کامپیوتر شما می‌نشیند نمی‌تواند اطلاعات را ببیند.'),
          const SizedBox(height: 12),
          if (on)
            TextField(controller: _cur, obscureText: true, decoration: const InputDecoration(labelText: 'رمز فعلی', border: OutlineInputBorder())),
          const SizedBox(height: 8),
          TextField(controller: _a, obscureText: true, decoration: InputDecoration(labelText: on ? 'رمز جدید' : 'رمز', border: const OutlineInputBorder())),
          const SizedBox(height: 8),
          TextField(controller: _b, obscureText: true, decoration: const InputDecoration(labelText: 'تکرار رمز', border: OutlineInputBorder())),
          if (_err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_err!, style: const TextStyle(color: Colors.red))),
          const SizedBox(height: 12),
          FilledButton(onPressed: _save, child: Text(on ? 'تغییر رمز' : 'فعال‌سازی قفل')),
          if (on) TextButton(onPressed: _remove, child: const Text('غیرفعال‌کردن قفل (با وارد کردن رمز فعلی)')),
        ],
      ),
    );
  }
}
