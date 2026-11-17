import 'package:flutter/material.dart';

import 'utils.dart';
import 'warehouse_ui.dart' show StockApi;
import 'widgets.dart';

/// S15.T15.2 — chart of accounts, tafsili and role mapping (gold). Online via StockApi.
const Map<String, String> _kTypeFa = <String, String>{
  'asset': 'دارایی',
  'liability': 'بدهی',
  'equity': 'حقوق صاحبان سرمایه',
  'revenue': 'درآمد',
  'expense': 'هزینه',
  'memo': 'انتظامی',
};
const Map<String, String> _kKindFa = <String, String>{
  'party': 'طرف‌حساب',
  'bank': 'بانک',
  'cash': 'صندوق',
  'employee': 'کارمند',
  'cost_center': 'مرکز هزینه',
  'other': 'سایر',
};

List<Map<String, dynamic>> _items(Map<String, dynamic> r) {
  final dynamic v = r['items'];
  final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
  if (v is List) {
    for (final dynamic x in v) {
      if (x is Map) out.add(Map<String, dynamic>.from(x));
    }
  }
  return out;
}

class AccountsScreen extends StatelessWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: DefaultTabController(
        length: 3,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('سرفصل حساب‌ها'),
            bottom: const TabBar(tabs: <Tab>[Tab(text: 'حساب‌ها'), Tab(text: 'تفصیلی'), Tab(text: 'نقش‌ها')]),
          ),
          body: const TabBarView(children: <Widget>[_AccountsTab(), _TafsiliTab(), _RolesTab()]),
        ),
      ),
    );
  }
}

class _AccountsTab extends StatefulWidget {
  const _AccountsTab();

  @override
  State<_AccountsTab> createState() => _AccountsTabState();
}

class _AccountsTabState extends State<_AccountsTab> with AutomaticKeepAliveClientMixin<_AccountsTab> {
  List<Map<String, dynamic>> _rows = <Map<String, dynamic>>[];
  bool _loading = true;
  String? _err;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _call('accounts.list');
  }

  Future<void> _call(String action, [Map<String, dynamic> p = const <String, dynamic>{}]) async {
    try {
      final Map<String, dynamic> r = await StockApi.call(action, p);
      _rows = _items(r);
      _err = null;
    } catch (e) {
      if (_loading) {
        _err = e.toString();
      } else if (mounted) {
        snack(context, e.toString());
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _edit(Map<String, dynamic>? a, {int? level, int? parentId, String? type}) async {
    final bool isSys = a != null && a['is_system'] == true;
    final TextEditingController code = TextEditingController(text: a == null ? '' : a['code'].toString());
    final TextEditingController name = TextEditingController(text: a == null ? '' : a['name'].toString());
    String t = a == null ? (type ?? 'asset') : a['type'].toString();
    String nature = a == null ? (t == 'liability' || t == 'equity' || t == 'revenue' ? 'credit' : 'debit') : a['nature'].toString();
    bool active = a == null ? true : a['active'] == true;
    final int lv = a == null ? (level ?? 1) : (a['level'] as num).toInt();
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter set) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: Text(a == null ? 'حساب جدید (سطح ${faNum(lv, dec: 0)})' : 'ویرایش حساب ${a['code']}'),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
                TextField(controller: code, enabled: !isSys, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'کد')),
                TextField(controller: name, decoration: const InputDecoration(labelText: 'نام حساب')),
                if (!isSys && lv == 1)
                  DropdownButtonFormField<String>(
                    value: t,
                    decoration: const InputDecoration(labelText: 'نوع'),
                    items: <DropdownMenuItem<String>>[
                      for (final MapEntry<String, String> e in _kTypeFa.entries) DropdownMenuItem<String>(value: e.key, child: Text(e.value)),
                    ],
                    onChanged: (String? v) => set(() => t = v ?? t),
                  ),
                if (!isSys)
                  DropdownButtonFormField<String>(
                    value: nature,
                    decoration: const InputDecoration(labelText: 'ماهیت'),
                    items: const <DropdownMenuItem<String>>[
                      DropdownMenuItem<String>(value: 'debit', child: Text('بدهکار')),
                      DropdownMenuItem<String>(value: 'credit', child: Text('بستانکار')),
                    ],
                    onChanged: (String? v) => set(() => nature = v ?? nature),
                  ),
                SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('فعال'), value: active, onChanged: (bool v) => set(() => active = v)),
                if (isSys) const Text('حساب سیستمی: فقط نام و وضعیت قابل ویرایش است.', style: TextStyle(fontSize: 12)),
              ]),
            ),
            actions: <Widget>[
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ذخیره')),
            ],
          ),
        ),
      ),
    );
    if (ok != true) return;
    await _call('accounts.save', <String, dynamic>{
      if (a != null) 'id': a['id'],
      'code': code.text.trim(),
      'name': name.text.trim(),
      'level': lv,
      if (a == null && parentId != null) 'parent_id': parentId,
      'type': t,
      'nature': nature,
      'active': active,
    });
  }

  Future<void> _delete(Map<String, dynamic> a) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text('حذف حساب ${a['code']}؟'),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('حذف')),
          ],
        ),
      ),
    );
    if (ok == true) await _call('accounts.delete', <String, dynamic>{'id': a['id']});
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_err != null) return Center(child: Text(_err!));
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'accNewGroup',
        onPressed: () => _edit(null, level: 1),
        icon: const Icon(Icons.add),
        label: const Text('گروه جدید'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 88),
        children: <Widget>[
          for (final Map<String, dynamic> a in _rows)
            ListTile(
              dense: true,
              contentPadding: EdgeInsetsDirectional.only(start: 12.0 + 18.0 * ((a['level'] as num).toInt() - 1), end: 4),
              leading: Icon(a['is_system'] == true ? Icons.lock_outline : Icons.account_tree_outlined, size: 18),
              title: Text('${a['code']}  ${a['name']}',
                  style: TextStyle(fontWeight: (a['level'] as num).toInt() == 1 ? FontWeight.bold : FontWeight.normal, color: a['active'] == true ? null : Colors.grey)),
              subtitle: Text('${_kTypeFa[a['type']] ?? a['type']} · ${a['nature'] == 'debit' ? 'بدهکار' : 'بستانکار'}'),
              onTap: () => _edit(a),
              trailing: PopupMenuButton<String>(
                onSelected: (String v) {
                  if (v == 'child') {
                    _edit(null, level: (a['level'] as num).toInt() + 1, parentId: (a['id'] as num).toInt(), type: a['type'].toString());
                  } else if (v == 'del') {
                    _delete(a);
                  }
                },
                itemBuilder: (BuildContext c) => <PopupMenuEntry<String>>[
                  if ((a['level'] as num).toInt() < 3) const PopupMenuItem<String>(value: 'child', child: Text('افزودن زیرحساب')),
                  if (a['is_system'] != true) const PopupMenuItem<String>(value: 'del', child: Text('حذف')),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _TafsiliTab extends StatefulWidget {
  const _TafsiliTab();

  @override
  State<_TafsiliTab> createState() => _TafsiliTabState();
}

class _TafsiliTabState extends State<_TafsiliTab> with AutomaticKeepAliveClientMixin<_TafsiliTab> {
  List<Map<String, dynamic>> _rows = <Map<String, dynamic>>[];
  bool _loading = true;
  String? _err;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _call('tafsili.list');
  }

  Future<void> _call(String action, [Map<String, dynamic> p = const <String, dynamic>{}]) async {
    try {
      _rows = _items(await StockApi.call(action, p));
      _err = null;
    } catch (e) {
      if (_loading) {
        _err = e.toString();
      } else if (mounted) {
        snack(context, e.toString());
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _add() async {
    final TextEditingController name = TextEditingController();
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('تفصیلی جدید'),
          content: TextField(controller: name, decoration: const InputDecoration(labelText: 'نام')),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ذخیره')),
          ],
        ),
      ),
    );
    if (ok == true) await _call('tafsili.save', <String, dynamic>{'kind': 'other', 'name': name.text.trim()});
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_err != null) return Center(child: Text(_err!));
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'tafAdd',
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('تفصیلی'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 88),
        children: <Widget>[
          ListTile(
            leading: const Icon(Icons.sync),
            title: const Text('همگام‌سازی از طرف‌حساب‌ها و کارمندان'),
            onTap: () async {
              await _call('tafsili.sync');
            },
          ),
          for (final Map<String, dynamic> r in _rows)
            ListTile(
              dense: true,
              title: Text('${r['code']}  ${r['name']}', style: TextStyle(color: r['active'] == true ? null : Colors.grey)),
              subtitle: Text(_kKindFa[r['kind']] ?? r['kind'].toString()),
              trailing: r['kind'] == 'other'
                  ? IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _call('tafsili.delete', <String, dynamic>{'id': r['id']}))
                  : null,
            ),
        ],
      ),
    );
  }
}

class _RolesTab extends StatefulWidget {
  const _RolesTab();

  @override
  State<_RolesTab> createState() => _RolesTabState();
}

class _RolesTabState extends State<_RolesTab> with AutomaticKeepAliveClientMixin<_RolesTab> {
  List<Map<String, dynamic>> _roles = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _accts = <Map<String, dynamic>>[];
  bool _loading = true;
  String? _err;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _roles = _items(await StockApi.call('accounts.roles'));
      final List<Map<String, dynamic>> all = _items(await StockApi.call('accounts.list'));
      _accts = all.where((Map<String, dynamic> a) => a['level'] == 3 && a['active'] == true).toList();
      _err = null;
    } catch (e) {
      _err = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _pick(Map<String, dynamic> role) async {
    final int? id = await showDialog<int>(
      context: context,
      builder: (BuildContext ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SimpleDialog(
          title: Text(role['label'].toString()),
          children: <Widget>[
            SizedBox(
              width: double.maxFinite,
              height: 360,
              child: ListView(children: <Widget>[
                for (final Map<String, dynamic> a in _accts)
                  SimpleDialogOption(onPressed: () => Navigator.pop(ctx, (a['id'] as num).toInt()), child: Text('${a['code']}  ${a['name']}')),
              ]),
            ),
          ],
        ),
      ),
    );
    if (id == null) return;
    try {
      await StockApi.call('accounts.roles_save', <String, dynamic>{
        'map': <String, dynamic>{role['role'].toString(): id},
      });
      await _load();
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_err != null) return Center(child: Text(_err!));
    final Map<int, String> byId = <int, String>{for (final Map<String, dynamic> a in _accts) (a['id'] as num).toInt(): '${a['code']}  ${a['name']}'};
    return ListView(
      children: <Widget>[
        for (final Map<String, dynamic> r in _roles)
          ListTile(
            dense: true,
            title: Text(r['label'].toString()),
            subtitle: Text(r['account_id'] == null ? 'نگاشت نشده' : (byId[(r['account_id'] as num).toInt()] ?? 'حساب #${r['account_id']}')),
            trailing: const Icon(Icons.edit_outlined, size: 18),
            onTap: () => _pick(r),
          ),
      ],
    );
  }
}
