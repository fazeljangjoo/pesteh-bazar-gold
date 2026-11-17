// تسعیر ارز حرفه‌ای — مرحلهٔ ۱۲: فهرست تسعیرهای ثبت‌شده، دیالوگ جزئیات و ابطال دستی.
//
// ساختار (grep -n "^class\|// =====" fx_reval_history_ui.dart):
//   FxRevalHistory      ← فهرست (list) با چیپ وضعیت، خالص سود/زیان، نشان «قدیمی‌شده»، ابطال
//   _DetailDialog       ← جزئیات (detail) + ریز snapshot با ویجت مشترک FxRevalPreviewBody
//   _Banner             ← نوار پیام کوچک
// (مرحلهٔ ۱۳) دکمه‌های Excel/PDF دیالوگ جزئیات: FxRevalExportButtons از fx_reval_export.dart
// ریز فاکتورها/طرف‌حساب‌ها از `fx_reval_ui.dart` (FxRevalPreviewBody و ابزارهای عمومی fxReval*) می‌آید.
// هیچ محاسبهٔ حسابداری در UI نیست؛ فقط نمایش مقادیر مدل‌ها. ابطال فقط با FxRevalPerms.canReverse.
import 'package:flutter/material.dart';

import 'fmt.dart' show Fmt;
import 'fx_reval_api.dart'; // FxRevalApi.I / FxRevalPerms + مدل‌ها و FxRevalException
import 'fx_reval_export.dart' show FxRevalExportButtons; // مرحلهٔ ۱۳
import 'fx_reval_ui.dart' show FxRevalEffectLabel, FxRevalErrorBox, FxRevalInfoRow, FxRevalPreviewBody, fxRevalEffectColor, fxRevalErrorText, fxRevalGainColor, fxRevalLossColor, fxRevalMutedColor, fxRevalRial;
import 'utils.dart' show jalaliDate, toFaDigits;
import 'widgets.dart' show snack;

/// توضیح نشان «قدیمی‌شده» (stale).
const String _kStaleHint = 'بعد از ثبت، پرداختی با تاریخ قبل از تسعیر وارد شده؛ پیشنهاد: ابطال و ثبت مجدد.';

String _jd(String? iso) {
  if (iso == null || iso.isEmpty) return '—';
  try {
    return jalaliDate(iso);
  } catch (_) {
    return iso;
  }
}

/// «YYYY-MM-DD HH:MM:SS» سرور → «تاریخ شمسی HH:MM» (در صورت ناتوانی همان رشته).
String _stamp(String? s) {
  if (s == null || s.length < 10) return s ?? '';
  final String d = _jd(s.substring(0, 10));
  final String t = s.length >= 16 ? toFaDigits(s.substring(11, 16)) : '';
  return t.isEmpty ? d : '$d  $t';
}

Color _statusColor(BuildContext c, FxRevalRecord r) {
  if (r.isCancelled) return fxRevalMutedColor(c);
  if (r.isAutoReversed) return Colors.blueGrey;
  if (r.isPending) return Colors.orange.shade800;
  return fxRevalGainColor(c);
}

// ===================== FxRevalHistory =====================

/// فهرست تسعیرهای قبلی. با تغییر [refreshToken] دوباره بارگذاری می‌شود؛ [onChanged] پس از ابطال موفق صدا زده می‌شود.
class FxRevalHistory extends StatefulWidget {
  final int refreshToken;
  final VoidCallback? onChanged;
  const FxRevalHistory({super.key, this.refreshToken = 0, this.onChanged});

  @override
  State<FxRevalHistory> createState() => _FxRevalHistoryState();
}

class _FxRevalHistoryState extends State<FxRevalHistory> {
  List<FxRevalRecord> _rows = const <FxRevalRecord>[];
  bool _loading = true;
  Object? _error;
  int _gen = 0;
  int? _busyId; // ابطال در جریان (جلوگیری از کلیک دوباره)

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(FxRevalHistory old) {
    super.didUpdateWidget(old);
    if (old.refreshToken != widget.refreshToken) _load();
  }

  Future<void> _load() async {
    final int g = ++_gen;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<FxRevalRecord> r = await FxRevalApi.I.list();
      if (!mounted || g != _gen) return;
      setState(() {
        _rows = r;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || g != _gen) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _open(FxRevalRecord r) async {
    final bool? wantReverse = await showDialog<bool>(
      context: context,
      builder: (BuildContext _) => _DetailDialog(record: r),
    );
    if (wantReverse == true && mounted) await _confirmReverse(r);
  }

  Future<void> _confirmReverse(FxRevalRecord r) async {
    if (_busyId != null) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('ابطال تسعیر'),
        content: Text(
          'تسعیر تاریخ ${_jd(r.asOf)} ابطال شود؟\n'
          'سند ابطال با تاریخ تسعیر ثبت می‌شود و اثر سند تسعیر را کاملاً خنثی می‌کند.',
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: fxRevalLossColor(ctx)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('ابطال تسعیر'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busyId = r.id);
    bool done = false;
    String? failure;
    try {
      await FxRevalApi.I.reverse(r.id);
      done = true;
    } catch (e) {
      failure = fxRevalErrorText(e); // ۴۰۹ (قبلاً برگشت‌خورده / قفل) پیام فارسی سرور
    }
    if (!mounted) return;
    setState(() => _busyId = null);
    snack(context, done ? 'تسعیر ابطال شد' : (failure ?? 'ابطال انجام نشد'));
    if (done) widget.onChanged?.call();
    await _load(); // در هر دو حالت وضعیت واقعی از سرور
  }

  @override
  Widget build(BuildContext context) {
    final Object? err = _error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: Text('تسعیرهای ثبت‌شده', style: Theme.of(context).textTheme.titleMedium)),
            if (_loading) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            IconButton(tooltip: 'بازخوانی', onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh)),
          ],
        ),
        if (_loading && _rows.isEmpty && err == null)
          const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Center(child: CircularProgressIndicator()))
        else if (err != null && _rows.isEmpty)
          FxRevalErrorBox(error: err, onRetry: _load)
        else if (_rows.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('هنوز تسعیری ثبت نشده است.', textAlign: TextAlign.center, style: TextStyle(color: fxRevalMutedColor(context))),
            ),
          )
        else ...<Widget>[
          if (err != null) ...<Widget>[FxRevalErrorBox(error: err, onRetry: _load), const SizedBox(height: 8)],
          for (final FxRevalRecord r in _rows) _row(context, r),
        ],
      ],
    );
  }

  Widget _row(BuildContext context, FxRevalRecord r) {
    final Color sc = _statusColor(context, r);
    final bool stale = r.isEffective && r.stale;
    final bool canRev = FxRevalPerms.canReverse && r.canReverse;
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => _open(r),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(child: Text('تسعیر ${toFaDigits('${r.id}')} — ${_jd(r.asOf)}', softWrap: true, style: const TextStyle(fontWeight: FontWeight.w700))),
                  const SizedBox(width: 8),
                  FxRevalEffectLabel(effect: r.netGain),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 10,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  _chip(r.statusLabel, sc),
                  Text('${Fmt.number(r.docCount)} سند', style: TextStyle(fontSize: 12.5, color: fxRevalMutedColor(context))),
                  if (r.revDate != null) Text('برگشت خودکار: ${_jd(r.revDate)}', style: TextStyle(fontSize: 12.5, color: fxRevalMutedColor(context))),
                  if (stale) Tooltip(message: _kStaleHint, child: _chip('قدیمی‌شده', Colors.orange.shade800, icon: Icons.history_toggle_off)),
                ],
              ),
              if (stale)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(_kStaleHint, style: TextStyle(fontSize: 12, color: Colors.orange.shade800)),
                ),
              if (canRev)
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton.icon(
                    onPressed: _busyId == null ? () => _confirmReverse(r) : null,
                    icon: _busyId == r.id
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.undo, size: 18),
                    label: const Text('ابطال'),
                    style: TextButton.styleFrom(foregroundColor: fxRevalLossColor(context)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(String text, Color c, {IconData? icon}) {
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(8, 2, 8, 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        border: Border.all(color: c.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[Icon(icon, size: 14, color: c), const SizedBox(width: 4)],
          Text(text, style: TextStyle(fontSize: 12, color: c, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// ===================== _DetailDialog =====================

/// جزئیات یک تسعیر. با «ابطال تسعیر» مقدار true برمی‌گرداند (تأیید و فراخوانی در فهرست انجام می‌شود).
class _DetailDialog extends StatefulWidget {
  final FxRevalRecord record;
  const _DetailDialog({required this.record});

  @override
  State<_DetailDialog> createState() => _DetailDialogState();
}

class _DetailDialogState extends State<_DetailDialog> {
  FxRevalRecord? _rec;
  Object? _error;
  bool _loading = true;

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
      final FxRevalRecord r = await FxRevalApi.I.detail(widget.record.id);
      if (!mounted) return;
      setState(() {
        _rec = r;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final FxRevalRecord? r = _rec;
    final Object? err = _error;
    final bool canRev = r != null && FxRevalPerms.canReverse && r.canReverse;
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 1000, maxHeight: MediaQuery.of(context).size.height * 0.9),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text('تسعیر شمارهٔ ${toFaDigits('${widget.record.id}')} — ${_jd(widget.record.asOf)}', style: Theme.of(context).textTheme.titleMedium),
                  ),
                  IconButton(tooltip: 'بستن', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: _loading
                  ? const SizedBox(height: 160, child: Center(child: CircularProgressIndicator()))
                  : err != null
                      ? SingleChildScrollView(padding: const EdgeInsets.all(16), child: FxRevalErrorBox(error: err, onRetry: _load))
                      : LayoutBuilder(
                          builder: (BuildContext context, BoxConstraints box) => SingleChildScrollView(
                            padding: const EdgeInsets.all(16),
                            child: _content(context, r!, box.maxWidth >= 700),
                          ),
                        ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: <Widget>[
                  // مرحلهٔ ۱۳: خروجی از snapshot ذخیره‌شدهٔ سرور (export)؛ تا پایان بارگذاری جزئیات غیرفعال.
                  FxRevalExportButtons(
                    enabled: r != null && err == null && FxRevalPerms.canView,
                    loader: () => FxRevalApi.I.export(widget.record.id),
                  ),
                  if (canRev)
                    FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: fxRevalLossColor(context)),
                      onPressed: () => Navigator.pop(context, true),
                      icon: const Icon(Icons.undo),
                      label: const Text('ابطال تسعیر'),
                    ),
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('بستن')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(BuildContext context, FxRevalRecord r, bool wide) {
    final FxRevalPreview? snap = r.snapshot;
    final bool stale = r.isEffective && r.stale;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (stale) _Banner(icon: Icons.history_toggle_off, color: Colors.orange.shade800, text: _kStaleHint),
        if (r.isAutoReversed)
          _Banner(icon: Icons.autorenew, color: Colors.blueGrey, text: 'این تسعیر خودکار برگشت خورده است؛ ابطال دستی ممکن نیست.'),
        FxRevalInfoRow('تاریخ تسعیر', _jd(r.asOf)),
        FxRevalInfoRow('وضعیت', r.statusLabel, valueColor: _statusColor(context, r)),
        if (r.revDate != null) FxRevalInfoRow('تاریخ برگشت خودکار', _jd(r.revDate)),
        FxRevalInfoRow(r.netGain > 0 ? 'سود خالص تحقق‌نیافته' : (r.netGain < 0 ? 'زیان خالص تحقق‌نیافته' : 'خالص'), fxRevalRial(r.netGain.abs()),
            valueColor: fxRevalEffectColor(context, r.netGain)),
        FxRevalInfoRow('جمع سودها', fxRevalRial(r.totalGain), valueColor: fxRevalGainColor(context)),
        FxRevalInfoRow('جمع زیان‌ها', fxRevalRial(r.totalLoss), valueColor: fxRevalLossColor(context)),
        FxRevalInfoRow('تعداد سند', Fmt.number(r.docCount)),
        if (r.note != null) FxRevalInfoRow('یادداشت', r.note!),
        if (r.createdBy != null || r.createdAt != null)
          FxRevalInfoRow('ثبت‌کننده', '${r.createdBy ?? ''}${r.createdAt == null ? '' : '  •  ${_stamp(r.createdAt)}'}'),
        if (r.reversedBy != null || r.reversedAt != null)
          FxRevalInfoRow('ابطال‌کننده', '${r.reversedBy ?? ''}${r.reversedAt == null ? '' : '  •  ${_stamp(r.reversedAt)}'}'),
        const SizedBox(height: 8),
        if (snap == null)
          Text('ریز محاسبه برای این تسعیر ذخیره نشده است.', style: TextStyle(color: fxRevalMutedColor(context)))
        else
          FxRevalPreviewBody(preview: snap, wide: wide),
      ],
    );
  }
}

// ===================== _Banner =====================

class _Banner extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  const _Banner({required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsetsDirectional.fromSTEB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}
