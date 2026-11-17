import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'license_service.dart';
import 'utils.dart';

/// پیام/اطلاعیه‌ای که مدیر از پنل ادمین می‌فرستد (به یک مشتری یا همه)
class AppMessage {
  final int id;
  final String title;
  final String body;
  final String? linkUrl;
  final String? linkLabel;
  final String kind; // info | update | greeting
  final String createdAt;
  bool read;
  AppMessage({
    required this.id,
    required this.title,
    required this.body,
    required this.linkUrl,
    required this.linkLabel,
    required this.kind,
    required this.createdAt,
    required this.read,
  });

  factory AppMessage.fromJson(Map<String, dynamic> j) => AppMessage(
        id: (j['id'] as num).toInt(),
        title: '${j['title'] ?? ''}',
        body: '${j['body'] ?? ''}',
        linkUrl: (j['link_url'] as String?)?.trim().isEmpty ?? true ? null : (j['link_url'] as String).trim(),
        linkLabel: (j['link_label'] as String?)?.trim().isEmpty ?? true ? null : (j['link_label'] as String).trim(),
        kind: '${j['kind'] ?? 'info'}',
        createdAt: '${j['created_at'] ?? ''}',
        read: j['read'] == true || j['read'] == 1,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        'link_url': linkUrl,
        'link_label': linkLabel,
        'kind': kind,
        'created_at': createdAt,
        'read': read,
      };
}

/// دریافت پیام‌ها از سرور (با کش محلی تا آفلاین هم آخرین پیام‌ها دیده شوند)
class MessageService {
  MessageService._();
  static final MessageService I = MessageService._();

  final ValueNotifier<List<AppMessage>> items = ValueNotifier<List<AppMessage>>(const []);
  bool _loadedCache = false;
  final Set<int> _pendingRead = {};

  String get _url => '${ApiConfig.baseUrl}/app.php';

  Future<String> _key() async => 'msgs_cache_${await LicenseService.I.savedPhone() ?? ''}';

  Future<void> _loadCache() async {
    if (_loadedCache) return;
    _loadedCache = true;
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(await _key());
      if (raw != null) {
        final list = (jsonDecode(raw) as List).map((e) => AppMessage.fromJson(Map<String, dynamic>.from(e as Map))).toList();
        items.value = list;
      }
    } catch (_) {}
  }

  Future<void> _saveCache() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(await _key(), jsonEncode(items.value.map((m) => m.toJson()).toList()));
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> _call(String phone, String token, String action, Map<String, dynamic> payload) async {
    try {
      final resp = await http
          .post(Uri.parse(_url),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'phone': phone, 'token': token, 'action': action, 'payload': payload}))
          .timeout(const Duration(seconds: 12));
      final j = jsonDecode(utf8.decode(resp.bodyBytes));
      return j is Map<String, dynamic> ? j : null;
    } catch (_) {
      return null; // آفلاین یا خطا: پیام‌های کش‌شده می‌مانند
    }
  }

  Future<void> refresh() async {
    await _loadCache();
    final cred = await LicenseService.I.credentials();
    if (cred == null) return;
    final j = await _call(cred.$1, cred.$2, 'messages.list', {});
    if (j == null || j['items'] is! List) return;
    final fresh = (j['items'] as List).map((e) => AppMessage.fromJson(Map<String, dynamic>.from(e as Map))).toList();
    for (final m in fresh) {
      if (_pendingRead.contains(m.id)) m.read = true;
    }
    items.value = fresh;
    await _saveCache();
    // خوانده‌شده‌هایی که هنوز به سرور نرسیده‌اند
    for (final id in _pendingRead.toList()) {
      final r = await _call(cred.$1, cred.$2, 'messages.read', {'id': id});
      if (r != null && r['ok'] == true) _pendingRead.remove(id);
    }
  }

  Future<void> markRead(AppMessage m) async {
    m.read = true;
    items.value = List.of(items.value);
    _pendingRead.add(m.id);
    await _saveCache();
    final cred = await LicenseService.I.credentials();
    if (cred == null) return;
    final r = await _call(cred.$1, cred.$2, 'messages.read', {'id': m.id});
    if (r != null && r['ok'] == true) _pendingRead.remove(m.id);
  }
}

/// کارت «پیام‌های مدیر» بالای تب خانه؛ فقط وقتی پیام خوانده‌نشده‌ای هست نمایش داده می‌شود
class MessagesCard extends StatefulWidget {
  const MessagesCard({super.key});
  @override
  State<MessagesCard> createState() => _MessagesCardState();
}

class _MessagesCardState extends State<MessagesCard> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    MessageService.I.refresh();
    _timer = Timer.periodic(const Duration(minutes: 10), (_) => MessageService.I.refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  (IconData, Color) _style(String kind, ColorScheme s) => switch (kind) {
        'update' => (Icons.system_update_alt, Colors.blue.shade700),
        'greeting' => (Icons.celebration_outlined, Colors.orange.shade800),
        _ => (Icons.campaign_outlined, s.primary),
      };

  Future<void> _open(String url) async {
    final u = Uri.tryParse(url);
    if (u == null || !(u.scheme == 'http' || u.scheme == 'https')) return;
    try {
      await launchUrl(u, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('باز کردن لینک ممکن نشد')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<List<AppMessage>>(
      valueListenable: MessageService.I.items,
      builder: (_, list, __) {
        final unread = list.where((m) => !m.read).toList();
        if (unread.isEmpty) return const SizedBox.shrink();
        return Column(children: [
          for (final m in unread)
            Builder(builder: (context) {
              final (icon, color) = _style(m.kind, scheme);
              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                color: color.withValues(alpha: 0.08),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16), side: BorderSide(color: color.withValues(alpha: 0.35))),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 8, 12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Icon(icon, color: color),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text(m.title, style: TextStyle(fontWeight: FontWeight.w800, color: color, fontSize: 15))),
                      IconButton(
                        tooltip: 'بستن پیام',
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => MessageService.I.markRead(m),
                      ),
                    ]),
                    if (m.body.isNotEmpty) Padding(padding: const EdgeInsets.only(right: 4, left: 6), child: Text(m.body)),
                    if (m.linkUrl != null) ...[
                      const SizedBox(height: 8),
                      FilledButton.tonalIcon(
                        onPressed: () => _open(m.linkUrl!),
                        icon: const Icon(Icons.open_in_new, size: 18),
                        label: Text(m.linkLabel ?? 'باز کردن لینک'),
                      ),
                    ],
                  ]),
                ),
              );
            }),
        ]);
      },
    );
  }
}
