import 'package:flutter/material.dart';

import 'db.dart';
import 'fmt.dart' show Fmt, MoneyField;
import 'utils.dart';

Widget numField(
  TextEditingController c,
  String label, {
  bool required = false,
  String? suffix,
  double? max,
  bool thousands = false,
  String? hint,
  VoidCallback? onChanged,
}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: thousands ? [ThousandsInputFormatter()] : null,
      decoration: InputDecoration(
        labelText: label,
        suffixText: suffix,
        hintText: hint,
        border: const OutlineInputBorder(),
      ),
      onChanged: (_) => onChanged?.call(),
      validator: (v) {
        if ((v ?? '').trim().isEmpty) return required ? 'الزامی است' : null;
        final n = parseNum(v);
        if (n == null || n < 0) return 'عدد معتبر وارد کنید';
        if (max != null && n > max) return 'حداکثر ${faNum(max)}';
        return null;
      },
    ),
  );
}

Widget textField(TextEditingController c, String label,
    {int lines = 1, bool required = false}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      controller: c,
      maxLines: lines,
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      validator: required
          ? (v) => (v ?? '').trim().isEmpty ? 'الزامی است' : null
          : null,
    ),
  );
}

Widget sectionTitle(BuildContext context, String t) => Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
      child: Text(t,
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(color: Theme.of(context).colorScheme.primary)),
    );

Widget infoRow(String k, String v, {Color? valueColor}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(k, style: const TextStyle(color: Colors.black54))),
          Text(v, style: TextStyle(fontWeight: FontWeight.w600, color: valueColor)),
        ],
      ),
    );

void snack(BuildContext c, String m) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

/// S35.T35.9a: دلیل حذف اجباری (۵ تا ۳۰۰ نویسه). null = انصراف.
Future<String?> askDeleteReason(BuildContext context, String msg) async {
  final TextEditingController c = TextEditingController();
  String? err;
  final String? r = await showDialog<String>(
    context: context,
    builder: (BuildContext ctx) => StatefulBuilder(
      builder: (BuildContext ctx, void Function(void Function()) setS) => AlertDialog(
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text(msg),
          const SizedBox(height: 12),
          TextField(
            controller: c,
            maxLength: 300,
            maxLines: 2,
            decoration: InputDecoration(labelText: 'دلیل حذف (حداقل ۵ نویسه)', errorText: err, border: const OutlineInputBorder()),
          ),
        ]),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('انصراف')),
          FilledButton(
            onPressed: () {
              final String t = c.text.trim();
              if (t.length < 5) {
                setS(() => err = 'دلیل باید حداقل ۵ نویسه باشد');
                return;
              }
              Navigator.pop(ctx, t);
            },
            child: const Text('حذف'),
          ),
        ],
      ),
    ),
  );
  c.dispose();
  return r;
}

Future<bool> confirm(BuildContext context, String msg) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: Text(msg),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تایید')),
      ],
    ),
  );
  return r ?? false;
}

/// انتخاب تاریخ با تقویم شمسی رسمی ایران (ماه/سال قابل‌جابه‌جایی، بدون وابستگی به تقویم میلادی)
Future<DateTime?> pickDate(BuildContext context, {DateTime? initial, DateTime? firstDate, DateTime? lastDate}) async {
  return showDialog<DateTime>(
    context: context,
    builder: (ctx) => _JalaliDatePickerDialog(
      initial: initial ?? DateTime.now(),
      firstDate: firstDate ?? DateTime(2015),
      lastDate: lastDate ?? DateTime(2035),
    ),
  );
}

class _JalaliDatePickerDialog extends StatefulWidget {
  final DateTime initial;
  final DateTime firstDate;
  final DateTime lastDate;
  const _JalaliDatePickerDialog({
    required this.initial,
    required this.firstDate,
    required this.lastDate,
  });

  @override
  State<_JalaliDatePickerDialog> createState() => _JalaliDatePickerDialogState();
}

class _JalaliDatePickerDialogState extends State<_JalaliDatePickerDialog> {
  late int _jy;
  late int _jm;
  late int _jd;

  @override
  void initState() {
    super.initState();
    final j = gregorianToJalali(widget.initial.year, widget.initial.month, widget.initial.day);
    _jy = j[0];
    _jm = j[1];
    _jd = j[2];
  }

  void _clampDay() {
    final dim = daysInJalaliMonth(_jy, _jm);
    if (_jd > dim) _jd = dim;
  }

  void _changeMonth(int delta) {
    setState(() {
      var m = _jm + delta;
      var y = _jy;
      if (m < 1) {
        m = 12;
        y -= 1;
      } else if (m > 12) {
        m = 1;
        y += 1;
      }
      _jy = y;
      _jm = m;
      _clampDay();
    });
  }

  void _changeYear(int delta) {
    setState(() {
      _jy += delta;
      _clampDay();
    });
  }

  Future<void> _editYear() async {
    final c = TextEditingController(text: toFaDigits('$_jy'));
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('انتخاب سال'),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'سال شمسی'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('تایید')),
        ],
      ),
    );
    if (v == null) return;
    final n = int.tryParse(toEnDigits(v).trim());
    if (n == null) return;
    setState(() {
      _jy = n;
      _clampDay();
    });
  }

  bool _isDisabled(int day) {
    final g = jalaliToGregorian(_jy, _jm, day);
    final gDay = DateTime(g.year, g.month, g.day);
    final first = DateTime(widget.firstDate.year, widget.firstDate.month, widget.firstDate.day);
    final last = DateTime(widget.lastDate.year, widget.lastDate.month, widget.lastDate.day);
    return gDay.isBefore(first) || gDay.isAfter(last);
  }

  @override
  Widget build(BuildContext context) {
    final dim = daysInJalaliMonth(_jy, _jm);
    final firstOfMonthG = jalaliToGregorian(_jy, _jm, 1);
    final startIdx = jalaliWeekdayIndex(firstOfMonthG);
    final scheme = Theme.of(context).colorScheme;

    final cells = <Widget>[];
    for (var i = 0; i < startIdx; i++) {
      cells.add(const SizedBox.shrink());
    }
    for (var day = 1; day <= dim; day++) {
      final isSelected = day == _jd;
      final disabled = _isDisabled(day);
      cells.add(
        InkWell(
          onTap: disabled ? null : () => setState(() => _jd = day),
          borderRadius: BorderRadius.circular(20),
          child: Container(
            margin: const EdgeInsets.all(2),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isSelected ? scheme.primary : null,
              shape: BoxShape.circle,
            ),
            child: Text(
              toFaDigits('$day'),
              style: TextStyle(
                color: disabled ? Colors.black26 : (isSelected ? scheme.onPrimary : null),
                fontWeight: isSelected ? FontWeight.bold : null,
              ),
            ),
          ),
        ),
      );
    }

    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
      content: SizedBox(
        width: 320,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            IconButton(onPressed: () => _changeYear(-1), icon: const Icon(Icons.arrow_back)),
            InkWell(
              onTap: _editYear,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(toFaDigits('$_jy'), style: Theme.of(context).textTheme.titleMedium),
              ),
            ),
            IconButton(onPressed: () => _changeYear(1), icon: const Icon(Icons.arrow_forward)),
          ]),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            IconButton(onPressed: () => _changeMonth(-1), icon: const Icon(Icons.arrow_back)),
            Text(kJalaliMonthNames[_jm - 1], style: Theme.of(context).textTheme.titleMedium),
            IconButton(onPressed: () => _changeMonth(1), icon: const Icon(Icons.arrow_forward)),
          ]),
          const SizedBox(height: 4),
          GridView.count(
            crossAxisCount: 7,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (final w in kJalaliWeekdayShort)
                Center(
                  child: Text(w,
                      style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black54)),
                ),
              ...cells,
            ],
          ),
          const SizedBox(height: 8),
        ]),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('انصراف')),
        FilledButton(
          onPressed: _isDisabled(_jd)
              ? null
              : () => Navigator.pop(context, jalaliToGregorian(_jy, _jm, _jd)),
          child: const Text('تایید'),
        ),
      ],
    );
  }
}

Widget dateField(BuildContext context, String label, DateTime? value, ValueChanged<DateTime> onPick) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: InkWell(
      onTap: () async {
        final d = await pickDate(context, initial: value);
        if (d != null) onPick(d);
      },
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        child: Text(value == null ? 'انتخاب تاریخ' : jalaliDateFromDt(value)),
      ),
    ),
  );
}

/// هشدار غیرمسدودکننده: اگر جمع همهٔ تراکنش‌های ثبت‌شده (به‌علاوهٔ مبلغ در حال ثبت) از مبلغ کل بیشتر شود نمایش داده می‌شود
class OverpayWarning extends StatelessWidget {
  final TextEditingController controller;
  final double total;
  final double others; // جمع سایر تراکنش‌های ثبت‌شده (بدون ردیف در حال ویرایش)
  final bool receipt;
  const OverpayWarning({
    super.key,
    required this.controller,
    required this.total,
    required this.others,
    this.receipt = false,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (_, __, ___) {
        final sum = others + (MoneyField.stored(controller) ?? 0);
        if (total <= 0 || sum <= total + 0.5) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.orange.shade50,
            border: Border.all(color: Colors.orange.shade700),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            'هشدار: با این مبلغ، جمع همهٔ تراکنش‌های ثبت‌شده '
            '${Fmt.money(sum - total)} بیشتر از مبلغ کل شده است؛ '
            'شما دارید بیشتر از مبلغ کل ${receipt ? 'دریافت' : 'پرداخت'} می‌کنید. ثبت آن همچنان ممکن است.',
            style: TextStyle(color: Colors.orange.shade900, fontSize: 12.5),
          ),
        );
      },
    );
  }
}

/// فیلد قفل‌شدهٔ ویژهٔ پلن ارزی (برای کاربر پلن ریالی نمایش داده می‌شود ولی غیرفعال است)
Widget fxLockedField(String label) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        enabled: false,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.lock_outline),
          helperText: 'ویژهٔ پلن ارزی؛ برای فعال‌سازی با پشتیبانی تماس بگیرید',
          border: const OutlineInputBorder(),
        ),
      ),
    );

// ============================================================================
// ثبت با «تأیید قطعی» + محافظ ویرایش
// ============================================================================

/// پیام خطای قابل‌فهم برای کاربر
String friendlyError(Object e) {
  if (e is StateError && '${e.message}'.contains('no_account')) {
    return 'نشست ورود شما بسته شده است؛ دوباره وارد حساب شوید.';
  }
  if (e is SaveNotConfirmed) return e.message;
  return e.toString().replaceFirst('Exception: ', '').replaceFirst('Bad state: ', '');
}

/// عملیات ثبت را اجرا می‌کند و فقط وقتی دیتابیس «تأیید قطعی» داد، پیام موفقیت نشان می‌دهد.
/// اگر ثبت نشود، یک اخطار صریح (نه پیام موفقیت) نشان داده می‌شود و کاربر می‌تواند دوباره تلاش کند؛
/// اطلاعاتِ فرم دست‌نخورده می‌ماند.
Future<bool> saveConfirmed(
  BuildContext context,
  Future<void> Function() action, {
  required String successMsg,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  while (true) {
    try {
      await action();
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          backgroundColor: Colors.green.shade700,
          duration: const Duration(seconds: 3),
          content: Row(children: [
            const Icon(Icons.check_circle, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(child: Text(successMsg)),
          ]),
        ));
      return true;
    } catch (e) {
      if (!context.mounted) return false;
      final retry = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          icon: Icon(Icons.warning_amber_rounded, color: Colors.orange.shade800, size: 38),
          title: const Text('ثبت انجام نشد'),
          content: Text('${friendlyError(e)}\n\n'
              'این مورد ثبت نشده است. اطلاعاتی که وارد کرده‌اید پاک نشده؛ می‌توانید دوباره تلاش کنید.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('بستن')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تلاش دوباره')),
          ],
        ),
      );
      if (retry != true) return false;
    }
  }
}

/// تا وقتی یک فرم/صفحهٔ ثبت باز است، دریافت خودکار از سرور (که شناسه‌ها را عوض می‌کند)
/// عقب می‌افتد؛ این همان چیزی است که باعث «گم‌شدنِ» ثبت‌های بعد از معطلیِ طولانی می‌شد.
mixin EditGuard<T extends StatefulWidget> on State<T> {
  Object? _editToken;

  @override
  void initState() {
    super.initState();
    _editToken = AppDb.I.beginEdit();
  }

  @override
  void dispose() {
    final t = _editToken;
    if (t != null) AppDb.I.endEdit(t);
    super.dispose();
  }
}
