import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'company_profile.dart';
import 'entity_store.dart';
import 'invoice_templates_pdf.dart';
import 'pdf_output.dart';
import 'widgets.dart';

/// S12.T12.1 — company profile, invoice template chooser and document number sequences.
class CompanySettingsScreen extends StatefulWidget {
  const CompanySettingsScreen({super.key});

  @override
  State<CompanySettingsScreen> createState() => _CompanySettingsScreenState();
}

class _CompanySettingsScreenState extends State<CompanySettingsScreen> {
  final Map<String, TextEditingController> _c = <String, TextEditingController>{
    'name': TextEditingController(),
    'address': TextEditingController(),
    'phones': TextEditingController(),
    'economic_code': TextEditingController(),
    'national_id': TextEditingController(),
    'postal_code': TextEditingController(),
    'registration_no': TextEditingController(),
    'footer_text': TextEditingController(),
  };
  static const Map<String, String> _labels = <String, String>{
    'name': 'نام شرکت',
    'address': 'نشانی',
    'phones': 'تلفن‌ها',
    'economic_code': 'کد اقتصادی',
    'national_id': 'شناسه ملی',
    'postal_code': 'کد پستی',
    'registration_no': 'شمارهٔ ثبت',
    'footer_text': 'متن پای فاکتور',
  };
  String? _uid;
  String _logo = '';
  InvTemplate _tpl = InvTemplate.a4;
  List<Map<String, dynamic>> _seqs = <Map<String, dynamic>>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final TextEditingController c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final Map<String, dynamic>? r = await CompanyProfile.row();
    final InvTemplate t = await InvoiceTemplates.chosen();
    final List<Map<String, dynamic>> s = await EntityStore.I.list('doc_sequences');
    if (!mounted) return;
    setState(() {
      if (r != null) {
        _uid = r['uid'] as String?;
        for (final MapEntry<String, TextEditingController> e in _c.entries) {
          e.value.text = (r[e.key] ?? '').toString();
        }
        _logo = (r['logo'] ?? '').toString();
      }
      _tpl = t;
      _seqs = s;
      _loading = false;
    });
  }

  Future<void> _pickLogo() async {
    try {
      final XFile? f = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 240, maxHeight: 240, imageQuality: 80);
      if (f == null) return;
      final List<int> bytes = await f.readAsBytes();
      final String mime = f.path.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
      final String url = 'data:$mime;base64,${base64Encode(bytes)}';
      if (url.length > 100000) {
        if (mounted) snack(context, 'تصویر لوگو بزرگ است؛ تصویر کوچک‌تری انتخاب کنید');
        return;
      }
      setState(() => _logo = url);
    } catch (e) {
      if (mounted) snack(context, 'خطا در انتخاب تصویر: $e');
    }
  }

  Future<void> _saveProfile() async {
    if (_c['name']!.text.trim().isEmpty) {
      snack(context, 'نام شرکت الزامی است');
      return;
    }
    try {
      final Map<String, dynamic> data = <String, dynamic>{
        for (final MapEntry<String, TextEditingController> e in _c.entries) e.key: e.value.text.trim(),
        'logo': _logo,
      };
      _uid = await EntityStore.I.save('company_profile', data, uid: _uid);
      if (mounted) snack(context, 'مشخصات شرکت ذخیره شد');
    } catch (e) {
      if (mounted) snack(context, '$e');
    }
  }

  Future<void> _chooseTemplate(InvTemplate t) async {
    await InvoiceTemplates.choose(t);
    if (mounted) setState(() => _tpl = t);
  }

  Future<void> _preview() async {
    try {
      final CompanyProfile? prof = await CompanyProfile.load();
      final file = await InvoiceTemplatesPdf.render(
        const InvDoc(
          title: 'نمونهٔ فاکتور',
          fileTag: 'sample',
          header: <List<String>>[
            <String>['شماره فاکتور', '۰۰۰۰۱'],
            <String>['تاریخ', '۱۴۰۵/۰۱/۰۱'],
            <String>['خریدار', 'نمونه'],
          ],
          columns: <String>['ردیف', 'کالا', 'وزن (کیلو)', 'فی (تومان)', 'مبلغ (تومان)'],
          rows: <List<String>>[
            <String>['۱', 'پستهٔ احمدآقایی', '۱۰۰', '۵۰۰٬۰۰۰', '۵۰٬۰۰۰٬۰۰۰'],
          ],
          totals: <List<String>>[
            <String>['جمع کل (تومان)', '۵۰٬۰۰۰٬۰۰۰'],
          ],
          signLabels: <String>['امضای فروشنده', 'امضای خریدار'],
        ),
        _tpl,
        prof,
      );
      if (!mounted) return;
      await PdfOutput.show(context, file);
    } catch (e) {
      if (mounted) snack(context, 'خطا در پیش‌نمایش: $e');
    }
  }

  Future<void> _editSeq(String docType) async {
    Map<String, dynamic>? row;
    for (final Map<String, dynamic> r in _seqs) {
      if (r['doc_type'] == docType && ((r['fy'] as num?)?.toInt() ?? 0) == 0) row = r;
    }
    final TextEditingController pre = TextEditingController(text: (row?['prefix'] ?? '').toString());
    final TextEditingController nxt = TextEditingController(text: '${(row?['next_no'] as num?)?.toInt() ?? 1}');
    final TextEditingController pad = TextEditingController(text: '${(row?['padding'] as num?)?.toInt() ?? 5}');
    final int minNext = (row?['next_no'] as num?)?.toInt() ?? 1;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(kDocTypeLabels[docType] ?? docType),
        content: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          textField(pre, 'پیشوند (حرف لاتین/عدد، اختیاری)'),
          textField(nxt, 'شمارهٔ بعدی (حداقل $minNext)'),
          textField(pad, 'تعداد ارقام'),
        ]),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ذخیره')),
        ],
      ),
    );
    if (ok != true) return;
    final int n = int.tryParse(nxt.text.trim()) ?? 0;
    final int p = int.tryParse(pad.text.trim()) ?? -1;
    if (n < minNext || p < 0 || p > 12) {
      if (mounted) snack(context, 'شمارهٔ بعدی نمی‌تواند کمتر از مقدار فعلی باشد و ارقام باید ۰ تا ۱۲ باشد');
      return;
    }
    try {
      await EntityStore.I.save(
        'doc_sequences',
        <String, dynamic>{'doc_type': docType, 'fy': 0, 'prefix': pre.text.trim(), 'next_no': n, 'padding': p},
        uid: row?['uid'] as String?,
      );
      _seqs = await EntityStore.I.list('doc_sequences');
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) snack(context, '$e');
    }
  }

  String _seqSummary(String docType) {
    for (final Map<String, dynamic> r in _seqs) {
      if (r['doc_type'] == docType && ((r['fy'] as num?)?.toInt() ?? 0) == 0) {
        return 'بعدی: ${DocNumbering.format((r['prefix'] ?? '').toString(), (r['next_no'] as num?)?.toInt() ?? 1, (r['padding'] as num?)?.toInt() ?? 5)}';
      }
    }
    return 'تنظیم نشده';
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('مشخصات شرکت و قالب فاکتور')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(padding: const EdgeInsets.all(16), children: <Widget>[
                const Text('مشخصات شرکت', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Row(children: <Widget>[
                  if (_logo.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: SizedBox(
                        width: 56,
                        height: 56,
                        child: Image.memory(base64Decode(_logo.substring(_logo.indexOf('base64,') + 7)), fit: BoxFit.contain),
                      ),
                    ),
                  OutlinedButton.icon(onPressed: _pickLogo, icon: const Icon(Icons.image_outlined), label: const Text('انتخاب لوگو')),
                  if (_logo.isNotEmpty)
                    TextButton(onPressed: () => setState(() => _logo = ''), child: const Text('حذف لوگو')),
                ]),
                const SizedBox(height: 12),
                for (final MapEntry<String, TextEditingController> e in _c.entries) textField(e.value, _labels[e.key] ?? e.key),
                FilledButton(onPressed: _saveProfile, child: const Text('ذخیرهٔ مشخصات')),
                const Divider(height: 32),
                const Text('قالب چاپ فاکتور', style: TextStyle(fontWeight: FontWeight.bold)),
                for (final InvTemplate t in InvTemplate.values)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(_tpl == t ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                    title: Text(kInvTemplateLabels[t] ?? t.name),
                    onTap: () => _chooseTemplate(t),
                  ),
                OutlinedButton.icon(onPressed: _preview, icon: const Icon(Icons.picture_as_pdf_outlined), label: const Text('پیش‌نمایش نمونه')),
                const Divider(height: 32),
                const Text('شماره‌گذاری اسناد', style: TextStyle(fontWeight: FontWeight.bold)),
                for (final MapEntry<String, String> e in kDocTypeLabels.entries)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(e.value),
                    subtitle: Text(_seqSummary(e.key)),
                    trailing: const Icon(Icons.edit_outlined),
                    onTap: () => _editSeq(e.key),
                  ),
              ]),
      ),
    );
  }
}
