import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'license_guard.dart';
import 'license_service.dart';
import 'utils.dart';

/// دور صفحهٔ اصلی پیچیده می‌شود و از ۳ روز مانده به پایان اشتراک، بالای صفحه یک یادآوری
/// تمدید نشان می‌دهد (مثل نسخهٔ وب). کاربر می‌تواند آن را ببندد؛ فردا دوباره نمایش داده می‌شود.
class RenewBannerHost extends StatefulWidget {
  final Widget child;
  const RenewBannerHost({super.key, required this.child});
  @override
  State<RenewBannerHost> createState() => _RenewBannerHostState();
}

class _RenewBannerHostState extends State<RenewBannerHost> with WidgetsBindingObserver {
  static const _kDismissKey = 'renew_dismiss';
  String? _dismissedOn; // تاریخ (yyyy-mm-dd) روزی که کاربر نوار را بسته

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    LicenseService.I.expiry.addListener(_onExpiry);
    LicenseGuard.I.daysToOnlineCheck.addListener(_onExpiry);
    _loadDismissed();
  }

  @override
  void dispose() {
    LicenseService.I.expiry.removeListener(_onExpiry);
    LicenseGuard.I.daysToOnlineCheck.removeListener(_onExpiry);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onExpiry() {
    if (mounted) setState(() {});
  }

  // اگر برنامه از دیروز باز مانده باشد، با بازگشت به آن، روز جدید حساب می‌شود
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) setState(() {});
  }

  Future<void> _loadDismissed() async {
    final sp = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _dismissedOn = sp.getString(_kDismissKey));
  }

  String _todayKey() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  /// تعداد روزِ باقی‌مانده تا تاریخ انقضا (امروز = ۰). فقط تاریخ مقایسه می‌شود، نه ساعت.
  int _daysLeft(DateTime expiry) {
    final now = DateTime.now();
    final a = DateTime.utc(expiry.year, expiry.month, expiry.day);
    final b = DateTime.utc(now.year, now.month, now.day);
    return a.difference(b).inDays;
  }

  Future<void> _dismiss() async {
    final key = _todayKey();
    setState(() => _dismissedOn = key);
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kDismissKey, key);
  }

  @override
  Widget build(BuildContext context) {
    final expiry = LicenseService.I.expiry.value;
    final int left = expiry == null ? -1 : _daysLeft(expiry);
    final show = left >= 0 && left <= 3 && _dismissedOn != _todayKey();

    // ویندوز: نزدیک شدن به سقف کار آفلاین (برای اعمال تمدید/لغو، گهگاه اینترنت لازم است)
    final off = kStrictLicense ? LicenseGuard.I.daysToOnlineCheck.value : null;
    final showOff = off != null && off <= 7;
    Widget offBanner = const SizedBox.shrink();
    if (showOff) {
      final msg = off! == 0
          ? '📶 برای ادامهٔ کار، همین حالا یک‌بار به اینترنت وصل شوید تا اشتراک تأیید شود.'
          : '📶 تا ${faNum(off, dec: 0)} روز دیگر باید یک‌بار به اینترنت وصل شوید تا اشتراک تأیید شود (اطلاعات شما سالم است).';
      offBanner = Material(
        color: Colors.transparent,
        child: SafeArea(
          top: !show,
          bottom: false,
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF4E0),
              border: Border.all(color: const Color(0xFFF0C987)),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(msg, style: const TextStyle(color: Color(0xFF7A4B00), fontSize: 13.5, height: 1.7)),
          ),
        ),
      );
    }

    Widget banner = const SizedBox.shrink();
    if (show) {
      final urgent = left <= 1;
      final when = left == 0
          ? 'امروز پایان می‌یابد'
          : (left == 1 ? 'فردا پایان می‌یابد' : '${faNum(left, dec: 0)} روز دیگر پایان می‌یابد');
      final bg = urgent ? const Color(0xFFFDECEC) : const Color(0xFFFFF4E0);
      final border = urgent ? const Color(0xFFF0B1B1) : const Color(0xFFF0C987);
      final fg = urgent ? const Color(0xFF8A1C1C) : const Color(0xFF7A4B00);
      banner = Material(
        color: Colors.transparent,
        child: SafeArea(
          bottom: false,
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            decoration: BoxDecoration(
              color: bg,
              border: Border.all(color: border),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('⏳ اشتراک شما $when. برای تمدید اشتراک با پشتیبانی تماس بگیرید.',
                      style: TextStyle(color: fg, fontSize: 13.5, height: 1.7)),
                  const SizedBox(height: 6),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    onPressed: () => callSupport(context, SupportContact.callNumber, SupportContact.displayPhone),
                    icon: const Icon(Icons.call_outlined, size: 18),
                    label: Text('تماس: ${SupportContact.displayPhone}'),
                  ),
                ]),
              ),
              IconButton(
                tooltip: 'بستن',
                icon: Icon(Icons.close, color: fg, size: 20),
                onPressed: _dismiss,
              ),
            ]),
          ),
        ),
      );
    }

    // ساختار ثابت (بنر در جایگاه اول، محتوا در Expanded) تا با ظاهر/پنهان‌شدن بنر،
    // وضعیت صفحه‌ها (تب‌ها، فرم‌ها) از بین نرود. وقتی بنر دیده می‌شود، فاصلهٔ بالای status bar را
    // خودِ بنر رعایت می‌کند و از محتوای زیرین کم می‌شود.
    return Column(children: [
      banner,
      offBanner,
      Expanded(child: MediaQuery.removePadding(context: context, removeTop: show || showOff, child: widget.child)),
    ]);
  }
}
