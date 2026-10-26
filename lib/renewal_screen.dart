import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'pay_invoice.dart';
import 'pay_service.dart';
import 'pdf_output.dart';
import 'utils.dart';

const Map<String, String> _planLabel = {'rial': 'ریالی', 'fx': 'ارزی (دلاری)'};
const Map<String, String> _statusLabel = {
  'pending': 'در انتظار پرداخت',
  'awaiting_review': 'در انتظار تأیید ادمین',
  'paid': 'پرداخت‌شده ✅',
  'rejected': 'رد شده',
  'canceled': 'لغوشده',
};

/// تبدیل ارقام فارسی/عربی به انگلیسی (برای فیلدهای عددی و کد)
String enDigits(String s) {
  const fa = '۰۱۲۳۴۵۶۷۸۹';
  const ar = '٠١٢٣٤٥٦٧٨٩';
  final b = StringBuffer();
  for (final ch in s.split('')) {
    final i = fa.indexOf(ch);
    final j = ar.indexOf(ch);
    b.write(i >= 0 ? '$i' : (j >= 0 ? '$j' : ch));
  }
  return b.toString();
}

/// صفحهٔ تمدید/خرید اشتراک. حتی وقتی اشتراک منقضی یا قفل است باز می‌شود.
/// [onDone] بعد از فعال‌شدن (یا ثبت پرداخت) صدا زده می‌شود تا وضعیت دوباره خوانده شود.
class RenewalScreen extends StatefulWidget {
  final VoidCallback? onDone;
  const RenewalScreen({super.key, this.onDone});

  @override
  State<RenewalScreen> createState() => _RenewalScreenState();
}

class _RenewalScreenState extends State<RenewalScreen> with WidgetsBindingObserver {
  bool _loading = true;
  bool _busy = false;
  String? _loadErr;

  Map<String, dynamic> _info = {};
  List<Map<String, dynamic>> _history = [];

  String _plan = 'rial';
  int _months = 3;
  final _codeCtl = TextEditingController();
  String _appliedCode = '';
  Map<String, dynamic>? _quote;
  String? _quoteErr;

  String? _method; // gateway | card | sheba
  Map<String, dynamic>? _order;
  String? _idem;

  String? _notice;
  String? _err;
  String? _pendingId;
  bool _paidNow = false;

  final _payerCtl = TextEditingController();
  final _last4Ctl = TextEditingController();
  // تاریخ و ساعت پرداخت (شمسی) با لیست‌های انتخاب
  final List<int> _todayJ = gregorianToJalali(DateTime.now().year, DateTime.now().month, DateTime.now().day);
  late int _payJy = _todayJ[0];
  late int _payJm = _todayJ[1];
  late int _payJd = _todayJ[2];
  late int _payHour = DateTime.now().hour;
  late int _payMin = DateTime.now().minute;
  final _amountCtl = TextEditingController();
  final _trackCtl = TextEditingController();

  // ---------------- داده و کمک‌ها

  Map<String, dynamic> get _acc {
    final a = _info['account'];
    return a is Map ? Map<String, dynamic>.from(a) : {};
  }

  Map<String, dynamic>? get _upgrade {
    final u = _info['upgrade'];
    return u is Map ? Map<String, dynamic>.from(u) : null;
  }

  Map<String, dynamic>? _price(String plan, int m) {
    final prices = _info['prices'];
    if (prices is! Map) return null;
    final p = prices[plan];
    if (p is! Map) return null;
    final x = p[m.toString()];
    return x is Map ? Map<String, dynamic>.from(x) : null;
  }

  bool _planEnabled(String p) {
    if (p == 'rial') return _info['can_buy_rial'] == true;
    return _upgrade != null || [3, 6, 12].any((m) => _price('fx', m) != null);
  }

  bool _monthEnabled(String p, int m) => m == 0 || _price(p, m) != null;

  List<int> _monthOptions(String p) => [if (p == 'fx' && _upgrade != null) 0, 3, 6, 12];

  int _n(dynamic v) => v is num ? v.round() : 0;

  String _money(dynamic v) {
    final n = _n(v);
    return n < 0 ? '−${faNum(-n, dec: 0)} تومان' : '${faNum(n, dec: 0)} تومان';
  }

  String _defaultPlan() {
    if (_acc['active'] == true && _acc['plan'] == 'fx') return 'fx';
    if (_upgrade != null) return 'fx';
    return _info['can_buy_rial'] == true ? 'rial' : 'fx';
  }

  int _defaultMonths(String p) => (p == 'fx' && _upgrade != null) ? 0 : 3;

  void _resetSel() {
    _order = null;
    _idem = null;
    _notice = null;
    _err = null;
  }

  // ---------------- چرخهٔ عمر

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _codeCtl.dispose();
    _payerCtl.dispose();
    _last4Ctl.dispose();
    _amountCtl.dispose();
    _trackCtl.dispose();
    super.dispose();
  }

  /// بعد از برگشت از مرورگر (درگاه): اگر سفارش درگاهی باز مانده، وضعیتش از سرور خوانده می‌شود
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_loading && _loadErr == null) {
      _recheckQuiet();
    }
  }

  Future<void> _recheckQuiet() async {
    await _checkPending();
    if (mounted) setState(() {});
  }

  // ---------------- بارگذاری

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadErr = null;
    });
    try {
      final d = await PayService.I.call('pay.info');
      _info = Map<String, dynamic>.from(d['item'] as Map);
      _plan = _defaultPlan();
      _months = _defaultMonths(_plan);
      await _loadHistory();
      await _checkPending();
      await _refreshQuote();
    } catch (e) {
      _loadErr = '$e';
    }
    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _loadHistory() async {
    try {
      final d = await PayService.I.call('pay.history');
      final items = d['items'];
      _history = items is List
          ? items.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
          : [];
    } catch (_) {
      _history = [];
    }
  }

  Future<void> _refreshInfo() async {
    try {
      final d = await PayService.I.call('pay.info');
      _info = Map<String, dynamic>.from(d['item'] as Map);
    } catch (_) {}
  }

  /// وضعیت سفارش درگاهی/ثبت‌شده را از سرور می‌پرسد (فعال‌سازی فقط با verify سرور)
  Future<void> _checkPending() async {
    final id = await PayService.I.pendingOrderId();
    _pendingId = null;
    if (id == null) return;
    try {
      final r = await PayService.I.call('pay.check_payment', {'order_id': id});
      final res = r['result'];
      if (res == 'paid') {
        await PayService.I.clearPendingOrder();
        _paidNow = true;
        _notice = 'پرداخت شما تأیید شد و اشتراک فعال است.';
      } else if (res == 'review') {
        await PayService.I.clearPendingOrder();
        _notice = 'پول شما دریافت شد ولی فعال‌سازی خودکار انجام نشد. ادمین بررسی و فعال می‌کند.';
      } else if (res == 'pending') {
        _pendingId = id;
        _notice = 'پرداخت هنوز تأیید نشده است. اگر پول کم شده، چند دقیقه بعد دوباره «بررسی پرداخت» را بزنید.';
      } else {
        await PayService.I.clearPendingOrder();
        _notice = 'این پرداخت تأیید نشد. اگر پول از حسابتان کم شده، با پشتیبانی تماس بگیرید.';
      }
    } catch (e) {
      _pendingId = id;
      _notice = '$e';
    }
  }

  /// محاسبهٔ مبلغ از سرور؛ اگر کد نامعتبر باشد، پیامش نشان داده و قیمت بدون کد گرفته می‌شود
  Future<void> _refreshQuote() async {
    _quote = null;
    _quoteErr = null;
    if (_months == 0 && _upgrade == null) return;
    if (!_monthEnabled(_plan, _months)) return;
    final base = <String, dynamic>{'plan': _plan, 'months': _months};
    if (_appliedCode.isNotEmpty) {
      try {
        final d = await PayService.I.call('pay.code_check', {...base, 'code': _appliedCode});
        _quote = Map<String, dynamic>.from(d['item'] as Map);
        return;
      } on PayException catch (e) {
        _quoteErr = e.message;
        _appliedCode = '';
        _codeCtl.clear();
      }
    }
    try {
      final d = await PayService.I.call('pay.quote', base);
      _quote = Map<String, dynamic>.from(d['item'] as Map);
    } on PayException catch (e) {
      _quoteErr ??= e.message;
    } catch (e) {
      _quoteErr ??= 'خطا در محاسبهٔ مبلغ: $e';
    }
  }

  /// تغییر انتخاب: سفارش/کلید قبلی دور ریخته می‌شود و مبلغ دوباره گرفته می‌شود
  Future<void> _change(void Function() mutate) async {
    setState(() {
      mutate();
      _resetSel();
      _busy = true;
    });
    await _refreshQuote();
    if (!mounted) return;
    setState(() => _busy = false);
  }

  void _selectPlan(String p) {
    if (p == _plan) return;
    _change(() {
      _plan = p;
      if (!_monthOptions(p).contains(_months) || !_monthEnabled(p, _months)) {
        _months = _defaultMonths(p);
      }
    });
  }

  void _selectMonths(int m) {
    if (m == _months) return;
    _change(() => _months = m);
  }

  void _applyCode() {
    final c = enDigits(_codeCtl.text).trim();
    _change(() => _appliedCode = c);
  }

  void _selectMethod(String m) {
    if (m == _method) return;
    setState(() {
      _method = m;
      _order = null;
      _idem = null;
      _err = null;
      _notice = null;
      _amountCtl.text = '${_n(_quote?['total'])}';
    });
  }

  // ---------------- پرداخت

  Future<Map<String, dynamic>> _createOrder(String method) async {
    _idem ??= PayService.newIdem();
    final p = <String, dynamic>{'plan': _plan, 'months': _months, 'method': method};
    if (_appliedCode.isNotEmpty) p['code'] = _appliedCode;
    final d = await PayService.I.call('pay.create_order', p, _idem);
    _order = Map<String, dynamic>.from(d['order'] as Map);
    return d;
  }

  Future<void> _finish(String msg) async {
    await PayService.I.clearPendingOrder();
    if (!mounted) return;
    if (msg.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop();
    widget.onDone?.call();
  }

  void _fail(Object e) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _err = e is PayException ? e.message : 'خطا: $e';
    });
  }

  Future<void> _payGateway() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      String? url;
      if (_order == null) {
        final d = await _createOrder('gateway');
        url = d['pay_url'] as String?;
      }
      final order = _order!;
      if (order['status'] == 'paid') {
        await _finish('اشتراک شما فعال شد');
        return;
      }
      url ??= (await PayService.I.call('pay.start_gateway', {'order_id': order['id']}))['pay_url'] as String?;
      if (url == null || url.isEmpty) throw PayException('آدرس درگاه دریافت نشد. دوباره تلاش کنید.');
      await PayService.I.setPendingOrder('${order['id']}');
      final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!ok) throw PayException('مرورگر باز نشد. دوباره تلاش کنید.');
      if (mounted) setState(() => _busy = false);
    } catch (e) {
      _fail(e);
    }
  }

  /// مبلغ صفر (کد ۱۰۰٪): سرور فوراً فعال می‌کند
  Future<void> _payFree() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await _createOrder('gateway');
      if (_order?['status'] == 'paid') {
        await _finish('اشتراک شما با کد تخفیف فعال شد');
        return;
      }
      _fail(PayException('ثبت سفارش انجام نشد. دوباره تلاش کنید.'));
    } catch (e) {
      _fail(e);
    }
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  Widget _numDrop(String label, int value, List<int> items, String Function(int) text, void Function(int) onChanged) {
    return Expanded(
      child: DropdownButtonFormField<int>(
        value: items.contains(value) ? value : null,
        isExpanded: true,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
        items: [for (final i in items) DropdownMenuItem<int>(value: i, child: Text(text(i)))],
        onChanged: (v) {
          if (v != null) setState(() => onChanged(v));
        },
      ),
    );
  }

  Future<void> _submitManual() async {
    final payer = _payerCtl.text.trim();
    final last4 = enDigits(_last4Ctl.text).trim();
    final gDate = jalaliToGregorian(_payJy, _payJm, _payJd);
    final whenDt = DateTime(gDate.year, gDate.month, gDate.day, _payHour, _payMin);
    final paidAt = '$_payJy/${_two(_payJm)}/${_two(_payJd)} ${_two(_payHour)}:${_two(_payMin)}';
    final amount = enDigits(_amountCtl.text).trim();
    final track = enDigits(_trackCtl.text).trim();
    String? v;
    if (payer.length < 2) {
      v = 'نام پرداخت‌کننده را وارد کنید';
    } else if (!RegExp(r'^\d{4}$').hasMatch(last4)) {
      v = 'ارقام آخر کارت باید ۴ رقم باشد';
    } else if (whenDt.isAfter(DateTime.now().add(const Duration(minutes: 10)))) {
      v = 'زمان پرداخت نمی‌تواند در آینده باشد';
    } else if (whenDt.isBefore(DateTime.now().subtract(const Duration(days: 30)))) {
      v = 'زمان پرداخت خیلی قدیمی است؛ با پشتیبانی تماس بگیرید';
    } else if (!RegExp(r'^\d+$').hasMatch(amount) || int.parse(amount) <= 0) {
      v = 'مبلغ واریزی را درست وارد کنید';
    }
    if (v != null) {
      setState(() => _err = v);
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      if (_order == null) await _createOrder(_method!);
      final d = await PayService.I.call('pay.submit_manual', {
        'order_id': _order!['id'],
        'method': _method,
        'payer_name': payer,
        'card_last4': last4,
        'paid_at': paidAt,
        'amount': int.parse(amount),
        if (track.isNotEmpty) 'tracking_no': track,
      });
      final ord = Map<String, dynamic>.from(d['order'] as Map);
      if (ord['status'] == 'paid') {
        await _finish('اشتراک شما فعال شد');
        return;
      }
      _order = null;
      _idem = null;
      _method = null;
      _payerCtl.clear();
      _last4Ctl.clear();
      _trackCtl.clear();
      _notice = '${d['message'] ?? 'اطلاعات پرداخت ثبت شد. بعد از بررسی ادمین اشتراک شما فعال می‌شود.'}';
      await _refreshInfo();
      await _loadHistory();
      if (mounted) setState(() => _busy = false);
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _recheck() async {
    setState(() => _busy = true);
    await _checkPending();
    if (_paidNow) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    await _refreshInfo();
    await _loadHistory();
    if (mounted) setState(() => _busy = false);
  }

  /// فاکتور PDF یک سفارش پرداخت‌شده: داده از سرور، ساخت PDF، و انتخاب پیش‌نمایش/ارسال/ذخیره
  Future<void> _showInvoice(String orderId) async {
    try {
      final d = await PayService.I.call('pay.invoice', {'order_id': orderId});
      final inv = Map<String, dynamic>.from(d['invoice'] as Map);
      final file = await PayInvoice.build(inv);
      if (!mounted) return;
      await PdfOutput.show(context, file);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('کپی شد')));
  }

  // ---------------- نمایش

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('تمدید اشتراک')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_loadErr != null ? _errorView() : _content(context)),
    );
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_loadErr!, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: _load, icon: const Icon(Icons.refresh), label: const Text('تلاش دوباره')),
          const SizedBox(height: 8),
          TextButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('بازگشت')),
        ]),
      ),
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 6),
        child: Text(t, style: const TextStyle(color: Colors.black54, fontSize: 13)),
      );

  Widget _row(String a, String b, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(child: Text(a, style: TextStyle(fontWeight: bold ? FontWeight.bold : null))),
            const SizedBox(width: 8),
            Flexible(child: Text(b, textAlign: TextAlign.end, style: TextStyle(fontWeight: bold ? FontWeight.bold : null))),
          ],
        ),
      );

  Widget _content(BuildContext context) {
    final acc = _acc;
    final q = _quote;
    final total = _n(q?['total']);
    final planName = acc['plan'] is String ? (_planLabel[acc['plan']] ?? '${acc['plan']}') : '—';
    final String statusTxt;
    if (acc['active'] != true && acc['expired'] == true) {
      statusTxt = 'منقضی شده — اطلاعات شما حفظ شده است';
    } else if (acc['active'] != true) {
      statusTxt = 'اشتراک فعال ندارید';
    } else {
      statusTxt = 'فعال تا ${acc['expiry_jalali'] ?? ''} (${toFaDigits('${acc['days_left'] ?? ''}')} روز مانده)';
    }

    final children = <Widget>[];

    if (_notice != null) {
      children.add(Card(
        color: Theme.of(context).colorScheme.primaryContainer,
        child: Padding(padding: const EdgeInsets.all(12), child: Text(_notice!)),
      ));
    }
    if (_paidNow) {
      children.add(const SizedBox(height: 8));
      children.add(FilledButton(onPressed: () => _finish(''), child: const Text('ورود به برنامه')));
    }
    if (_pendingId != null) {
      children.add(const SizedBox(height: 8));
      children.add(OutlinedButton.icon(
        onPressed: _busy ? null : _recheck,
        icon: const Icon(Icons.sync),
        label: const Text('بررسی پرداخت'),
      ));
    }

    children.add(Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          _row('پلن فعلی', planName),
          _row('وضعیت', statusTxt),
        ]),
      ),
    ));
    children.add(Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text('اشتراک تمدید یا خرید می‌شود؛ هیچ استردادی وجود ندارد. اطلاعات شما حفظ می‌شود.',
          style: const TextStyle(color: Colors.black54, fontSize: 12.5, height: 1.7)),
    ));

    // ۱. پلن
    children.add(_label('۱. پلن'));
    children.add(Wrap(
      spacing: 8,
      runSpacing: 8,
      children: ['rial', 'fx'].map((p) {
        final en = _planEnabled(p) && !_busy;
        return ChoiceChip(
          label: Text(_planLabel[p]!),
          selected: _plan == p,
          onSelected: en ? (_) => _selectPlan(p) : null,
        );
      }).toList(),
    ));

    // ۲. مدت
    children.add(_label('۲. مدت'));
    children.add(Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _monthOptions(_plan).map((m) {
        final en = _monthEnabled(_plan, m) && !_busy;
        String text;
        if (m == 0) {
          text = 'فقط ارتقا به ارزی — ${_money(_upgrade?['amount'])}';
        } else {
          final pr = _price(_plan, m);
          text = '${toFaDigits('$m')} ماهه — ${pr != null ? _money(pr['final']) : 'به‌زودی'}';
        }
        return ChoiceChip(
          label: Text(text),
          selected: _months == m,
          onSelected: en ? (_) => _selectMonths(m) : null,
        );
      }).toList(),
    ));
    if (_months > 0) {
      final pr = _price(_plan, _months);
      if (pr != null && _n(pr['normal']) > _n(pr['final'])) {
        children.add(Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('صرفه‌جویی شما: ${_money(_n(pr['normal']) - _n(pr['final']))}',
              style: TextStyle(color: Colors.green.shade800, fontSize: 13)),
        ));
      }
    }

    // ۳. کد تخفیف
    children.add(_label('۳. کد تخفیف (اختیاری)'));
    children.add(Row(children: [
      Expanded(
        child: TextField(
          controller: _codeCtl,
          maxLength: 40,
          decoration: const InputDecoration(hintText: 'کد تخفیف را وارد کنید', border: OutlineInputBorder(), isDense: true, counterText: ''),
        ),
      ),
      const SizedBox(width: 8),
      FilledButton.tonal(onPressed: _busy ? null : _applyCode, child: const Text('اعمال')),
    ]));

    // ۴. خلاصه
    children.add(_label('۴. خلاصهٔ سفارش'));
    if (_quoteErr != null) {
      children.add(Text(_quoteErr!, style: const TextStyle(color: Colors.red)));
    }
    if (q == null) {
      if (_quoteErr == null) {
        children.add(const Text('برای دیدن مبلغ، پلن و مدت را انتخاب کنید.', style: TextStyle(color: Colors.black54)));
      }
    } else {
      final s = q['summary'] is Map ? Map<String, dynamic>.from(q['summary'] as Map) : <String, dynamic>{};
      final lines = (s['lines'] is List) ? (s['lines'] as List).whereType<Map>().toList() : <Map>[];
      final notes = (s['notes'] is List) ? (s['notes'] as List).map((e) => '$e').toList() : <String>[];
      children.add(Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(children: [
            if (lines.isEmpty) _row('مبلغ قابل پرداخت', _money(total), bold: true),
            for (final l in lines) _row('${l['label']}', _money(l['amount']), bold: l['kind'] == 'total'),
            for (final n in notes) Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Align(alignment: Alignment.centerRight, child: Text('• $n', style: const TextStyle(color: Colors.black54, fontSize: 12.5))),
            ),
            if (s['new_expiry_jalali'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Align(alignment: Alignment.centerRight, child: Text('اعتبار تا: ${s['new_expiry_jalali']}')),
              ),
          ]),
        ),
      ));
    }

    // ۵. روش پرداخت
    if (q != null && _quoteErr == null) {
      children.add(_label('۵. روش پرداخت'));
      if (total == 0) {
        children.add(FilledButton(
          onPressed: _busy ? null : _payFree,
          child: const Text('✅ ثبت رایگان (با کد تخفیف)'),
        ));
      } else {
        final m = _info['methods'] is Map ? Map<String, dynamic>.from(_info['methods'] as Map) : <String, dynamic>{};
        final tiles = <Widget>[];
        void addTile(String key, IconData icon, String title, String sub) {
          tiles.add(Card(
            child: ListTile(
              leading: Icon(icon),
              title: Text(title),
              subtitle: Text(sub),
              selected: _method == key,
              onTap: _busy ? null : () => _selectMethod(key),
              trailing: _method == key ? const Icon(Icons.check_circle) : null,
            ),
          ));
        }
        if (m['gateway'] == true) addTile('gateway', Icons.credit_card, 'درگاه زرین‌پال', 'فعال‌سازی فوری — سریع‌تر است');
        if (m['card'] == true) addTile('card', Icons.account_balance, 'کارت‌به‌کارت', 'بعد از ثبت، ادمین بررسی می‌کند');
        if (m['sheba'] == true) addTile('sheba', Icons.swap_horiz, 'شبا', 'بعد از ثبت، ادمین بررسی می‌کند');
        if (tiles.isEmpty) {
          children.add(const Text('روش پرداخت فعالی وجود ندارد؛ با پشتیبانی تماس بگیرید.', style: TextStyle(color: Colors.red)));
        } else {
          children.addAll(tiles);
        }
        if (_method == 'gateway') children.add(_gatewayBody(total));
        if (_method == 'card' || _method == 'sheba') children.add(_manualBody(total));
      }
    }

    if (_err != null) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(_err!, style: const TextStyle(color: Colors.red)),
      ));
    }

    // سفارش‌های من
    if (_history.isNotEmpty) {
      children.add(_label('سفارش‌های من'));
      for (final o in _history.take(10)) {
        final kind = o['order_type'] == 'upgrade'
            ? 'ارتقا به ارزی'
            : '${_planLabel[o['plan']] ?? o['plan']} ${(o['months'] ?? 0) != 0 ? '${toFaDigits('${o['months']}')} ماهه' : ''}';
        final st = _statusLabel[o['status']] ?? '${o['status']}';
        final rej = o['reject_reason'] != null ? ' — ${o['reject_reason']}' : '';
        children.add(Card(
          child: ListTile(
            title: Text('${o['created_jalali'] ?? ''}'),
            subtitle: Text('$kind\n$st$rej'),
            isThreeLine: true,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_money(o['total'])),
                if (o['status'] == 'paid' && o['id'] != null)
                  IconButton(
                    tooltip: 'فاکتور PDF',
                    icon: const Icon(Icons.receipt_long_outlined),
                    onPressed: _busy ? null : () => _showInvoice('${o['id']}'),
                  ),
              ],
            ),
          ),
        ));
      }
    }

    children.add(const SizedBox(height: 16));
    children.add(OutlinedButton(
      onPressed: () => Navigator.of(context).maybePop(),
      child: const Text('بازگشت'),
    ));

    return ListView(padding: const EdgeInsets.all(16), children: children);
  }

  Widget _gatewayBody(int total) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('به صفحهٔ امن زرین‌پال می‌روید. بعد از پرداخت، اشتراک خودکار فعال می‌شود. اگر به برنامه برگشتید و فعال نشد، «بررسی پرداخت» را بزنید.',
            style: TextStyle(height: 1.7)),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _busy ? null : _payGateway,
          child: Text('پرداخت با درگاه — ${_money(total)}'),
        ),
      ]),
    );
  }

  Widget _manualBody(int total) {
    final banks = _info['banks'] is List ? (_info['banks'] as List).whereType<Map>().toList() : <Map>[];
    final isCard = _method == 'card';
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('مبلغ ${_money(total)} را به حساب زیر واریز کنید، سپس فرم را پر کنید.', style: const TextStyle(height: 1.7)),
        const SizedBox(height: 8),
        if (banks.isEmpty)
          const Text('اطلاعات حساب فعلاً ثبت نشده؛ با پشتیبانی تماس بگیرید.', style: TextStyle(color: Colors.red)),
        for (final b in banks)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${b['bank_name'] ?? ''}${b['owner_name'] != null ? ' — ${b['owner_name']}' : ''}',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    if ((isCard ? b['card_number'] : b['sheba']) != null)
                      Text('${isCard ? 'شمارهٔ کارت' : 'شماره شبا'}: ${isCard ? b['card_number'] : b['sheba']}',
                          textDirection: TextDirection.ltr),
                    if (b['note'] != null && '${b['note']}'.isNotEmpty)
                      Text('${b['note']}', style: const TextStyle(color: Colors.black54, fontSize: 12)),
                  ]),
                ),
                if ((isCard ? b['card_number'] : b['sheba']) != null)
                  IconButton(
                    tooltip: 'کپی',
                    icon: const Icon(Icons.copy_outlined),
                    onPressed: () => _copy('${isCard ? b['card_number'] : b['sheba']}'),
                  ),
              ]),
            ),
          ),
        const SizedBox(height: 8),
        TextField(controller: _payerCtl, maxLength: 60, decoration: const InputDecoration(labelText: 'نام پرداخت‌کننده', border: OutlineInputBorder())),
        const SizedBox(height: 8),
        TextField(
          controller: _last4Ctl,
          keyboardType: TextInputType.number,
          maxLength: 4,
          decoration: const InputDecoration(labelText: '۴ رقم آخر کارتی که با آن پرداخت کرده‌اید', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        const Align(
          alignment: Alignment.centerRight,
          child: Text('تاریخ پرداخت (شمسی)', style: TextStyle(fontSize: 12.5, color: Colors.black54)),
        ),
        const SizedBox(height: 4),
        Row(children: [
          _numDrop('روز', _payJd, List.generate(daysInJalaliMonth(_payJy, _payJm), (i) => i + 1),
              (i) => toFaDigits('$i'), (v) => _payJd = v),
          const SizedBox(width: 6),
          _numDrop('ماه', _payJm, List.generate(12, (i) => i + 1), (i) => kJalaliMonthNames[i - 1], (v) {
            _payJm = v;
            final maxD = daysInJalaliMonth(_payJy, v);
            if (_payJd > maxD) _payJd = maxD;
          }),
          const SizedBox(width: 6),
          _numDrop('سال', _payJy, [for (var y = _todayJ[0] - 1; y <= _todayJ[0]; y++) y],
              (i) => toFaDigits('$i'), (v) => _payJy = v),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          _numDrop('ساعت', _payHour, List.generate(24, (i) => i), (i) => toFaDigits(_two(i)), (v) => _payHour = v),
          const SizedBox(width: 6),
          _numDrop('دقیقه', _payMin, List.generate(60, (i) => i), (i) => toFaDigits(_two(i)), (v) => _payMin = v),
        ]),
        const SizedBox(height: 8),
        TextField(
          controller: _amountCtl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'مبلغ واریزی (تومان)', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        TextField(controller: _trackCtl, maxLength: 40, decoration: const InputDecoration(labelText: 'شمارهٔ پیگیری (اختیاری)', border: OutlineInputBorder())),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy ? null : _submitManual,
          child: const Text('✅ پرداخت کردم — ثبت برای بررسی'),
        ),
      ]),
    );
  }
}
