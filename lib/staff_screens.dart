import 'package:flutter/material.dart';

import 'edition.dart';
import 'fiscal_ui.dart';
import 'perms.dart';
import 'warehouse_ui.dart';
import 'widgets.dart';

/// T02.2 — کارکنان و نقش‌ها. فقط برای مالک یا کارکنی که users.manage دارد.
/// آنلاین از طریق StockApi (app.php → staff.* / roles.*). سرور مجوز را دوباره بررسی می‌کند.

List<Map<String, dynamic>> _mapList(dynamic raw) {
  final out = <Map<String, dynamic>>[];
  if (raw is List) {
    for (final x in raw) {
      if (x is Map) out.add(Map<String, dynamic>.from(x));
    }
  }
  return out;
}

List<String> _strs(dynamic raw) => raw is List ? raw.whereType<String>().toList() : <String>[];

String _errText(Object e) => e.toString().replaceFirst('Exception: ', '');

// ======================= فهرست کارکنان =======================

class StaffUsersScreen extends StatefulWidget {
  const StaffUsersScreen({super.key});

  @override
  State<StaffUsersScreen> createState() => _StaffUsersScreenState();
}

class _StaffUsersScreenState extends State<StaffUsersScreen> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final r = await StockApi.call('staff.list');
    return _mapList(r['items']);
  }

  void _refresh() {
    setState(() {
      _future = _load();
    });
  }

  Future<void> _openForm([Map<String, dynamic>? staff]) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute<bool>(builder: (_) => StaffFormScreen(staff: staff)),
    );
    if (changed == true) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('کارکنان'),
        actions: <Widget>[
          IconButton(
            tooltip: 'نقش‌ها و مجوزها',
            icon: const Icon(Icons.admin_panel_settings_outlined),
            onPressed: () {
              Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const RolesScreen()))
                  .then((_) => _refresh());
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(),
        icon: const Icon(Icons.person_add_alt_1_outlined),
        label: const Text('کارکن جدید'),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (BuildContext ctx, AsyncSnapshot<List<Map<String, dynamic>>> snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(padding: const EdgeInsets.all(16), child: Text(_errText(snap.error!))),
            );
          }
          final items = snap.data ?? const <Map<String, dynamic>>[];
          if (items.isEmpty) return const Center(child: Text('هنوز کارکنی ثبت نشده است'));
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: items.length,
            itemBuilder: (BuildContext c, int i) {
              final s = items[i];
              final active = s['active'] == true;
              return Card(
                elevation: 0,
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Icon(
                    active ? Icons.person_outline : Icons.person_off_outlined,
                    color: active ? null : Colors.grey,
                  ),
                  title: Text((s['name'] ?? '').toString()),
                  subtitle: Text(
                    '${s['username']} • نقش: ${s['role_name'] ?? '-'}${active ? '' : ' • غیرفعال'}',
                  ),
                  onTap: () => _openForm(s),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// ======================= فرم کارکن (ایجاد / ویرایش / تغییر رمز) =======================

class StaffFormScreen extends StatefulWidget {
  final Map<String, dynamic>? staff; // null = کارکن جدید

  const StaffFormScreen({super.key, this.staff});

  @override
  State<StaffFormScreen> createState() => _StaffFormScreenState();
}

class _StaffFormScreenState extends State<StaffFormScreen> {
  final TextEditingController _username = TextEditingController();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _pass = TextEditingController();
  List<Map<String, dynamic>> _roles = <Map<String, dynamic>>[];
  int? _roleId;
  bool _active = true;
  Set<int>? _fyIds; // S15.T15.4: null = all fiscal years (gold only)
  bool _loading = true;
  bool _busy = false;
  String? _error;

  bool get _isNew => widget.staff == null;

  @override
  void initState() {
    super.initState();
    final s = widget.staff;
    if (s != null) {
      _username.text = (s['username'] ?? '').toString();
      _name.text = (s['name'] ?? '').toString();
      _roleId = (s['role_id'] as num?)?.toInt();
      _active = s['active'] == true;
      final dynamic fy = s['allowed_fy_ids'];
      if (fy is List) _fyIds = fy.whereType<num>().map((num n) => n.toInt()).toSet();
    }
    if (EditionService.I.edition.isGold) FiscalService.I.refresh();
    _loadRoles();
  }

  @override
  void dispose() {
    _username.dispose();
    _name.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _loadRoles() async {
    try {
      final r = await StockApi.call('roles.list');
      if (!mounted) return;
      final roles = _mapList(r['items']);
      setState(() {
        _roles = roles;
        _roleId ??= roles.isEmpty ? null : (roles.first['id'] as num).toInt();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _errText(e);
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    final username = _username.text.trim();
    final name = _name.text.trim();
    if (username.isEmpty) {
      setState(() => _error = 'نام کاربری را وارد کنید');
      return;
    }
    if (name.isEmpty) {
      setState(() => _error = 'نام کارکن را وارد کنید');
      return;
    }
    if (_roleId == null) {
      setState(() => _error = 'نقش را انتخاب کنید');
      return;
    }
    final payload = <String, dynamic>{
      if (!_isNew) 'id': (widget.staff!['id'] as num).toInt(),
      'username': username,
      'name': name,
      'role_id': _roleId,
      'active': _active,
      if (EditionService.I.edition.isGold) 'allowed_fy_ids': _fyIds?.toList(),
      if (_pass.text.isNotEmpty) 'password': _pass.text,
    };
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await StockApi.call('staff.save', payload);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _errText(e);
      });
    }
  }

  Future<void> _delete() async {
    final s = widget.staff;
    if (s == null) return;
    if (!await confirm(context, 'کارکن «${s['name']}» حذف شود؟ نشست‌های فعالش هم بی‌اعتبار می‌شود.')) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await StockApi.call('staff.delete', <String, dynamic>{'id': (s['id'] as num).toInt()});
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _errText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isNew ? 'کارکن جدید' : 'ویرایش کارکن')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                TextField(
                  controller: _username,
                  enabled: !_busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLength: 60,
                  textDirection: TextDirection.ltr,
                  decoration: const InputDecoration(
                    labelText: 'نام کاربری (انگلیسی)',
                    counterText: '',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _name,
                  enabled: !_busy,
                  maxLength: 120,
                  decoration: const InputDecoration(
                    labelText: 'نام و نام خانوادگی',
                    counterText: '',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  value: _roleId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'نقش', border: OutlineInputBorder()),
                  items: _roles
                      .map((Map<String, dynamic> r) => DropdownMenuItem<int>(
                            value: (r['id'] as num).toInt(),
                            child: Text((r['name'] ?? '').toString()),
                          ))
                      .toList(),
                  onChanged: _busy ? null : (int? v) => setState(() => _roleId = v),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pass,
                  enabled: !_busy,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLength: 200,
                  textDirection: TextDirection.ltr,
                  decoration: InputDecoration(
                    labelText: _isNew ? 'رمز اولیه (حداقل ۶ نویسه)' : 'رمز جدید (برای تغییر، خالی بگذارید)',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.lock_outline),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('فعال'),
                  subtitle: const Text('غیرفعال‌کردن، ورود و نشست‌های فعلی این کارکن را قطع می‌کند'),
                  value: _active,
                  onChanged: _busy ? null : (bool v) => setState(() => _active = v),
                ),
                if (EditionService.I.edition.isGold) ...<Widget>[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('دسترسی به همهٔ سال‌های مالی'),
                    value: _fyIds == null,
                    onChanged: _busy
                        ? null
                        : (bool v) => setState(() => _fyIds = v ? null : <int>{}),
                  ),
                  if (_fyIds != null)
                    ValueListenableBuilder<List<FiscalYear>>(
                      valueListenable: FiscalService.I.years,
                      builder: (BuildContext c, List<FiscalYear> ys, Widget? _) => Column(children: <Widget>[
                        for (final FiscalYear y in ys)
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text('${y.name} (${y.statusFa})'),
                            value: _fyIds!.contains(y.id),
                            onChanged: _busy
                                ? null
                                : (bool? v) => setState(() {
                                      if (v == true) {
                                        _fyIds!.add(y.id);
                                      } else {
                                        _fyIds!.remove(y.id);
                                      }
                                    }),
                          ),
                      ]),
                    ),
                ],
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(_error!, style: TextStyle(color: Colors.red.shade700)),
                  ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: _busy ? null : _save,
                  child: Text(_busy ? 'در حال ذخیره…' : 'ذخیره'),
                ),
                if (!_isNew) ...<Widget>[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _busy ? null : _delete,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('حذف کارکن'),
                  ),
                ],
              ],
            ),
    );
  }
}

// ======================= نقش‌ها =======================

class RolesScreen extends StatefulWidget {
  const RolesScreen({super.key});

  @override
  State<RolesScreen> createState() => _RolesScreenState();
}

class _RolesScreenState extends State<RolesScreen> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final r = await StockApi.call('roles.list');
    return _mapList(r['items']);
  }

  Future<void> _open([Map<String, dynamic>? role]) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute<bool>(builder: (_) => RoleEditScreen(role: role)),
    );
    if (changed == true) {
      setState(() {
        _future = _load();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('نقش‌ها و مجوزها')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _open(),
        icon: const Icon(Icons.add),
        label: const Text('نقش جدید'),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (BuildContext ctx, AsyncSnapshot<List<Map<String, dynamic>>> snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(_errText(snap.error!))));
          }
          final items = snap.data ?? const <Map<String, dynamic>>[];
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: items.length,
            itemBuilder: (BuildContext c, int i) {
              final r = items[i];
              final n = _strs(r['perms']).length;
              final sys = r['is_system'] == true;
              return Card(
                elevation: 0,
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  title: Text((r['name'] ?? '').toString()),
                  subtitle: Text('$n مجوز${sys ? ' • پیش‌فرض' : ''}'),
                  onTap: () => _open(r),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// ویرایش نقش: نام + ماتریس مجوز گروه‌بندی‌شده. کارکن فقط مجوزهایی را که خودش دارد می‌تواند تیک بزند.
class RoleEditScreen extends StatefulWidget {
  final Map<String, dynamic>? role; // null = نقش جدید

  const RoleEditScreen({super.key, this.role});

  @override
  State<RoleEditScreen> createState() => _RoleEditScreenState();
}

class _RoleEditScreenState extends State<RoleEditScreen> {
  final TextEditingController _name = TextEditingController();
  final Set<String> _perms = <String>{};
  List<String> _catalog = <String>[];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final role = widget.role;
    if (role != null) {
      _name.text = (role['name'] ?? '').toString();
      _perms.addAll(_strs(role['perms']));
    }
    _loadCatalog();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _loadCatalog() async {
    try {
      final r = await StockApi.call('roles.list');
      if (!mounted) return;
      setState(() {
        _catalog = _strs(r['catalog']);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _errText(e);
        _loading = false;
      });
    }
  }

  Widget _matrix() {
    final groups = <String, List<String>>{};
    for (final String k in _catalog) {
      final mod = k.split('.').first;
      groups.putIfAbsent(mod, () => <String>[]).add(k);
    }
    final children = <Widget>[];
    groups.forEach((String mod, List<String> keys) {
      children.add(Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 2),
        child: Text(kModuleLabels[mod] ?? mod, style: const TextStyle(fontWeight: FontWeight.w700)),
      ));
      for (final String k in keys) {
        // کارکن فقط مجوزهایی را که خودش دارد می‌تواند به نقش بدهد
        final allowed = StaffPerms.I.can(k);
        children.add(CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.trailing,
          title: Text(kPermLabels[k] ?? k),
          value: _perms.contains(k),
          onChanged: (_busy || !allowed)
              ? null
              : (bool? v) {
                  setState(() {
                    if (v == true) {
                      _perms.add(k);
                    } else {
                      _perms.remove(k);
                    }
                  });
                },
        ));
      }
    });
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'نام نقش را وارد کنید');
      return;
    }
    final payload = <String, dynamic>{
      if (widget.role != null) 'id': (widget.role!['id'] as num).toInt(),
      'name': name,
      'perms': _perms.toList(),
    };
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await StockApi.call('roles.save', payload);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _errText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.role == null ? 'نقش جدید' : 'ویرایش نقش')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                TextField(
                  controller: _name,
                  enabled: !_busy,
                  maxLength: 100,
                  decoration: const InputDecoration(labelText: 'نام نقش', counterText: '', border: OutlineInputBorder()),
                ),
                _matrix(),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(_error!, style: TextStyle(color: Colors.red.shade700)),
                  ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _busy ? null : _save,
                  child: Text(_busy ? 'در حال ذخیره…' : 'ذخیره نقش'),
                ),
              ],
            ),
    );
  }
}
