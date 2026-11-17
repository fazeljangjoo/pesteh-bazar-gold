// تسعیر ارز حرفه‌ای — مرحلهٔ ۱۰: صفحهٔ «تسعیر ارز» (فقط‌خواندنی: بررسی + پیش‌نمایش).
//
// ساختار (برای مراحل ۱۱ و ۱۲؛ پیدا کردن بخش‌ها: grep -n "^class\|// =====" fx_reval_ui.dart):
//   FxRevalScreen   ← وضعیت صفحه، فراخوانی FxRevalApi.I، نوار بالا، چینش ریسپانسیو
//   _CheckPanel     ← نتیجهٔ check (نرخ‌ها، هشدارها، سال مالی/قفل، مشکلات)
//   _SummaryCards   ← سود / زیان / خالص / تعداد فاکتور + پیام برگشت خودکار
//   _PreviewTable   ← ریز فاکتورها (عرض ≥ ۹۰۰: DataTable فشرده)
//   _PreviewCards   ← ریز فاکتورها (عرض کمتر: کارت عمودی؛ سازگار با اندروید)
//   _DocRow         ← یک فاکتور در حالت کارت
//   _SelectionPanel ← انتخاب جداگانهٔ فاکتورها (چک‌باکس، جست‌وجو؛ فاکتورِ قبلاً تسعیرشده غیرفعال)
//   _ApplyDialog    ← دیالوگ تأیید اعمال دسته‌ای (مرحلهٔ ۱۱)
//   API عمومی       ← fxReval* / FxRevalPreviewBody / FxRevalErrorBox برای fx_reval_history_ui.dart (مرحلهٔ ۱۲؛ انتهای فایل)
// هیچ محاسبهٔ حسابداری در UI نیست؛ همهٔ مبالغ از مدل‌ها/سرور می‌آید و فقط قالب‌بندی می‌شود.
// مبالغ تسعیر «ریال صحیح» هستند (مستقل از واحد نمایش شرکت) ⇒ با from/to = rial قالب‌بندی می‌شوند.
// مرحلهٔ ۱۱: اعمال دسته‌ای (_apply/_applyBlock/_ApplyDialog). مرحلهٔ ۱۲: فهرست/جزئیات/ابطال دستی.
import 'dart:async' show Timer;

import 'package:flutter/material.dart';

import 'fmt.dart' show Fmt;
import 'fx_rates_ui.dart' show FxRatesScreen;
import 'fx_reval_api.dart'; // FxRevalApi.I / FxRevalPerms + (export) همهٔ مدل‌ها و FxRevalException
import 'fx_reval_export.dart' show FxRevalExportButtons; // مرحلهٔ ۱۳ (Excel/PDF)
import 'fx_reval_history_ui.dart' show FxRevalHistory; // مرحلهٔ ۱۲ (فایل history خودش از همین فایل API عمومی می‌گیرد؛ ایمپورت دوری مجاز است)
import 'utils.dart' show jalaliDate, jalaliDateFromDt, toFaDigits;
import 'widgets.dart' show JalaliDateField, snack;

// مرحلهٔ ۱۳: main.dart فقط همین فایل را ایمپورت می‌کند و FxRevalPerms را برای نمایش ردیف منو از این‌جا می‌گیرد.
export 'fx_reval_api.dart' show FxRevalPerms;

/// عرض آستانهٔ حالت جدول؛ کمتر از آن کارت‌های عمودی.
const double _kWideBreakpoint = 900;

// ===================== ابزارهای قالب‌بندی (فقط نمایش) =====================

Color _gainColor(BuildContext c) => Theme.of(c).brightness == Brightness.dark ? Colors.green.shade300 : Colors.green.shade700;
Color _lossColor(BuildContext c) => Theme.of(c).brightness == Brightness.dark ? Colors.red.shade300 : Colors.red.shade700;
Color _mutedColor(BuildContext c) => Theme.of(c).colorScheme.onSurfaceVariant;

/// ریال صحیح با برچسب «ریال» (بدون تبدیل واحد).
String _rial(num v) => Fmt.money(v, from: 'rial', to: 'rial');

/// نرخ (ریال به‌ازای هر واحد ارز): تا ۴ رقم اعشار، صفرهای انتهایی حذف.
String _rateText(double v) => '${Fmt.number(v, dec: 4)} ریال';

/// مقدار ارزی: تا ۴ رقم اعشار.
String _ccyAmount(double v, String ccy) => '${Fmt.number(v, dec: 4)} $ccy';

/// اثر سودی/زیانی را بدون علامت منفی (برای جلوگیری از به‌هم‌ریختگی RTL) با برچسب «سود/زیان» می‌نویسد.
String _effectText(int effect) {
  if (effect == 0) return _rial(0);
  return '${_rial(effect.abs())} ${effect > 0 ? 'سود' : 'زیان'}';
}

Color _effectColor(BuildContext c, int effect) => effect > 0 ? _gainColor(c) : (effect < 0 ? _lossColor(c) : _mutedColor(c));

String _jalaliOrDash(String? iso) {
  if (iso == null || iso.isEmpty) return '—';
  try {
    return jalaliDate(iso);
  } catch (_) {
    return iso;
  }
}

String _errorText(Object e) {
  if (e is FxRevalException) return e.message;
  return 'خطای ناشناخته: $e';
}

/// تاریخ فقط‌روز (بدون ساعت).
DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

// ===================== صفحهٔ اصلی =====================

class FxRevalScreen extends StatefulWidget {
  /// پس از ثبت موفق تسعیر فراخوانی می‌شود (مرحلهٔ ۱۲: بازخوانی فهرست تسعیرها).
  final VoidCallback? onApplied;
  const FxRevalScreen({super.key, this.onApplied});

  @override
  State<FxRevalScreen> createState() => _FxRevalScreenState();
}

class _FxRevalScreenState extends State<FxRevalScreen> {
  DateTime _asOf = _dayOnly(DateTime.now());

  FxRevalCheck? _check;
  bool _checkLoading = false;
  Object? _checkError;

  FxRevalPreview? _preview;
  bool _previewLoading = false;
  Object? _previewError;

  /// فهرست فاکتورهای باز (action docs) و انتخاب کاربر؛ null = هنوز بارگذاری نشده. کلیدها "ar:12" / "ap:7".
  List<FxRevalCandidate>? _candidates;
  Set<String> _selected = <String>{};

  /// انتخاب تغییر کرده و بررسی/پیش‌نمایش تازه هنوز نرسیده؛ تا آن موقع اعمال بسته است.
  bool _selDirty = false;
  Timer? _selDebounce;

  /// اعمال دسته‌ای در جریان است (جلوگیری از کلیک دوباره) و خطای آخرین تلاش.
  bool _applying = false;
  Object? _applyError;

  /// با هر تغییر، `FxRevalHistory` دوباره بارگذاری می‌شود (پس از اعمال موفق / کشیدن برای تازه‌سازی).
  int _historyToken = 0;

  /// شمارندهٔ درخواست‌ها؛ پاسخ‌های کهنه (با تاریخ قبلی) نادیده گرفته می‌شوند.
  int _checkGen = 0;
  int _previewGen = 0;

  @override
  void initState() {
    super.initState();
    if (FxRevalPerms.canView) _runCheck();
  }

  @override
  void dispose() {
    _selDebounce?.cancel();
    super.dispose();
  }

  /// کلیدهای انتخاب‌شده (مرتب)؛ تا وقتی فهرست بارگذاری نشده null ⇒ سرور همهٔ فاکتورهای بازِ تسعیرنشده را در نظر می‌گیرد.
  List<String>? get _docKeys => _candidates == null ? null : (_selected.toList()..sort());

  Future<void> _runCheck() async {
    final int gen = ++_checkGen;
    setState(() {
      _checkLoading = true;
      _checkError = null;
    });
    try {
      final FxRevalCheck r = await FxRevalApi.I.check(_asOf, docKeys: _docKeys);
      if (!mounted || gen != _checkGen) return;
      setState(() {
        _check = r;
        _checkLoading = false;
      });
    } catch (e) {
      if (!mounted || gen != _checkGen) return;
      setState(() {
        _check = null;
        _checkError = e;
        _checkLoading = false;
      });
    }
  }

  /// [reload] true ⇒ فهرست فاکتورها دوباره خوانده می‌شود (انتخاب قبلی برای فاکتورهای هنوز قابل‌انتخاب حفظ می‌شود؛ بارِ اول: همهٔ فاکتورهای قابل‌انتخاب).
  /// پیش‌فرض: فقط اگر فهرست هنوز نیامده. false ⇒ فقط محاسبهٔ مجدد برای انتخاب فعلی.
  Future<void> _runPreview({bool? reload}) async {
    final int gen = ++_previewGen;
    final bool doReload = reload ?? (_candidates == null);
    setState(() {
      _previewLoading = true;
      _previewError = null;
    });
    try {
      if (doReload) {
        final List<FxRevalCandidate> c = await FxRevalApi.I.docs(_asOf);
        if (!mounted || gen != _previewGen) return;
        final Set<String> selectable = <String>{
          for (final FxRevalCandidate x in c)
            if (x.selectable) x.key
        };
        final Set<String> sel = _candidates == null ? selectable : _selected.intersection(selectable);
        setState(() {
          _candidates = c;
          _selected = sel;
        });
      }
      if (_selected.isEmpty) {
        // چیزی انتخاب نشده (یا فاکتور بازی نیست): محاسبه‌ای لازم نیست.
        setState(() {
          _preview = null;
          _previewLoading = false;
          _selDirty = false;
        });
        return;
      }
      final FxRevalPreview r = await FxRevalApi.I.preview(_asOf, docKeys: _docKeys);
      if (!mounted || gen != _previewGen) return;
      setState(() {
        _preview = r;
        _previewLoading = false;
        _selDirty = false;
      });
    } catch (e) {
      if (!mounted || gen != _previewGen) return;
      setState(() {
        _preview = null;
        _previewError = e;
        _previewLoading = false;
        _selDirty = false;
      });
    }
  }

  /// تغییر انتخاب فاکتورها ⇒ با کمی تأخیر (برای کلیک‌های پشت‌سرهم) بررسی و پیش‌نمایش برای انتخاب جدید.
  void _onSelectionChanged(Set<String> s) {
    if (_applying) return;
    _selDebounce?.cancel();
    setState(() {
      _selected = s;
      _selDirty = true;
      _previewError = null;
      _applyError = null;
    });
    _selDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      _runCheck();
      _runPreview(reload: false);
    });
  }

  /// دکمهٔ «بررسی و پیش‌نمایش»: هر دو را دوباره می‌گیرد.
  void _checkAndPreview() {
    _selDebounce?.cancel();
    _runPreview(reload: true).then((_) {
      if (mounted) _runCheck(); // بررسی با کلیدهای انتخابِ نهایی
    });
  }

  /// تغییر تاریخ ⇒ پیش‌نمایش قبلی باطل می‌شود و check خودکار اجرا می‌شود.
  void _onDateChanged(DateTime d) {
    final DateTime day = _dayOnly(d);
    if (day == _asOf || _applying) return;
    _selDebounce?.cancel();
    _previewGen++; // پاسخ در راهِ پیش‌نمایش قبلی دور ریخته شود
    setState(() {
      _candidates = null; // فاکتورهای باز به تاریخ وابسته‌اند
      _selected = <String>{};
      _selDirty = false;
      _asOf = day;
      _check = null;
      _preview = null;
      _previewError = null;
      _applyError = null;
      _previewLoading = false;
    });
    _runCheck();
  }

  Future<void> _openRates() async {
    await Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (BuildContext _) => const FxRatesScreen()));
    if (!mounted) return;
    // پس از ثبت نرخ: بررسی تازه؛ و اگر پیش‌نمایش به‌خاطر نبود نرخ شکست خورده بود، خطایش پاک شود.
    final Object? pe = _previewError;
    final Object? ae = _applyError;
    if ((pe is FxRevalException && pe.isRateMissing) || (ae is FxRevalException && ae.isRateMissing)) {
      setState(() {
        if (pe is FxRevalException && pe.isRateMissing) _previewError = null;
        if (ae is FxRevalException && ae.isRateMissing) _applyError = null;
      });
    }
    _runCheck();
  }

  /// کشیدن برای تازه‌سازی کل صفحه: فهرست تسعیرها + بررسی.
  Future<void> _pullRefresh() async {
    setState(() => _historyToken++);
    await _runCheck();
  }

  // ---------- اعمال دسته‌ای (مرحلهٔ ۱۱) ----------

  /// چرا دکمهٔ اعمال غیرفعال است؟ null ⇒ شرایط برقرار.
  String? _applyBlockReason() {
    final FxRevalCheck? c = _check;
    final FxRevalPreview? p = _preview;
    if (c == null) return 'ابتدا بررسی انجام شود.';
    if (_selDirty) return 'در حال به‌روزرسانی انتخاب فاکتورها…';
    if (_candidates != null && _candidates!.isNotEmpty && _selected.isEmpty) return 'هیچ فاکتوری انتخاب نشده است.';
    if (!c.canApply) return 'بر اساس نتیجهٔ بررسی، ثبت در وضعیت فعلی ممکن نیست.';
    if (p == null) return 'ابتدا «بررسی و پیش‌نمایش» را بزنید.';
    if (p.docCount <= 0) return 'فاکتور ارزی بازی برای تسعیر وجود ندارد.';
    return null;
  }

  bool get _canApplyNow => FxRevalPerms.canApply && !_applying && !_checkLoading && !_previewLoading && _applyBlockReason() == null;

  Future<void> _apply() async {
    if (!_canApplyNow) return;
    final FxRevalPreview p = _preview!;
    final String? note = await showDialog<String>(
      context: context,
      builder: (BuildContext _) => _ApplyDialog(preview: p, asOf: _asOf),
    );
    if (note == null || !mounted) return; // انصراف
    setState(() {
      _applying = true;
      _applyError = null;
    });
    try {
      await FxRevalApi.I.apply(_asOf, note: note, docKeys: _docKeys);
      if (!mounted) return;
      setState(() {
        _applying = false;
        _historyToken++; // فهرست تسعیرها دوباره خوانده شود
      });
      snack(context, 'تسعیر ثبت شد');
      widget.onApplied?.call();
      _checkAndPreview();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _applying = false;
        _applyError = e;
      });
    }
  }

  Widget _applyButton() {
    // موبایل: برچسب طولانی است؛ Flexible + softWrap تا در عرض باریک (یا فونت بزرگ) به‌جای سرریز، به دو خط برود.
    return FilledButton(
      onPressed: _canApplyNow ? _apply : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _applying
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.playlist_add_check_circle_outlined, size: 20),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              _applying
                  ? 'در حال ثبت…'
                  : (_candidates == null ? 'اعمال تسعیر دسته‌ای (همهٔ فاکتورهای باز)' : 'اعمال تسعیر برای فاکتورهای انتخاب‌شده (${Fmt.number(_selected.length)})'),
              textAlign: TextAlign.center,
              softWrap: true,
            ),
          ),
        ],
      ),
    );
  }

  /// دکمه + دلیل غیرفعال‌بودن؛ فقط با مجوز اعمال.
  Widget _applyBlock() {
    final String? why = _applying ? null : _applyBlockReason();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _applyButton(),
        if (why != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(why, textAlign: TextAlign.center, softWrap: true, style: TextStyle(fontSize: 12, color: _mutedColor(context))),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!FxRevalPerms.canView) {
      return Scaffold(
        appBar: AppBar(title: const Text('تسعیر ارز')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('تسعیر ارز فقط در نسخهٔ طلایی-ارزی و برای کاربران دارای مجوز در دسترس است.', textAlign: TextAlign.center),
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final bool wide = box.maxWidth >= _kWideBreakpoint;
        final bool showApply = FxRevalPerms.canApply;
        final Object? applyErr = _applyError;
        return Scaffold(
          appBar: AppBar(title: const Text('تسعیر ارز')),
          // حالت کارت (باریک/اندروید): نوار ثابت پایین با SafeArea
          bottomNavigationBar: (showApply && !wide)
              ? Material(
                  elevation: 8,
                  child: SafeArea(
                    child: Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 8), child: _applyBlock()),
                  ),
                )
              : null,
          body: RefreshIndicator(
            onRefresh: _pullRefresh,
            child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsetsDirectional.fromSTEB(12, 12, 12, 24),
            children: <Widget>[
              _buildTopBar(wide),
              const SizedBox(height: 12),
              _CheckPanel(
                check: _check,
                loading: _checkLoading,
                error: _checkError,
                onRetry: _runCheck,
                onOpenRates: _openRates,
              ),
              const SizedBox(height: 12),
              _buildPreviewArea(wide),
              if (applyErr != null) ...<Widget>[
                const SizedBox(height: 12),
                _ErrorBox(error: applyErr, onRetry: _apply, onOpenRates: _openRates),
              ],
              // حالت جدول (عریض): دکمه پایین پیش‌نمایش
              if (showApply && wide) ...<Widget>[
                const SizedBox(height: 16),
                Align(alignment: AlignmentDirectional.centerEnd, child: SizedBox(width: 420, child: _applyBlock())),
              ],
              // مرحلهٔ ۱۲: فهرست تسعیرهای ثبت‌شده؛ پس از ابطال، بررسی (تسعیر فعال) تازه می‌شود.
              const SizedBox(height: 24),
              FxRevalHistory(refreshToken: _historyToken, onChanged: _runCheck),
            ],
          ),
          ),
        );
      },
    );
  }

  Widget _buildTopBar(bool wide) {
    final Widget dateField = SizedBox(
      width: wide ? 220 : double.infinity,
      child: JalaliDateField(label: 'تاریخ تسعیر', value: _asOf, onChanged: _onDateChanged),
    );
    final Widget button = FilledButton.icon(
      onPressed: (_checkLoading || _previewLoading || _applying) ? null : _checkAndPreview,
      icon: const Icon(Icons.fact_check_outlined),
      label: const Text('بررسی و پیش‌نمایش'),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: wide
            ? Row(
                children: <Widget>[
                  dateField,
                  const SizedBox(width: 12),
                  button,
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      'نرخ‌ها و فاکتورهای ارزی باز در این تاریخ بررسی می‌شود. این صفحه فقط پیش‌نمایش است و چیزی ثبت نمی‌کند.',
                      style: TextStyle(color: _mutedColor(context), fontSize: 12.5),
                    ),
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  dateField,
                  const SizedBox(height: 8),
                  button,
                ],
              ),
      ),
    );
  }

  Widget _buildPreviewArea(bool wide) {
    final List<FxRevalCandidate>? cands = _candidates;
    final Widget body = _buildPreviewBody(wide, cands != null && cands.isNotEmpty);
    if (cands == null || cands.isEmpty) return body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SelectionPanel(candidates: cands, selected: _selected, enabled: !_applying, onChanged: _onSelectionChanged),
        const SizedBox(height: 12),
        body,
      ],
    );
  }

  Widget _buildPreviewBody(bool wide, bool hasPanel) {
    if (_previewLoading) {
      // با پنل انتخاب: فقط نوار باریک تا چک‌باکس‌ها سر جایشان بمانند.
      return hasPanel
          ? const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: LinearProgressIndicator())
          : const Padding(padding: EdgeInsets.symmetric(vertical: 32), child: Center(child: CircularProgressIndicator()));
    }
    final Object? err = _previewError;
    if (err != null) {
      return _ErrorBox(error: err, onRetry: _runPreview, onOpenRates: _openRates);
    }
    final FxRevalPreview? p = _preview;
    if (_candidates != null && _candidates!.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: <Widget>[
              const Icon(Icons.inbox_outlined, size: 40),
              const SizedBox(height: 8),
              const Text('فاکتور ارزی بازی برای این تاریخ وجود ندارد؛ چیزی برای تسعیر نیست.', textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    if (p == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            hasPanel
                ? 'فاکتوری انتخاب نشده است؛ برای دیدن سود و زیان تحقق‌نیافته، دست‌کم یک فاکتور را انتخاب کنید.'
                : 'تاریخ تسعیر را انتخاب کنید و «بررسی و پیش‌نمایش» را بزنید تا سود و زیان تحقق‌نیافتهٔ فاکتورهای ارزی باز نمایش داده شود.',
            textAlign: TextAlign.center,
            style: TextStyle(color: _mutedColor(context)),
          ),
        ),
      );
    }
    if (p.docs.isEmpty && p.items.isEmpty && !p.hasChanges) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: <Widget>[
              const Icon(Icons.inbox_outlined, size: 40),
              const SizedBox(height: 8),
              const Text('فاکتور ارزی بازی برای این تاریخ وجود ندارد؛ چیزی برای تسعیر نیست.', textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    final DateTime base = p.asOfDate ?? _asOf;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SummaryCards(preview: p, wide: wide, asOf: base),
        const SizedBox(height: 12),
        if (p.docs.isNotEmpty) ...<Widget>[
          // مرحلهٔ ۱۳: خروجی پیش‌نمایش جاری (قبل از اعمال) — داده محلی از همین پیش‌نمایش ساخته می‌شود
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FxRevalExportButtons(loader: () async => FxRevalExport.fromPreview(p)),
          ),
          const _SectionHeader('ریز فاکتورها (به تفکیک ارز و طلب/بدهی)'),
          if (wide) _PreviewTable(preview: p) else _PreviewCards(preview: p),
          const SizedBox(height: 12),
        ],
        if (p.parties.isNotEmpty) ...<Widget>[
          const _SectionHeader('به تفکیک طرف‌حساب'),
          _PartiesSection(parties: p.parties),
        ],
      ],
    );
  }
}

// ===================== اجزای مشترک کوچک =====================

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(4, 8, 4, 6),
      child: Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
    );
  }
}

/// جعبهٔ خطا (FxRevalException و غیره) با «تلاش مجدد»؛ برای rate_missing فهرست ارزها + «ثبت نرخ».
class _ErrorBox extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;
  final VoidCallback? onOpenRates;
  const _ErrorBox({required this.error, required this.onRetry, this.onOpenRates});

  @override
  Widget build(BuildContext context) {
    final Color c = _lossColor(context);
    final Object e = error;
    final FxRevalException? fx = e is FxRevalException ? e : null;
    final bool rateMissing = fx != null && fx.isRateMissing;
    final bool network = fx != null && fx.isNetwork;
    // تلاش مجدد برای خطاهای دائمی (دسترسی/نسخه/تعارض) فایده ندارد.
    final bool retryable = fx == null || !(fx.code == FxRevalException.codeForbidden || fx.code == FxRevalException.codeEditionRequired || fx.isConflict);
    final List<String> ccys = fx?.ccys ?? const <String>[];
    final List<FxRevalProblem> problems = fx?.problems ?? const <FxRevalProblem>[];
    final bool duplicate = fx != null && fx.isConflict && fx.reason == 'duplicate';
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: c)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(network ? Icons.wifi_off_outlined : Icons.error_outline, color: c),
                const SizedBox(width: 8),
                Expanded(child: Text(_errorText(e), style: TextStyle(color: c, fontWeight: FontWeight.w600))),
              ],
            ),
            if (rateMissing && ccys.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text('ارزهای بدون نرخ: ${ccys.join('، ')}'),
            ],
            for (final FxRevalProblem pr in problems)
              if (pr.message.isNotEmpty && pr.message != _errorText(e))
                Padding(padding: const EdgeInsets.only(top: 4), child: Text('• ${pr.message}', style: const TextStyle(fontSize: 13))),
            if (duplicate) ...<Widget>[
              const SizedBox(height: 8),
              const Text('فاکتور(های) انتخابی قبلاً در یک تسعیر فعالِ همین تاریخ لحاظ شده‌اند. اگر باید دوباره تسعیر شوند، ابتدا آن تسعیر را از «فهرست تسعیرها» ابطال کنید یا فاکتورهای دیگری را انتخاب کنید.',
                  style: TextStyle(fontSize: 13)),
            ],
            if (retryable || (rateMissing && onOpenRates != null)) ...<Widget>[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  if (retryable) OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('تلاش مجدد')),
                  if (rateMissing && onOpenRates != null)
                    FilledButton.icon(onPressed: onOpenRates, icon: const Icon(Icons.currency_exchange), label: const Text('ثبت نرخ')),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// نوار پیام رنگی (هشدار/اطلاع).
class _Notice extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  final Widget? trailing;
  const _Notice({required this.icon, required this.color, required this.text, this.trailing});

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
          if (trailing != null) ...<Widget>[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}

// ===================== _CheckPanel =====================

/// پنل بررسی (خروجی `check`): نرخ ارزها، تسعیر فعال، سال مالی/قفل، چک‌های نادیده، مشکلات.
class _CheckPanel extends StatelessWidget {
  final FxRevalCheck? check;
  final bool loading;
  final Object? error;
  final VoidCallback onRetry;
  final VoidCallback onOpenRates;
  const _CheckPanel({required this.check, required this.loading, required this.error, required this.onRetry, required this.onOpenRates});

  static String _fiscalStatusLabel(String? s) {
    if (s == null || s.isEmpty) return '';
    if (s == 'open') return 'باز';
    if (s == 'closed') return 'بسته';
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final FxRevalCheck? c = check;
    final Object? err = error;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(child: Text('نتیجهٔ بررسی', style: Theme.of(context).textTheme.titleMedium)),
                if (c != null && !loading) Flexible(child: _canApplyChip(context, c)),
              ],
            ),
            const SizedBox(height: 8),
            if (loading) ...<Widget>[
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text('در حال بررسی…', style: TextStyle(color: _mutedColor(context))),
            ] else if (err != null)
              _ErrorBox(error: err, onRetry: onRetry)
            else if (c == null)
              Text('هنوز بررسی انجام نشده است.', style: TextStyle(color: _mutedColor(context)))
            else
              ..._body(context, c),
          ],
        ),
      ),
    );
  }

  Widget _canApplyChip(BuildContext context, FxRevalCheck c) {
    final Color col = c.canApply ? _gainColor(context) : _lossColor(context);
    return Chip(
      avatar: Icon(c.canApply ? Icons.check_circle_outline : Icons.block, size: 18, color: col),
      label: Text(c.canApply ? 'شرایط ثبت برقرار است' : 'ثبت در وضعیت فعلی ممکن نیست', style: TextStyle(color: col, fontSize: 12)),
      visualDensity: VisualDensity.compact,
      side: BorderSide(color: col.withValues(alpha: 0.5)),
      backgroundColor: Colors.transparent,
    );
  }

  List<Widget> _body(BuildContext context, FxRevalCheck c) {
    final Color bad = _lossColor(context);
    final Color good = _gainColor(context);
    final Color warn = Colors.orange.shade800;
    final Color info = Theme.of(context).colorScheme.primary;
    final List<Widget> w = <Widget>[];

    // --- تاریخ، سال مالی، قفل ---
    if (c.inFuture) {
      w.add(_Notice(icon: Icons.event_busy_outlined, color: bad, text: 'تاریخ تسعیر در آینده است؛ تسعیر فقط تا امروز مجاز است.'));
    }
    if (c.fiscalOk) {
      final String st = _fiscalStatusLabel(c.fiscalStatus);
      final String name = c.fiscalName ?? '';
      w.add(_Notice(
        icon: Icons.verified_outlined,
        color: good,
        text: 'سال مالی: ${name.isEmpty ? 'مشخص' : name}${st.isEmpty ? '' : ' ($st)'}',
      ));
    } else {
      w.add(_Notice(icon: Icons.warning_amber_rounded, color: bad, text: 'برای این تاریخ سال مالیِ معتبر (باز) وجود ندارد.'));
    }
    if (c.periodLocked) {
      w.add(_Notice(icon: Icons.lock_outline, color: bad, text: 'دورهٔ مالی این تاریخ قفل است.'));
    }
    if (c.hasActiveReval) {
      final String id = toFaDigits('${c.activeRevalId}');
      w.add(_Notice(
        icon: Icons.info_outline,
        color: warn,
        text: 'برای این تاریخ تسعیر فعال هست (شمارهٔ $id). فاکتورهای آن در انتخاب غیرفعال‌اند؛ برای تسعیر دوبارهٔ آن‌ها ابتدا آن تسعیر را از «فهرست تسعیرها» ابطال کنید.',
      ));
    }

    // --- نرخ‌ها ---
    w.add(const _SectionHeader('نرخ ارزها در تاریخ تسعیر'));
    final List<String> shown = <String>[for (final FxRevalRate r in c.rates) r.ccy];
    final List<String> extraMissing = <String>[
      for (final String m in c.missingCcys)
        if (!shown.contains(m)) m
    ];
    if (c.rates.isEmpty && extraMissing.isEmpty) {
      w.add(Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text('ارزی برای بررسی نرخ وجود ندارد.', style: TextStyle(color: _mutedColor(context))),
      ));
    }
    for (final FxRevalRate r in c.rates) {
      w.add(_rateRow(context, r.ccy, r.missing ? null : r.rate, r.rateDate, r.missing));
    }
    for (final String m in extraMissing) {
      w.add(_rateRow(context, m, null, null, true));
    }

    // --- فاکتورهای باز و چک‌های نادیده ---
    w.add(const _SectionHeader('فاکتورهای ارزی باز'));
    w.add(Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        'طلب (فروش): ${Fmt.number(c.openDocsAr)} فاکتور   •   بدهی (خرید): ${Fmt.number(c.openDocsAp)} فاکتور',
      ),
    ));
    if (c.ignoredCheques > 0) {
      w.add(_Notice(
        icon: Icons.receipt_long_outlined,
        color: info,
        text: 'چک/قسط ارزی تسویه حساب نمی‌شود (${Fmt.number(c.ignoredCheques)} مورد)؛ مانده‌ی ارزی فاکتورها بدون احتساب آن‌ها محاسبه می‌شود.',
      ));
    }

    // --- مشکلات ---
    if (c.problems.isNotEmpty) {
      w.add(const _SectionHeader('مشکلات'));
      for (final FxRevalProblem p in c.problems) {
        final String extra = p.ccys.isEmpty ? '' : ' (${p.ccys.join('، ')})';
        w.add(_Notice(
          icon: Icons.error_outline,
          color: bad,
          text: '${p.message.isEmpty ? p.code : p.message}$extra',
        ));
      }
    }
    return w;
  }

  Widget _rateRow(BuildContext context, String ccy, double? rate, String? rateDate, bool missing) {
    final Color bad = _lossColor(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: <Widget>[
          SizedBox(width: 56, child: Text(ccy, style: const TextStyle(fontWeight: FontWeight.w700))),
          Expanded(
            child: missing
                ? Row(
                    children: <Widget>[
                      Icon(Icons.error_outline, size: 18, color: bad),
                      const SizedBox(width: 6),
                      Flexible(child: Text('نرخ ثبت نشده', style: TextStyle(color: bad, fontWeight: FontWeight.w600))),
                    ],
                  )
                : Text(
                    rate == null ? '—' : '${_rateText(rate)}   (نرخ مورخ ${_jalaliOrDash(rateDate)})',
                    style: const TextStyle(fontSize: 13),
                  ),
          ),
          if (missing)
            TextButton.icon(
              onPressed: onOpenRates,
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('ثبت نرخ'),
              style: TextButton.styleFrom(foregroundColor: bad),
            ),
        ],
      ),
    );
  }
}

// ===================== _SummaryCards =====================

/// کارت‌های خلاصه + پیام برگشت خودکار. مبالغ همه از مدل (totalGain/totalLoss/netGain/docCount).
class _SummaryCards extends StatelessWidget {
  final FxRevalPreview preview;
  final bool wide;
  final DateTime asOf;
  const _SummaryCards({required this.preview, required this.wide, required this.asOf});

  @override
  Widget build(BuildContext context) {
    final FxRevalPreview p = preview;
    final int net = p.netGain;
    final String netTitle = net > 0 ? 'سود خالص تحقق‌نیافته' : (net < 0 ? 'زیان خالص تحقق‌نیافته' : 'خالص');
    final DateTime next = DateTime(asOf.year, asOf.month, asOf.day + 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints box) {
            const double gap = 8;
            final int n = wide ? 4 : 2;
            final double w = (box.maxWidth - gap * (n - 1)) / n;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: <Widget>[
                _StatCard(width: w, title: 'جمع سودها', value: _rial(p.totalGain), color: _gainColor(context), icon: Icons.trending_up),
                _StatCard(width: w, title: 'جمع زیان‌ها', value: _rial(p.totalLoss), color: _lossColor(context), icon: Icons.trending_down),
                _StatCard(width: w, title: netTitle, value: _rial(net.abs()), color: _effectColor(context, net), icon: Icons.balance_outlined),
                _StatCard(
                  width: w,
                  title: 'تعداد فاکتور',
                  value: '${Fmt.number(p.docCount)} فاکتور',
                  color: Theme.of(context).colorScheme.primary,
                  icon: Icons.receipt_long_outlined,
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 10),
        if (!p.hasChanges)
          _Notice(
            icon: Icons.info_outline,
            color: _mutedColor(context),
            text: 'اختلاف ریالی وجود ندارد؛ برای این تاریخ سند تسعیری ساخته نمی‌شود.',
          )
        else
          _Notice(
            icon: Icons.autorenew,
            color: Theme.of(context).colorScheme.primary,
            text: 'این سند در تاریخ ${jalaliDateFromDt(next)} (شمسی) خودکار برگشت می‌خورد. '
                'اگر سال یا دورهٔ مالی آن تاریخ هنوز باز نباشد، برگشت در انتظار می‌ماند و پس از باز شدن ثبت می‌شود.',
          ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final double width;
  final String title;
  final String value;
  final Color color;
  final IconData icon;
  const _StatCard({required this.width, required this.title, required this.value, required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(icon, size: 18, color: color),
                  const SizedBox(width: 6),
                  Expanded(child: Text(title, softWrap: true, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: _mutedColor(context)))),
                ],
              ),
              const SizedBox(height: 6),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Text(value, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: color)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===================== گروه (ارز × طرف) =====================

/// یک گروه ارز×طرف به‌صورت ExpansionTile؛ بدنه را _PreviewTable یا _PreviewCards می‌دهد.
class _GroupTile extends StatelessWidget {
  final FxRevalDocGroup group;
  final List<Widget> children;
  const _GroupTile({required this.group, required this.children});

  @override
  Widget build(BuildContext context) {
    final Color ec = _effectColor(context, group.effect);
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text('${group.ccy}  •  ${group.sideLabel}', style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text.rich(
          TextSpan(
            style: TextStyle(fontSize: 12.5, color: _mutedColor(context)),
            children: <InlineSpan>[
              TextSpan(text: '${Fmt.number(group.docs.length)} فاکتور  •  مانده ارزی ${_ccyAmount(group.remCcy, group.ccy)}  •  '),
              TextSpan(text: _effectText(group.effect), style: TextStyle(color: ec, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
        childrenPadding: const EdgeInsetsDirectional.fromSTEB(8, 0, 8, 8),
        children: children,
      ),
    );
  }
}

// ===================== _PreviewTable =====================

/// حالت جدول (عرض ≥ ۹۰۰): برای هر گروه یک DataTable فشرده.
class _PreviewTable extends StatelessWidget {
  final FxRevalPreview preview;
  const _PreviewTable({required this.preview});

  @override
  Widget build(BuildContext context) {
    final List<FxRevalDocGroup> groups = preview.groupDocs(byParty: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final FxRevalDocGroup g in groups)
          _GroupTile(
            group: g,
            children: <Widget>[
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columnSpacing: 24,
                  headingRowHeight: 36,
                  dataRowMinHeight: 32,
                  dataRowMaxHeight: 40,
                  columns: const <DataColumn>[
                    DataColumn(label: Text('شمارهٔ سند')),
                    DataColumn(label: Text('طرف‌حساب')),
                    DataColumn(label: Text('مانده ارزی')),
                    DataColumn(label: Text('نرخ ثبت‌شده')),
                    DataColumn(label: Text('نرخ روز')),
                    DataColumn(label: Text('اختلاف ریالی')),
                  ],
                  rows: <DataRow>[
                    for (final FxRevalDoc d in g.docs)
                      DataRow(cells: <DataCell>[
                        DataCell(Text(d.ref)),
                        DataCell(Text(d.party.isEmpty ? '—' : d.party)),
                        DataCell(Text(_ccyAmount(d.remCcy, d.ccy))),
                        DataCell(Text(_rateText(d.bookedRate))),
                        DataCell(Text(_rateText(d.rate))),
                        DataCell(Text(_effectText(d.effect), style: TextStyle(color: _effectColor(context, d.effect), fontWeight: FontWeight.w600))),
                      ]),
                  ],
                ),
              ),
            ],
          ),
      ],
    );
  }
}

// ===================== _PreviewCards =====================

/// حالت کارت (عرض کمتر از ۹۰۰ و اندروید): برای هر گروه فهرست عمودی `_DocRow`.
class _PreviewCards extends StatelessWidget {
  final FxRevalPreview preview;
  const _PreviewCards({required this.preview});

  @override
  Widget build(BuildContext context) {
    final List<FxRevalDocGroup> groups = preview.groupDocs(byParty: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final FxRevalDocGroup g in groups)
          _GroupTile(
            group: g,
            children: <Widget>[for (final FxRevalDoc d in g.docs) _DocRow(doc: d)],
          ),
      ],
    );
  }
}

// ===================== _DocRow =====================

/// یک فاکتور در حالت کارت: شمارهٔ سند + اثر ریالی، طرف‌حساب، مانده و نرخ‌ها.
class _DocRow extends StatelessWidget {
  final FxRevalDoc doc;
  const _DocRow({required this.doc});

  @override
  Widget build(BuildContext context) {
    final FxRevalDoc d = doc;
    final TextStyle small = TextStyle(fontSize: 12.5, color: _mutedColor(context));
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text('سند ${d.ref}', softWrap: true, style: const TextStyle(fontWeight: FontWeight.w700))),
              const SizedBox(width: 8),
              FxRevalEffectLabel(effect: d.effect),
            ],
          ),
          if (d.party.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Text(d.party, softWrap: true, style: small)),
          const SizedBox(height: 6),
          Text('مانده ارزی: ${_ccyAmount(d.remCcy, d.ccy)}', style: small),
          Text('نرخ ثبت‌شده: ${_rateText(d.bookedRate)}', style: small),
          Text('نرخ روز: ${_rateText(d.rate)}', style: small),
        ],
      ),
    );
  }
}

// ===================== به تفکیک طرف‌حساب =====================

class _PartiesSection extends StatelessWidget {
  final List<FxRevalParty> parties;
  const _PartiesSection({required this.parties});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: <Widget>[
            for (int i = 0; i < parties.length; i++) ...<Widget>[
              if (i > 0) const Divider(height: 1),
              _partyRow(context, parties[i]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _partyRow(BuildContext context, FxRevalParty p) {
    final String name = (p.noParty || p.party.isEmpty) ? 'بدون طرف‌حساب' : p.party;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(14, 8, 14, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(name, softWrap: true, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(p.sideLabel, softWrap: true, style: TextStyle(fontSize: 12, color: _mutedColor(context))),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FxRevalEffectLabel(effect: p.effect),
        ],
      ),
    );
  }
}

// ===================== انتخاب جداگانهٔ فاکتورها =====================

/// فهرست فاکتورهای ارزیِ باز با چک‌باکس. فاکتورِ قبلاً تسعیرشده (coveredBy) غیرفعال است. هیچ محاسبه‌ای این‌جا نیست؛
/// تغییر انتخاب را به بالا می‌دهد و صفحه از سرور دوباره پیش‌نمایش می‌گیرد.
class _SelectionPanel extends StatefulWidget {
  final List<FxRevalCandidate> candidates;
  final Set<String> selected;
  final bool enabled;
  final ValueChanged<Set<String>> onChanged;
  const _SelectionPanel({required this.candidates, required this.selected, required this.enabled, required this.onChanged});

  @override
  State<_SelectionPanel> createState() => _SelectionPanelState();
}

class _SelectionPanelState extends State<_SelectionPanel> {
  final TextEditingController _q = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  List<FxRevalCandidate> get _visible {
    final String q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.candidates;
    return <FxRevalCandidate>[
      for (final FxRevalCandidate c in widget.candidates)
        if (c.ref.toLowerCase().contains(q) || c.party.toLowerCase().contains(q) || c.ccy.toLowerCase().contains(q)) c
    ];
  }

  void _toggle(String key, bool on) {
    final Set<String> s = <String>{...widget.selected};
    if (on) {
      s.add(key);
    } else {
      s.remove(key);
    }
    widget.onChanged(s);
  }

  /// انتخاب/برداشتن همهٔ فاکتورهای قابل‌انتخابِ نمایش‌داده‌شده (با جست‌وجو: فقط نتیجه‌ها).
  void _setVisible(bool on) {
    final Set<String> s = <String>{...widget.selected};
    for (final FxRevalCandidate c in _visible) {
      if (!c.selectable) continue;
      if (on) {
        s.add(c.key);
      } else {
        s.remove(c.key);
      }
    }
    widget.onChanged(s);
  }

  @override
  Widget build(BuildContext context) {
    final List<FxRevalCandidate> vis = _visible;
    final int selectable = widget.candidates.where((FxRevalCandidate c) => c.selectable).length;
    final int covered = widget.candidates.length - selectable;
    final int chosen = widget.selected.length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(child: Text('انتخاب فاکتورها', style: Theme.of(context).textTheme.titleMedium)),
                Text('${Fmt.number(chosen)} از ${Fmt.number(selectable)} انتخاب شده', style: TextStyle(fontSize: 12.5, color: _mutedColor(context))),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'تسعیر فقط برای فاکتورهای تیک‌خورده ثبت می‌شود.'
              '${covered > 0 ? ' ${Fmt.number(covered)} فاکتور قبلاً در تسعیر فعالِ همین تاریخ لحاظ شده و غیرفعال است.' : ''}',
              style: TextStyle(fontSize: 12.5, color: _mutedColor(context)),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _q,
              onChanged: (String v) => setState(() => _query = v),
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 20),
                hintText: 'جست‌وجوی شمارهٔ سند، طرف‌حساب یا ارز',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: <Widget>[
                TextButton.icon(
                  onPressed: widget.enabled ? () => _setVisible(true) : null,
                  icon: const Icon(Icons.select_all, size: 18),
                  label: Text(_query.trim().isEmpty ? 'انتخاب همه' : 'انتخاب نتایج'),
                ),
                TextButton.icon(
                  onPressed: widget.enabled ? () => _setVisible(false) : null,
                  icon: const Icon(Icons.deselect, size: 18),
                  label: Text(_query.trim().isEmpty ? 'برداشتن همه' : 'برداشتن نتایج'),
                ),
              ],
            ),
            if (vis.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text('موردی پیدا نشد.', textAlign: TextAlign.center, style: TextStyle(color: _mutedColor(context))),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 340),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: vis.length,
                  itemBuilder: (BuildContext context, int i) => _candidateTile(context, vis[i]),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _candidateTile(BuildContext context, FxRevalCandidate c) {
    final TextStyle small = TextStyle(fontSize: 12.5, color: _mutedColor(context));
    final bool on = widget.selected.contains(c.key);
    return CheckboxListTile(
      value: on,
      onChanged: (!widget.enabled || !c.selectable) ? null : (bool? v) => _toggle(c.key, v ?? false),
      controlAffinity: ListTileControlAffinity.leading,
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text('سند ${c.ref}${c.party.isEmpty ? '' : '  •  ${c.party}'}', softWrap: true, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        '${c.sideLabel}  •  مانده ${_ccyAmount(c.remCcy, c.ccy)}'
        '${c.isCovered ? '\nقبلاً در تسعیر شمارهٔ ${toFaDigits('${c.coveredBy}')}' : ''}',
        softWrap: true,
        style: small,
      ),
      secondary: c.rateMissing
          ? Text('نرخ ثبت نشده', style: TextStyle(fontSize: 12, color: _lossColor(context)))
          : FxRevalEffectLabel(effect: c.effect ?? 0, maxWidth: 130),
    );
  }
}

// ===================== دیالوگ تأیید اعمال (مرحلهٔ ۱۱) =====================

/// تعداد ارزهای درگیر (فقط شمارش از دادهٔ پیش‌نمایش).
int _ccyCountOf(FxRevalPreview p) {
  final Set<String> s = <String>{for (final FxRevalDoc d in p.docs) d.ccy};
  if (s.isEmpty) {
    for (final FxRevalItem it in p.items) {
      s.add(it.ccy);
    }
  }
  return s.length;
}

/// دیالوگ تأیید: با «تأیید و ثبت» رشتهٔ یادداشت (ممکن است خالی باشد) و با «انصراف» null برمی‌گرداند.
class _ApplyDialog extends StatefulWidget {
  final FxRevalPreview preview;
  final DateTime asOf;
  const _ApplyDialog({required this.preview, required this.asOf});

  @override
  State<_ApplyDialog> createState() => _ApplyDialogState();
}

class _ApplyDialogState extends State<_ApplyDialog> {
  final TextEditingController _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final FxRevalPreview p = widget.preview;
    final DateTime a = widget.asOf;
    final DateTime next = DateTime(a.year, a.month, a.day + 1);
    final int net = p.netGain;
    return AlertDialog(
      title: const Text('تأیید تسعیر دسته‌ای'),
      content: SizedBox(
        // گوشی: AlertDialog حاشیهٔ افقی ۴۰ دارد؛ عرض ثابت ۴۲۰ از صفحه بیرون می‌زد.
        width: (MediaQuery.sizeOf(context).width - 112).clamp(240.0, 420.0).toDouble(), // clamp روی double نوع num می‌دهد
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              FxRevalInfoRow('تاریخ سند', jalaliDateFromDt(a)),
              FxRevalInfoRow('برگشت خودکار در', jalaliDateFromDt(next)),
              FxRevalInfoRow(net > 0 ? 'سود خالص تحقق‌نیافته' : (net < 0 ? 'زیان خالص تحقق‌نیافته' : 'خالص'), _rial(net.abs()), valueColor: _effectColor(context, net)),
              FxRevalInfoRow('تعداد فاکتور', Fmt.number(p.docCount)),
              FxRevalInfoRow('تعداد ارز', Fmt.number(_ccyCountOf(p))),
              const SizedBox(height: 8),
              TextField(
                controller: _note,
                maxLength: 255,
                maxLines: 2,
                decoration: const InputDecoration(labelText: 'یادداشت (اختیاری)', border: OutlineInputBorder()),
              ),
              Text(
                'یک سند تسعیر برای همین فاکتورهای انتخاب‌شده ثبت می‌شود و روز بعد خودکار برگشت می‌خورد.',
                style: TextStyle(fontSize: 12, color: _mutedColor(context)),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('انصراف')),
        FilledButton(onPressed: () => Navigator.pop(context, _note.text.trim()), child: const Text('تأیید و ثبت')),
      ],
    );
  }
}

// ===================== API عمومی برای fx_reval_history_ui.dart (مرحلهٔ ۱۲) =====================
// نمایش‌دهنده‌های مشترک؛ فقط پوستهٔ نازک روی ابزارهای خصوصی همین فایل (بدون منطق جدید).

String fxRevalRial(num v) => _rial(v);
String fxRevalEffectText(int effect) => _effectText(effect);
String fxRevalErrorText(Object e) => _errorText(e);
Color fxRevalEffectColor(BuildContext c, int effect) => _effectColor(c, effect);
Color fxRevalGainColor(BuildContext c) => _gainColor(c);
Color fxRevalLossColor(BuildContext c) => _lossColor(c);
Color fxRevalMutedColor(BuildContext c) => _mutedColor(c);

/// برچسب اثر سود/زیان با سقف عرض؛ مبلغ‌های بلند به‌جای سرریز در همان کادر می‌شکنند (موبایل).
class FxRevalEffectLabel extends StatelessWidget {
  final int effect;
  final double maxWidth;
  const FxRevalEffectLabel({super.key, required this.effect, this.maxWidth = 170});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Text(
        _effectText(effect),
        textAlign: TextAlign.end,
        softWrap: true,
        style: TextStyle(color: _effectColor(context, effect), fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// ردیف «کلید: مقدار» برای دیالوگ‌ها. مقدار بلند (یادداشت تا ۲۵۵ نویسه، «نام • تاریخ») در همان ردیف می‌شکند؛
/// `infoRow` مشترک مقدار را بدون Flexible می‌گذارد و روی موبایل سرریز می‌داد. هر دو ستون Expanded (نسبت ۲:۳).
class FxRevalInfoRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  const FxRevalInfoRow(this.label, this.value, {super.key, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(flex: 2, child: Text(label, softWrap: true, style: TextStyle(color: _mutedColor(context)))),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: Text(value, textAlign: TextAlign.end, softWrap: true, style: TextStyle(fontWeight: FontWeight.w600, color: valueColor)),
          ),
        ],
      ),
    );
  }
}

/// جعبهٔ خطای مشترک (همان `_ErrorBox`).
class FxRevalErrorBox extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;
  const FxRevalErrorBox({super.key, required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) => _ErrorBox(error: error, onRetry: onRetry);
}

/// ریز یک محاسبه (پیش‌نمایش یا snapshot ذخیره‌شده): نرخ‌ها، فاکتورها (گروه ارز×طرف)، طرف‌حساب‌ها.
/// ردیف قدیمی (فقط items) ⇒ جمع هر ارز×طرف.
class FxRevalPreviewBody extends StatelessWidget {
  final FxRevalPreview preview;
  final bool wide;
  const FxRevalPreviewBody({super.key, required this.preview, required this.wide});

  @override
  Widget build(BuildContext context) {
    final FxRevalPreview p = preview;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (p.rates.isNotEmpty) ...<Widget>[
          const _SectionHeader('نرخ ارزها'),
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: <Widget>[
                  for (final FxRevalRate r in p.rates)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: <Widget>[
                          SizedBox(width: 56, child: Text(r.ccy, style: const TextStyle(fontWeight: FontWeight.w700))),
                          Expanded(
                            child: Text(
                              r.rate == null ? 'نرخ ثبت نشده' : '${_rateText(r.rate!)}   (نرخ مورخ ${_jalaliOrDash(r.rateDate)})',
                              style: TextStyle(fontSize: 13, color: r.rate == null ? _lossColor(context) : null),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
        if (p.docs.isNotEmpty) ...<Widget>[
          const _SectionHeader('ریز فاکتورها (به تفکیک ارز و طلب/بدهی)'),
          if (wide) _PreviewTable(preview: p) else _PreviewCards(preview: p),
        ] else if (p.items.isNotEmpty) ...<Widget>[
          const _SectionHeader('به تفکیک ارز'),
          Card(
            child: Column(
              children: <Widget>[
                for (final FxRevalItem it in p.items)
                  Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(14, 8, 14, 8),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text('${it.ccy}  •  ${it.sideLabel}  •  مانده ارزی ${_ccyAmount(it.openCcy, it.ccy)}', softWrap: true, style: const TextStyle(fontSize: 13)),
                        ),
                        const SizedBox(width: 8),
                        FxRevalEffectLabel(effect: it.effect),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
        if (p.parties.isNotEmpty) ...<Widget>[
          const SizedBox(height: 4),
          const _SectionHeader('به تفکیک طرف‌حساب'),
          _PartiesSection(parties: p.parties),
        ],
      ],
    );
  }
}
