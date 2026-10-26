import 'package:flutter/material.dart';

import 'db.dart';
import 'notify_service.dart';
import 'pdf_output.dart';
import 'pdf_service.dart';
import 'utils.dart';
import 'widgets.dart';

/// مدیریت وصول مطالبات فروش (دریافت وجه) — نظیر مدیریت پرداخت خرید
class ReceiptScreen extends StatefulWidget {
  final int saleId;
  final String saleLabel;
  const ReceiptScreen({super.key, required this.saleId, required this.saleLabel});

  @override
  State<ReceiptScreen> createState() => _ReceiptScreenState();
}

class _ReceiptScreenState extends State<ReceiptScreen> with EditGuard<ReceiptScreen> {
  bool _loading = true;
  late int _saleId;
  int? _receiptId;
  String? _recvType; // lump | staged
  String? _stagedType; // credit | cheque

  Map<String, dynamic>? _sale;
  List<Map<String, dynamic>> _lump = [];
  List<Map<String, dynamic>> _credit = [];
  List<Map<String, dynamic>> _cheque = [];

  double get _total {
    final s = _sale;
    if (s == null) return 0;
    return (s['net_weight'] as num).toDouble() * (s['price'] as num).toDouble();
  }

  double get _settled {
    if (_recvType == 'lump') {
      return _lump.where((r) => (r['paid'] as int? ?? 1) == 1).fold<double>(
          0, (s, r) => s + (r['amount'] as num).toDouble());
    } else if (_recvType == 'staged' && _stagedType == 'credit') {
      return _credit.where((r) => (r['paid'] as int) == 1).fold<double>(
          0, (s, r) => s + (r['amount'] as num).toDouble());
    } else if (_recvType == 'staged' && _stagedType == 'cheque') {
      return _cheque.where((r) => (r['paid'] as int) == 1).fold<double>(
          0, (s, r) => s + (r['amount'] as num).toDouble());
    }
    return 0;
  }

  double get _remaining => _total - _settled;

  /// جمع همهٔ ردیف‌های ثبت‌شده (تسویه‌شده یا نه) به‌جز ردیفی که در حال ویرایش است
  double _othersSum(List<Map<String, dynamic>> rows, int? exceptId) => rows
      .where((r) => exceptId == null || r['id'] != exceptId)
      .fold<double>(0, (s, r) => s + (r['amount'] as num).toDouble());

  @override
  void initState() {
    super.initState();
    _saleId = widget.saleId;
    AppDb.I.version.addListener(_onDbChanged);
    _load();
  }

  @override
  void dispose() {
    AppDb.I.version.removeListener(_onDbChanged);
    super.dispose();
  }

  // بعد از هر دریافت از سرور شناسه‌ها عوض می‌شوند؛ صفحه باید دوباره خودش را با شناسه‌های جدید بسازد
  void _onDbChanged() {
    if (!mounted || _loading) return;
    _load();
  }

  Future<void> _load() async {
    _saleId = await AppDb.I.currentId('sale', _saleId);
    _sale = await AppDb.I.saleById(_saleId);
    final rec = await AppDb.I.receiptOf(_saleId);
    _receiptId = rec?['id'] as int?;
    _recvType = rec?['recv_type'] as String?;
    _stagedType = rec?['staged_type'] as String?;
    _lump = [];
    _credit = [];
    _cheque = [];
    if (_receiptId != null) {
      _lump = await AppDb.I.receiptLumpTxList(_receiptId!);
      _credit = await AppDb.I.receiptCreditInstList(_receiptId!);
      _cheque = await AppDb.I.receiptChequeInstList(_receiptId!);
    }
    if (mounted) setState(() => _loading = false);
  }

  String _typeLabel(String t, String? st) => t == 'lump'
      ? 'دریافت یکجا'
      : (st == 'cheque' ? 'دریافت مرحله‌ای (چک)' : 'دریافت مرحله‌ای (اعتباری/قسطی)');

  /// انتخاب یا تغییر نوع دریافت همیشه با تأیید کاربر انجام می‌شود
  Future<void> _requestType(String t, String? st) async {
    if (t == _recvType && st == _stagedType) return;
    final String msg = _recvType == null
        ? 'نوع «${_typeLabel(t, st)}» انتخاب شود؟'
        : 'با تغییر نوع دریافت از «${_typeLabel(_recvType!, _stagedType)}» به «${_typeLabel(t, st)}»، '
            'همهٔ اطلاعات دریافت قبلی (تراکنش‌ها، اقساط و چک‌ها) حذف می‌شوند و باید اطلاعات جدید را دوباره وارد کنید. ادامه می‌دهید؟';
    if (!await confirm(context, msg)) return;
    if (_recvType != null) {
    for (final r in _credit) {
      await NotifyService.I.cancelCreditRow(r['id'] as int);
    }
    for (final r in _cheque) {
      await NotifyService.I.cancelChequeRow(r['id'] as int);
    }
    }
    await _setType(t, st);
  }

  Future<void> _setType(String recvType, String? stagedType) async {
    _saleId = await AppDb.I.currentId('sale', _saleId);
    int? newId;
    if (!await saveConfirmed(context, () async { newId = await AppDb.I.setReceiptType(_saleId, recvType, stagedType); },
        successMsg: 'نوع دریافت ثبت شد')) {
      return;
    }
    _receiptId = newId;
    setState(() {
      _recvType = recvType;
      _stagedType = stagedType;
    });
    await _load();
  }

  Future<void> _exportPdf() async {
    try {
      final codes = await AppDb.I.saleCodes(_saleId);
      final file = await PdfService.buildPaymentLedger(
        title: 'رسید وصول مطالبات — ${widget.saleLabel}',
        pesteCode: codes,
        totalLabel: 'مبلغ کل فروش',
        total: _total,
        settled: _settled,
        remaining: _remaining,
        payType: _recvType,
        stagedType: _stagedType,
        lump: _lump,
        credit: _credit,
        cheque: _cheque,
        directionLabels: const (
          from: 'از حساب',
          fromName: 'پرداخت‌کننده (خریدار)',
          to: 'به حساب',
          toName: 'دریافت‌کننده'
        ),
      );
      await PdfOutput.show(context, file);
    } catch (e) {
      if (mounted) snack(context, 'خطا در ساخت PDF: $e');
    }
  }

  Future<void> _addLump() async {
    if (_lump.length >= kMaxLumpTx) {
      snack(context, 'حداکثر ${faNum(kMaxLumpTx)} تراکنش مجاز است');
      return;
    }
    final row = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ReceiptLumpForm(total: _total, others: _othersSum(_lump, null)),
    );
    if (row == null) return;
    if (!await saveConfirmed(context, () => AppDb.I.addReceiptLumpTx(_receiptId!, row), successMsg: 'تراکنش دریافت با موفقیت ثبت شد')) return;
    await _load();
  }

  Future<void> _editLump(Map<String, dynamic> existing) async {
    final row = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ReceiptLumpForm(existing: existing, total: _total, others: _othersSum(_lump, existing['id'] as int?)),
    );
    if (row == null) return;
    if (!await saveConfirmed(context, () => AppDb.I.updateReceiptLumpTx(existing['id'] as int, row), successMsg: 'ویرایش با موفقیت ثبت شد')) return;
    await _load();
  }

  Future<void> _toggleLumpPaid(Map<String, dynamic> row, bool paid) async {
    final updated = Map<String, dynamic>.from(row)..remove('id')..remove('receipt_id');
    updated['paid'] = paid ? 1 : 0;
    if (!await saveConfirmed(context, () => AppDb.I.updateReceiptLumpTx(row['id'] as int, updated), successMsg: 'وضعیت تسویه با موفقیت ثبت شد')) return;
    await _load();
  }

  Future<void> _addCredit() async {
    if (_credit.length >= kMaxStagedTx) {
      snack(context, 'حداکثر ${faNum(kMaxStagedTx)} قسط مجاز است');
      return;
    }
    final row = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ReceiptCreditForm(total: _total, others: _othersSum(_credit, null)),
    );
    if (row == null) return;
    int? id;
    if (!await saveConfirmed(context, () async { id = await AppDb.I.addReceiptCreditInst(_receiptId!, row); }, successMsg: 'قسط دریافت با موفقیت ثبت شد')) return;
    if (id != null) {
      await NotifyService.I.scheduleReceiptCreditRow({...row, 'id': id});
    }
    await _load();
  }

  Future<void> _editCredit(Map<String, dynamic> existing) async {
    final row = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ReceiptCreditForm(existing: existing, total: _total, others: _othersSum(_credit, existing['id'] as int?)),
    );
    if (row == null) return;
    if (!await saveConfirmed(context, () => AppDb.I.updateReceiptCreditInst(existing['id'] as int, row), successMsg: 'ویرایش با موفقیت ثبت شد')) return;
    if (row['paid'] == 1) {
      await NotifyService.I.cancelReceiptCreditRow(existing['id'] as int);
    } else {
      await NotifyService.I.scheduleReceiptCreditRow({...row, 'id': existing['id']});
    }
    await _load();
  }

  Future<void> _toggleCreditPaid(Map<String, dynamic> row, bool paid) async {
    final updated = Map<String, dynamic>.from(row)..remove('id')..remove('receipt_id');
    updated['paid'] = paid ? 1 : 0;
    if (!await saveConfirmed(context, () => AppDb.I.updateReceiptCreditInst(row['id'] as int, updated), successMsg: 'وضعیت تسویه با موفقیت ثبت شد')) return;
    if (paid) {
      await NotifyService.I.cancelReceiptCreditRow(row['id'] as int);
    } else {
      await NotifyService.I.scheduleReceiptCreditRow({...updated, 'id': row['id']});
    }
    await _load();
  }

  Future<void> _addCheque() async {
    if (_cheque.length >= kMaxStagedTx) {
      snack(context, 'حداکثر ${faNum(kMaxStagedTx)} چک مجاز است');
      return;
    }
    final row = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ReceiptChequeForm(total: _total, others: _othersSum(_cheque, null)),
    );
    if (row == null) return;
    int? id;
    if (!await saveConfirmed(context, () async { id = await AppDb.I.addReceiptChequeInst(_receiptId!, row); }, successMsg: 'چک دریافت با موفقیت ثبت شد')) return;
    if (id != null) {
      await NotifyService.I.scheduleReceiptChequeRow({...row, 'id': id});
    }
    await _load();
  }

  Future<void> _editCheque(Map<String, dynamic> existing) async {
    final row = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ReceiptChequeForm(existing: existing, total: _total, others: _othersSum(_cheque, existing['id'] as int?)),
    );
    if (row == null) return;
    if (!await saveConfirmed(context, () => AppDb.I.updateReceiptChequeInst(existing['id'] as int, row), successMsg: 'ویرایش با موفقیت ثبت شد')) return;
    if (row['paid'] == 1) {
      await NotifyService.I.cancelReceiptChequeRow(existing['id'] as int);
    } else {
      await NotifyService.I.scheduleReceiptChequeRow({...row, 'id': existing['id']});
    }
    await _load();
  }

  Future<void> _toggleChequePaid(Map<String, dynamic> row, bool paid) async {
    final updated = Map<String, dynamic>.from(row)..remove('id')..remove('receipt_id');
    updated['paid'] = paid ? 1 : 0;
    if (!await saveConfirmed(context, () => AppDb.I.updateReceiptChequeInst(row['id'] as int, updated), successMsg: 'وضعیت تسویه با موفقیت ثبت شد')) return;
    if (paid) {
      await NotifyService.I.cancelReceiptChequeRow(row['id'] as int);
    } else {
      await NotifyService.I.scheduleReceiptChequeRow({...updated, 'id': row['id']});
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('وصول مطالبات — ${widget.saleLabel}'),
        actions: [
          if (!_loading)
            IconButton(
              onPressed: _exportPdf,
              icon: const Icon(Icons.picture_as_pdf_outlined),
              tooltip: 'خروجی PDF',
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _summaryCard(context),
                const SizedBox(height: 16),
                sectionTitle(context, 'نحوه‌ی دریافت'),
                Card(
                  child: Column(children: [
                    RadioListTile<String>(
                      value: 'lump',
                      groupValue: _recvType,
                      title: const Text('دریافت یکجا'),
                      onChanged: (v) => _requestType('lump', null),
                    ),
                    RadioListTile<String>(
                      value: 'staged',
                      groupValue: _recvType,
                      title: const Text('دریافت مرحله‌ای'),
                      onChanged: (v) => _requestType('staged', _stagedType ?? 'credit'),
                    ),
                  ]),
                ),
                if (_recvType == 'staged') ...[
                  const SizedBox(height: 8),
                  Card(
                    child: Column(children: [
                      RadioListTile<String>(
                        value: 'credit',
                        groupValue: _stagedType,
                        title: const Text('وصول اعتباری (قسطی)'),
                        onChanged: (v) => _requestType('staged', 'credit'),
                      ),
                      RadioListTile<String>(
                        value: 'cheque',
                        groupValue: _stagedType,
                        title: const Text('چک دریافتی'),
                        onChanged: (v) => _requestType('staged', 'cheque'),
                      ),
                    ]),
                  ),
                ],
                const SizedBox(height: 16),
                if (_recvType == 'lump') _lumpSection(),
                if (_recvType == 'staged' && _stagedType == 'credit') _creditSection(),
                if (_recvType == 'staged' && _stagedType == 'cheque') _chequeSection(),
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  Widget _summaryCard(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          infoRow('مبلغ کل فروش', '${faNum(_total, dec: 0)} تومان'),
          infoRow('وصول شده', '${faNum(_settled, dec: 0)} تومان'),
          infoRow(_remaining >= 0 ? 'باقیمانده' : 'دریافت اضافی',
              '${faNum(_remaining.abs(), dec: 0)} تومان'),
        ]),
      ),
    );
  }

  Widget _lumpSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: sectionTitle(context, 'تراکنش‌های دریافت یکجا (${faNum(_lump.length)}/${faNum(kMaxLumpTx)})')),
        IconButton(onPressed: _addLump, icon: const Icon(Icons.add_circle_outline)),
      ]),
      if (_lump.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('هنوز تراکنشی ثبت نشده')),
      for (final r in _lump)
        Card(
          child: ListTile(
            onTap: () => _editLump(r),
            leading: Checkbox(
              value: (r['paid'] as int? ?? 1) == 1,
              onChanged: (v) => _toggleLumpPaid(r, v ?? false),
            ),
            title: Text('${faNum(r['amount'] as num, dec: 0)} تومان — ${jalaliDate(r['date'] as String)}'),
            subtitle: Text('از ${r['from_account'] ?? '-'} (${r['payer_name'] ?? '-'})\nبه ${r['to_account'] ?? '-'} (${r['receiver_name'] ?? '-'})'
                '${(r['paid'] as int? ?? 1) == 1 ? '\nوصول شده' : ''}'),
            isThreeLine: true,
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                if (await confirm(context, 'این تراکنش حذف شود؟')) {
                  await saveConfirmed(context, () => AppDb.I.deleteReceiptLumpTx(r['id'] as int), successMsg: 'حذف شد');
                  await _load();
                }
              },
            ),
          ),
        ),
    ]);
  }

  Widget _creditSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: sectionTitle(context, 'اقساط وصولی (${faNum(_credit.length)}/${faNum(kMaxStagedTx)})')),
        IconButton(onPressed: _addCredit, icon: const Icon(Icons.add_circle_outline)),
      ]),
      if (_credit.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('هنوز قسطی ثبت نشده')),
      for (final r in _credit)
        Card(
          child: ListTile(
            onTap: () => _editCredit(r),
            leading: Checkbox(
              value: (r['paid'] as int) == 1,
              onChanged: (v) => _toggleCreditPaid(r, v ?? false),
            ),
            title: Text('${faNum(r['amount'] as num, dec: 0)} تومان — سررسید ${jalaliDate(r['due_date'] as String)}'),
            subtitle: Text('از ${r['from_account'] ?? '-'} (${r['payer_name'] ?? '-'})\nبه ${r['to_account'] ?? '-'} (${r['receiver_name'] ?? '-'})'
                '${(r['paid'] as int) == 1 ? '\nوصول شده' : ''}'),
            isThreeLine: true,
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                if (await confirm(context, 'این قسط حذف شود؟')) {
                  await NotifyService.I.cancelReceiptCreditRow(r['id'] as int);
                  await saveConfirmed(context, () => AppDb.I.deleteReceiptCreditInst(r['id'] as int), successMsg: 'حذف شد');
                  await _load();
                }
              },
            ),
          ),
        ),
    ]);
  }

  Widget _chequeSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: sectionTitle(context, 'چک‌های دریافتی (${faNum(_cheque.length)}/${faNum(kMaxStagedTx)})')),
        IconButton(onPressed: _addCheque, icon: const Icon(Icons.add_circle_outline)),
      ]),
      if (_cheque.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('هنوز چکی ثبت نشده')),
      for (final r in _cheque)
        Card(
          child: ListTile(
            onTap: () => _editCheque(r),
            leading: Checkbox(
              value: (r['paid'] as int) == 1,
              onChanged: (v) => _toggleChequePaid(r, v ?? false),
            ),
            title: Text('${faNum(r['amount'] as num, dec: 0)} تومان — سررسید ${jalaliDate(r['due_date'] as String)}'),
            subtitle: Text('چک ${r['cheque_no'] ?? '-'} — بانک ${r['bank_name'] ?? '-'}\n'
                'از ${r['from_account'] ?? '-'} (${r['payer_name'] ?? '-'}) به ${r['to_account'] ?? '-'} (${r['receiver_name'] ?? '-'})'
                '${(r['paid'] as int) == 1 ? '\nوصول شده' : ''}'),
            isThreeLine: true,
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                if (await confirm(context, 'این چک حذف شود؟')) {
                  await NotifyService.I.cancelReceiptChequeRow(r['id'] as int);
                  await saveConfirmed(context, () => AppDb.I.deleteReceiptChequeInst(r['id'] as int), successMsg: 'حذف شد');
                  await _load();
                }
              },
            ),
          ),
        ),
    ]);
  }
}

// ------------------- فرم تراکنش دریافت یکجا -------------------
class _ReceiptLumpForm extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final double total;
  final double others;
  const _ReceiptLumpForm({this.existing, this.total = 0, this.others = 0});
  @override
  State<_ReceiptLumpForm> createState() => _ReceiptLumpFormState();
}

class _ReceiptLumpFormState extends State<_ReceiptLumpForm> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _amount;
  late final TextEditingController _fromAccount;
  late final TextEditingController _payerName;
  late final TextEditingController _toAccount;
  late final TextEditingController _receiverName;
  DateTime? _date;
  bool _paid = true;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _amount = TextEditingController(text: e == null ? '' : plain(e['amount'] as num));
    _fromAccount = TextEditingController(text: e?['from_account'] as String? ?? '');
    _payerName = TextEditingController(text: e?['payer_name'] as String? ?? '');
    _toAccount = TextEditingController(text: e?['to_account'] as String? ?? '');
    _receiverName = TextEditingController(text: e?['receiver_name'] as String? ?? '');
    _date = e == null ? DateTime.now() : DateTime.parse(e['date'] as String);
    _paid = e == null ? true : (e['paid'] as int? ?? 1) == 1;
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    Navigator.pop(context, {
      'amount': parseNum(_amount.text) ?? 0,
      'date': (_date ?? DateTime.now()).toIso8601String(),
      'from_account': _fromAccount.text.trim(),
      'payer_name': _payerName.text.trim(),
      'to_account': _toAccount.text.trim(),
      'receiver_name': _receiverName.text.trim(),
      'paid': _paid ? 1 : 0,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom, left: 16, right: 16, top: 16),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(widget.existing == null ? 'تراکنش دریافتی جدید' : 'ویرایش تراکنش',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              numField(_amount, 'مبلغ (تومان)', required: true, thousands: true),
              OverpayWarning(controller: _amount, total: widget.total, others: widget.others, receipt: true),
              dateField(context, 'تاریخ دریافت', _date, (d) => setState(() => _date = d)),
              textField(_fromAccount, 'از کدام حساب (خریدار)'),
              textField(_payerName, 'به نام چه کسی (پرداخت‌کننده)'),
              textField(_toAccount, 'به کدام حساب ما'),
              textField(_receiverName, 'به نام چه کسی (دریافت‌کننده)'),
              SwitchListTile(
                value: _paid,
                onChanged: (v) => setState(() => _paid = v),
                title: const Text('وصول شده'),
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 8),
              FilledButton(onPressed: _save, child: const Text('ذخیره')),
              const SizedBox(height: 16),
            ]),
          ),
        ),
      ),
    );
  }
}

// ------------------- فرم قسط وصولی -------------------
class _ReceiptCreditForm extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final double total;
  final double others;
  const _ReceiptCreditForm({this.existing, this.total = 0, this.others = 0});
  @override
  State<_ReceiptCreditForm> createState() => _ReceiptCreditFormState();
}

class _ReceiptCreditFormState extends State<_ReceiptCreditForm> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _amount;
  late final TextEditingController _fromAccount;
  late final TextEditingController _payerName;
  late final TextEditingController _toAccount;
  late final TextEditingController _receiverName;
  DateTime? _due;
  bool _paid = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _amount = TextEditingController(text: e == null ? '' : plain(e['amount'] as num));
    _fromAccount = TextEditingController(text: e?['from_account'] as String? ?? '');
    _payerName = TextEditingController(text: e?['payer_name'] as String? ?? '');
    _toAccount = TextEditingController(text: e?['to_account'] as String? ?? '');
    _receiverName = TextEditingController(text: e?['receiver_name'] as String? ?? '');
    _due = e == null ? DateTime.now() : DateTime.parse(e['due_date'] as String);
    _paid = e != null && (e['paid'] as int) == 1;
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    if (_due == null) {
      snack(context, 'سررسید را انتخاب کنید');
      return;
    }
    Navigator.pop(context, {
      'amount': parseNum(_amount.text) ?? 0,
      'due_date': _due!.toIso8601String(),
      'from_account': _fromAccount.text.trim(),
      'payer_name': _payerName.text.trim(),
      'to_account': _toAccount.text.trim(),
      'receiver_name': _receiverName.text.trim(),
      'paid': _paid ? 1 : 0,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom, left: 16, right: 16, top: 16),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(widget.existing == null ? 'قسط جدید' : 'ویرایش قسط', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              numField(_amount, 'مبلغ قسط (تومان)', required: true, thousands: true),
              OverpayWarning(controller: _amount, total: widget.total, others: widget.others, receipt: true),
              dateField(context, 'تاریخ سررسید', _due, (d) => setState(() => _due = d)),
              textField(_fromAccount, 'از کدام حساب (خریدار)'),
              textField(_payerName, 'به نام چه کسی (پرداخت‌کننده)'),
              textField(_toAccount, 'به کدام حساب ما'),
              textField(_receiverName, 'به نام چه کسی (دریافت‌کننده)'),
              SwitchListTile(
                value: _paid,
                onChanged: (v) => setState(() => _paid = v),
                title: const Text('وصول شده'),
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 8),
              FilledButton(onPressed: _save, child: const Text('ذخیره')),
              const SizedBox(height: 16),
            ]),
          ),
        ),
      ),
    );
  }
}

// ------------------- فرم چک دریافتی -------------------
class _ReceiptChequeForm extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final double total;
  final double others;
  const _ReceiptChequeForm({this.existing, this.total = 0, this.others = 0});
  @override
  State<_ReceiptChequeForm> createState() => _ReceiptChequeFormState();
}

class _ReceiptChequeFormState extends State<_ReceiptChequeForm> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _amount;
  late final TextEditingController _chequeNo;
  late final TextEditingController _bankName;
  late final TextEditingController _fromAccount;
  late final TextEditingController _payerName;
  late final TextEditingController _toAccount;
  late final TextEditingController _receiverName;
  DateTime? _due;
  bool _paid = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _amount = TextEditingController(text: e == null ? '' : plain(e['amount'] as num));
    _chequeNo = TextEditingController(text: e?['cheque_no'] as String? ?? '');
    _bankName = TextEditingController(text: e?['bank_name'] as String? ?? '');
    _fromAccount = TextEditingController(text: e?['from_account'] as String? ?? '');
    _payerName = TextEditingController(text: e?['payer_name'] as String? ?? '');
    _toAccount = TextEditingController(text: e?['to_account'] as String? ?? '');
    _receiverName = TextEditingController(text: e?['receiver_name'] as String? ?? '');
    _due = e == null ? DateTime.now() : DateTime.parse(e['due_date'] as String);
    _paid = e != null && (e['paid'] as int) == 1;
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    if (_due == null) {
      snack(context, 'سررسید را انتخاب کنید');
      return;
    }
    Navigator.pop(context, {
      'amount': parseNum(_amount.text) ?? 0,
      'due_date': _due!.toIso8601String(),
      'cheque_no': _chequeNo.text.trim(),
      'bank_name': _bankName.text.trim(),
      'from_account': _fromAccount.text.trim(),
      'payer_name': _payerName.text.trim(),
      'to_account': _toAccount.text.trim(),
      'receiver_name': _receiverName.text.trim(),
      'paid': _paid ? 1 : 0,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom, left: 16, right: 16, top: 16),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(widget.existing == null ? 'چک دریافتی جدید' : 'ویرایش چک', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              numField(_amount, 'مبلغ چک (تومان)', required: true, thousands: true),
              OverpayWarning(controller: _amount, total: widget.total, others: widget.others, receipt: true),
              dateField(context, 'تاریخ سررسید چک', _due, (d) => setState(() => _due = d)),
              textField(_chequeNo, 'شماره چک'),
              textField(_bankName, 'نام بانک'),
              textField(_fromAccount, 'از کدام حساب (خریدار)'),
              textField(_payerName, 'به نام چه کسی (پرداخت‌کننده)'),
              textField(_toAccount, 'به کدام حساب ما'),
              textField(_receiverName, 'به نام چه کسی (دریافت‌کننده)'),
              SwitchListTile(
                value: _paid,
                onChanged: (v) => setState(() => _paid = v),
                title: const Text('وصول شده'),
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 8),
              FilledButton(onPressed: _save, child: const Text('ذخیره')),
              const SizedBox(height: 16),
            ]),
          ),
        ),
      ),
    );
  }
}
