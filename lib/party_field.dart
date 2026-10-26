import 'package:flutter/material.dart';

import 'db.dart';
import 'ledger.dart';

/// فیلد نام فروشنده/خریدار با پیشنهاد خودکار از نام‌های قبلی
/// (تا یک نفر با چند املای مختلف ثبت نشود و «حساب طرف‌ها» درست جمع بزند).
class PartyField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  const PartyField({super.key, required this.controller, required this.label});

  @override
  State<PartyField> createState() => _PartyFieldState();
}

class _PartyFieldState extends State<PartyField> {
  final FocusNode _focus = FocusNode();
  List<String> _names = [];

  @override
  void initState() {
    super.initState();
    AppDb.I.partyNames().then((l) {
      if (mounted) setState(() => _names = l);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: RawAutocomplete<String>(
        textEditingController: widget.controller,
        focusNode: _focus,
        optionsBuilder: (TextEditingValue v) {
          final q = partyKey(v.text);
          if (q.isEmpty) return const Iterable<String>.empty();
          return _names.where((n) {
            final k = partyKey(n);
            return k != q && k.contains(q);
          }).take(6);
        },
        fieldViewBuilder: (context, textController, focusNode, onFieldSubmitted) {
          return TextFormField(
            controller: textController,
            focusNode: focusNode,
            decoration: InputDecoration(
              labelText: widget.label,
              border: const OutlineInputBorder(),
            ),
          );
        },
        optionsViewBuilder: (context, onSelected, options) {
          return Align(
            alignment: AlignmentDirectional.topStart,
            child: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: 240,
                  maxWidth: MediaQuery.of(context).size.width - 32,
                ),
                child: ListView(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  children: [
                    for (final o in options)
                      ListTile(dense: true, title: Text(o), onTap: () => onSelected(o)),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
