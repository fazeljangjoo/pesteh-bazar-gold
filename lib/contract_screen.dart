import 'package:flutter/material.dart';

import 'pay_service.dart';
import 'utils.dart';

/// قرارداد فعلی: کاربر تا تیک نزند و نپذیرد وارد برنامه نمی‌شود.
/// [onAccepted] بعد از پذیرش صدا زده می‌شود (LicenseGate دوباره بررسی می‌کند).
class ContractAcceptScreen extends StatefulWidget {
  final Map<String, dynamic> item;
  final VoidCallback onAccepted;
  final VoidCallback onLogout;
  const ContractAcceptScreen({super.key, required this.item, required this.onAccepted, required this.onLogout});

  @override
  State<ContractAcceptScreen> createState() => _ContractAcceptScreenState();
}

class _ContractAcceptScreenState extends State<ContractAcceptScreen> {
  bool _agree = false;
  bool _busy = false;
  String? _err;

  Future<void> _accept() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final v = widget.item['version'];
      await PayService.I.acceptContract(v is num ? v.toInt() : int.parse('$v'));
      if (!mounted) return;
      widget.onAccepted();
    } on PayException catch (e) {
      if (!mounted) return;
      if (e.code == 'contract_outdated') {
        // نسخهٔ جدید منتشر شده: LicenseGate دوباره قرارداد را می‌خواند
        widget.onAccepted();
        return;
      }
      setState(() {
        _busy = false;
        _err = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _err = 'ثبت پذیرش انجام نشد. دوباره تلاش کنید.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = (widget.item['title'] as String?) ?? 'قرارداد استفاده از پسته بازار';
    final version = widget.item['version'];
    final body = (widget.item['body'] as String?) ?? '';
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
              const SizedBox(height: 4),
              Text('نسخهٔ ${toFaDigits('$version')}',
                  style: const TextStyle(color: Colors.black54), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.black12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(body, style: const TextStyle(height: 1.9, fontSize: 14)),
                  ),
                ),
              ),
              CheckboxListTile(
                value: _agree,
                onChanged: _busy ? null : (v) => setState(() => _agree = v ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                title: const Text('متن قرارداد را خوانده‌ام و شرایط آن را می‌پذیرم.'),
              ),
              if (_err != null) Text(_err!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: (_agree && !_busy) ? _accept : null,
                child: _busy
                    ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('پذیرش و ادامه'),
              ),
              TextButton(onPressed: _busy ? null : widget.onLogout, child: const Text('خروج از حساب')),
            ],
          ),
        ),
      ),
    );
  }
}
