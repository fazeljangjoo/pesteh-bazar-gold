import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'db_crypto.dart';
import 'local_backup.dart';
import 'utils.dart';
import 'widgets.dart';

/// صفحهٔ «پشتیبان‌گیری» نسخهٔ ویندوز.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});
  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  List<File> _files = [];
  String _dirPath = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await LocalBackup.I.dir();
    final f = await LocalBackup.I.list();
    if (!mounted) return;
    setState(() {
      _dirPath = d.path;
      _files = f;
    });
  }

  String _kindLabel(String k) {
    switch (k) {
      case 'daily':
        return 'خودکار (روزانه)';
      case 'manual':
        return 'دستی';
      case 'pre-sync':
        return 'قبل از همگام‌سازی';
      case 'pre-reload':
        return 'قبل از بازخوانی از سرور';
      case 'pre-restore':
        return 'قبل از بازگردانی';
      default:
        return k;
    }
  }

  String _when(File f) {
    final m = f.lastModifiedSync();
    final hh = m.hour.toString().padLeft(2, '0');
    final mm = m.minute.toString().padLeft(2, '0');
    return '${jalaliDateFromDt(m)}  ${toFaDigits('$hh:$mm')}';
  }

  Future<void> _now() async {
    setState(() => _busy = true);
    final f = await LocalBackup.I.snapshot('manual');
    if (!mounted) return;
    setState(() => _busy = false);
    snack(context, f == null ? 'پشتیبان‌گیری ناموفق بود' : 'پشتیبان ساخته شد');
    await _load();
  }

  Future<void> _openFolder() async {
    try {
      await Process.run('explorer', [_dirPath]);
    } catch (_) {}
  }

  Future<void> _restore(File f) async {
    final ok = await confirm(
        context,
        'کل داده‌های این حساب (روی سرور و این کامپیوتر) با محتوای این پشتیبان جایگزین می‌شود.\n'
        'قبل از آن از وضعیت فعلی یک نسخهٔ ایمنی گرفته می‌شود.\n'
        'برای بازگردانی اینترنت لازم است. ادامه می‌دهید؟');
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    final err = await LocalBackup.I.restore(f);
    if (!mounted) return;
    setState(() => _busy = false);
    snack(context, err ?? 'بازگردانی انجام شد');
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('پشتیبان‌گیری')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'روزی یک‌بار خودکار از اطلاعات شما روی همین کامپیوتر پشتیبان گرفته می‌شود '
                    '(۳۰ نسخهٔ آخر نگه‌داری می‌شود). اطلاعات شما هم‌زمان روی سرور هم ذخیره است.\n'
                    'توجه: چون پشتیبان‌ها رمزگذاری‌اند، فقط روی همین کامپیوتر و همین کاربر ویندوز باز می‌شوند؛ '
                    'روی کامپیوتر جدید اطلاعات از سرور برمی‌گردد.',
                  ),
                  const SizedBox(height: 8),
                  Text(DbCrypto.statusText, style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text('پوشه: $_dirPath', textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _now,
                  icon: const Icon(Icons.save_alt),
                  label: const Text('پشتیبان‌گیری همین الان'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _openFolder,
                icon: const Icon(Icons.folder_open),
                label: const Text('باز کردن پوشه'),
              ),
            ],
          ),
          if (_busy) const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator()),
          const SizedBox(height: 8),
          if (_files.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('هنوز پشتیبانی ساخته نشده'))),
          for (final f in _files)
            Card(
              child: ListTile(
                leading: const Icon(Icons.history),
                title: Text(_kindLabel(LocalBackup.I.kindOf(f))),
                subtitle: Text('${_when(f)} · ${faNum(f.lengthSync() / 1024 / 1024, dec: 1)} مگابایت\n${p.basename(f.path)}',
                    style: const TextStyle(fontSize: 11)),
                isThreeLine: true,
                trailing: TextButton(
                  onPressed: _busy ? null : () => _restore(f),
                  child: const Text('بازگردانی'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
