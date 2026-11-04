import 'package:flutter/material.dart';

import 'returns_ui.dart' show ReturnsHelp;
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;
import 'workshop_calc.dart';
import 'workshop_ui.dart' show wsParseNum;

/// مرحلهٔ ۴ کارگاه — کارگاه بیرونی با قبض (جهت `paid` فراوری) + «فایل خام شکست کارگاه‌ها».
/// سرور: processing.create/receive/receipt_save (فیلدهای قبض) و workshop.outside_raw (api/workshop_outside.php).
/// هیچ مبلغی در این فایل نیست؛ G/J/K فقط نمایش‌اند و از `outsideCalc` (آینهٔ PHP) می‌آیند.
/// «کش» و «غیر شرکتی» تا پاسخ کاربر فقط متن اختیاری‌اند.

double _od(dynamic v) => ReturnsHelp.d(v);
String _okg(dynamic v) => faNum(_od(v), dec: 3);
String _onum(dynamic v) {
  if (v == null) return '';
  final double d = _od(v);
  return d == d.roundToDouble() ? d.toInt().toString() : '$d';
}

/// نمایش اختیاری: null ⇒ «—».
String _optKg(double? v) => v == null ? '—' : _okg(v);
String _optPct(double? v) => v == null ? '—' : '${faNum(v, dec: 2)}٪';

/// کنترلرهای فیلدهای قبض (فرم ثبت، ویرایش در جزئیات و صفحهٔ دریافت).
class OutsideReceiptCtl {
  final TextEditingController receiptNo = TextEditingController();
  final TextEditingController owner = TextEditingController();
  final TextEditingController bale = TextEditingController();
  final TextEditingController sentGram = TextEditingController();
  final TextEditingController cash = TextEditingController();
  final TextEditingController nonCompany = TextEditingController();
  final TextEditingController recvKernel = TextEditingController();
  final TextEditingController recvGram = TextEditingController();

  OutsideReceiptCtl([Map<String, dynamic>? o]) {
    if (o == null) return;
    receiptNo.text = o['receipt_no'] == null ? '' : '${o['receipt_no']}';
    owner.text = o['owner'] == null ? '' : '${o['owner']}';
    bale.text = _onum(o['bale_count']);
    sentGram.text = _onum(o['sent_gram_pct']);
    cash.text = o['cash_note'] == null ? '' : '${o['cash_note']}';
    nonCompany.text = o['non_company_note'] == null ? '' : '${o['non_company_note']}';
    recvKernel.text = _onum(o['recv_kernel_kg']);
    recvGram.text = _onum(o['recv_gram_pct']);
  }

  void dispose() {
    receiptNo.dispose();
    owner.dispose();
    bale.dispose();
    sentGram.dispose();
    cash.dispose();
    nonCompany.dispose();
    recvKernel.dispose();
    recvGram.dispose();
  }

  static double? opt(TextEditingController c) => c.text.trim().isEmpty ? null : wsParseNum(c.text);

  double? get sentGramV => opt(sentGram);
  double? get recvKernelV => opt(recvKernel);
  double? get recvGramV => opt(recvGram);

  /// [clearEmpty] = true ⇒ فیلد خالی هم با null فرستاده می‌شود (پاک‌کردن در ویرایش)؛ false ⇒ فیلد خالی ارسال نمی‌شود (ثبت اولیه).
  Map<String, dynamic> sentPayload({required bool clearEmpty}) {
    final Map<String, dynamic> p = <String, dynamic>{};
    void put(String k, dynamic v) {
      if (v == null || (v is String && v.isEmpty)) {
        if (clearEmpty) p[k] = null;
      } else {
        p[k] = v;
      }
    }

    put('receipt_no', receiptNo.text.trim());
    put('owner', owner.text.trim());
    put('bale_count', opt(bale));
    put('sent_gram_pct', sentGramV);
    put('cash_note', cash.text.trim());
    put('non_company_note', nonCompany.text.trim());
    return p;
  }

  Map<String, dynamic> recvPayload({required bool clearEmpty}) {
    final Map<String, dynamic> p = <String, dynamic>{};
    if (recvKernelV != null) {
      p['recv_kernel_kg'] = recvKernelV;
    } else if (clearEmpty) {
      p['recv_kernel_kg'] = null;
    }
    if (recvGramV != null) {
      p['recv_gram_pct'] = recvGramV;
    } else if (clearEmpty) {
      p['recv_gram_pct'] = null;
    }
    return p;
  }
}

InputDecoration _dec(String label) => InputDecoration(labelText: label, border: const OutlineInputBorder());
const TextInputType _numKb = TextInputType.numberWithOptions(decimal: true);

/// فیلدهای قبض. [showSent] بخش ارسال (قبض، مالک، عدل، گرم ارسالی، کش، غیر شرکتی)، [showRecv] بخش دریافت (مغز و گرم دریافتی).
class OutsideReceiptFields extends StatelessWidget {
  final OutsideReceiptCtl ctl;
  final bool showSent;
  final bool showRecv;
  final double sentKg;
  final VoidCallback onChanged;
  const OutsideReceiptFields({super.key, required this.ctl, required this.sentKg, required this.onChanged, this.showSent = true, this.showRecv = false});

  @override
  Widget build(BuildContext context) {
    final OutsideCalc c = outsideCalc(sentKg: sentKg, sentGramPct: ctl.sentGramV, recvKernelKg: ctl.recvKernelV, recvGramPct: ctl.recvGramV);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (showSent) ...<Widget>[
          Row(children: <Widget>[
            Expanded(child: TextField(controller: ctl.receiptNo, decoration: _dec('شمارهٔ قبض'))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: ctl.bale, keyboardType: _numKb, decoration: _dec('تعداد عدل'))),
          ]),
          const SizedBox(height: 8),
          TextField(controller: ctl.owner, decoration: _dec('نام مالک')),
          const SizedBox(height: 8),
          TextField(controller: ctl.sentGram, keyboardType: _numKb, onChanged: (_) => onChanged(), decoration: _dec('گرم پستهٔ ارسالی (٪)')),
          const SizedBox(height: 8),
          Row(children: <Widget>[
            Expanded(child: TextField(controller: ctl.cash, decoration: _dec('کش (اختیاری)'))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: ctl.nonCompany, decoration: _dec('غیر شرکتی (اختیاری)'))),
          ]),
        ],
        if (showRecv) ...<Widget>[
          if (showSent) const SizedBox(height: 8),
          Row(children: <Widget>[
            Expanded(child: TextField(controller: ctl.recvKernel, keyboardType: _numKb, onChanged: (_) => onChanged(), decoration: _dec('مغز دریافتی (کیلو)'))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: ctl.recvGram, keyboardType: _numKb, onChanged: (_) => onChanged(), decoration: _dec('گرم دریافتی (٪)'))),
          ]),
        ],
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: OutsideCalcLines(calc: c, sentKg: sentKg),
          ),
        ),
      ],
    );
  }
}

/// خطوط محاسباتی فقط‌خواندنی: وزن مغز برآوردی (G)، تخمین مغز باقی‌مانده (J)، افت (K).
class OutsideCalcLines extends StatelessWidget {
  final OutsideCalc calc;
  final double sentKg;
  const OutsideCalcLines({super.key, required this.calc, required this.sentKg});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('وزن پستهٔ ارسالی: ${_okg(sentKg)} کیلو'),
        Text('وزن مغز برآوردی: ${_optKg(calc.estKernelKg)} کیلو'),
        Text('تخمین مغز باقی‌مانده: ${_optKg(calc.remainingKernelKg)} کیلو'),
        Text('افت (اختلاف گرم ارسالی و دریافتی): ${calc.lossGram == null ? '—' : faNum(calc.lossGram!, dec: 2)}'),
      ],
    );
  }
}

/// کارت قبض در جزئیات سفارش paid؛ دکمهٔ ویرایش (processing.receipt_save) فقط وقتی [canEdit].
class OutsideReceiptCard extends StatelessWidget {
  final Map<String, dynamic> order;
  final bool canEdit;
  final Future<void> Function() onEdit;
  const OutsideReceiptCard({super.key, required this.order, required this.canEdit, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final OutsideCalc c = outsideCalc(
      sentKg: _od(order['input_kg']),
      sentGramPct: order['sent_gram_pct'] == null ? null : _od(order['sent_gram_pct']),
      recvKernelKg: order['recv_kernel_kg'] == null ? null : _od(order['recv_kernel_kg']),
      recvGramPct: order['recv_gram_pct'] == null ? null : _od(order['recv_gram_pct']),
    );
    String t(String k) => order[k] == null ? '' : '${order[k]}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('قبض کارگاه بیرونی', style: Theme.of(context).textTheme.titleMedium),
            Text('شمارهٔ قبض: ${t('receipt_no').isEmpty ? '—' : t('receipt_no')}'),
            Text('نام مالک: ${t('owner').isEmpty ? '—' : t('owner')}'),
            Text('تعداد عدل: ${order['bale_count'] == null ? '—' : faNum(_od(order['bale_count']), dec: 0)}'),
            Text('گرم پستهٔ ارسالی: ${order['sent_gram_pct'] == null ? '—' : _optPct(_od(order['sent_gram_pct']))}'),
            if (t('cash_note').isNotEmpty) Text('کش: ${t('cash_note')}'),
            if (t('non_company_note').isNotEmpty) Text('غیر شرکتی: ${t('non_company_note')}'),
            Text('مغز دریافتی: ${order['recv_kernel_kg'] == null ? '—' : '${_okg(order['recv_kernel_kg'])} کیلو'}'),
            Text('گرم دریافتی: ${order['recv_gram_pct'] == null ? '—' : _optPct(_od(order['recv_gram_pct']))}'),
            const Divider(),
            OutsideCalcLines(calc: c, sentKg: _od(order['input_kg'])),
            if (canEdit)
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: OutlinedButton.icon(onPressed: onEdit, icon: const Icon(Icons.edit_outlined), label: const Text('ویرایش قبض')),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// «فایل خام شکست کارگاه‌ها» — برگهٔ اکسل A..K + ردیف جمع (فقط‌خواندنی، بدون قیمت)
// ---------------------------------------------------------------------------

class OutsideRawScreen extends StatefulWidget {
  const OutsideRawScreen({super.key});

  @override
  State<OutsideRawScreen> createState() => _OutsideRawScreenState();
}

class _OutsideRawScreenState extends State<OutsideRawScreen> {
  final TextEditingController _owner = TextEditingController();
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  Map<String, dynamic> _tot = <String, dynamic>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _owner.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final Map<String, dynamic> q = <String, dynamic>{};
      if (_owner.text.trim().isNotEmpty) q['owner'] = _owner.text.trim();
      final Map<String, dynamic> r = await StockApi.call('workshop.outside_raw', q);
      if (!mounted) return;
      setState(() {
        _items = ReturnsHelp.maps(r['items']);
        _tot = r['totals'] is Map ? Map<String, dynamic>.from(r['totals'] as Map) : <String, dynamic>{};
        _error = null;
        _loading = false;
      });
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  String _txt(dynamic v) => v == null || '$v'.isEmpty ? '—' : '$v';
  String _kgOrDash(dynamic v) => v == null ? '—' : _okg(v);
  String _pctOrDash(dynamic v) => v == null ? '—' : faNum(_od(v), dec: 2);

  @override
  Widget build(BuildContext context) {
    const List<String> heads = <String>[
      'تاریخ', 'کارگاه', 'کش', 'شمارهٔ قبض', 'عدل', 'نام مالک', 'وزن پستهٔ ارسالی', 'گرم ارسالی', 'وزن مغز برآوردی',
      'مغز دریافتی', 'گرم دریافتی', 'تخمین مغز باقی‌مانده', 'افت',
    ];
    DataCell cell(String s, {bool bold = false}) => DataCell(Text(s, style: bold ? const TextStyle(fontWeight: FontWeight.bold) : null));
    final List<DataRow> rows = <DataRow>[
      for (final Map<String, dynamic> r in _items)
        DataRow(cells: <DataCell>[
          cell(jalaliDate('${r['date']}')),
          cell(_txt(r['party'])),
          cell(_txt(r['cash_note'])),
          cell(_txt(r['receipt_no'])),
          cell(r['bale_count'] == null ? '—' : faNum(_od(r['bale_count']), dec: 0)),
          cell(_txt(r['owner'])),
          cell(_okg(r['sent_kg'])),
          cell(_pctOrDash(r['sent_gram_pct'])),
          cell(_kgOrDash(r['calc'] is Map ? (r['calc'] as Map)['est_kernel_kg'] : null)),
          cell(_kgOrDash(r['recv_kernel_kg'])),
          cell(_pctOrDash(r['recv_gram_pct'])),
          cell(_kgOrDash(r['calc'] is Map ? (r['calc'] as Map)['remaining_kernel_kg'] : null)),
          cell(_pctOrDash(r['calc'] is Map ? (r['calc'] as Map)['loss_gram'] : null)),
        ]),
      if (_items.isNotEmpty)
        DataRow(cells: <DataCell>[
          cell('جمع', bold: true),
          cell(''),
          cell(''),
          cell(''),
          cell(''),
          cell(''),
          cell(_okg(_tot['sent_kg']), bold: true),
          cell(_pctOrDash(_tot['sent_gram_sum']), bold: true),
          cell(_okg(_tot['est_kernel_kg']), bold: true),
          cell(_okg(_tot['recv_kernel_kg']), bold: true),
          cell(_pctOrDash(_tot['recv_gram_sum']), bold: true),
          cell(_okg(_tot['remaining_kernel_kg']), bold: true),
          cell(_pctOrDash(_tot['loss_gram']), bold: true),
        ]),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('فایل خام شکست کارگاه‌ها'),
        actions: <Widget>[IconButton(tooltip: 'به‌روزرسانی', icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: <Widget>[
          Row(children: <Widget>[
            Expanded(child: TextField(controller: _owner, onSubmitted: (_) => _load(), decoration: _dec('فیلتر نام مالک'))),
            const SizedBox(width: 8),
            FilledButton(onPressed: _load, child: const Text('اعمال')),
          ]),
          const SizedBox(height: 10),
          if (_error != null)
            Card(color: Theme.of(context).colorScheme.errorContainer, child: Padding(padding: const EdgeInsets.all(10), child: Text(_error!))),
          if (_loading) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
          if (!_loading && _items.isEmpty && _error == null) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('سفارش برون‌سپاری ثبت نشده است'))),
          if (_items.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: <DataColumn>[for (final String h in heads) DataColumn(label: Text(h))],
                rows: rows,
              ),
            ),
          const SizedBox(height: 8),
          const Text('افت = گرم ارسالی − گرم دریافتی (نقطهٔ درصد). مقدار خالی یعنی هنوز ثبت نشده است.', style: TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}
