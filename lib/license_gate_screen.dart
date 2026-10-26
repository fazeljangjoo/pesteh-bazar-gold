import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'contract_screen.dart';
import 'db.dart';
import 'pay_service.dart';
import 'renewal_screen.dart';
import 'notify_service.dart';
import 'sync_service.dart';
import 'license_guard.dart';
import 'license_service.dart';
import 'local_backup.dart';
import 'utils.dart';
import 'widgets.dart';

/// این ویجت را دور کل برنامه می‌پیچیم: تا وقتی کاربر وارد نشده یا اشتراکش
/// معتبر نیست، به‌جای برنامه، صفحهٔ ورود/پیام مناسب نشان داده می‌شود.
class LicenseGate extends StatefulWidget {
  final Widget child;
  const LicenseGate({super.key, required this.child});
  @override
  State<LicenseGate> createState() => LicenseGateState();
}

class LicenseGateState extends State<LicenseGate> with WidgetsBindingObserver {
  bool _loading = true;
  LicenseResult? _result;
  String? _dataError;
  Map<String, dynamic>? _contract; // قرارداد نپذیرفته‌شده: تا پذیرش، برنامه باز نمی‌شود
  Timer? _recheck;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (kStrictLicense) {
      // برنامهٔ ویندوز ممکن است روزها باز بماند؛ تمدید/پایان اشتراک را هر نیم‌ساعت دوباره می‌سنجیم
      _recheck = Timer.periodic(const Duration(minutes: 30), (_) {
        if (mounted && !_loading) refresh();
      });
    }
    LicenseService.I.sessionInvalid.addListener(_onSessionInvalid);
    refresh();
  }

  @override
  void dispose() {
    _recheck?.cancel();
    LicenseService.I.sessionInvalid.removeListener(_onSessionInvalid);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// سرور توکن را نپذیرفت (مثلاً رمز از دستگاه دیگری عوض شد): وضعیت دوباره بررسی می‌شود و
  /// اگر توکن واقعاً نامعتبر بود، کاربر به صفحهٔ ورود می‌رود (مثل وب).
  void _onSessionInvalid() {
    if (mounted && !_loading) refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // بعد از قفل صفحه/خواب سیستم: مطمئن شو دیتابیس باز و سالم است تا ثبت بعدی ناموفق نشود
      AppDb.I.ensureHealthy();
      refresh();
    }
  }

  /// دیتابیس حساب را باز می‌کند؛ اگر این دستگاه هنوز داده‌های حساب را نگرفته (ورود اول /
  /// نصب مجدد)، همه را از سرور می‌آورد. بعد از آن برنامه بدون اینترنت هم کار می‌کند.
  Future<String?> _prepareData(String phone) async {
    try {
      await AppDb.I.useAccount(phone);
      if (await AppDb.I.metaGet('initial_done') == null) {
        final err = await SyncService.I.initialSync();
        if (err != null) return err;
      }
      LocalBackup.I.start(); // فقط ویندوز: پشتیبان‌گیری روزانهٔ محلی
      // ignore: unawaited_futures
      NotifyService.I.rescheduleAll();
      // ignore: unawaited_futures
      SyncService.I.syncNow();
    } catch (e) {
      return 'خطا در باز کردن اطلاعات حساب: $e';
    }
    return null;
  }

  Future<void> refresh() async {
    // در بازگشت به برنامه، اگر قبلاً وارد شده بود، صفحهٔ فعلی با اسپینر عوض نشود
    if (_result == null || _result!.state != LicenseState.valid) setState(() => _loading = true);
    final r = await LicenseService.I.check();
    String? dataErr;
    Map<String, dynamic>? contract;
    if (r.state == LicenseState.valid && r.phone != null) {
      contract = await _fetchPendingContract();
      if (contract == null) dataErr = await _prepareData(r.phone!);
    }
    if (!mounted) return;
    setState(() {
      _result = r;
      _dataError = dataErr;
      _contract = contract;
      _loading = false;
    });
    // خوش‌آمدگویی کاربر جدیدی که همین الان ثبت‌نام کرده
    if (r.state == LicenseState.valid && dataErr == null) {
      final welcome = LicenseService.I.takeWelcome();
      if (welcome != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text(welcome), duration: const Duration(seconds: 6)));
        });
      }
    }
  }

  /// قرارداد نپذیرفته‌شده را برمی‌گرداند. خطای شبکه کاربر را نمی‌بندد (برنامهٔ آفلاین کار کند)
  /// و تا اتصال بعدی بررسی می‌شود.
  Future<Map<String, dynamic>?> _fetchPendingContract() async {
    try {
      return await PayService.I.pendingContract().timeout(const Duration(seconds: 15));
    } catch (e) {
      debugPrint('contract check skipped: $e');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final r = _result!;
    switch (r.state) {
      case LicenseState.loggedOut:
        return LoginScreen(onSuccess: refresh);
      case LicenseState.needsInternet:
        return MessageScreen(
          icon: Icons.wifi_off_outlined,
          title: 'نیاز به اتصال اینترنت',
          message: r.message ?? 'برای اولین بررسیِ اشتراک، یک‌بار باید اینترنت داشته باشید.',
          onRetry: refresh,
        );
      case LicenseState.blocked:
        return BlockedScreen(phone: r.phone, onRetry: refresh);
      case LicenseState.valid:
        if (_contract != null) {
          return ContractAcceptScreen(
            item: _contract!,
            onAccepted: refresh,
            onLogout: () async {
              try {
                await LicenseService.I.signOut();
              } catch (e) {
                debugPrint('signOut error: $e');
              }
              refresh();
            },
          );
        }
        if (_dataError != null) {
          return MessageScreen(
            icon: Icons.cloud_download_outlined,
            title: 'دریافت اطلاعات حساب',
            message: _dataError!,
            onRetry: refresh,
          );
        }
        return widget.child;
    }
  }
}

/// دکمه‌های تماس/واتس‌اپ با پشتیبانی — در چند صفحه استفاده می‌شود
class ContactButtons extends StatelessWidget {
  final String? phoneForMessage;
  const ContactButtons({super.key, this.phoneForMessage});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: [
        OutlinedButton.icon(
          onPressed: () => callSupport(context, SupportContact.callNumber, SupportContact.displayPhone),
          icon: const Icon(Icons.call_outlined),
          label: Text('تماس: ${SupportContact.displayPhone}'),
        ),
        OutlinedButton.icon(
          onPressed: () {
            final base = 'سلام، برای فعال‌سازی/تمدید اشتراک پسته بازار تماس می‌گیرم.';
            final withPhone = (phoneForMessage != null && phoneForMessage!.trim().isNotEmpty)
                ? '$base شماره من: ${phoneForMessage!}'
                : base;
            final msg = Uri.encodeComponent(withPhone);
            launchUrl(Uri.parse('https://wa.me/${SupportContact.whatsappNumber}?text=$msg'));
          },
          icon: const Icon(Icons.chat_outlined),
          label: const Text('واتس‌اپ'),
        ),
      ],
    );
  }
}

enum _LoginStep { phone, code, name, newpass, pass }

/// ورود با شماره موبایل: پیش‌فرض «کد پیامکی» (شماره ← کد ← [نام، فقط کاربر جدید])
/// و با یک لینک زیر دکمه «ورود با رمز عبور» (شماره + رمز؛ فقط برای حساب‌هایی که رمز دارند)
class LoginScreen extends StatefulWidget {
  final VoidCallback onSuccess;
  const LoginScreen({super.key, required this.onSuccess});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _pass = TextEditingController();
  final _user = TextEditingController(); // T02.2: نام کاربری کارکن
  bool _asStaff = false;
  final _newPass = TextEditingController();
  final _newPass2 = TextEditingController();
  bool _showPass = false;
  _LoginStep _step = _LoginStep.phone;
  String _verifiedCode = ''; // کدی که درست بود ولی منتظر نام هستیم
  bool _loading = false;
  String? _error;
  int _cooldown = 0;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _phone.dispose();
    _code.dispose();
    _name.dispose();
    _pass.dispose();
    _user.dispose();
    _newPass.dispose();
    _newPass2.dispose();
    super.dispose();
  }

  void _startCooldown(int sec) {
    _timer?.cancel();
    setState(() => _cooldown = sec < 0 ? 0 : sec);
    if (_cooldown <= 0) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _cooldown--);
      if (_cooldown <= 0) t.cancel();
    });
  }

  void _goStep(_LoginStep s) {
    setState(() {
      _step = s;
      _error = null;
    });
    if (s == _LoginStep.phone || s == _LoginStep.pass) {
      _timer?.cancel();
      _cooldown = 0;
      _code.clear();
      _verifiedCode = '';
      _newPass.clear();
      _newPass2.clear();
    }
    if (s == _LoginStep.pass) _pass.clear();
  }

  /// جابه‌جایی «ورود با رمز عبور» ⇄ «ورود با کد پیامکی» (فقط در دو مرحلهٔ اول دیده می‌شود)
  void _toggleMode() => _goStep(_step == _LoginStep.pass ? _LoginStep.phone : _LoginStep.pass);

  Future<void> _passwordLogin() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final err = _asStaff
        ? await LicenseService.I.signInStaff(_phone.text, _user.text, _pass.text)
        : await LicenseService.I.signInWithPassword(_phone.text, _pass.text);
    if (!mounted) return;
    setState(() => _loading = false);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    _pass.clear();
    widget.onSuccess();
  }

  Future<void> _sendCode({bool resend = false}) async {
    if (!LicenseService.I.isValidPhone(_phone.text)) {
      setState(() => _error = _phone.text.trim().isEmpty
          ? 'شماره موبایل را وارد کنید'
          : 'شماره موبایل را درست وارد کنید (مثال: 09123456789)');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final r = await LicenseService.I.sendOtp(_phone.text);
    if (!mounted) return;
    setState(() => _loading = false);
    if (r.ok) {
      if (resend) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('کد جدید ارسال شد')));
      } else {
        _goStep(_LoginStep.code);
        _code.clear();
      }
      _startCooldown(r.resendIn);
    } else if (r.canEnterCode) {
      // کد قبلاً فرستاده شده و مهلت ارسال دوباره تمام نشده: کاربر را به مرحلهٔ کد می‌بریم
      if (!resend) _goStep(_LoginStep.code);
      _startCooldown(r.resendIn);
      setState(() => _error = r.error);
    } else {
      setState(() => _error = r.error);
    }
  }

  Future<void> _verify() async {
    // مرحلهٔ نام (کاربر جدید): فقط نام را می‌گیریم و به مرحلهٔ تعیین رمز می‌رویم
    if (_step == _LoginStep.name) {
      if (_name.text.trim().length < 2) {
        setState(() => _error = 'نام خود را وارد کنید');
        return;
      }
      _goStep(_LoginStep.newpass);
      return;
    }
    final isNewPassStep = _step == _LoginStep.newpass;
    final code = isNewPassStep ? _verifiedCode : _code.text;
    String? name;
    String? password;
    if (isNewPassStep) {
      name = _name.text.trim();
      password = _newPass.text;
      if (password.length < LicenseService.passwordMinLen) {
        setState(() => _error = 'رمز عبور باید حداقل ۶ کاراکتر باشد');
        return;
      }
      if (password != _newPass2.text) {
        setState(() => _error = 'تکرار رمز با رمز عبور یکسان نیست');
        return;
      }
    } else if (code.trim().isEmpty) {
      setState(() => _error = 'کد پیامکی را وارد کنید');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final r = await LicenseService.I.verifyOtp(_phone.text, code, name: name, password: password);
    if (!mounted) return;
    setState(() => _loading = false);
    if (r.needName) {
      // کاربر جدید: کد درست است ولی هنوز مصرف نشده؛ نام و بعد رمز را می‌پرسیم
      _verifiedCode = code;
      _goStep(_LoginStep.name);
      return;
    }
    if (r.error != null) {
      setState(() => _error = r.error);
      return;
    }
    _timer?.cancel();
    widget.onSuccess();
  }

  void _submit() {
    if (_loading) return;
    if (_step == _LoginStep.phone) {
      _sendCode();
    } else if (_step == _LoginStep.pass) {
      _passwordLogin();
    } else {
      _verify();
    }
  }

  String get _buttonLabel => switch (_step) {
        _LoginStep.phone => 'دریافت کد ورود',
        _LoginStep.code => 'ورود',
        _LoginStep.name => 'ادامه',
        _LoginStep.newpass => 'ثبت‌نام و ورود',
        _LoginStep.pass => 'ورود',
      };

  @override
  Widget build(BuildContext context) {
    final phoneShown = toFaDigits(toEnDigits(_phone.text.trim()));
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.storefront_outlined, size: 64),
              const SizedBox(height: 12),
              Text('پسته بازار', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text(
                  _step == _LoginStep.pass
                      ? 'ورود با شماره موبایل و رمز عبور'
                      : 'ورود با شماره موبایل و کد پیامکی',
                  style: const TextStyle(color: Colors.black54)),
              const SizedBox(height: 24),
              if (_step == _LoginStep.phone || _step == _LoginStep.pass)
                TextField(
                  key: const ValueKey('login_phone'),
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  textDirection: TextDirection.ltr,
                  autofocus: false,
                  textInputAction: _step == _LoginStep.pass ? TextInputAction.next : TextInputAction.done,
                  onSubmitted: (_) {
                    if (_step != _LoginStep.pass) _submit();
                  },
                  decoration: const InputDecoration(
                    labelText: 'شماره موبایل',
                    hintText: '09xxxxxxxxx',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.phone_outlined),
                  ),
                ),
              if (_step == _LoginStep.pass) ...[
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('login_pass'),
                  controller: _pass,
                  obscureText: !_showPass,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLength: 200,
                  textDirection: TextDirection.ltr,
                  autofillHints: const [AutofillHints.password],
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: 'رمز عبور',
                    counterText: '',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      tooltip: _showPass ? 'پنهان‌کردن رمز' : 'نمایش رمز',
                      icon: Icon(_showPass ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                      onPressed: () => setState(() => _showPass = !_showPass),
                    ),
                  ),
                ),
              ],
              if (_step == _LoginStep.pass) ...[
                const SizedBox(height: 4),
                if (_asStaff)
                  TextField(
                    key: const ValueKey('login_user'),
                    controller: _user,
                    autocorrect: false,
                    enableSuggestions: false,
                    maxLength: 60,
                    textDirection: TextDirection.ltr,
                    decoration: const InputDecoration(
                      labelText: 'نام کاربری کارکن',
                      counterText: '',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.badge_outlined),
                    ),
                  ),
                TextButton(
                  onPressed: _loading
                      ? null
                      : () => setState(() {
                            _asStaff = !_asStaff;
                            _error = null;
                          }),
                  child: Text(_asStaff ? 'ورود با حساب مالک' : 'ورود کارکن'),
                ),
              ],
              if (_step == _LoginStep.code) ...[
                Text('کد پیامکی به $phoneShown ارسال شد',
                    textAlign: TextAlign.center, style: const TextStyle(color: Colors.black54)),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('login_code'),
                  controller: _code,
                  keyboardType: TextInputType.number,
                  textDirection: TextDirection.ltr,
                  textAlign: TextAlign.center,
                  maxLength: 12,
                  autofocus: true,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                  style: const TextStyle(fontSize: 20, letterSpacing: 4),
                  decoration: const InputDecoration(
                    labelText: 'کد پیامکی',
                    counterText: '',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.sms_outlined),
                  ),
                ),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  TextButton(
                    onPressed: (_cooldown > 0 || _loading) ? null : () => _sendCode(resend: true),
                    child: Text(_cooldown > 0
                        ? 'ارسال دوباره (${faNum(_cooldown, dec: 0)} ثانیه)'
                        : 'ارسال دوباره کد'),
                  ),
                  TextButton(
                    onPressed: _loading ? null : () => _goStep(_LoginStep.phone),
                    child: const Text('تغییر شماره'),
                  ),
                ]),
              ],
              if (_step == _LoginStep.name) ...[
                const Text('به پسته بازار خوش آمدید! برای ساخت حساب جدید، نام خود را وارد کنید.',
                    textAlign: TextAlign.center, style: TextStyle(color: Colors.black54)),
                const SizedBox(height: 12),
                TextField(
                  // کلید یکتا لازم است: بدون آن، فلاتر فیلد «کد پیامکی» (کیبورد عددی) را برای
                  // فیلد «نام» دوباره استفاده می‌کند و کیبورد عددی باقی می‌ماند.
                  key: const ValueKey('login_name'),
                  controller: _name,
                  keyboardType: TextInputType.name,
                  textCapitalization: TextCapitalization.words,
                  maxLength: 60,
                  autofocus: true,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                  decoration: const InputDecoration(
                    labelText: 'نام و نام خانوادگی',
                    hintText: 'مثلاً علی رضایی',
                    counterText: '',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    onPressed: _loading ? null : () => _goStep(_LoginStep.phone),
                    child: const Text('تغییر شماره'),
                  ),
                ),
              ],
              if (_step == _LoginStep.newpass) ...[
                const Text('یک رمز عبور برای حساب خود تعیین کنید (حداقل ۶ کاراکتر)',
                    textAlign: TextAlign.center, style: TextStyle(color: Colors.black54)),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('login_newpass'),
                  controller: _newPass,
                  obscureText: !_showPass,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLength: 72,
                  autofocus: true,
                  textDirection: TextDirection.ltr,
                  autofillHints: const [AutofillHints.newPassword],
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: 'رمز عبور',
                    counterText: '',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      tooltip: _showPass ? 'پنهان‌کردن رمز' : 'نمایش رمز',
                      icon: Icon(_showPass ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                      onPressed: () => setState(() => _showPass = !_showPass),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('login_newpass2'),
                  controller: _newPass2,
                  obscureText: !_showPass,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLength: 72,
                  textDirection: TextDirection.ltr,
                  autofillHints: const [AutofillHints.newPassword],
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                  decoration: const InputDecoration(
                    labelText: 'تکرار رمز عبور',
                    counterText: '',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.lock_outline),
                  ),
                ),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    onPressed: _loading ? null : () => _goStep(_LoginStep.name),
                    child: const Text('بازگشت'),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _loading ? null : _submit,
                  child: _loading
                      ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_buttonLabel),
                ),
              ),
              if (_step == _LoginStep.phone || _step == _LoginStep.pass) ...[
                const SizedBox(height: 4),
                Center(
                  child: TextButton(
                    onPressed: _loading ? null : _toggleMode,
                    child: Text(_step == _LoginStep.pass ? 'ورود با کد پیامکی' : 'ورود با رمز عبور'),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              const Text('کاربر جدید: ۲۰ روز اشتراک آزمایشی رایگان',
                  textAlign: TextAlign.center, style: TextStyle(color: Colors.black54, fontSize: 12.5)),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              const Text('مشکلی در ورود دارید؟',
                  textAlign: TextAlign.center, style: TextStyle(color: Colors.black54)),
              const SizedBox(height: 10),
              ContactButtons(phoneForMessage: _phone.text),
            ]),
          ),
        ),
      ),
    );
  }
}

class MessageScreen extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final VoidCallback onRetry;
  const MessageScreen(
      {super.key, required this.icon, required this.title, required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 56, color: Colors.black45),
              const SizedBox(height: 12),
              Text(title, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(message, textAlign: TextAlign.center, style: const TextStyle(color: Colors.black54)),
              const SizedBox(height: 20),
              FilledButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('بررسی مجدد')),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () async {
                  await LicenseService.I.signOut();
                  onRetry();
                },
                child: const Text('خروج از حساب'),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class BlockedScreen extends StatelessWidget {
  final String? phone;
  final VoidCallback onRetry;
  const BlockedScreen({super.key, this.phone, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.lock_clock_outlined, size: 56, color: Colors.redAccent),
              const SizedBox(height: 12),
              Text('اشتراک شما فعال نیست', style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              const Text(
                'اشتراک این حساب هنوز فعال نشده یا منقضی شده است. برای فعال‌سازی یا تمدید با پشتیبانی تماس بگیرید.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black54),
              ),
              if (phone != null) ...[
                const SizedBox(height: 8),
                Text('شماره حساب شما: ${toFaDigits(phone!)}', style: const TextStyle(fontWeight: FontWeight.w600)),
              ],
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => RenewalScreen(onDone: onRetry)),
                ),
                icon: const Icon(Icons.payments_outlined),
                label: const Text('تمدید اشتراک'),
              ),
              const SizedBox(height: 12),
              ContactButtons(phoneForMessage: phone),
              const SizedBox(height: 20),
              OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('بررسی مجدد')),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () async {
                  await LicenseService.I.signOut();
                  onRetry();
                },
                child: const Text('خروج از حساب'),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
