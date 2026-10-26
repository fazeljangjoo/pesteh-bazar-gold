import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'license_service.dart';
import 'utils.dart';
import 'widgets.dart';

/// قفل صفحهٔ «سود و زیان»: با یک رمز عددی (۴ تا ۸ رقم) که فقط روی همین دستگاه و به‌صورت هش‌شده نگه‌داشته می‌شود.
/// سود و زیان فقط در همین صفحه نشان داده می‌شود؛ پس اگر مشتری گوشی/کامپیوتر را ببیند درآمد دیده نمی‌شود.
class ProfitLock {
  ProfitLock._();
  static final ProfitLock I = ProfitLock._();

  static const _kHash = 'profit_lock_hash';
  static const _kSalt = 'profit_lock_salt';
  static const Duration _grace = Duration(minutes: 3); // بعد از باز کردن، چند دقیقه دوباره رمز نمی‌خواهد

  DateTime? _unlockedAt;

  String _hash(String pin, String salt) => sha256.convert(utf8.encode('$salt|$pin|pesteh')).toString();

  Future<bool> isEnabled() async {
    final sp = await SharedPreferences.getInstance();
    return (sp.getString(_kHash) ?? '').isNotEmpty;
  }

  bool get recentlyUnlocked => _unlockedAt != null && DateTime.now().difference(_unlockedAt!) < _grace;

  void lockNow() => _unlockedAt = null;

  Future<void> setPin(String pin) async {
    final sp = await SharedPreferences.getInstance();
    final rnd = math.Random.secure();
    final salt = List<int>.generate(12, (_) => rnd.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await sp.setString(_kSalt, salt);
    await sp.setString(_kHash, _hash(pin, salt));
    _unlockedAt = DateTime.now();
  }

  Future<bool> verify(String pin) async {
    final sp = await SharedPreferences.getInstance();
    final salt = sp.getString(_kSalt) ?? '';
    final h = sp.getString(_kHash) ?? '';
    final ok = h.isNotEmpty && h == _hash(pin, salt);
    if (ok) _unlockedAt = DateTime.now();
    return ok;
  }

  Future<void> remove() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kHash);
    await sp.remove(_kSalt);
    _unlockedAt = null;
  }
}

/// صفحهٔ وارد کردن رمز (به‌جای محتوای سود و زیان)
class ProfitLockPad extends StatefulWidget {
  final VoidCallback onUnlocked;
  const ProfitLockPad({super.key, required this.onUnlocked});
  @override
  State<ProfitLockPad> createState() => _ProfitLockPadState();
}

class _ProfitLockPadState extends State<ProfitLockPad> {
  final _pin = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await ProfitLock.I.verify(toEnDigits(_pin.text.trim()));
    if (!mounted) return;
    if (ok) {
      widget.onUnlocked();
    } else {
      setState(() {
        _busy = false;
        _error = 'رمز درست نیست';
        _pin.clear();
      });
    }
  }

  Future<void> _forgot() async {
    final ok = await confirm(context,
        'برای ریست رمز باید از حساب خارج شوید و دوباره با کد پیامکی وارد شوید (اطلاعات شما پاک نمی‌شود). ادامه می‌دهید؟');
    if (!ok) return;
    await ProfitLock.I.remove();
    try {
      await LicenseService.I.signOut();
    } catch (_) {}
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.lock_outline, size: 56, color: scheme.primary),
            const SizedBox(height: 12),
            Text('صفحهٔ سود و زیان قفل است', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text('رمز را وارد کنید', style: TextStyle(color: Colors.black54)),
            const SizedBox(height: 16),
            TextField(
              controller: _pin,
              autofocus: true,
              obscureText: true,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              maxLength: 8,
              style: const TextStyle(fontSize: 22, letterSpacing: 8),
              decoration: InputDecoration(border: const OutlineInputBorder(), counterText: '', errorText: _error),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: _busy ? null : _submit, child: const Text('باز کردن')),
            ),
            TextButton(onPressed: _forgot, child: const Text('رمز را فراموش کرده‌ام')),
          ]),
        ),
      ),
    );
  }
}

/// تنظیم / تغییر / حذف رمز قفل سود و زیان
Future<void> showProfitLockSettings(BuildContext context) async {
  final enabled = await ProfitLock.I.isEnabled();
  if (!context.mounted) return;
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text('قفل صفحهٔ سود و زیان', style: Theme.of(ctx).textTheme.titleMedium),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text(
              enabled
                  ? 'قفل فعال است؛ برای دیدن سود و زیان باید رمز را وارد کنید.'
                  : 'با فعال‌کردن قفل، هیچ‌کس بدون رمز درآمد و سود شما را نمی‌بیند.',
              style: const TextStyle(color: Colors.black54)),
        ),
        ListTile(
          leading: const Icon(Icons.password),
          title: Text(enabled ? 'تغییر رمز' : 'فعال‌کردن قفل'),
          onTap: () => Navigator.pop(ctx, 'set'),
        ),
        if (enabled)
          ListTile(
            leading: const Icon(Icons.lock_open),
            title: const Text('حذف قفل'),
            onTap: () => Navigator.pop(ctx, 'remove'),
          ),
      ]),
    ),
  );
  if (choice == null || !context.mounted) return;
  if (choice == 'remove') {
    final cur = await _askPin(context, 'رمز فعلی را وارد کنید');
    if (cur == null || !context.mounted) return;
    if (!await ProfitLock.I.verify(cur)) {
      if (context.mounted) snack(context, 'رمز درست نیست');
      return;
    }
    await ProfitLock.I.remove();
    if (context.mounted) snack(context, 'قفل برداشته شد');
    return;
  }
  if (enabled) {
    final cur = await _askPin(context, 'رمز فعلی را وارد کنید');
    if (cur == null || !context.mounted) return;
    if (!await ProfitLock.I.verify(cur)) {
      if (context.mounted) snack(context, 'رمز درست نیست');
      return;
    }
  }
  if (!context.mounted) return;
  final a = await _askPin(context, 'رمز جدید (۴ تا ۸ رقم)');
  if (a == null || !context.mounted) return;
  if (a.length < 4) {
    snack(context, 'رمز باید دست‌کم ۴ رقم باشد');
    return;
  }
  final b = await _askPin(context, 'رمز جدید را دوباره وارد کنید');
  if (b == null || !context.mounted) return;
  if (a != b) {
    snack(context, 'دو رمز یکی نیستند');
    return;
  }
  await ProfitLock.I.setPin(a);
  if (context.mounted) snack(context, 'قفل صفحهٔ سود و زیان فعال شد');
}

Future<String?> _askPin(BuildContext context, String title) async {
  final c = TextEditingController();
  final r = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        obscureText: true,
        keyboardType: TextInputType.number,
        maxLength: 8,
        textAlign: TextAlign.center,
        decoration: const InputDecoration(border: OutlineInputBorder(), counterText: ''),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('انصراف')),
        FilledButton(onPressed: () => Navigator.pop(ctx, toEnDigits(c.text.trim())), child: const Text('تأیید')),
      ],
    ),
  );
  c.dispose();
  return (r == null || r.isEmpty) ? null : r;
}
