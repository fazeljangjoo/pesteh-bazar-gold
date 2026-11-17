import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'widgets.dart' show sectionTitle;

/// مرحلهٔ ۶: زیربنای فرم‌های فشرده و چندستونه (فقط ویندوز و عرض ≥ ۷۲۰).
/// در موبایل / عرض کم همه‌چیز مثل قبل است (تک‌ستون، بدون کارت، دکمه‌ها انتهای لیست).

/// فرم عریض؟ فقط ویندوز و عرض صفحه ≥ ۷۲۰.
bool kWideForm(BuildContext context) => Platform.isWindows && MediaQuery.sizeOf(context).width >= 720;

/// فاصلهٔ عمودی بین فیلدها: ۸ در ویندوز، ۱۲ در بقیه (به پارامتر `gap` فیلدها بدهید).
final double kFormGap = Platform.isWindows ? 8 : 12;

/// صفحهٔ فرم: Scaffold + وسط‌چین با حداکثر عرض ۱۱۸۰ + اسکرول.
/// [actions] در حالت عریض پایین و ثابت (bottomNavigationBar) و در حالت کم‌عرض انتهای صفحه می‌آید.
class FormPage extends StatelessWidget {
  const FormPage({
    super.key,
    required this.title,
    required this.children,
    this.actions = const <Widget>[],
    this.formKey,
  });

  final String title;
  final List<Widget> children;
  final List<Widget> actions;
  final GlobalKey<FormState>? formKey;

  @override
  Widget build(BuildContext context) {
    final bool wide = kWideForm(context);
    final List<Widget> body = <Widget>[
      ...children,
      if (!wide) ...actions,
      const SizedBox(height: 24),
    ];
    Widget content = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: body);
    if (formKey != null) content = Form(key: formKey, child: content);
    final Widget scroll = SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: wide
          ? Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1180), child: content))
          : content,
    );
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: scroll,
      bottomNavigationBar: wide && actions.isNotEmpty
          ? Material(
              elevation: 3,
              color: Theme.of(context).colorScheme.surface,
              child: SafeArea(
                top: false,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1180),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Row(
                        children: <Widget>[
                          for (int i = 0; i < actions.length; i++) ...<Widget>[
                            if (i > 0) const SizedBox(width: 8),
                            actions[i],
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            )
          : null,
    );
  }
}

/// بخش فشرده: در حالت عریض کارت با عنوان کوچک؛ در حالت کم‌عرض فقط عنوان + فرزندان (مثل قبل).
class FormSection extends StatelessWidget {
  const FormSection({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (!kWideForm(context)) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
        sectionTitle(context, title),
        ...children,
      ]);
    }
    final ThemeData t = Theme.of(context);
    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 12, 2),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
          Padding(
            padding: const EdgeInsetsDirectional.only(bottom: 8),
            child: Text(title, style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.primary, fontWeight: FontWeight.bold)),
          ),
          ...children,
        ]),
      ),
    );
  }
}

/// فیلد عریض داخل [FormGrid]: [span] = تعداد ستون‌ها (۲ تا ۴) یا null = تمام‌عرض.
class FormSpan extends StatelessWidget {
  const FormSpan({super.key, required this.child, this.span});

  final Widget child;
  final int? span;

  @override
  Widget build(BuildContext context) => child;
}

/// شبکهٔ فیلدها: ستون‌ها = floor(عرض / minColWidth) (حداکثر ۴)، عرض مساوی. فیلدها به ترتیب (راست‌به‌چپ) می‌آیند.
class FormGrid extends StatelessWidget {
  const FormGrid({super.key, required this.children, this.minColWidth = 300, this.gap = 12});

  final List<Widget> children;
  final double minColWidth;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final bool wide = kWideForm(context);
    final List<Widget> kids = children.where((Widget w) => !(w is SizedBox && w.width == 0 && w.height == 0)).toList();
    if (!wide) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: kids);
    return LayoutBuilder(builder: (BuildContext context, BoxConstraints bc) {
      final double w = bc.maxWidth.isFinite ? bc.maxWidth : 1180;
      final int cols = (w / minColWidth).floor().clamp(1, 4);
      if (cols == 1) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: kids);
      final double colW = (w - gap * (cols - 1)) / cols;
      return Wrap(
        spacing: gap,
        runSpacing: 0,
        textDirection: Directionality.of(context),
        children: <Widget>[
          for (final Widget k in kids)
            SizedBox(
              key: k.key,
              width: _widthFor(k, cols, colW),
              child: k is FormSpan ? k.child : k,
            ),
        ],
      );
    });
  }

  double _widthFor(Widget k, int cols, double colW) {
    if (k is! FormSpan) return colW;
    final int s = k.span == null ? cols : k.span!.clamp(1, cols);
    return colW * s + gap * (s - 1);
  }
}

/// ردیف‌های اطلاعات کارت (infoRow) را در حالت عریض (ویندوز ≥۷۲۰) کنار هم در چند ستون می‌چیند
/// تا کارت کوتاه شود؛ در موبایل/کم‌عرض همان ستون عمودی قبلی.
class CompactInfo extends StatelessWidget {
  const CompactInfo({super.key, required this.children, this.colWidth = 260});

  final List<Widget> children;
  final double colWidth;

  @override
  Widget build(BuildContext context) {
    if (!kWideForm(context)) return Column(children: children);
    return LayoutBuilder(builder: (BuildContext context, BoxConstraints bc) {
      final double w = bc.maxWidth.isFinite ? bc.maxWidth : 1000;
      final int cols = (w / colWidth).floor().clamp(1, 4);
      if (cols == 1) return Column(children: children);
      const double gap = 24;
      final double cw = (w - gap * (cols - 1)) / cols;
      return Wrap(
        spacing: gap,
        runSpacing: 0,
        children: <Widget>[for (final Widget c in children) SizedBox(width: cw, child: c)],
      );
    });
  }
}
