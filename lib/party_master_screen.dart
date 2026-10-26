import 'package:flutter/material.dart';

import 'crm_ui.dart';
import 'warehouse_ui.dart';

/// T03.1 — مشخصات طرف‌حساب (نوع، تماس، شناسه‌ها، سقف اعتبار، مانده افتتاحیه). آنلاین از طریق StockApi
/// (parties.list / parties.save). نام طرف‌حساب ثابت است؛ خرید و فروش با همین نام تطبیق می‌شوند.

const Map<String, String> kPartyTypesFa = <String, String>{
  'customer': 'مشتری',
  'supplier': 'تأمین‌کننده',
  'broker': 'دلال',
  'employee': 'کارمند',
  'processor': 'فرآوری‌کار',
  'consignor': 'امانت‌دار',
  'other': 'سایر',
};

class PartyMasterScreen extends StatefulWidget {
  final String partyName;
  const PartyMasterScreen({super.key, required this.partyName});

  @override
  State<PartyMasterScreen> createState() => _PartyMasterScreenState();
}

class _PartyMasterScreenState extends State<PartyMasterScreen> {
  final TextEditingController _phone = TextEditingController();
  final TextEditingController _address = TextEditingController();
  final TextEditingController _nid = TextEditingController();
  final TextEditingController _eco = TextEditingController();
  final TextEditingController _postal = TextEditingController();
  final TextEditingController _limit = TextEditingController();
  final TextEditingController _opening = TextEditingController();
  final TextEditingController _note = TextEditingController();
  final TextEditingController _tags = TextEditingController();
  String _stage = 'active';
  final Set<String> _types = <String>{};
  String _side = 'debtor';
  bool _active = true;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  int _id = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in <TextEditingController>[_phone, _address, _nid, _eco, _postal, _limit, _opening, _note, _tags]) {
      c.dispose();
    }
    super.dispose();
  }

  String _digits(String s) {
    const fa = '۰۱۲۳۴۵۶۷۸۹';
    final StringBuffer b = StringBuffer();
    for (final int c in s.runes) {
      final int i = fa.indexOf(String.fromCharCode(c));
      b.write(i >= 0 ? '$i' : String.fromCharCode(c));
    }
    return b.toString().replaceAll(',', '').replaceAll('٬', '').trim();
  }

  Future<void> _load() async {
    try {
      final r = await StockApi.call('parties.list');
      final raw = r['items'];
      if (raw is List) {
        for (final x in raw) {
          if (x is Map && (x['key'] ?? '').toString() == widget.partyName) {
            _id = int.tryParse('${x['party_id'] ?? 0}') ?? 0;
            _phone.text = (x['phone'] ?? '').toString();
            _address.text = (x['address'] ?? '').toString();
            _nid.text = (x['national_id'] ?? '').toString();
            _eco.text = (x['economic_code'] ?? '').toString();
            _postal.text = (x['postal_code'] ?? '').toString();
            _limit.text = x['credit_limit'] == null ? '' : '${x['credit_limit']}';
            final num ob = (x['opening_balance'] as num?) ?? 0;
            _opening.text = ob == 0 ? '' : '${ob.round()}';
            _note.text = (x['note'] ?? '').toString();
            final Object? tg = x['tags'];
            if (tg is List) _tags.text = tg.map((Object? e) => '$e').join('، ');
            final String stg = (x['stage'] ?? 'active').toString();
            _stage = kPartyStagesFa.containsKey(stg) ? stg : 'active';
            _side = x['opening_side'] == 'creditor' ? 'creditor' : 'debtor';
            _active = x['active'] != false;
            final t = x['types'];
            if (t is List) _types.addAll(t.whereType<String>());
            break;
          }
        }
      }
    } catch (e) {
      _error = e.toString().replaceFirst('Exception: ', '');
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> p = <String, dynamic>{
        if (_id > 0) 'id': _id else 'name': widget.partyName,
        'types': _types.toList(),
        'phone': _phone.text.trim(),
        'address': _address.text.trim(),
        'national_id': _digits(_nid.text),
        'economic_code': _digits(_eco.text),
        'postal_code': _digits(_postal.text),
        'credit_limit': _digits(_limit.text),
        'opening_balance': _digits(_opening.text),
        'opening_side': _side,
        'active': _active ? 1 : 0,
        'note': _note.text.trim(),
        'tags': _tags.text.split(RegExp('[,،]')).map((String t) => t.trim()).where((String t) => t.isNotEmpty).toList(),
        'stage': _stage,
      };
      final r = await StockApi.call('parties.save', p);
      _id = int.tryParse('${r['id'] ?? _id}') ?? _id;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('ذخیره شد')));
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
    if (mounted) setState(() => _saving = false);
  }

  Widget _tf(TextEditingController c, String label, {bool numeric = false, int lines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        maxLines: lines,
        keyboardType: numeric ? TextInputType.number : TextInputType.text,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('مشخصات ${widget.partyName}'),
        actions: <Widget>[
          if (_phone.text.trim().isNotEmpty)
            IconButton(tooltip: 'تماس', icon: const Icon(Icons.call_outlined), onPressed: () => crmLaunch(context, 'tel', _phone.text)),
          if (_phone.text.trim().isNotEmpty)
            IconButton(tooltip: 'پیامک', icon: const Icon(Icons.sms_outlined), onPressed: () => crmLaunch(context, 'sms', _phone.text)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_error!, style: const TextStyle(color: Colors.red))),
                const Text('نوع طرف‌حساب'),
                Wrap(
                  spacing: 8,
                  children: <Widget>[
                    for (final e in kPartyTypesFa.entries)
                      FilterChip(
                        label: Text(e.value),
                        selected: _types.contains(e.key),
                        onSelected: (bool v) => setState(() {
                          if (v) {
                            _types.add(e.key);
                          } else {
                            _types.remove(e.key);
                          }
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                _tf(_phone, 'تلفن', numeric: true),
                _tf(_address, 'نشانی', lines: 2),
                _tf(_nid, 'کد ملی / شناسهٔ ملی', numeric: true),
                _tf(_eco, 'کد اقتصادی', numeric: true),
                _tf(_postal, 'کد پستی', numeric: true),
                _tf(_limit, 'سقف اعتبار (اختیاری)', numeric: true),
                _tf(_opening, 'مانده افتتاحیه', numeric: true),
                DropdownButtonFormField<String>(
                  value: _side,
                  decoration: const InputDecoration(labelText: 'وضعیت مانده افتتاحیه', border: OutlineInputBorder()),
                  items: const <DropdownMenuItem<String>>[
                    DropdownMenuItem<String>(value: 'debtor', child: Text('بدهکار (او به ما بدهکار است)')),
                    DropdownMenuItem<String>(value: 'creditor', child: Text('بستانکار (ما به او بدهکاریم)')),
                  ],
                  onChanged: (String? v) => setState(() => _side = v ?? 'debtor'),
                ),
                const SizedBox(height: 12),
                _tf(_note, 'یادداشت', lines: 2),
                DropdownButtonFormField<String>(
                  value: _stage,
                  decoration: const InputDecoration(labelText: 'مرحلهٔ مشتری', border: OutlineInputBorder()),
                  items: <DropdownMenuItem<String>>[
                    for (final MapEntry<String, String> e in kPartyStagesFa.entries)
                      DropdownMenuItem<String>(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (String? v) => setState(() => _stage = v ?? 'active'),
                ),
                const SizedBox(height: 12),
                _tf(_tags, 'برچسب‌ها (با ویرگول جدا کنید، حداکثر ۱۰)'),
                SwitchListTile(title: const Text('فعال'), value: _active, onChanged: (bool v) => setState(() => _active = v)),
                const SizedBox(height: 8),
                FilledButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'در حال ذخیره…' : 'ذخیره')),
              ],
            ),
    );
  }
}
