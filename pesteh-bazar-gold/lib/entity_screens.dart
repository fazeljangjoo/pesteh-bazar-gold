import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'db.dart';
import 'entity_store.dart';
import 'party_field.dart';
import 'utils.dart';
import 'widgets.dart';

/// Display text of one field value (Persian digits, Jalali dates, enum labels).
String entityDisplay(EntityField f, Object? v) {
  if (v == null) return '';
  switch (f.type) {
    case 'bool':
      return v == true ? 'بله' : 'خیر';
    case 'date':
      try {
        return jalaliDate(v.toString());
      } catch (_) {
        return v.toString();
      }
    case 'int':
    case 'bigint':
      return v is num ? faNum(v, dec: 0) : v.toString();
    case 'decimal':
      return v is num ? faNum(v, dec: f.scale > 4 ? 4 : f.scale) : v.toString();
    case 'enum':
      return f.valueLabels[v.toString()] ?? v.toString();
    case 'json':
      return '';
  }
  return v.toString();
}

/// Generic list screen for any entity of [kEntityRegistry]: search, add, edit, delete, empty state.
class EntityListScreen extends StatefulWidget {
  final String entity;
  const EntityListScreen({super.key, required this.entity});

  @override
  State<EntityListScreen> createState() => _EntityListScreenState();
}

class _EntityListScreenState extends State<EntityListScreen> {
  final TextEditingController _q = TextEditingController();
  List<Map<String, dynamic>> _rows = <Map<String, dynamic>>[];
  bool _loading = true;
  int _gen = 0;

  EntitySpec? get _spec => kEntityRegistry[widget.entity];

  @override
  void initState() {
    super.initState();
    AppDb.I.version.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    AppDb.I.version.removeListener(_reload);
    _q.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final g = ++_gen;
    try {
      final r = await EntityStore.I.list(widget.entity, q: _q.text);
      if (!mounted || g != _gen) return;
      setState(() {
        _rows = r;
        _loading = false;
      });
    } catch (_) {
      if (mounted && g == _gen) setState(() => _loading = false);
    }
  }

  Future<void> _open([String? uid]) async {
    await Navigator.push(
        context, MaterialPageRoute<void>(builder: (_) => EntityFormScreen(entity: widget.entity, uid: uid)));
    _reload();
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    final ok = await confirm(context, 'این مورد حذف شود؟');
    if (!ok) return;
    try {
      await EntityStore.I.delete(widget.entity, row['uid'] as String);
      if (mounted) snack(context, 'حذف شد');
    } catch (e) {
      if (mounted) snack(context, friendlyError(e));
    }
  }

  Widget _tile(EntitySpec spec, Map<String, dynamic> row) {
    final lf = spec.listFields.isNotEmpty ? spec.listFields : spec.fields.map((f) => f.key).take(3).toList();
    String text(int i) {
      if (i >= lf.length) return '';
      final f = spec.field(lf[i]);
      return f == null ? '' : entityDisplay(f, row[lf[i]]);
    }

    final title = text(0);
    final sub = text(1);
    final trail = text(2);
    final pending = (row['rev'] as int? ?? 0) == 0;
    return ListTile(
      title: Text(title.isEmpty ? '—' : title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: sub.isEmpty ? null : Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis),
      leading: pending ? const Icon(Icons.cloud_upload_outlined, size: 18) : null,
      trailing: trail.isEmpty ? null : Text(trail),
      onTap: () => _open(row['uid'] as String),
      onLongPress: () => _delete(row),
    );
  }

  @override
  Widget build(BuildContext context) {
    final spec = _spec;
    if (spec == null) {
      return Scaffold(appBar: AppBar(title: const Text('بخش نامعتبر')), body: const SizedBox.shrink());
    }
    return Scaffold(
      appBar: AppBar(title: Text(spec.label)),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _open(),
        tooltip: 'افزودن',
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          if (spec.search.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: TextField(
                controller: _q,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'جستجو',
                  border: const OutlineInputBorder(),
                  suffixIcon: _q.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _q.clear();
                            _reload();
                          }),
                ),
                onChanged: (_) => _reload(),
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _rows.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _q.text.trim().isEmpty ? 'هنوز موردی ثبت نشده؛ با دکمهٔ + اضافه کنید' : 'موردی پیدا نشد',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: _rows.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) => _tile(spec, _rows[i]),
                      ),
          ),
        ],
      ),
    );
  }
}

/// Generic create/edit form built from the entity's field specs.
class EntityFormScreen extends StatefulWidget {
  final String entity;
  final String? uid;
  const EntityFormScreen({super.key, required this.entity, this.uid});

  @override
  State<EntityFormScreen> createState() => _EntityFormScreenState();
}

class _EntityFormScreenState extends State<EntityFormScreen> {
  final GlobalKey<FormState> _form = GlobalKey<FormState>();
  final Map<String, TextEditingController> _ctl = <String, TextEditingController>{};
  final Map<String, Object?> _vals = <String, Object?>{}; // bool/date/enum/ref values
  final Map<String, List<Map<String, dynamic>>> _refRows = <String, List<Map<String, dynamic>>>{};
  late final Object _editToken;
  bool _loading = true;
  bool _saving = false;

  EntitySpec? get _spec => kEntityRegistry[widget.entity];

  @override
  void initState() {
    super.initState();
    _editToken = AppDb.I.beginEdit(); // no pull from the server while the form is open
    _init();
  }

  @override
  void dispose() {
    AppDb.I.endEdit(_editToken);
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _init() async {
    final spec = _spec;
    if (spec == null) return;
    Map<String, dynamic> row = <String, dynamic>{};
    if (widget.uid != null) {
      row = await EntityStore.I.get(widget.entity, widget.uid!) ?? <String, dynamic>{};
    }
    final isNew = widget.uid == null;
    for (final f in spec.fields) {
      final v = isNew ? f.defaultValue : row[f.key];
      switch (f.type) {
        case 'string':
        case 'text':
          _ctl[f.key] = TextEditingController(text: v?.toString() ?? '');
          break;
        case 'int':
        case 'bigint':
        case 'decimal':
          _ctl[f.key] = TextEditingController(text: v is num ? plain(v) : '');
          break;
        case 'bool':
          _vals[f.key] = v == true;
          break;
        case 'date':
          _vals[f.key] = v == null ? null : DateTime.tryParse(v.toString());
          break;
        case 'enum':
          _vals[f.key] = (v is String && f.values.contains(v)) ? v : null;
          break;
        case 'ref':
          _vals[f.key] = v is String ? v : null;
          final rn = f.ref;
          if (rn != null && kEntityRegistry.containsKey(rn)) {
            _refRows[f.key] = await EntityStore.I.list(rn);
          }
          break;
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Map<String, dynamic> _collect(EntitySpec spec) {
    final data = <String, dynamic>{};
    for (final f in spec.fields) {
      switch (f.type) {
        case 'string':
        case 'text':
          data[f.key] = _ctl[f.key]?.text.trim();
          break;
        case 'int':
        case 'bigint':
        case 'decimal':
          final t = _ctl[f.key]?.text.trim() ?? '';
          data[f.key] = t.isEmpty ? null : parseNum(t);
          break;
        case 'bool':
          data[f.key] = _vals[f.key] == true;
          break;
        case 'date':
          final d = _vals[f.key];
          data[f.key] = d is DateTime ? _ymd(d) : null;
          break;
        case 'enum':
        case 'ref':
          data[f.key] = _vals[f.key];
          break;
      }
    }
    return data;
  }

  Future<void> _save() async {
    final spec = _spec;
    if (spec == null || _saving) return;
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      await EntityStore.I.save(widget.entity, _collect(spec), uid: widget.uid);
      if (!mounted) return;
      Navigator.pop(context);
    } on ArgumentError catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        snack(context, '${e.message}');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        snack(context, friendlyError(e));
      }
    }
  }

  Widget _field(EntityField f) {
    switch (f.type) {
      case 'string':
      case 'text':
        final c = _ctl[f.key]!;
        if (f.party) return PartyField(controller: c, label: f.label);
        return textField(c, f.label, lines: f.isLong ? 4 : 1, required: f.required);
      case 'int':
      case 'bigint':
      case 'decimal':
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextFormField(
            controller: _ctl[f.key],
            keyboardType: TextInputType.numberWithOptions(decimal: f.type == 'decimal', signed: (f.vmin ?? 0) < 0),
            inputFormatters: f.money ? <TextInputFormatter>[ThousandsInputFormatter()] : null,
            decoration: InputDecoration(labelText: f.label, border: const OutlineInputBorder()),
            validator: (v) {
              if ((v ?? '').trim().isEmpty) return f.required ? 'الزامی است' : null;
              final n = parseNum(v);
              if (n == null) return 'عدد معتبر وارد کنید';
              if (f.vmin != null && n < f.vmin!) return 'حداقل ${faNum(f.vmin!)}';
              if (f.vmax != null && n > f.vmax!) return 'حداکثر ${faNum(f.vmax!)}';
              if (f.type != 'decimal' && n != n.roundToDouble()) return 'عدد صحیح وارد کنید';
              return null;
            },
          ),
        );
      case 'bool':
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(f.label),
          value: _vals[f.key] == true,
          onChanged: (b) => setState(() => _vals[f.key] = b),
        );
      case 'date':
        final cur = _vals[f.key];
        return Row(
          children: [
            Expanded(
              child: dateField(context, f.label, cur is DateTime ? cur : null, (d) => setState(() => _vals[f.key] = d)),
            ),
            if (cur != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: IconButton(
                  tooltip: 'پاک کردن تاریخ',
                  icon: const Icon(Icons.clear),
                  onPressed: () => setState(() => _vals[f.key] = null),
                ),
              ),
          ],
        );
      case 'enum':
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: DropdownButtonFormField<String>(
            value: _vals[f.key] as String?,
            decoration: InputDecoration(labelText: f.label, border: const OutlineInputBorder()),
            items: f.values
                .map((v) => DropdownMenuItem<String>(value: v, child: Text(f.valueLabels[v] ?? v)))
                .toList(),
            onChanged: (v) => setState(() => _vals[f.key] = v),
            validator: (v) => (f.required && v == null) ? 'الزامی است' : null,
          ),
        );
      case 'ref':
        final rows = _refRows[f.key] ?? <Map<String, dynamic>>[];
        final target = f.ref == null ? null : kEntityRegistry[f.ref!];
        final titleKey = (target != null && target.listFields.isNotEmpty)
            ? target.listFields.first
            : (target != null && target.fields.isNotEmpty ? target.fields.first.key : 'uid');
        final cur = _vals[f.key] as String?;
        final has = rows.any((r) => r['uid'] == cur);
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: DropdownButtonFormField<String>(
            value: has ? cur : null,
            decoration: InputDecoration(labelText: f.label, border: const OutlineInputBorder()),
            items: rows
                .map((r) => DropdownMenuItem<String>(value: r['uid'] as String, child: Text('${r[titleKey] ?? '—'}')))
                .toList(),
            onChanged: (v) => setState(() => _vals[f.key] = v),
            validator: (v) => (f.required && v == null) ? 'الزامی است' : null,
          ),
        );
    }
    return const SizedBox.shrink(); // json and unknown types are not editable here
  }

  @override
  Widget build(BuildContext context) {
    final spec = _spec;
    if (spec == null) {
      return Scaffold(appBar: AppBar(title: const Text('بخش نامعتبر')), body: const SizedBox.shrink());
    }
    return Scaffold(
      appBar: AppBar(title: Text(widget.uid == null ? 'افزودن ${spec.label}' : 'ویرایش ${spec.label}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  for (final f in spec.fields) _field(f),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? 'در حال ذخیره…' : 'ذخیره'),
                  ),
                ],
              ),
            ),
    );
  }
}
