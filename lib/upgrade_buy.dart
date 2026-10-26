import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'pay_service.dart';
import 'utils.dart';
import 'widgets.dart';

/// S22.T22.3c — «ارتقا به طلایی» purchase card (shown by upgrade_ui.dart while the account is not entitled yet).
/// Server contract (T22.3b): `pay.info` -> item.tier_upgrade {amount, remaining_days, plan} (null = cannot buy),
/// `pay.create_order` {kind:'tier_upgrade', plan, months:0, method:'gateway'} -> order + pay_url.
/// Paying only ENTITLES the account; the owner then runs the upgrade wizard. [onRefresh] re-reads `tier.upgrade_status`.
/// Card/sheba payments and offline deals are handled by support (admin «ثبت دستی حق ارتقا»).
class TierUpgradeBuyCard extends StatefulWidget {
  const TierUpgradeBuyCard({super.key, required this.onRefresh});

  final Future<void> Function() onRefresh;

  @override
  State<TierUpgradeBuyCard> createState() => _TierUpgradeBuyCardState();
}

class _TierUpgradeBuyCardState extends State<TierUpgradeBuyCard> {
  bool _loading = true;
  bool _busy = false;
  bool _waiting = false; // gateway opened in the browser: offer «بررسی پرداخت»
  String? _error;
  Map<String, dynamic>? _offer; // item.tier_upgrade
  bool _gateway = false;
  String? _idem;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> d = await PayService.I.call('pay.info');
      final Map<String, dynamic> item = Map<String, dynamic>.from(d['item'] as Map);
      final Object? t = item['tier_upgrade'];
      _offer = t is Map ? Map<String, dynamic>.from(t) : null;
      final Object? m = item['methods'];
      _gateway = m is Map && m['gateway'] == true;
    } on PayException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = 'خطا در دریافت قیمت ارتقا: $e';
    }
    if (!mounted) return;
    setState(() => _loading = false);
  }

  int _amount() {
    final Object? a = _offer?['amount'];
    return a is num ? a.toInt() : 0;
  }

  Future<void> _buy() async {
    final Map<String, dynamic>? offer = _offer;
    if (offer == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _idem ??= PayService.newIdem();
      final Map<String, dynamic> d = await PayService.I.call(
        'pay.create_order',
        <String, dynamic>{'kind': 'tier_upgrade', 'plan': '${offer['plan'] ?? 'rial'}', 'months': 0, 'method': 'gateway'},
        _idem,
      );
      final Map<String, dynamic> order = Map<String, dynamic>.from(d['order'] as Map);
      if ('${order['status']}' == 'paid') {
        await widget.onRefresh();
        return;
      }
      String? url = d['pay_url'] as String?;
      url ??= (await PayService.I.call('pay.start_gateway', <String, dynamic>{'order_id': order['id']}))['pay_url'] as String?;
      if (url == null || url.isEmpty) throw PayException('آدرس درگاه دریافت نشد. دوباره تلاش کنید.');
      await PayService.I.setPendingOrder('${order['id']}');
      final bool ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!ok) throw PayException('مرورگر باز نشد. دوباره تلاش کنید.');
      if (mounted) setState(() => _waiting = true);
    } on PayException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = 'خطا: $e';
    }
    if (!mounted) return;
    setState(() => _busy = false);
  }

  Future<void> _check() async {
    setState(() => _busy = true);
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> body = <Widget>[
      sectionTitle(context, 'خرید ارتقا به طلایی'),
    ];
    if (_loading) {
      body.add(const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator())));
    } else if (_offer == null) {
      body.add(Text(_error ?? 'خرید ارتقا برای این حساب فعال نیست (اشتراک فعال سبز لازم است). برای ارتقای دستی با پشتیبانی تماس بگیرید.'));
    } else {
      final int amount = _amount();
      final String days = faNum((_offer!['remaining_days'] as num?) ?? 0, dec: 0);
      body.add(Text('هزینهٔ ارتقا برای $days روز باقی‌ماندهٔ اشتراک: ${faNum(amount, dec: 0)} تومان. پس از پرداخت، ارتقا را از همین صفحه اجرا می‌کنید؛ تاریخ انقضای اشتراک تغییر نمی‌کند.'));
      body.add(const SizedBox(height: 8));
      if (_gateway) {
        body.add(FilledButton.icon(
          onPressed: _busy ? null : _buy,
          icon: const Icon(Icons.workspace_premium_outlined),
          label: Text(_waiting ? 'باز کردن دوبارهٔ درگاه' : 'پرداخت و ارتقا به طلایی'),
        ));
        if (_waiting) {
          body.add(OutlinedButton.icon(
            onPressed: _busy ? null : _check,
            icon: const Icon(Icons.refresh),
            label: const Text('بررسی پرداخت'),
          ));
        }
      } else {
        body.add(const Text('پرداخت آنلاین فعال نیست؛ برای پرداخت کارت‌به‌کارت یا ارتقای دستی با پشتیبانی تماس بگیرید.'));
      }
    }
    if (_error != null && _offer != null) {
      body.add(Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: Colors.red.shade900))));
    }
    return Card(
      color: Colors.amber.shade50,
      child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: body)),
    );
  }
}
