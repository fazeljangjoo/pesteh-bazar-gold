import 'package:flutter/material.dart';

import 'edit_guard.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;
import 'widgets.dart' show JalaliDateField;

/// فاز ۳ مجد — «ویرایش امن»، بخش UI (فایل مشترک اندروید و ویندوز).
///   [EditField] / [showEditDocDialog]: فرم ویرایش؛ فیلدهای قفل خاکستری با توضیح («چون … فروخته شده»).
///   [submitDocEdit]: ارسال آنلاین با base_version؛ ۴۰۹ تعارض ⇒ پیام «این سند در این فاصله تغییر کرده؛ دوباره باز کنید» (تکرار نمی‌شود).

enum EditKind { text, number, date }

class EditField {
  const EditField(this.key, this.label, this.initial, {this.kind = EditKind.text, this.locked = false, this.options});
  final String key;
  final String label;
  final Object? initial;
  final EditKind kind;
  final bool locked;

  /// برای انتخاب از فهرست (مقدار ⇒ برچسب).
  final Map<String, String>? options;
}

String _isoOf(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

double? _num(String s) {
  const String fa = '۰۱۲۳۴۵۶۷۸۹';
  final StringBuffer b = StringBuffer();
  for (final int c in s.runes) {
    final String ch = String.fromCharCode(c);
    final int i = fa.indexOf(ch);
    if (i >= 0) {
      b.write(i);
    } else if (ch == '٫') {
      b.write('.');
    } else if (ch != ',' && ch != '٬') {
      b.write(ch);
    }
  }
  return double.tryParse(b.toString().trim());
}

/// فرم ویرایش. خروجی: فقط فیلدهای قفل‌نشده (کلید ⇒ مقدار؛ تاریخ yyyy-mm-dd، عدد double) یا null (انصراف).
/// [lockReason] زیر فیلدهای قفل نمایش داده می‌شود.
Future<Map<String, dynamic>?> showEditDocDialog(BuildContext context, String title, List<EditField> fields, {String? lockReason}) {
  return showDialog<Map<String, dynamic>>(context: context, builder: (_) => _EditDocDialog(title: title, fields: fields, lockReason: lockReason));
}

class _EditDocDialog extends StatefulWidget {
  const _EditDocDialog({required this.title, required this.fields, this.lockReason});
  final String title;
  final List<EditField> fields;
  final String? lockReason;

  @override
  State<_EditDocDialog> createState() => _EditDocDialogState();
}

class _EditDocDialogState extends State<_EditDocDialog> {
  late final Map<String, TextEditingController> _ctl = <String, TextEditingController>{
    for (final EditField f in widget.fields)
      if (f.kind != EditKind.date && f.options == null) f.key: TextEditingController(text: f.initial == null ? '' : '${f.initial}'),
  };
  late final Map<String, DateTime> _dates = <String, DateTime>{
    for (final EditField f in widget.fields)
      if (f.kind == EditKind.date) f.key: DateTime.tryParse('${f.initial ?? ''}') ?? DateTime.now(),
  };
  late final Map<String, String?> _opts = <String, String?>{
    for (final EditField f in widget.fields)
      if (f.options != null) f.key: f.initial == null ? null : '${f.initial}',
  };

  @override
  void dispose() {
    for (final TextEditingController c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _field(EditField f) {
    final String? helper = f.locked ? (widget.lockReason ?? 'قفل') : null;
    if (f.kind == EditKind.date) {
      final Widget w = JalaliDateField(label: f.label, value: _dates[f.key]!, onChanged: (DateTime d) => setState(() => _dates[f.key] = d));
      return f.locked ? IgnorePointer(child: Opacity(opacity: 0.5, child: w)) : w;
    }
    if (f.options != null) {
      return DropdownButtonFormField<String>(
        initialValue: _opts[f.key],
        decoration: InputDecoration(labelText: f.label, helperText: helper, border: const OutlineInputBorder(), filled: f.locked),
        items: <DropdownMenuItem<String>>[
          for (final MapEntry<String, String> e in f.options!.entries) DropdownMenuItem<String>(value: e.key, child: Text(e.value)),
        ],
        onChanged: f.locked ? null : (String? v) => setState(() => _opts[f.key] = v),
      );
    }
    return TextField(
      controller: _ctl[f.key],
      enabled: !f.locked,
      keyboardType: f.kind == EditKind.number ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
      decoration: InputDecoration(labelText: f.label, helperText: helper, helperMaxLines: 3, border: const OutlineInputBorder(), filled: f.locked),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          for (final EditField f in widget.fields) Padding(padding: const EdgeInsets.only(bottom: 10), child: _field(f)),
        ]),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('انصراف')),
        FilledButton(
          onPressed: () {
            final Map<String, dynamic> out = <String, dynamic>{};
            for (final EditField f in widget.fields) {
              if (f.locked) continue;
              if (f.kind == EditKind.date) {
                out[f.key] = _isoOf(_dates[f.key]!);
              } else if (f.options != null) {
                if (_opts[f.key] != null) out[f.key] = _opts[f.key];
              } else if (f.kind == EditKind.number) {
                final double? v = _num(_ctl[f.key]!.text);
                if (v == null) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('«${f.label}» عدد معتبر نیست')));
                  return;
                }
                out[f.key] = v;
              } else {
                out[f.key] = _ctl[f.key]!.text.trim();
              }
            }
            Navigator.pop(context, out);
          },
          child: const Text('ذخیره'),
        ),
      ],
    );
  }
}

/// ارسال ویرایش (آنلاین). [baseVersion] = edit_version آخرین دریافت سند (null = بدون بررسی).
/// موفق ⇒ پاسخ سرور؛ خطا ⇒ پیام در SnackBar و null. تعارض نسخه ⇒ پیام روشن «دوباره باز کنید».
Future<Map<String, dynamic>?> submitDocEdit(BuildContext context, String action, Map<String, dynamic> payload, {Object? baseVersion}) async {
  final ScaffoldMessengerState sm = ScaffoldMessenger.of(context);
  try {
    final Map<String, dynamic> r = await StockApi.call(action, <String, dynamic>{...payload, if (baseVersion != null) 'base_version': baseVersion});
    sm.showSnackBar(const SnackBar(content: Text('ویرایش ذخیره شد')));
    return r;
  } on StockApiException catch (e) {
    sm.showSnackBar(SnackBar(content: Text(editGuardIsConflict(e.code, e.data) ? kEditConflictMsg : e.message), duration: const Duration(seconds: 6)));
    return null;
  }
}
