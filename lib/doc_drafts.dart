import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart' show Database;

import 'db.dart';
import 'utils.dart';
import 'widgets.dart';

/// S35.T35.9b — پیش‌نویس سند (فقط محلی، بدون هیچ اثر انباری/مالی).
/// پیش‌نویس یک عکس‌فوری از داده‌های فرم است؛ «ثبت نهایی» همان مسیر ثبتِ معمولی (insertPurchase) را اجرا می‌کند.
class DocDraftsLocal {
  DocDraftsLocal._();

  static Future<Database> _d() async {
    final Database d = await AppDb.I.db;
    await d.execute('''
      CREATE TABLE IF NOT EXISTS doc_drafts(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        doc_type TEXT NOT NULL,
        title TEXT NOT NULL,
        payload TEXT NOT NULL,
        created_at TEXT NOT NULL
      )''');
    return d;
  }

  static Future<int> save(String docType, String title, Map<String, dynamic> payload) async {
    final Database d = await _d();
    final Map<String, dynamic> clean = Map<String, dynamic>.from(payload)..remove('photo');
    return d.insert('doc_drafts', <String, Object?>{
      'doc_type': docType,
      'title': title,
      'payload': jsonEncode(clean),
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  static Future<List<Map<String, Object?>>> list(String docType) async {
    final Database d = await _d();
    return d.query('doc_drafts', where: 'doc_type = ?', whereArgs: <Object?>[docType], orderBy: 'id DESC');
  }

  static Future<void> delete(int id) async {
    final Database d = await _d();
    await d.delete('doc_drafts', where: 'id = ?', whereArgs: <Object?>[id]);
  }

  static Map<String, dynamic> decode(Map<String, Object?> row) =>
      Map<String, dynamic>.from(jsonDecode(row['payload'] as String) as Map<dynamic, dynamic>);
}

/// لیست پیش‌نویس‌های خرید یا فروش (docType = purchase | sale) با «ثبت نهایی» و حذف.
class DraftsScreen extends StatefulWidget {
  const DraftsScreen({super.key, required this.docType});
  final String docType;

  @override
  State<DraftsScreen> createState() => _DraftsScreenState();
}

class _DraftsScreenState extends State<DraftsScreen> {
  List<Map<String, Object?>> _rows = <Map<String, Object?>>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final List<Map<String, Object?>> r = await DocDraftsLocal.list(widget.docType);
    if (!mounted) return;
    setState(() {
      _rows = r;
      _loading = false;
    });
  }

  Future<void> _finalize(Map<String, Object?> row) async {
    if (!await confirm(context, 'این پیش‌نویس به‌صورت نهایی ثبت شود؟ موجودی انبار و حساب‌ها تغییر می‌کند.')) return;
    final Map<String, dynamic> data = DocDraftsLocal.decode(row);
    try {
      if (widget.docType == 'sale') {
        final Map<String, dynamic> sale = Map<String, dynamic>.from(data['sale'] as Map<dynamic, dynamic>);
        final List<Map<String, dynamic>> items = (data['items'] as List<dynamic>)
            .map((dynamic e) => Map<String, dynamic>.from(e as Map<dynamic, dynamic>))
            .toList();
        sale['date'] = DateTime.now().toIso8601String();
        await AppDb.I.insertSale(sale, items);
      } else {
        data['date'] = DateTime.now().toIso8601String();
        await AppDb.I.insertPurchase(data);
      }
      await DocDraftsLocal.delete(row['id'] as int);
      if (mounted) snack(context, 'پیش‌نویس به‌صورت نهایی ثبت شد');
    } catch (e) {
      if (mounted) snack(context, 'ثبت نهایی انجام نشد: $e');
    }
    await _load();
  }

  Future<void> _remove(Map<String, Object?> row) async {
    if (!await confirm(context, 'این پیش‌نویس حذف شود؟')) return;
    await DocDraftsLocal.delete(row['id'] as int);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.docType == 'sale' ? 'پیش‌نویس‌های فروش' : 'پیش‌نویس‌های خرید')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _rows.isEmpty
              ? const Center(child: Text('پیش‌نویسی وجود ندارد'))
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: <Widget>[
                    for (final Map<String, Object?> r in _rows)
                      Card(
                        child: ListTile(
                          title: Text('${r['title']}'),
                          subtitle: Text('ذخیره: ${jalaliDate('${r['created_at']}')}'),
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
                            IconButton(tooltip: 'ثبت نهایی', icon: const Icon(Icons.check_circle_outline), onPressed: () => _finalize(r)),
                            IconButton(tooltip: 'حذف', icon: const Icon(Icons.delete_outline), onPressed: () => _remove(r)),
                          ]),
                        ),
                      ),
                  ],
                ),
    );
  }
}
