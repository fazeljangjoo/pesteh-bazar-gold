import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'db.dart';
import 'entity_store.dart';
import 'intake_confirm_screen.dart';
import 'intake_form.dart';
import 'perms.dart';

/// S5.T3: فهرست پذیرش‌های اتاق انس (جستجو با کد/صاحب، فیلتر وضعیت).
/// سرور خودش دید را محدود می‌کند (ounce.view_own/view_all)؛ اینجا فقط آنچه همگام شده نمایش داده می‌شود.
class IntakeListScreen extends StatefulWidget {
  const IntakeListScreen({super.key, this.initialFilter = 'all'});

  /// S6.T4: فیلتر اولیه (مثلاً `submitted` از نشان «در انتظار قطعی»)
  final String initialFilter;

  @override
  State<IntakeListScreen> createState() => _IntakeListScreenState();
}

const Map<String, String> kIntakeStatusLabels = <String, String>{
  'draft': 'پیش‌نویس',
  'submitted': 'ثبت‌شده',
  'returned': 'برگشتی برای اصلاح',
  'confirmed': 'قطعی‌شده',
  'rejected': 'ردشده',
  'sample_only': 'نمونه',
};

/// یک ردیف فهرست + اینکه `intake.submit` آن هنوز در صف است یا نه
class IntakeRowView {
  IntakeRowView(this.data, this.pending);
  final Map<String, dynamic> data;
  final bool pending;

  String get uid => data['uid'] as String;
  String get status => (data['status'] ?? 'draft').toString();
  String get statusLabel => pending ? 'در انتظار ارسال' : (kIntakeStatusLabels[status] ?? status);
}

String _fmtKg(Object? v) {
  if (v is! num) return '-';
  return v % 1 == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(3);
}

class _IntakeListScreenState extends State<IntakeListScreen> {
  final TextEditingController _q = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  late String _filter;
  late Future<List<IntakeRowView>> _future;

  @override
  void initState() {
    super.initState();
    _filter = widget.initialFilter;
    _future = _load();
    AppDb.I.version.addListener(_onDbChanged);
  }

  @override
  void dispose() {
    AppDb.I.version.removeListener(_onDbChanged);
    _q.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onDbChanged() {
    if (mounted) setState(() => _future = _load());
  }

  void _refresh() => setState(() => _future = _load());

  Future<List<IntakeRowView>> _load() async {
    final rows = await EntityStore.I.list('lot_intakes', q: _q.text);
    final out = <IntakeRowView>[];
    for (final r in rows) {
      final pending = const <String>['draft', 'returned'].contains((r['status'] ?? 'draft').toString()) && await EntityStore.I.isSubmitPending(r['uid'] as String);
      final v = IntakeRowView(r, pending);
      if (_filter == 'all' || (_filter == 'pending' ? pending : v.status == _filter)) out.add(v);
    }
    return out;
  }

  Future<void> _open(IntakeRowView v) async {
    if (v.pending) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('این پذیرش هنوز در صف ارسال است؛ پس از ارسال قابل مشاهده است.')));
      return;
    }
    // S6: پذیرشِ «ثبت‌شده» برای مدیر/حسابدار (قطعی‌سازی + قیمت) → صفحهٔ قطعی‌سازی
    if (v.status == 'submitted' && canConfirmIntakes()) {
      await Navigator.of(context).push(MaterialPageRoute<bool>(builder: (_) => IntakeConfirmScreen(uid: v.uid)));
      _refresh();
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => IntakeFormScreen(uid: (v.status == 'draft' || v.status == 'returned') ? v.uid : null),
    ));
    _refresh();
  }

  Future<void> _new() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const IntakeFormScreen()));
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): _new,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () => _searchFocus.requestFocus(),
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('پذیرش‌های اتاق انس'),
          actions: [
            IconButton(tooltip: 'به‌روزرسانی', icon: const Icon(Icons.refresh), onPressed: _refresh),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _new,
          icon: const Icon(Icons.add),
          label: const Text('پذیرش جدید'),
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _q,
                          focusNode: _searchFocus,
                          decoration: const InputDecoration(
                            hintText: 'جستجو: کد، نام صاحب، نوع…',
                            prefixIcon: Icon(Icons.search),
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onChanged: (_) => _refresh(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      DropdownButton<String>(
                        value: _filter,
                        items: const [
                          DropdownMenuItem(value: 'all', child: Text('همه')),
                          DropdownMenuItem(value: 'pending', child: Text('در صف ارسال')),
                          DropdownMenuItem(value: 'draft', child: Text('پیش‌نویس')),
                          DropdownMenuItem(value: 'submitted', child: Text('ثبت‌شده')),
                          DropdownMenuItem(value: 'returned', child: Text('برگشتی')),
                          DropdownMenuItem(value: 'confirmed', child: Text('قطعی‌شده')),
                          DropdownMenuItem(value: 'rejected', child: Text('ردشده')),
                          DropdownMenuItem(value: 'sample_only', child: Text('نمونه')),
                        ],
                        onChanged: (v) {
                          _filter = v ?? 'all';
                          _refresh();
                        },
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: FutureBuilder<List<IntakeRowView>>(
                    future: _future,
                    builder: (context, snap) {
                      if (snap.connectionState != ConnectionState.done) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      final list = snap.data ?? <IntakeRowView>[];
                      if (list.isEmpty) {
                        return const Center(child: Text('پذیرشی پیدا نشد.'));
                      }
                      return ListView.separated(
                        itemCount: list.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final v = list[i];
                          final d = v.data;
                          final code = (d['code'] as String?)?.trim();
                          final owner = (d['is_sample'] == true) ? 'نمونه' : (d['owner_name'] ?? '').toString();
                          return ListTile(
                            onTap: () => _open(v),
                            leading: Icon(v.pending ? Icons.cloud_upload_outlined : Icons.inventory_2_outlined),
                            title: Text(
                              (code == null || code.isEmpty) ? 'کد: بعد از ثبت' : code,
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            subtitle: Text('$owner · ${d['type_name'] ?? '-'} · ${_fmtKg(d['gross_kg'])} کیلو'),
                            trailing: Chip(
                              label: Text(v.statusLabel),
                              visualDensity: VisualDensity.compact,
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// S6: کاربر هم «قطعی‌سازی» و هم «قیمت‌گذاری» دارد؟ (مالک = بله)
bool canConfirmIntakes() => StaffPerms.I.can('intake.confirm') && StaffPerms.I.can('intake.price');

/// S6.T4: نشان/کارت «پذیرش‌های در انتظار قطعی» برای صفحهٔ اصلی مدیر/حسابدار.
/// فقط وقتی دیده می‌شود که کاربر مجوز قطعی‌سازی+قیمت دارد و حداقل یک پذیرش «ثبت‌شده» (غیرنمونه) هست.
/// با همگام‌سازی (AppDb.I.version) خودکار تازه می‌شود؛ لمس = فهرست با فیلتر «ثبت‌شده».
class PendingIntakesCard extends StatefulWidget {
  const PendingIntakesCard({super.key});

  @override
  State<PendingIntakesCard> createState() => _PendingIntakesCardState();
}

class _PendingIntakesCardState extends State<PendingIntakesCard> {
  int _n = 0;

  @override
  void initState() {
    super.initState();
    AppDb.I.version.addListener(_reload);
    StaffPerms.I.current.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    AppDb.I.version.removeListener(_reload);
    StaffPerms.I.current.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    if (!canConfirmIntakes()) {
      if (mounted && _n != 0) setState(() => _n = 0);
      return;
    }
    int n = 0;
    try {
      if (await EntityStore.I.isVisible('lot_intakes')) {
        final rows = await EntityStore.I.list('lot_intakes');
        n = rows.where((r) => r['status'] == 'submitted' && r['is_sample'] != true).length;
      }
    } catch (_) {
      n = 0;
    }
    if (mounted && n != _n) setState(() => _n = n);
  }

  @override
  Widget build(BuildContext context) {
    if (_n <= 0) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const IntakeListScreen(initialFilter: 'submitted')));
          _reload();
        },
        child: Card(
          color: scheme.tertiaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Badge(label: Text('$_n'), child: const Icon(Icons.pending_actions_outlined)),
              const SizedBox(width: 14),
              const Expanded(
                child: Text('پذیرش‌های در انتظار قطعی', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              const Icon(Icons.chevron_left),
            ]),
          ),
        ),
      ),
    );
  }
}
