import 'package:flutter/material.dart';

import 'renewal_screen.dart';
import 'sync_screen.dart';
import 'license_gate_screen.dart' show ContactButtons;
import 'edition.dart';
import 'license_service.dart';
import 'utils.dart';
import 'widgets.dart';

class SubscriptionScreen extends StatefulWidget {
  const SubscriptionScreen({super.key});
  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  bool _loading = true;
  LicenseResult? _result;

  // --- نام و رمز عبور ---
  final _name = TextEditingController();
  final _curPass = TextEditingController();
  final _newPass = TextEditingController();
  final _newPass2 = TextEditingController();
  bool _accountLoading = true;
  bool _accountLoaded = false; // اطلاعات حساب (نام/رمز دارد؟) از سرور رسیده یا نه
  bool _hasPassword = false;
  bool _savingName = false;
  bool _savingPass = false;
  bool _showPass = false;
  String? _passError;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _name.dispose();
    _curPass.dispose();
    _newPass.dispose();
    _newPass2.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final r = await LicenseService.I.check();
    if (!mounted) return;
    setState(() {
      _result = r;
      _loading = false;
    });
    _loadAccount();
  }

  /// فقط وضعیت اشتراک/نام را بدون اسپینر تازه می‌کند (بعد از ذخیرهٔ نام)
  Future<void> _refreshQuiet() async {
    final r = await LicenseService.I.check();
    if (!mounted) return;
    setState(() => _result = r);
  }

  Future<void> _loadAccount() async {
    setState(() => _accountLoading = true);
    final info = await LicenseService.I.fetchAccountInfo();
    if (!mounted) return;
    setState(() {
      _accountLoading = false;
      _accountLoaded = info != null;
      if (info != null) {
        _hasPassword = info.hasPassword;
        _name.text = info.name ?? '';
      }
    });
  }

  Future<void> _saveName() async {
    if (_savingName) return;
    setState(() => _savingName = true);
    final r = await LicenseService.I.setName(_name.text);
    if (!mounted) return;
    setState(() => _savingName = false);
    snack(context, r.ok ? 'نام ذخیره شد' : r.error!);
    if (r.ok) _refreshQuiet();
  }

  Future<void> _savePassword() async {
    if (_savingPass) return;
    final cur = _curPass.text;
    final n1 = _newPass.text;
    final n2 = _newPass2.text;
    String? err;
    if (_hasPassword && cur.isEmpty) {
      err = 'رمز فعلی را وارد کنید';
    } else if (n1.length < LicenseService.passwordMinLen) {
      err = 'رمز جدید باید حداقل ۶ کاراکتر باشد';
    } else if (n1 != n2) {
      err = 'تکرار رمز با رمز جدید یکسان نیست';
    }
    if (err != null) {
      setState(() => _passError = err);
      return;
    }
    setState(() {
      _savingPass = true;
      _passError = null;
    });
    final r = await LicenseService.I.setPassword(currentPassword: cur, newPassword: n1);
    if (!mounted) return;
    setState(() => _savingPass = false);
    if (!r.ok) {
      setState(() => _passError = r.error);
      return;
    }
    _curPass.clear();
    _newPass.clear();
    _newPass2.clear();
    snack(context, 'رمز عبور ذخیره شد؛ دستگاه‌های دیگر خارج شدند');
    _loadAccount();
  }

  Widget _accountCard() {
    if (_accountLoading && !_accountLoaded) {
      return const Card(
        child: Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
      );
    }
    if (!_accountLoaded) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('اطلاعات حساب دریافت نشد؛ اینترنت را بررسی کنید.',
                textAlign: TextAlign.center, style: TextStyle(color: Colors.black54)),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _loadAccount,
              icon: const Icon(Icons.refresh),
              label: const Text('تلاش دوباره'),
            ),
          ]),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            controller: _name,
            maxLength: 60,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'نام',
              hintText: 'نام و نام خانوادگی',
              counterText: '',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.person_outline),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _savingName ? null : _saveName,
            child: _savingName
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('ذخیرهٔ نام'),
          ),
          const Divider(height: 28),
          const Text(
            'با تعیین رمز عبور، وقتی پیامک نمی‌رسد هم می‌توانید با «ورود با رمز عبور» وارد شوید.',
            style: TextStyle(color: Colors.black54, fontSize: 12.5),
          ),
          const SizedBox(height: 10),
          if (_hasPassword) ...[
            _passField(_curPass, 'رمز فعلی', max: 200),
            const SizedBox(height: 10),
          ],
          _passField(_newPass, 'رمز جدید (حداقل ۶ کاراکتر)', max: 72),
          const SizedBox(height: 10),
          _passField(_newPass2, 'تکرار رمز جدید', max: 72),
          if (_passError != null) ...[
            const SizedBox(height: 8),
            Text(_passError!, style: const TextStyle(color: Colors.red, fontSize: 13)),
          ],
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _savingPass ? null : _savePassword,
            icon: _savingPass
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.key_outlined),
            label: Text(_hasPassword ? 'تغییر رمز عبور' : 'تعیین رمز عبور'),
          ),
          const SizedBox(height: 8),
          const Text(
            'با هر تغییر رمز، دستگاه‌های دیگرِ این حساب خارج می‌شوند و باید دوباره وارد شوند.',
            style: TextStyle(color: Colors.black54, fontSize: 12),
          ),
        ]),
      ),
    );
  }

  Widget _passField(TextEditingController c, String label, {required int max}) => TextField(
        controller: c,
        obscureText: !_showPass,
        autocorrect: false,
        enableSuggestions: false,
        maxLength: max,
        textDirection: TextDirection.ltr,
        decoration: InputDecoration(
          labelText: label,
          counterText: '',
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(Icons.lock_outline),
          suffixIcon: IconButton(
            tooltip: _showPass ? 'پنهان‌کردن رمز' : 'نمایش رمز',
            icon: Icon(_showPass ? Icons.visibility_off_outlined : Icons.visibility_outlined),
            onPressed: () => setState(() => _showPass = !_showPass),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final r = _result;
    final valid = r?.state == LicenseState.valid;
    return Scaffold(
      appBar: AppBar(title: const Text('اشتراک من')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  color: valid
                      ? Theme.of(context).colorScheme.primaryContainer
                      : Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      if (r?.name != null) infoRow('نام', r!.name!),
                      infoRow('شماره حساب', r?.phone != null ? toFaDigits(r!.phone!) : '-'),
                      infoRow('نوع اشتراک', EditionService.I.edition.nameFa),
                      if (r?.expiry != null) infoRow('تاریخ انقضا', jalaliDateFromDt(r!.expiry!)),
                      infoRow(
                        'وضعیت',
                        valid ? 'فعال — ${faNum(r!.remainingDays)} روز باقی‌مانده' : 'غیرفعال / منقضی',
                        valueColor: valid ? Colors.green.shade800 : Colors.red.shade800,
                      ),
                    ]),
                  ),
                ),
                ValueListenableBuilder<Edition>(
                  valueListenable: EditionService.I.current,
                  builder: (BuildContext ctx, Edition e, Widget? _) {
                    if (e.isGold) return const SizedBox.shrink();
                    // placeholder: the real upgrade flow is wired in S20 (Green only)
                    return Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.workspace_premium_outlined),
                        label: const Text('ارتقا به طلایی'),
                        onPressed: () => snack(ctx, 'ارتقا به نسخهٔ طلایی به‌زودی فعال می‌شود؛ فعلاً با پشتیبانی تماس بگیرید'),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 20),
                const Text('برای تمدید یا تغییر اشتراک با پشتیبانی تماس بگیرید:',
                    textAlign: TextAlign.center),
                const SizedBox(height: 12),
                ContactButtons(phoneForMessage: r?.phone),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => RenewalScreen(onDone: _refresh)),
                  ),
                  icon: const Icon(Icons.payments_outlined),
                  label: const Text('تمدید / خرید اشتراک'),
                ),
                const SizedBox(height: 24),
                sectionTitle(context, 'نام و رمز عبور'),
                _accountCard(),
                const SizedBox(height: 24),
                FilledButton.tonalIcon(
                  onPressed: () => Navigator.push(
                      context, MaterialPageRoute(builder: (_) => const SyncScreen())),
                  icon: const Icon(Icons.cloud_upload_outlined),
                  label: const Text('همگام‌سازی و بازیابی اطلاعات'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                    onPressed: _refresh, icon: const Icon(Icons.refresh), label: const Text('بررسی مجدد وضعیت')),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () async {
                    if (await confirm(context, 'از حساب خارج شوید؟')) {
                      await LicenseService.I.signOut();
                      // LicenseGate وضعیت را دوباره می‌خواند و صفحهٔ ورود را نشان می‌دهد
                      LicenseService.I.sessionInvalid.value++;
                      if (context.mounted) Navigator.of(context).popUntil((route) => route.isFirst);
                    }
                  },
                  icon: const Icon(Icons.logout),
                  label: const Text('خروج از حساب'),
                ),
              ],
            ),
    );
  }
}
