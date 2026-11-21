import 'package:flutter/material.dart';

import 'db.dart';
import 'perms.dart';
import 'widgets.dart' show confirm;

/// v83 — مدیریت دسته‌ها و انواع پسته (فهرست مشترک خرید، اتاق انس، کوت و کارگاه). فایل مشترک اندروید و ویندوز.
/// افزودن، تغییر نام و حذف دسته و نوع؛ آفلاین در صف همگام‌سازی (categories.* / types.*).
/// حذف دسته فقط وقتی دستهٔ پیش‌فرض نیست و لاتی در آن ثبت نشده؛ حذف نوع فقط از فهرست انتخاب (نام روی لات‌های ثبت‌شده می‌ماند).
class CatalogManageScreen extends StatefulWidget {
  const CatalogManageScreen({super.key});

  @override
  State<CatalogManageScreen> createState() => _CatalogManageScreenState();
}

class _CatalogManageScreenState extends State<CatalogManageScreen> {
  List<Map<String, dynamic>> _cats = <Map<String, dynamic>>[];
  final Map<int, List<String>> _types = <int, List<String>>{};
  bool _loading = true;

  bool get _can => StaffPerms.I.can('catalog.manage');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final List<Map<String, dynamic>> cats = await AppDb.I.categories();
    _types.clear();
    for (final Map<String, dynamic> c in cats) {
      final int id = (c['id'] as num).toInt();
      _types[id] = <String>{for (final Map<String, dynamic> t in await AppDb.I.typesOf(id)) '${t['name']}'}.toList();
    }
    if (!mounted) return;
    setState(() {
      _cats = cats;
      _loading = false;
    });
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<String?> _ask(String title, {String initial = ''}) async {
    final TextEditingController c = TextEditingController(text: initial);
    final String? r = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(title),
        content: TextField(controller: c, autofocus: true, maxLength: 100, decoration: const InputDecoration(labelText: 'نام', border: OutlineInputBorder())),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('ذخیره')),
        ],
      ),
    );
    c.dispose();
    return (r == null || r.isEmpty) ? null : r;
  }

  Future<void> _run(Future<void> Function() f, String ok) async {
    try {
      await f();
      if (!mounted) return;
      _snack(ok);
      await _load();
    } catch (e) {
      if (mounted) _snack('$e'.replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _addCat() async {
    final String? n = await _ask('دستهٔ تازه');
    if (n != null) await _run(() => AppDb.I.addCategory(n), 'دستهٔ «$n» اضافه شد');
  }

  Future<void> _renameCat(Map<String, dynamic> c) async {
    final String? n = await _ask('نام تازهٔ دسته', initial: '${c['name']}');
    if (n != null) await _run(() => AppDb.I.renameCategory((c['id'] as num).toInt(), n), 'نام دسته عوض شد');
  }

  Future<void> _deleteCat(Map<String, dynamic> c) async {
    if (!await confirm(context, 'دستهٔ «${c['name']}» و انواعش حذف شود؟')) return;
    await _run(() => AppDb.I.deleteCategory((c['id'] as num).toInt()), 'دسته حذف شد');
  }

  Future<void> _addType(Map<String, dynamic> c) async {
    final String? n = await _ask('نوع تازه برای «${c['name']}»');
    if (n == null) return;
    final int id = (c['id'] as num).toInt();
    if ((_types[id] ?? const <String>[]).contains(n)) return _snack('این نوع از قبل هست');
    await _run(() async => AppDb.I.addType(id, n), 'نوع «$n» اضافه شد');
  }

  Future<void> _renameType(Map<String, dynamic> c, String t) async {
    final String? n = await _ask('نام تازهٔ نوع «$t»', initial: t);
    if (n != null && n != t) await _run(() => AppDb.I.renameType((c['id'] as num).toInt(), t, n), 'نام نوع عوض شد');
  }

  Future<void> _deleteType(Map<String, dynamic> c, String t) async {
    if (!await confirm(context, 'نوع «$t» از فهرست حذف شود؟ (لات‌های ثبت‌شده نامشان را نگه می‌دارند)')) return;
    await _run(() => AppDb.I.deleteType((c['id'] as num).toInt(), t), 'نوع حذف شد');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('دسته‌ها و انواع پسته')),
      floatingActionButton: _can ? FloatingActionButton.extended(onPressed: _addCat, icon: const Icon(Icons.add), label: const Text('دستهٔ تازه')) : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 88), children: <Widget>[
              const Text('همین فهرست در خرید، اتاق انس، کوت‌ریزی و کارگاه استفاده می‌شود. تغییر نام روی لات‌های ثبت‌شده اثری ندارد.'),
              if (!_can) const Padding(padding: EdgeInsets.only(top: 6), child: Text('ویرایش نیاز به مجوز «مدیریت دسته‌ها» دارد.', style: TextStyle(color: Colors.orange))),
              for (final Map<String, dynamic> c in _cats)
                Card(
                  child: ExpansionTile(
                    title: Text('${c['name']}${c['preset_key'] == null ? '' : '  (پیش‌فرض)'}'),
                    subtitle: Text('${(_types[(c['id'] as num).toInt()] ?? const <String>[]).length} نوع'),
                    trailing: _can
                        ? Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
                            IconButton(tooltip: 'تغییر نام دسته', icon: const Icon(Icons.edit_outlined), onPressed: () => _renameCat(c)),
                            if (c['preset_key'] == null) IconButton(tooltip: 'حذف دسته', icon: const Icon(Icons.delete_outline), onPressed: () => _deleteCat(c)),
                          ])
                        : null,
                    children: <Widget>[
                      for (final String t in _types[(c['id'] as num).toInt()] ?? const <String>[])
                        ListTile(
                          dense: true,
                          title: Text(t),
                          trailing: _can
                              ? Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
                                  IconButton(tooltip: 'تغییر نام نوع', icon: const Icon(Icons.edit_outlined, size: 20), onPressed: () => _renameType(c, t)),
                                  IconButton(tooltip: 'حذف نوع', icon: const Icon(Icons.delete_outline, size: 20), onPressed: () => _deleteType(c, t)),
                                ])
                              : null,
                        ),
                      if (_can)
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: TextButton.icon(onPressed: () => _addType(c), icon: const Icon(Icons.add), label: const Text('نوع تازه')),
                        ),
                    ],
                  ),
                ),
            ]),
    );
  }
}
