import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'assistant_api.dart';
import 'license_service.dart';
import 'utils.dart';

/// یک اکشن دستیار (همان قرارداد assistant.js): نام کارکرد + مرحله + پارامترهای اختیاری.
class AssistantAction {
  final String q;
  final String step;
  final Map<String, dynamic>? params;

  const AssistantAction(this.q, [this.step = 'start', this.params]);

  static AssistantAction? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final q = raw['q'];
    if (q is! String || q.isEmpty) return null;
    final step = raw['step'];
    final p = raw['params'];
    return AssistantAction(
      q,
      step is String && step.isNotEmpty ? step : 'start',
      p is Map ? Map<String, dynamic>.from(p) : null,
    );
  }
}

/// اجرای یک اکشن از داخل بلوک‌ها. [quietErrors] = true یعنی خطا را فراخواننده خودش نشان می‌دهد (مثلاً فرم).
typedef ActionCallback = Future<AssistantResult> Function(AssistantAction action, {bool? quietErrors});

enum _Mode { push, replace, back }

/// Intent ارسال پیام چت (کلید Enter در ویندوز)
class _SendIntent extends Intent {
  const _SendIntent();
}

const AssistantAction _rootAction = AssistantAction('menu');

/// سقف طول پرسش از پسته‌کاو (هم‌راستا با متن راهنمای فرم در سرور).
const int _textMaxChars = 500;

// ---------------------------------------------------------------- کمک‌های ساده

String _s(dynamic v) => v == null ? '' : v.toString();

List<dynamic> _list(dynamic v) => v is List ? v : const <dynamic>[];

Map<String, dynamic> _map(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

List<Map<String, dynamic>> _maps(dynamic v) => [
      for (final raw in _list(v))
        if (raw is Map) Map<String, dynamic>.from(raw),
    ];

/// رنگ hex سرور (#RGB، #RRGGBB، #RRGGBBAA). مقدار نامعتبر = null (پیش‌فرض اعمال می‌شود).
Color? _parseHex(dynamic v) {
  if (v is! String || !RegExp(r'^#[0-9a-fA-F]{3,8}$').hasMatch(v)) return null;
  var h = v.substring(1);
  if (h.length == 3 || h.length == 4) h = h.split('').map((c) => c + c).join();
  if (h.length == 6) {
    h = 'FF$h';
  } else if (h.length == 8) {
    h = h.substring(6) + h.substring(0, 6); // RRGGBBAA -> AARRGGBB
  } else {
    return null;
  }
  final n = int.tryParse(h, radix: 16);
  return n == null ? null : Color(n);
}

class _Palette {
  final Color assistant;
  final Color user;
  final Color support;
  final Color accent;

  const _Palette({
    required this.assistant,
    required this.user,
    required this.support,
    required this.accent,
  });

  static const _Palette defaults = _Palette(
    assistant: Color(0xFFE8F5E9),
    user: Color(0xFFFFFFFF),
    support: Color(0xFFFFF3E0),
    accent: Color(0xFF2E7D32),
  );

  factory _Palette.fromTheme(dynamic raw) {
    final t = _map(raw);
    return _Palette(
      assistant: _parseHex(t['assistant']) ?? defaults.assistant,
      user: _parseHex(t['user']) ?? defaults.user,
      support: _parseHex(t['support']) ?? defaults.support,
      accent: _parseHex(t['accent']) ?? defaults.accent,
    );
  }
}

/// جعبهٔ نوتیس با رنگ ثابت (مستقل از تم اپ، مثل نسخهٔ وب)
Widget _noticeBox(String tone, String text) {
  final (bg, fg) = switch (tone) {
    'success' => (const Color(0xFFE8F5E9), const Color(0xFF1B5E20)),
    'warning' => (const Color(0xFFFFF4E0), const Color(0xFF8A5300)),
    'error' => (const Color(0xFFFDECEA), const Color(0xFFC62828)),
    _ => (const Color(0xFFE8F1FB), const Color(0xFF1A4A7A)),
  };
  return Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
    child: Text(text, style: TextStyle(color: fg, height: 1.8)),
  );
}

Widget _sectionHead(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
      ),
    );

// ---------------------------------------------------------------- صفحهٔ دستیار

class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key});

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  final List<AssistantAction> _stack = [];
  AssistantAction _current = _rootAction;
  Map<String, dynamic>? _data;
  _Palette _palette = _Palette.defaults;
  String _title = 'دستیار پسته بازار';
  String? _loadError;
  bool _retryableLoad = false;
  bool _busy = false;
  bool _closing = false;
  int _seq = 0;
  int _renderId = 0;
  // اکشنی که الان منتظر پاسخ سرور است (برای نشان دادن حالت «در حال بررسی»)
  AssistantAction? _inFlight;
  // حباب پاسخ پسته‌کاو؛ بعد از رسیدن پاسخ، صفحه روی همین حباب می‌رود
  final GlobalKey _answerKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // اگر نشست در هر جای اپ نامعتبر شد، دستیار هم بسته شود (مثل closeAssistant در نسخهٔ وب)
    LicenseService.I.sessionInvalid.addListener(_closeForAuth);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _navigate(_rootAction, _Mode.replace);
    });
  }

  @override
  void dispose() {
    LicenseService.I.sessionInvalid.removeListener(_closeForAuth);
    super.dispose();
  }

  void _closeForAuth() {
    if (!mounted || _closing) return;
    _closing = true;
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<AssistantResult> _action(AssistantAction a, {bool? quietErrors}) =>
      _navigate(a, _Mode.push, quietErrors: quietErrors);

  void _back() {
    if (_stack.isEmpty) {
      Navigator.of(context).maybePop();
      return;
    }
    _navigate(_stack.last, _Mode.back);
  }

  Future<AssistantResult> _navigate(AssistantAction a, _Mode mode, {bool? quietErrors}) async {
    final seq = ++_seq;
    if (mounted) setState(() {
      _busy = true;
      _inFlight = a;
    });
    final res = await AssistantApi.call(a.q, step: a.step, params: a.params);
    if (!mounted) return res;
    if (res.authExpired) {
      _closeForAuth();
      return res;
    }
    if (seq != _seq) return res; // پاسخ قدیمی‌تر از درخواست بعدی؛ نادیده

    if (res.ok) {
      final data = res.data!;
      final t = data['title'];
      setState(() {
        _busy = false;
        _inFlight = null;
        _loadError = null;
        if (mode == _Mode.push) _stack.add(_current);
        if (mode == _Mode.back && _stack.isNotEmpty) _stack.removeLast();
        _current = a;
        _data = data;
        _palette = _Palette.fromTheme(data['theme']);
        _title = t is String && t.isNotEmpty ? t : 'دستیار پسته بازار';
        _renderId++;
      });
      if (a.q == 'ai_ask' && a.step == 'answer') {
        // بعد از ساخته شدن صفحهٔ تازه، به حباب پاسخ اسکرول کن
        WidgetsBinding.instance.addPostFrameCallback((_) => _revealAnswer());
      }
      return res;
    }

    setState(() {
      _busy = false;
      _inFlight = null;
    });
    if (_data == null) {
      setState(() {
        _loadError = res.message;
        _retryableLoad = res.retryable;
      });
    } else if (quietErrors != true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(res.message),
          action: res.retryable
              ? SnackBarAction(label: 'تلاش مجدد', onPressed: () => _navigate(a, mode))
              : null,
        ),
      );
    }
    return res;
  }

  /// بعد از پاسخ پسته‌کاو، صفحه را روی حباب پاسخ می‌برد (نه ته صفحه، که فرم و دکمه‌ها هستند).
  void _revealAnswer() {
    final ctx = _answerKey.currentContext;
    if (!mounted || ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 250),
      alignment: 0.0,
    );
  }

  /// اندیس آخرین بلوک متن دستیار (نه پرسش کاربر)؛ اگر نبود -1.
  int _lastAssistantTextIndex(List<dynamic> blocks) {
    for (var i = blocks.length - 1; i >= 0; i--) {
      final raw = blocks[i];
      if (raw is Map && raw['type'] == 'text' && raw['role'] != 'user' && raw['role'] != 'support') {
        return i;
      }
    }
    return -1;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: _back),
        title: Text(_title, overflow: TextOverflow.ellipsis),
      ),
      body: Column(
        children: [
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          if (_inFlight?.q == 'ai_ask' && _inFlight?.step == 'answer')
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                'پسته‌کاو در حال بررسی است…',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final data = _data;
    if (data == null) {
      if (_loadError == null) return const Center(child: CircularProgressIndicator());
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_loadError!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              if (_retryableLoad)
                FilledButton(
                  onPressed: () => _navigate(_current, _Mode.replace),
                  child: const Text('تلاش دوباره'),
                ),
            ],
          ),
        ),
      );
    }

    final blocks = _list(data['blocks']);
    final note = _s(data['data_note']);
    // ویندوز: ستون خواندن حداکثر ۷۲۰ پیکسل و وسط‌چین (در عرض بزرگ)
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: _messageList(data, blocks, note),
      ),
    );
  }

  Widget _messageList(Map<String, dynamic> data, List<dynamic> blocks, String note) {
    final answerIdx = _lastAssistantTextIndex(blocks);
    return ListView(
      key: ValueKey(_renderId), // با هر صفحهٔ تازه، وضعیت بلوک‌ها (مثلاً چت) از نو ساخته می‌شود
      padding: const EdgeInsets.all(16),
      children: [
        for (var i = 0; i < blocks.length; i++)
          Padding(
            key: i == answerIdx ? _answerKey : null,
            padding: const EdgeInsets.only(bottom: 12),
            child: _renderBlock(blocks[i]),
          ),
        if (note.isNotEmpty)
          Text(
            note,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
      ],
    );
  }

  Widget _renderBlock(dynamic raw) {
    if (raw is! Map) return const SizedBox.shrink();
    final b = Map<String, dynamic>.from(raw);
    switch (b['type']) {
      case 'text':
        return _textBlock(b);
      case 'notice':
        return _noticeBox(_s(b['tone']), _s(b['text']));
      case 'buttons':
        return Column(
          children: [for (final it in _maps(b['items'])) _menuTile(it)],
        );
      case 'choice':
        return _ChoiceBlock(block: b, onAction: _action);
      case 'form':
        return _FormBlock(block: b, onAction: _action);
      case 'table':
        return _tableBlock(b);
      case 'card':
        return _cardBody(context, b);
      case 'confirm':
        return _confirmBlock(b);
      case 'chat':
        return _ChatBlock(
          block: b,
          palette: _palette,
          onAuthExpired: _closeForAuth,
        );
      default:
        return _noticeBox('info', 'این بخش در این نسخه پشتیبانی نمی‌شود');
    }
  }

  Widget _textBlock(Map<String, dynamic> b) {
    final role = b['role'] == 'user' || b['role'] == 'support' ? b['role'] as String : 'assistant';
    final color = switch (role) {
      'user' => _palette.user,
      'support' => _palette.support,
      _ => _palette.assistant,
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(14),
        border: role == 'user' ? Border.all(color: Theme.of(context).dividerColor) : null,
      ),
      // Text ساده است؛ هیچ رشته‌ای به‌عنوان HTML یا Markdown تفسیر نمی‌شود
      child: Text(_s(b['text']), style: const TextStyle(color: Colors.black87, height: 1.8)),
    );
  }

  Widget _menuTile(Map<String, dynamic> it) {
    final action = AssistantAction.fromJson(it['action']);
    final badge = it['badge'];
    final n = badge is num ? badge.toInt() : 0;
    final icon = _s(it['icon']);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: icon.isEmpty ? null : Text(icon, style: const TextStyle(fontSize: 20)),
        title: Text(_s(it['label']), style: const TextStyle(fontWeight: FontWeight.w600)),
        trailing: n > 0 ? _badge(context, n) : const Icon(Icons.chevron_left),
        onTap: action == null ? null : () => _action(action),
      ),
    );
  }

  Widget _badge(BuildContext context, int n) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 22),
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: scheme.error, borderRadius: BorderRadius.circular(999)),
      child: Text(
        faNum(n, dec: 0),
        style: TextStyle(color: scheme.onError, fontWeight: FontWeight.w700, fontSize: 12),
      ),
    );
  }

  Widget _tableBlock(Map<String, dynamic> b) {
    final cols = _maps(b['columns']);
    final rows = _list(b['rows']);
    final footer = _list(b['footer']);
    final title = _s(b['title']);
    if (cols.isEmpty) return _noticeBox('info', 'جدول داده‌ای ندارد');

    String cell(dynamic v) => v == null ? '' : v.toString();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title.isNotEmpty) _sectionHead(context, title),
        Card(
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowHeight: 40,
              dataRowMinHeight: 36,
              dataRowMaxHeight: 56,
              columns: [for (final c in cols) DataColumn(label: Text(_s(c['label'])))],
              rows: [
                for (final r in rows)
                  DataRow(cells: [
                    for (var i = 0; i < cols.length; i++)
                      DataCell(Text(cell(r is List && i < r.length ? r[i] : null))),
                  ]),
                if (footer.isNotEmpty)
                  DataRow(cells: [
                    for (var i = 0; i < cols.length; i++)
                      DataCell(Text(
                        cell(i < footer.length ? footer[i] : null),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      )),
                  ]),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// بدنهٔ کارت خلاصه؛ برای بلوک card و confirm مشترک است
  Widget _cardBody(BuildContext context, Map<String, dynamic> b) {
    final scheme = Theme.of(context).colorScheme;
    final title = _s(b['title']);
    final highlight = _s(b['highlight']);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            for (final ln in _maps(b['lines'])) _lineRow(context, ln),
            if (highlight.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  highlight,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _lineRow(BuildContext context, Map<String, dynamic> ln) {
    final color = switch (_s(ln['tone'])) {
      'pos' => const Color(0xFF2E7D32),
      'neg' => const Color(0xFFC62828),
      'warn' => const Color(0xFF8A5300),
      _ => null,
    };
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(_s(ln['label']), style: TextStyle(color: muted))),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              _s(ln['value']),
              textAlign: TextAlign.end,
              style: TextStyle(fontWeight: FontWeight.w700, color: color),
            ),
          ),
        ],
      ),
    );
  }

  Widget _confirmBlock(Map<String, dynamic> b) {
    final confirm = _map(b['confirm']);
    final cancel = _map(b['cancel']);
    final action = AssistantAction.fromJson(confirm['action']);
    final yesLabel = _s(confirm['label']).isEmpty ? 'تأیید' : _s(confirm['label']);
    final noLabel = _s(cancel['label']).isEmpty ? 'انصراف' : _s(cancel['label']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _cardBody(context, b),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: (action == null || _busy) ? null : () => _action(action), // در حین ارسال غیرفعال
          child: Text(yesLabel),
        ),
        TextButton(onPressed: _back, child: Text(noLabel)),
      ],
    );
  }
}

// ---------------------------------------------------------------- انتخاب از فهرست

class _ChoiceBlock extends StatefulWidget {
  final Map<String, dynamic> block;
  final ActionCallback onAction;

  const _ChoiceBlock({required this.block, required this.onAction});

  @override
  State<_ChoiceBlock> createState() => _ChoiceBlockState();
}

class _ChoiceBlockState extends State<_ChoiceBlock> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final b = widget.block;
    final items = _maps(b['items']);
    final needle = _query.trim().toLowerCase();
    final visible = needle.isEmpty
        ? items
        : items
            .where((it) => '${_s(it['label'])} ${_s(it['sublabel'])}'.toLowerCase().contains(needle))
            .toList();
    final title = _s(b['title']);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title.isNotEmpty) _sectionHead(context, title),
        if (b['search'] == true)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                hintText: 'جستجو…',
                prefixIcon: Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
        if (items.isEmpty) Text('موردی برای نمایش نیست', style: TextStyle(color: muted)),
        if (items.isNotEmpty && visible.isEmpty)
          Text('موردی با این جستجو پیدا نشد', style: TextStyle(color: muted)),
        for (final it in visible)
          Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              title: Text(_s(it['label']), style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: _s(it['sublabel']).isEmpty ? null : Text(_s(it['sublabel'])),
              onTap: () {
                final action = AssistantAction.fromJson(it['action']);
                if (action != null) widget.onAction(action);
              },
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------- فرم (ردیف‌های تکرارشونده)

class _FormRow {
  final Map<String, TextEditingController> ctrls = {};

  Map<String, String> values() => {for (final e in ctrls.entries) e.key: e.value.text};

  void dispose() {
    for (final c in ctrls.values) {
      c.dispose();
    }
  }
}

class _FormBlock extends StatefulWidget {
  final Map<String, dynamic> block;
  final ActionCallback onAction;

  const _FormBlock({required this.block, required this.onAction});

  @override
  State<_FormBlock> createState() => _FormBlockState();
}

class _FormBlockState extends State<_FormBlock> {
  late final List<Map<String, dynamic>> _fields;
  late final bool _repeat;
  late final int _min;
  late final int _max;
  final List<_FormRow> _rows = [];
  String _err = '';
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    final b = widget.block;
    _fields = _maps(b['fields']);
    final rep = _map(b['repeat']);
    _repeat = b['repeat'] is Map;
    final mn = rep['min'] is num ? (rep['min'] as num).toInt() : 1;
    final mx = rep['max'] is num ? (rep['max'] as num).toInt() : 50;
    _min = mn < 1 ? 1 : mn;
    _max = mx < _min ? _min : mx;
    final initial = _repeat ? _min : 1;
    for (var i = 0; i < initial; i++) {
      _rows.add(_newRow());
    }
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  _FormRow _newRow() {
    final row = _FormRow();
    for (final f in _fields) {
      row.ctrls[_s(f['name'])] = TextEditingController();
    }
    return row;
  }

  void _addRow() {
    if (_rows.length >= _max) return;
    setState(() => _rows.add(_newRow()));
  }

  void _removeRow(int i) {
    if (_rows.length <= _min) return;
    setState(() {
      final r = _rows.removeAt(i);
      r.dispose();
    });
  }

  bool _isText(Map<String, dynamic> f) => _s(f['kind']) == 'text';

  /// ارسال از کیبورد (فقط فیلد متن)؛ اگر در حال ارسال باشیم یا اکشنی نباشد، کاری نمی‌کند.
  void _submitFromKeyboard(AssistantAction? action) {
    if (action == null || _submitting) return;
    _submit(action);
  }

  Future<void> _submit(AssistantAction action) async {
    setState(() {
      _submitting = true;
      _err = '';
    });
    // مقادیر تایپ‌شده بدون تبدیل فرستاده می‌شوند؛ تبدیل ارقام فارسی و اعشار با سرور است
    final Map<String, dynamic> collected = _repeat
        ? {'rows': [for (final r in _rows) r.values()]}
        : {'values': _rows.isEmpty ? <String, String>{} : _rows.first.values()};
    final merged = AssistantAction(
      action.q,
      action.step,
      {...?action.params, ...collected},
    );
    final res = await widget.onAction(merged, quietErrors: true);
    if (!mounted) return; // موفق بود و صفحه عوض شد
    setState(() {
      _submitting = false;
      if (!res.ok && !res.authExpired) _err = res.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.block;
    final title = _s(b['title']);
    final submit = _map(b['submit']);
    final submitAction = AssistantAction.fromJson(submit['action']);
    final rep = _map(b['repeat']);
    final addLabel = _s(rep['add_label']).isEmpty ? 'افزودن ردیف' : _s(rep['add_label']);
    final removeLabel = _s(rep['remove_label']).isEmpty ? 'حذف ردیف' : _s(rep['remove_label']);
    final submitLabel = _s(submit['label']).isEmpty ? 'ثبت' : _s(submit['label']);
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title.isNotEmpty) _sectionHead(context, title),
        for (var i = 0; i < _rows.length; i++)
          Card(
            key: ValueKey(_rows[i]),
            margin: const EdgeInsets.only(bottom: 10),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_repeat)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'ردیف ${faNum(i + 1, dec: 0)}',
                            style: TextStyle(fontWeight: FontWeight.w700, color: scheme.primary),
                          ),
                        ),
                        TextButton(
                          onPressed: _rows.length > _min ? () => _removeRow(i) : null,
                          child: Text(removeLabel),
                        ),
                      ],
                    ),
                  LayoutBuilder(
                    builder: (context, c) {
                      final full = _fields.length <= 1;
                      final w = full ? c.maxWidth : (c.maxWidth - 8) / 2;
                      return Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final f in _fields)
                            SizedBox(
                              width: w,
                              child: Shortcuts(
                                // ویندوز: Enter = ارسال (فقط فیلد متن)؛ Shift+Enter = خط جدید
                                shortcuts: _isText(f)
                                    ? const <ShortcutActivator, Intent>{
                                        SingleActivator(LogicalKeyboardKey.enter): _SendIntent(),
                                        SingleActivator(LogicalKeyboardKey.numpadEnter): _SendIntent(),
                                      }
                                    : const <ShortcutActivator, Intent>{},
                                child: Actions(
                                  actions: <Type, Action<Intent>>{
                                    _SendIntent: CallbackAction<Intent>(onInvoke: (_) {
                                      _submitFromKeyboard(submitAction);
                                      return null;
                                    }),
                                  },
                                  child: TextField(
                                controller: _rows[i].ctrls[_s(f['name'])],
                                // در حالت انتظار پاسخ سرور، فیلد قفل می‌شود
                                enabled: !_submitting,
                                // kind:'text' = متن آزاد چندخطی (پرسش از پسته‌کاو)؛ بقیه عددی‌اند
                                keyboardType: _isText(f)
                                    ? TextInputType.multiline
                                    : const TextInputType.numberWithOptions(decimal: true),
                                maxLines: _isText(f) ? 4 : 1,
                                maxLength: _isText(f) ? _textMaxChars : null,
                                // ارسال با دکمهٔ «ارسال» کیبورد (برای متن) به‌جای خط جدید
                                textInputAction: _isText(f) ? TextInputAction.send : null,
                                autocorrect: _isText(f),
                                enableSuggestions: _isText(f),
                                decoration: InputDecoration(
                                  labelText: _s(f['label']).isEmpty ? _s(f['name']) : _s(f['label']),
                                  helperText: _s(f['hint']).isEmpty ? null : _s(f['hint']),
                                  helperMaxLines: 2,
                                  isDense: true,
                                  border: const OutlineInputBorder(),
                                ),
                              ),
                                ),
                              )
                            ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        if (_repeat && _rows.length < _max)
          OutlinedButton(onPressed: _addRow, child: Text(addLabel)),
        if (_err.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              _err,
              style: TextStyle(color: scheme.error, fontWeight: FontWeight.w600, height: 1.7),
            ),
          ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: submitAction == null || _submitting ? null : () => _submit(submitAction),
          child: Text(submitLabel),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- چت پشتیبانی

class _ChatBlock extends StatefulWidget {
  final Map<String, dynamic> block;
  final _Palette palette;
  final VoidCallback onAuthExpired;

  const _ChatBlock({
    required this.block,
    required this.palette,
    required this.onAuthExpired,
  });

  @override
  State<_ChatBlock> createState() => _ChatBlockState();
}

class _ChatBlockState extends State<_ChatBlock> with WidgetsBindingObserver {
  final List<Map<String, dynamic>> _msgs = [];
  final Set<int> _seen = {};
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  int _lastId = 0;
  bool _welcomed = false;
  String _status = '';
  String _err = '';
  bool _sending = false;
  bool _polling = false;
  bool _resumed = true;
  String? _pendingCid;
  String? _pendingText;
  Timer? _timer;

  AssistantAction? get _pollAction => AssistantAction.fromJson(_map(widget.block['poll'])['action']);
  AssistantAction? get _sendAction => AssistantAction.fromJson(_map(widget.block['send'])['action']);

  Duration get _interval {
    final p = _map(widget.block['poll']);
    final ms = p['interval_ms'] is num ? (p['interval_ms'] as num).toInt() : 5000;
    return Duration(milliseconds: ms < 2000 ? 2000 : ms);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _resumed = state == null || state == AppLifecycleState.resumed;
    _absorb([widget.block]); // بلوک chat خودش پیام‌های اولیه را دارد
    _applyTimer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// فقط وقتی اپ در پیش‌زمینه است و صفحه بالاست، polling فعال است (بدون نشت تایمر)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    _applyTimer();
    if (_resumed) _poll();
  }

  void _applyTimer() {
    _timer?.cancel();
    _timer = null;
    if (_resumed && _pollAction != null) {
      _timer = Timer.periodic(_interval, (_) => _poll());
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  /// بلوک‌های پاسخ: نوتیس وضعیت و پیام‌های تازه (بدون setState؛ فراخواننده مسئول است)
  void _absorb(dynamic blocks) {
    for (final raw in (blocks is List ? blocks : const <dynamic>[])) {
      if (raw is! Map) continue;
      final b = Map<String, dynamic>.from(raw);
      if (b['type'] == 'notice') {
        _status = _s(b['text']);
      } else if (b['type'] == 'chat') {
        _appendMessages(b['messages']);
      }
    }
  }

  void _appendMessages(dynamic list) {
    if (list is! List) return;
    final wasAtEnd = _lastId == 0 ||
        !_scroll.hasClients ||
        _scroll.position.maxScrollExtent - _scroll.offset < 120;
    var added = false;
    for (final raw in list) {
      if (raw is! Map) continue;
      final m = Map<String, dynamic>.from(raw);
      final id = m['id'] is num ? (m['id'] as num).toInt() : 0;
      if (id == 0) {
        // پیام خوش‌آمد: فقط یک‌بار و ذخیره‌نشده
        if (m['sender'] != 'assistant' || _welcomed) continue;
        _welcomed = true;
      } else {
        if (_seen.contains(id)) continue;
        _seen.add(id);
        if (id > _lastId) _lastId = id;
      }
      _msgs.add(m);
      added = true;
    }
    if (added && wasAtEnd) _scrollToEnd();
  }

  Future<void> _poll() async {
    final action = _pollAction;
    if (!mounted || action == null || _polling || _sending || !_resumed) return;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return; // صفحه‌ای روی دستیار باز است
    _polling = true;
    final res = await AssistantApi.call(
      action.q,
      step: action.step,
      params: {'after_id': _lastId},
    );
    _polling = false;
    if (!mounted) return;
    if (res.authExpired) {
      widget.onAuthExpired();
      return;
    }
    if (!res.ok) return; // خطای گذرای poll بی‌صدا؛ دفعهٔ بعد دوباره
    setState(() => _absorb(res.data!['blocks']));
  }

  Future<void> _send() async {
    final action = _sendAction;
    final text = _input.text.trim();
    if (_sending || action == null || text.isEmpty) return;
    // client_id برای تلاش مجدد همان متن ثابت می‌ماند تا پیام دوبار ثبت نشود
    if (_pendingCid == null || _pendingText != text) {
      _pendingCid = _newClientId();
      _pendingText = text;
    }
    final cid = _pendingCid!;
    setState(() {
      _sending = true;
      _err = '';
    });
    final res = await AssistantApi.call(
      action.q,
      step: action.step,
      params: {'body': text, 'client_id': cid},
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (res.authExpired) {
      widget.onAuthExpired();
      return;
    }
    if (!res.ok) {
      setState(() => _err = res.message); // متن پیام می‌ماند تا دوباره بفرستد
      return;
    }
    _pendingCid = null;
    _pendingText = null;
    _input.clear();
    setState(() => _absorb(res.data!['blocks']));
    _scrollToEnd();
  }

  static String _newClientId() {
    final rnd = Random.secure();
    final sb = StringBuffer('c');
    for (var i = 0; i < 16; i++) {
      sb.write(rnd.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString(); // ۳۳ کاراکتر، فقط hex و حرف اول c
  }

  Widget _msgRow(BuildContext context, Map<String, dynamic> m) {
    final sender = m['sender'] == 'user' || m['sender'] == 'support' ? m['sender'] as String : 'assistant';
    final color = switch (sender) {
      'user' => widget.palette.user,
      'support' => widget.palette.support,
      _ => widget.palette.assistant,
    };
    final time = _s(m['time']);
    final maxW = MediaQuery.of(context).size.width * 0.82;
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: maxW > 480 ? 480 : maxW),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(14),
        border: sender == 'user' ? Border.all(color: Theme.of(context).dividerColor) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_s(m['body']), style: const TextStyle(color: Colors.black87, height: 1.8)),
          if (time.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(time, style: const TextStyle(fontSize: 11, color: Colors.black54)),
            ),
        ],
      ),
    );
    // کاربر در سمت چپ (پایان در RTL)، پشتیبان و دستیار در سمت راست؛ همان چیدمان نسخهٔ وب
    return Row(
      mainAxisAlignment: sender == 'user' ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [Flexible(child: bubble)],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxH = MediaQuery.of(context).size.height * 0.5;
    final canSend = !_sending && _sendAction != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_status.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _noticeBox('info', _status),
          ),
        Container(
          constraints: BoxConstraints(minHeight: 120, maxHeight: maxH < 160 ? 160 : maxH),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: _msgs.isEmpty
              ? Center(
                  child: Text(
                    'هنوز پیامی نیست',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                )
              : ListView.separated(
                  controller: _scroll,
                  shrinkWrap: true,
                  itemCount: _msgs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (ctx, i) => _msgRow(ctx, _msgs[i]),
                ),
        ),
        if (_err.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _err,
              style: TextStyle(color: scheme.error, fontWeight: FontWeight.w600, height: 1.7),
            ),
          ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Shortcuts(
                // Enter: ارسال؛ Shift+Enter: خط جدید (پیش‌فرض TextField)
                shortcuts: <ShortcutActivator, Intent>{
                  const SingleActivator(LogicalKeyboardKey.enter): _SendIntent(),
                  const SingleActivator(LogicalKeyboardKey.numpadEnter): _SendIntent(),
                },
                child: Actions(
                  actions: <Type, Action<Intent>>{
                    _SendIntent: CallbackAction<Intent>(onInvoke: (_) {
                      _send();
                      return null;
                    }),
                  },
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: 1000,
                    decoration: const InputDecoration(
                      hintText: 'پیام خود را بنویسید…  (Enter ارسال، Shift+Enter خط جدید)',
                      counterText: '',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: canSend ? _send : null,
              child: const Text('ارسال'),
            ),
          ],
        ),
      ],
    );
  }
}
