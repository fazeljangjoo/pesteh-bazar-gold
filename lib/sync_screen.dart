import 'package:flutter/material.dart';

import 'db.dart';
import 'sync_service.dart';
import 'utils.dart';
import 'widgets.dart';

String _actionLabel(String a) => switch (a) {
      'categories.create' => 'افزودن دسته',
      'types.create' => 'افزودن نوع',
      'purchases.create' => 'ثبت/ویرایش خرید',
      'purchases.delete' => 'حذف خرید',
      'mixes.create' => 'ثبت مخلوط/جداسازی',
      'mixes.update' => 'ویرایش مخلوط/جداسازی',
      'mixes.delete' => 'حذف مخلوط/جداسازی',
      'payments.save' => 'ثبت پرداخت',
      'receipts.save' => 'ثبت دریافت',
      'sales.create' => 'ثبت فروش',
      'sales.update' => 'ویرایش فروش',
      'sales.delete' => 'حذف فروش',
      'parties.create' => 'افزودن طرف‌حساب',
      'loans.create' => 'ثبت قرض/بازپرداخت',
      'loans.delete' => 'حذف قرض/بازپرداخت',
      _ => a,
    };

/// وضعیت همگام‌سازی حساب با سرور (جایگزین صفحهٔ قدیمیِ پشتیبان‌گیری فایل)
class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key});
  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  List<Map<String, dynamic>> _failed = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final f = await AppDb.I.failedOps();
      if (mounted) setState(() => _failed = f);
    } catch (_) {}
  }

  Future<void> _syncNow() async {
    setState(() => _busy = true);
    await SyncService.I.syncNow(pull: true);
    await _load();
    if (mounted) setState(() => _busy = false);
    final e = SyncService.I.info.value.error;
    if (mounted) snack(context, e ?? 'همگام‌سازی انجام شد');
  }

  Future<void> _retry() async {
    await AppDb.I.retryFailedOps();
    await _syncNow();
  }

  Future<void> _reload() async {
    final info = SyncService.I.info.value;
    final extra = (info.pending + info.failed) > 0
        ? '\n\n⚠ ${faNum(info.pending + info.failed)} تغییر ارسال‌نشده روی این گوشی هست که از بین می‌رود.'
        : '';
    final ok = await confirm(
        context, 'همهٔ اطلاعات این گوشی با اطلاعات ذخیره‌شده روی سرور جایگزین شود؟$extra\n\nادامه می‌دهید؟');
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    final err = await SyncService.I.reloadFromServer();
    await _load();
    if (!mounted) return;
    setState(() => _busy = false);
    snack(context, err ?? 'اطلاعات از سرور بازخوانی شد');
  }

  String _time(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${jalaliDateFromDt(t)}  ${toFaDigits('${two(t.hour)}:${two(t.minute)}')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('همگام‌سازی و بازیابی')),
      body: ValueListenableBuilder<SyncInfo>(
        valueListenable: SyncService.I.info,
        builder: (context, info, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  infoRow('حساب', AppDb.I.phone == null ? '-' : toFaDigits(AppDb.I.phone!)),
                  infoRow('آخرین همگام‌سازی', info.lastOk == null ? '-' : _time(info.lastOk!)),
                  infoRow('در انتظار ارسال', faNum(info.pending)),
                  infoRow('خطادار', faNum(info.failed),
                      valueColor: info.failed > 0 ? Colors.red.shade800 : null),
                  if (info.offline) infoRow('اینترنت', 'قطع (اطلاعات روی گوشی ذخیره است)'),
                  if (info.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(info.error!, style: TextStyle(color: Colors.red.shade800)),
                    ),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'همهٔ اطلاعات شما هم روی گوشی و هم روی سرور نگه‌داری می‌شود. برنامه بدون اینترنت کار می‌کند '
              'و با وصل‌شدن اینترنت، تغییرات خودکار ارسال می‌شود. با همین شماره و کد پیامکی روی وب، اندروید '
              'یا ویندوز وارد شوید، همین اطلاعات را می‌بینید.',
              style: TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy || info.running ? null : _syncNow,
              icon: (_busy || info.running)
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sync),
              label: const Text('همگام‌سازی همین حالا'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _reload,
              icon: const Icon(Icons.cloud_download_outlined),
              label: const Text('بازخوانی کامل از سرور'),
            ),
            if (_failed.isNotEmpty) ...[
              const SizedBox(height: 20),
              sectionTitle(context, 'تغییرات ارسال‌نشده (خطادار)'),
              for (final f in _failed)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.error_outline, color: Colors.red),
                    title: Text(_actionLabel(f['action'] as String)),
                    subtitle: Text((f['err'] as String?) ?? ''),
                  ),
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : _retry,
                icon: const Icon(Icons.refresh),
                label: const Text('تلاش دوباره برای موارد خطادار'),
              ),
              const SizedBox(height: 4),
              const Text(
                'اگر خطا تکرار شد، «بازخوانی کامل از سرور» اطلاعات گوشی را با سرور یکی می‌کند '
                '(تغییرات خطادار از بین می‌رود).',
                style: TextStyle(color: Colors.black54),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
