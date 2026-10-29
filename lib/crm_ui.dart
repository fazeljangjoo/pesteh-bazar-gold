import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'db.dart';
import 'entity_store.dart';
import 'notify_service.dart';
import 'party_master_screen.dart';
import 'party_statement_screen.dart';
import 'perms.dart';
import 'utils.dart';
import 'warehouse_ui.dart';

/// T03.4 — CRM: یادداشت‌ها و پیگیری‌های هر طرف‌حساب (آفلاین، از طریق EntityStore: crm_notes / crm_tasks)،
/// داشبورد CRM (آنلاین: crm.dashboard) و فهرست طرف‌حساب‌ها با فیلتر برچسب/مرحله.

const Map<String, String> kPartyStagesFa = <String, String>{
  'lead': 'سرنخ',
  'active': 'فعال',
  'inactive': 'غیرفعال',
  'lost': 'از دست رفته',
};

const Map<String, String> kCrmKindsFa = <String, String>{
  'call': 'تماس',
  'visit': 'بازدید',
  'message': 'پیام',
  'other': 'سایر',
};

String crmDateIso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String _two(int v) => v.toString().padLeft(2, '0');

DateTime? _parseDt(Object? v) {
  if (v == null) return null;
  final String s = v.toString().trim();
  if (s.isEmpty) return null;
  return DateTime.tryParse(s.replaceFirst(' ', 'T'));
}

String _dueText(Object? v) {
  final DateTime? d = _parseDt(v);
  if (d == null) return 'بدون موعد';
  final String t = (d.hour == 0 && d.minute == 0) ? '' : ' ${faNum(d.hour, dec: 0)}:${_two(d.minute)}';
  return '${jalaliDateFromDt(d)}$t';
}

bool _truthy(Object? v) => v == true || v == 1 || v == '1';

Future<void> crmLaunch(BuildContext context, String scheme, String phone) async {
  final String p = phone.trim();
  if (p.isEmpty) return;
  bool ok = false;
  try {
    ok = await launchUrl(Uri(scheme: scheme, path: p));
  } catch (_) {
    ok = false;
  }
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('امکان باز کردن برنامه نیست')));
  }
}

// ============================ party CRM screen ============================

class PartyCrmScreen extends StatefulWidget {
  final String partyName;
  const PartyCrmScreen({super.key, required this.partyName});

  @override
  State<PartyCrmScreen> createState() => _PartyCrmScreenState();
}

class _PartyCrmScreenState extends State<PartyCrmScreen> {
  String _phone = '';
  String _stage = '';
  List<String> _tags = <String>[];

  @override
  void initState() {
    super.initState();
    _loadParty();
  }

  Future<void> _loadParty() async {
    try {
      final Map<String, dynamic> r = await StockApi.call('parties.list');
      final Object? raw = r['items'];
      if (raw is List) {
        for (final Object? x in raw) {
          if (x is Map && (x['key'] ?? '').toString() == widget.partyName) {
            if (!mounted) return;
            setState(() {
              _phone = (x['phone'] ?? '').toString();
              _stage = (x['stage'] ?? '').toString();
              final Object? t = x['tags'];
              _tags = t is List ? t.map((Object? e) => '$e').toList() : <String>[];
            });
            break;
          }
        }
      }
    } catch (_) {
      // آفلاین: فقط یادداشت‌ها و پیگیری‌ها
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool canEdit = StaffPerms.I.can('crm.edit');
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.partyName),
          actions: <Widget>[
            if (_phone.isNotEmpty)
              IconButton(tooltip: 'تماس', icon: const Icon(Icons.call_outlined), onPressed: () => crmLaunch(context, 'tel', _phone)),
            if (_phone.isNotEmpty)
              IconButton(tooltip: 'پیامک', icon: const Icon(Icons.sms_outlined), onPressed: () => crmLaunch(context, 'sms', _phone)),
            IconButton(
              tooltip: 'صورت‌حساب و سن بدهی',
              icon: const Icon(Icons.receipt_long_outlined),
              onPressed: () => Navigator.push(
                  context, MaterialPageRoute<void>(builder: (_) => PartyStatementScreen(partyName: widget.partyName))),
            ),
            IconButton(
              tooltip: 'مشخصات',
              icon: const Icon(Icons.badge_outlined),
              onPressed: () async {
                await Navigator.push(
                    context, MaterialPageRoute<bool>(builder: (_) => PartyMasterScreen(partyName: widget.partyName)));
                _loadParty();
              },
            ),
          ],
          bottom: const TabBar(tabs: <Widget>[Tab(text: 'یادداشت‌ها'), Tab(text: 'پیگیری‌ها')]),
        ),
        body: Column(
          children: <Widget>[
            if (_stage.isNotEmpty || _tags.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Wrap(
                    spacing: 6,
                    children: <Widget>[
                      if (_stage.isNotEmpty) Chip(label: Text(kPartyStagesFa[_stage] ?? _stage)),
                      for (final String t in _tags) Chip(label: Text(t)),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: TabBarView(
                children: <Widget>[
                  _NotesTab(party: widget.partyName, canEdit: canEdit),
                  _TasksTab(party: widget.partyName, canEdit: canEdit),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NotesTab extends StatelessWidget {
  final String party;
  final bool canEdit;
  const _NotesTab({required this.party, required this.canEdit});

  Future<List<Map<String, dynamic>>> _load() async {
    final List<Map<String, dynamic>> all = await EntityStore.I.list('crm_notes');
    final List<Map<String, dynamic>> out = all.where((Map<String, dynamic> m) => m['party'] == party).toList();
    out.sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
        ('${b['date'] ?? ''}${b['created_at'] ?? ''}').compareTo('${a['date'] ?? ''}${a['created_at'] ?? ''}'));
    return out;
  }

  Future<void> _add(BuildContext context) async {
    final TextEditingController text = TextEditingController();
    String kind = 'call';
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, void Function(void Function()) setS) => AlertDialog(
          title: const Text('یادداشت جدید'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              DropdownButtonFormField<String>(
                value: kind,
                decoration: const InputDecoration(labelText: 'نوع', border: OutlineInputBorder()),
                items: <DropdownMenuItem<String>>[
                  for (final MapEntry<String, String> e in kCrmKindsFa.entries)
                    DropdownMenuItem<String>(value: e.key, child: Text(e.value)),
                ],
                onChanged: (String? v) => setS(() => kind = v ?? 'call'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: text,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'متن', border: OutlineInputBorder()),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ذخیره')),
          ],
        ),
      ),
    );
    final String t = text.text.trim();
    text.dispose();
    if (ok != true || t.isEmpty) return;
    try {
      await EntityStore.I.save('crm_notes', <String, dynamic>{
        'party': party,
        'kind': kind,
        'text': t,
        'date': crmDateIso(DateTime.now()),
      });
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Invalid argument(s): ', ''))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: canEdit
          ? FloatingActionButton(onPressed: () => _add(context), tooltip: 'یادداشت جدید', child: const Icon(Icons.add))
          : null,
      body: ValueListenableBuilder<int>(
        valueListenable: AppDb.I.version,
        builder: (BuildContext context, int _, Widget? __) => FutureBuilder<List<Map<String, dynamic>>>(
          future: _load(),
          builder: (BuildContext context, AsyncSnapshot<List<Map<String, dynamic>>> snap) {
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final List<Map<String, dynamic>> rows = snap.data!;
            if (rows.isEmpty) return const Center(child: Text('یادداشتی ثبت نشده'));
            return ListView.builder(
              padding: const EdgeInsets.only(bottom: 80),
              itemCount: rows.length,
              itemBuilder: (BuildContext context, int i) {
                final Map<String, dynamic> r = rows[i];
                final String d = (r['date'] ?? '').toString();
                return ListTile(
                  leading: const Icon(Icons.sticky_note_2_outlined),
                  title: Text((r['text'] ?? '').toString()),
                  subtitle: Text('${kCrmKindsFa[r['kind']] ?? 'سایر'}${d.isEmpty ? '' : ' · ${jalaliDate(d)}'}'),
                  trailing: canEdit
                      ? IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => EntityStore.I.delete('crm_notes', r['uid'] as String),
                        )
                      : null,
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _TasksTab extends StatelessWidget {
  final String party;
  final bool canEdit;
  const _TasksTab({required this.party, required this.canEdit});

  Future<List<Map<String, dynamic>>> _load() async {
    final List<Map<String, dynamic>> all = await EntityStore.I.list('crm_tasks');
    final List<Map<String, dynamic>> out = all.where((Map<String, dynamic> m) => m['party'] == party).toList();
    out.sort((Map<String, dynamic> a, Map<String, dynamic> b) {
      final bool da = _truthy(a['done']);
      final bool db = _truthy(b['done']);
      if (da != db) return da ? 1 : -1;
      return '${a['due_at'] ?? '9999'}'.compareTo('${b['due_at'] ?? '9999'}');
    });
    return out;
  }

  Future<void> _add(BuildContext context) async {
    final TextEditingController text = TextEditingController();
    DateTime? day = DateTime.now().add(const Duration(days: 1));
    TimeOfDay time = const TimeOfDay(hour: 9, minute: 0);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, void Function(void Function()) setS) => AlertDialog(
          title: const Text('پیگیری جدید'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: text,
                decoration: const InputDecoration(labelText: 'شرح پیگیری', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.event),
                label: Text(day == null ? 'تاریخ موعد' : jalaliDateFromDt(day!)),
                onPressed: () async {
                  final DateTime now = DateTime.now();
                  final DateTime? p = await showDatePicker(
                      context: ctx, initialDate: day ?? now, firstDate: now.subtract(const Duration(days: 30)), lastDate: now.add(const Duration(days: 1825)));
                  if (p != null) setS(() => day = p);
                },
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.schedule),
                label: Text('${faNum(time.hour, dec: 0)}:${_two(time.minute)}'),
                onPressed: () async {
                  final TimeOfDay? p = await showTimePicker(context: ctx, initialTime: time);
                  if (p != null) setS(() => time = p);
                },
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ذخیره')),
          ],
        ),
      ),
    );
    final String t = text.text.trim();
    text.dispose();
    if (ok != true || t.isEmpty) return;
    final String? due = day == null ? null : '${crmDateIso(day!)} ${_two(time.hour)}:${_two(time.minute)}:00';
    try {
      final Map<String, dynamic> data = <String, dynamic>{'party': party, 'text': t, 'done': false};
      if (due != null) data['due_at'] = due;
      final String uid = await EntityStore.I.save('crm_tasks', data);
      await NotifyService.I.scheduleCrmTask(<String, dynamic>{...data, 'uid': uid});
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Invalid argument(s): ', ''))));
      }
    }
  }

  Future<void> _toggle(Map<String, dynamic> r, bool done) async {
    final String uid = r['uid'] as String;
    await EntityStore.I.save('crm_tasks', <String, dynamic>{'done': done}, uid: uid);
    if (done) {
      await NotifyService.I.cancelCrmTask(uid);
    } else {
      await NotifyService.I.scheduleCrmTask(<String, dynamic>{...r, 'done': false});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: canEdit
          ? FloatingActionButton(onPressed: () => _add(context), tooltip: 'پیگیری جدید', child: const Icon(Icons.add))
          : null,
      body: ValueListenableBuilder<int>(
        valueListenable: AppDb.I.version,
        builder: (BuildContext context, int _, Widget? __) => FutureBuilder<List<Map<String, dynamic>>>(
          future: _load(),
          builder: (BuildContext context, AsyncSnapshot<List<Map<String, dynamic>>> snap) {
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final List<Map<String, dynamic>> rows = snap.data!;
            if (rows.isEmpty) return const Center(child: Text('پیگیری‌ای ثبت نشده'));
            final DateTime now = DateTime.now();
            return ListView.builder(
              padding: const EdgeInsets.only(bottom: 80),
              itemCount: rows.length,
              itemBuilder: (BuildContext context, int i) {
                final Map<String, dynamic> r = rows[i];
                final bool done = _truthy(r['done']);
                final DateTime? due = _parseDt(r['due_at']);
                final bool late = !done && due != null && due.isBefore(now);
                return ListTile(
                  leading: Checkbox(value: done, onChanged: canEdit ? (bool? v) => _toggle(r, v == true) : null),
                  title: Text((r['text'] ?? '').toString(),
                      style: done ? const TextStyle(decoration: TextDecoration.lineThrough) : null),
                  subtitle: Text(_dueText(r['due_at']), style: late ? const TextStyle(color: Colors.red) : null),
                  trailing: canEdit
                      ? IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            final String uid = r['uid'] as String;
                            await NotifyService.I.cancelCrmTask(uid);
                            await EntityStore.I.delete('crm_tasks', uid);
                          },
                        )
                      : null,
                );
              },
            );
          },
        ),
      ),
    );
  }
}

// ============================ home card (offline) ============================

class CrmHomeCard extends StatelessWidget {
  const CrmHomeCard({super.key});

  Future<List<int>?> _counts() async {
    if (!StaffPerms.I.can('crm.view')) return null;
    if (!await EntityStore.I.isVisible('crm_tasks')) return null;
    final List<Map<String, dynamic>> rows = await EntityStore.I.list('crm_tasks');
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    int overdue = 0;
    int dueToday = 0;
    for (final Map<String, dynamic> r in rows) {
      if (_truthy(r['done'])) continue;
      final DateTime? d = _parseDt(r['due_at']);
      if (d == null) continue;
      final DateTime day = DateTime(d.year, d.month, d.day);
      if (day.isBefore(today)) {
        overdue++;
      } else if (day == today) {
        dueToday++;
      }
    }
    return <int>[overdue, dueToday];
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: AppDb.I.version,
      builder: (BuildContext context, int _, Widget? __) => FutureBuilder<List<int>?>(
        future: _counts(),
        builder: (BuildContext context, AsyncSnapshot<List<int>?> snap) {
          final List<int>? c = snap.data;
          if (c == null) return const SizedBox.shrink();
          return Card(
            child: ListTile(
              leading: const Icon(Icons.support_agent_outlined),
              title: const Text('پیگیری مشتریان'),
              subtitle: Text('عقب‌افتاده: ${faNum(c[0], dec: 0)} · امروز: ${faNum(c[1], dec: 0)}'),
              trailing: const Icon(Icons.chevron_left),
              onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const CrmDashboardScreen())),
            ),
          );
        },
      ),
    );
  }
}

// ============================ dashboard screen (online) ============================

class CrmDashboardScreen extends StatelessWidget {
  const CrmDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('مدیریت ارتباط با مشتری'),
          bottom: const TabBar(tabs: <Widget>[Tab(text: 'داشبورد'), Tab(text: 'طرف‌حساب‌ها')]),
        ),
        body: const TabBarView(children: <Widget>[_DashTab(), _PartiesTab()]),
      ),
    );
  }
}

void _openParty(BuildContext context, String party) {
  if (party.isEmpty) return;
  Navigator.push(context, MaterialPageRoute<void>(builder: (_) => PartyCrmScreen(partyName: party)));
}

class _DashTab extends StatefulWidget {
  const _DashTab();

  @override
  State<_DashTab> createState() => _DashTabState();
}

class _DashTabState extends State<_DashTab> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _d = <String, dynamic>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> r = await StockApi.call('crm.dashboard', <String, dynamic>{'days': 60});
      if (!mounted) return;
      setState(() {
        _d = r;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  List<Map<String, dynamic>> _list(String k) {
    final Object? v = _d[k];
    if (v is! List) return <Map<String, dynamic>>[];
    return v.whereType<Map>().map((Map e) => Map<String, dynamic>.from(e)).toList();
  }

  Widget _section(BuildContext context, String title, List<Widget> kids) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            if (kids.isEmpty) const Text('موردی نیست') else ...kids,
          ],
        ),
      ),
    );
  }

  List<Widget> _taskTiles(BuildContext context, String key) {
    return <Widget>[
      for (final Map<String, dynamic> t in _list(key))
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text('${t['party'] ?? ''} — ${t['text'] ?? ''}'),
          subtitle: Text(_dueText(t['due_at'])),
          onTap: () => _openParty(context, (t['party'] ?? '').toString()),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          Text(_error!, style: const TextStyle(color: Colors.red)),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _load, child: const Text('تلاش مجدد')),
        ]),
      );
    }
    final Object? st = _d['stages'];
    final bool profit = _d['profit_included'] == true;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: <Widget>[
          if (st is Map)
            Wrap(
              spacing: 8,
              children: <Widget>[
                for (final MapEntry<String, String> e in kPartyStagesFa.entries)
                  Chip(label: Text('${e.value}: ${faNum((st[e.key] as num?) ?? 0, dec: 0)}')),
              ],
            ),
          _section(context, 'پیگیری‌های عقب‌افتاده', _taskTiles(context, 'overdue_tasks')),
          _section(context, 'پیگیری‌های امروز', _taskTiles(context, 'today_tasks')),
          _section(context, 'پیگیری‌های هفتهٔ آینده', _taskTiles(context, 'upcoming_tasks')),
          _section(context, 'مشتریان بدون خرید اخیر', <Widget>[
            for (final Map<String, dynamic> c in _list('inactive_customers'))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text((c['party'] ?? '').toString()),
                subtitle: Text('آخرین فروش: ${(c['last_sale'] ?? '').toString().isEmpty ? '—' : jalaliDate('${c['last_sale']}')}'),
                onTap: () => _openParty(context, (c['party'] ?? '').toString()),
              ),
          ]),
          _section(context, 'مشتریان برتر', <Widget>[
            for (final Map<String, dynamic> c in _list('top_customers'))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text((c['party'] ?? '').toString()),
                subtitle: Text('فروش: ${faNum((c['revenue'] as num?) ?? 0, dec: 0)} ریال'
                    '${profit && c['profit'] is num ? ' · سود تقریبی: ${faNum(c['profit'] as num, dec: 0)}' : ''}'),
                onTap: () => _openParty(context, (c['party'] ?? '').toString()),
              ),
          ]),
        ],
      ),
    );
  }
}

class _PartiesTab extends StatefulWidget {
  const _PartiesTab();

  @override
  State<_PartiesTab> createState() => _PartiesTabState();
}

class _PartiesTabState extends State<_PartiesTab> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  String _tag = '';
  String _stage = '';
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final Map<String, dynamic> r = await StockApi.call('parties.list');
      final Object? raw = r['items'];
      if (!mounted) return;
      setState(() {
        _items = raw is List ? raw.whereType<Map>().map((Map e) => Map<String, dynamic>.from(e)).toList() : <Map<String, dynamic>>[];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  List<String> _tagsOf(Map<String, dynamic> x) {
    final Object? t = x['tags'];
    return t is List ? t.map((Object? e) => '$e').toList() : <String>[];
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text(_error!, style: const TextStyle(color: Colors.red)));
    final Set<String> allTags = <String>{};
    for (final Map<String, dynamic> x in _items) {
      allTags.addAll(_tagsOf(x));
    }
    final List<Map<String, dynamic>> shown = _items.where((Map<String, dynamic> x) {
      if (_tag.isNotEmpty && !_tagsOf(x).contains(_tag)) return false;
      if (_stage.isNotEmpty && (x['stage'] ?? 'active') != _stage) return false;
      if (_q.isNotEmpty && !(x['key'] ?? '').toString().contains(_q)) return false;
      return true;
    }).toList();
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'جستجوی نام', border: OutlineInputBorder(), isDense: true),
            onChanged: (String v) => setState(() => _q = v.trim()),
          ),
        ),
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: <Widget>[
              for (final MapEntry<String, String> e in kPartyStagesFa.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 8),
                  child: ChoiceChip(
                    label: Text(e.value),
                    selected: _stage == e.key,
                    onSelected: (bool v) => setState(() => _stage = v ? e.key : ''),
                  ),
                ),
              for (final String t in allTags)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 8),
                  child: FilterChip(
                    label: Text('#$t'),
                    selected: _tag == t,
                    onSelected: (bool v) => setState(() => _tag = v ? t : ''),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? const Center(child: Text('طرف‌حسابی پیدا نشد'))
              : ListView.builder(
                  itemCount: shown.length,
                  itemBuilder: (BuildContext context, int i) {
                    final Map<String, dynamic> x = shown[i];
                    final String key = (x['key'] ?? '').toString();
                    final String phone = (x['phone'] ?? '').toString();
                    final List<String> tg = _tagsOf(x);
                    return ListTile(
                      title: Text(key),
                      subtitle: Text('${kPartyStagesFa[x['stage']] ?? 'فعال'}${tg.isEmpty ? '' : ' · ${tg.join('، ')}'}'),
                      trailing: phone.isEmpty
                          ? null
                          : Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
                              IconButton(icon: const Icon(Icons.call_outlined), onPressed: () => crmLaunch(context, 'tel', phone)),
                              IconButton(icon: const Icon(Icons.sms_outlined), onPressed: () => crmLaunch(context, 'sms', phone)),
                            ]),
                      onTap: () => _openParty(context, key),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
