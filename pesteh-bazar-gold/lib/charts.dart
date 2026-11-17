import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'fmt.dart' show Fmt;
import 'utils.dart';

// ============================================================================
// نمودارهای ساده و تمیز «پسته بازار» — بدون هیچ پکیج خارجی (فقط CustomPaint)
// ============================================================================

/// پالت رنگ ملایم، هماهنگ با سبز پسته
const List<Color> kChartPalette = [
  Color(0xFF5B7F2A), // سبز پسته
  Color(0xFFD9A441), // طلایی
  Color(0xFF3E8E8A), // فیروزه‌ای
  Color(0xFFC1673E), // آجری
  Color(0xFF7A6BB0), // بنفش ملایم
  Color(0xFF8FA64B), // سبز روشن
];
const Color kChartOther = Color(0xFF9E9E9E);
const Color kGainColor = Color(0xFF2E7D32);
const Color kLossColor = Color(0xFFC62828);

/// عدد کوتاه‌شده برای نمودار (ریال): ۱٫۲ هزار میلیارد / ۱٫۲ میلیارد / ۴۵۰ میلیون / ۱۲ هزار
String faCompact(double v) {
  final a = v.abs();
  final sign = v < 0 ? '-' : '';
  if (a >= 1e12) return '$sign${faNum(a / 1e12, dec: 1)} هزار میلیارد';
  if (a >= 1e9) return '$sign${faNum(a / 1e9, dec: 1)} میلیارد';
  if (a >= 1e6) return '$sign${faNum(a / 1e6, dec: 1)} میلیون';
  if (a >= 1e3) return '$sign${faNum(a / 1e3, dec: 0)} هزار';
  return '$sign${faNum(a, dec: 0)}';
}

/// S35.T35.11b: مبلغ ذخیره‌شده -> واحد نمایش (ریال/تومان) و سپس کوتاه‌شده. فقط برای نمودار مبلغ؛ وزن با faCompact.
String faCompactMoney(double stored) => faCompact(Fmt.toDisplay(stored).toDouble());

// ----------------------------------------------------------------------------
// قالب مشترک کارت نمودار
// ----------------------------------------------------------------------------
class ChartCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;
  const ChartCard({super.key, required this.title, this.subtitle, this.trailing, required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(subtitle!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54)),
                  ),
              ]),
            ),
            if (trailing != null) trailing!,
          ]),
          const SizedBox(height: 12),
          child,
        ]),
      ),
    );
  }
}

class ChartEmpty extends StatelessWidget {
  final String message;
  const ChartEmpty(this.message, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Center(child: Text(message, style: const TextStyle(color: Colors.black54))),
      );
}

/// یک عدد کوچک با عنوان (برای زیر نمودار)
class MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  const MiniStat({super.key, required this.label, required this.value, this.color});
  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(children: [
          Text(label, style: const TextStyle(fontSize: 11.5, color: Colors.black54), textAlign: TextAlign.center),
          const SizedBox(height: 2),
          Text(value,
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: color),
              textAlign: TextAlign.center),
        ]),
      );
}

// ----------------------------------------------------------------------------
// نمودار کروی (دونات)
// ----------------------------------------------------------------------------
class ChartSlice {
  final String label;
  final double value; // همیشه مثبت (اندازهٔ تکه)
  final Color color;
  final bool negative; // مثلاً زیان: در فهرست با علامت منفی نشان داده می‌شود
  const ChartSlice(this.label, this.value, this.color, {this.negative = false});
}

/// عدد کوتاه‌شدهٔ دلاری (برای نمودار پلن ارزی): ۱٫۲ میلیون / ۴٫۵ هزار / ۱۲۰ / ۵٫۲۵
String faCompactUsd(double v) => faCompactCcy(v);

/// عدد کوتاه‌شدهٔ ارزی (هر ارز) — S30.T30.5
String faCompactCcy(double v) {
  final a = v.abs();
  final sign = v < 0 ? '-' : '';
  if (a >= 1e6) return '$sign${faNum(a / 1e6, dec: 2)} میلیون';
  if (a >= 1e3) return '$sign${faNum(a / 1e3, dec: 1)} هزار';
  return '$sign${faNum(a, dec: a >= 100 ? 0 : 2)}';
}

/// بیشترین [maxSlices] تکه را نگه می‌دارد و بقیه را در «سایر» جمع می‌کند.
List<ChartSlice> topSlices(Map<String, double> data, {int maxSlices = 5}) {
  final entries = data.entries.where((e) => e.value > 0).toList()..sort((a, b) => b.value.compareTo(a.value));
  final out = <ChartSlice>[];
  double other = 0;
  for (var i = 0; i < entries.length; i++) {
    if (i < maxSlices) {
      out.add(ChartSlice(entries[i].key, entries[i].value, kChartPalette[i % kChartPalette.length]));
    } else {
      other += entries[i].value;
    }
  }
  if (other > 0) out.add(ChartSlice('سایر', other, kChartOther));
  return out;
}

class DonutChart extends StatefulWidget {
  final List<ChartSlice> slices;
  final String centerTitle;
  final String Function(double) format;
  final double size;
  final double? centerValue; // اگر داده شود به‌جای جمع تکه‌ها در مرکز نشان داده می‌شود (مثلاً سود خالص)
  const DonutChart({
    super.key,
    required this.slices,
    required this.centerTitle,
    required this.format,
    this.size = 180,
    this.centerValue,
  });

  @override
  State<DonutChart> createState() => _DonutChartState();
}

class _DonutChartState extends State<DonutChart> {
  int? _sel;

  void _onTap(Offset p) {
    final slices = widget.slices.where((s) => s.value > 0).toList();
    final total = slices.fold<double>(0, (a, s) => a + s.value);
    if (total <= 0) return;
    final c = Offset(widget.size / 2, widget.size / 2);
    final d = p - c;
    final dist = d.distance;
    final r = widget.size / 2;
    if (dist < r * 0.40 || dist > r) {
      setState(() => _sel = null);
      return;
    }
    var ang = math.atan2(d.dy, d.dx) + math.pi / 2;
    if (ang < 0) ang += 2 * math.pi;
    var acc = 0.0;
    for (var i = 0; i < slices.length; i++) {
      acc += slices[i].value / total * 2 * math.pi;
      if (ang <= acc) {
        setState(() => _sel = _sel == i ? null : i);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final slices = widget.slices.where((s) => s.value > 0).toList();
    final total = slices.fold<double>(0, (a, s) => a + s.value);
    final sel = (_sel != null && _sel! < slices.length) ? _sel : null;
    final centerLabel = sel == null ? widget.centerTitle : slices[sel].label;
    final centerValue = sel == null ? (widget.centerValue ?? total) : (slices[sel].negative ? -slices[sel].value : slices[sel].value);

    return Column(children: [
      SizedBox(
        width: widget.size,
        height: widget.size,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => _onTap(d.localPosition),
          child: Stack(alignment: Alignment.center, children: [
            TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: const Duration(milliseconds: 750),
              curve: Curves.easeOutCubic,
              builder: (_, t, __) => CustomPaint(
                size: Size(widget.size, widget.size),
                painter: _DonutPainter(slices: slices, total: total, selected: sel, progress: t),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(widget.size * 0.24),
              child: Column(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(centerLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5, color: Colors.black54)),
                const SizedBox(height: 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(widget.format(centerValue),
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                ),
              ]),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 12),
      for (var i = 0; i < slices.length; i++)
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _sel = _sel == i ? null : i),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
            decoration: BoxDecoration(
              color: sel == i ? slices[i].color.withValues(alpha: 0.10) : null,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(children: [
              Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(color: slices[i].color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(slices[i].label, overflow: TextOverflow.ellipsis)),
              Text('${slices[i].negative ? '-' : ''}${widget.format(slices[i].value)}',
                  style: TextStyle(fontWeight: FontWeight.w600, color: slices[i].negative ? kLossColor : null)),
              const SizedBox(width: 8),
              SizedBox(
                width: 44,
                child: Text('${faNum(slices[i].value / total * 100, dec: 0)}٪',
                    textAlign: TextAlign.end, style: const TextStyle(color: Colors.black54, fontSize: 12.5)),
              ),
            ]),
          ),
        ),
    ]);
  }
}

class _DonutPainter extends CustomPainter {
  final List<ChartSlice> slices;
  final double total;
  final int? selected;
  final double progress;
  _DonutPainter({required this.slices, required this.total, required this.selected, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    if (total <= 0) return;
    final c = size.center(Offset.zero);
    final r = math.min(size.width, size.height) / 2;
    final stroke = r * 0.30;
    final rect = Rect.fromCircle(center: c, radius: r - stroke / 2 - 4);
    // مسیر کم‌رنگ پشت
    canvas.drawArc(
      rect,
      0,
      2 * math.pi,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = const Color(0x11000000),
    );
    var start = -math.pi / 2;
    final gap = slices.length > 1 ? 0.035 : 0.0;
    for (var i = 0; i < slices.length; i++) {
      final full = slices[i].value / total * 2 * math.pi;
      final sweep = full * progress;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.butt
        ..strokeWidth = selected == i ? stroke + 8 : stroke
        ..color = slices[i].color;
      final s = math.max(0.0, sweep - gap);
      if (s > 0) canvas.drawArc(rect, start + gap / 2, s, false, paint);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.progress != progress || old.selected != selected || old.total != total || old.slices != slices;
}

// ----------------------------------------------------------------------------
// نمودار میله‌ای (یک یا دو سری) — زمان از راست به چپ (مناسب فارسی)
// ----------------------------------------------------------------------------
class BarSeries {
  final String name;
  final Color color;
  final Color? negativeColor; // اگر مقدار منفی بود (سود/زیان)
  const BarSeries(this.name, this.color, {this.negativeColor});
}

class BarGroup {
  final String label; // برچسب کوتاه زیر میله
  final String fullLabel; // برچسب کامل هنگام لمس
  final List<double> values; // به تعداد سری‌ها
  const BarGroup(this.label, this.fullLabel, this.values);
}

class GroupedBarChart extends StatefulWidget {
  final List<BarGroup> groups;
  final List<BarSeries> series;
  final double height;
  final String Function(double) format;
  final String Function(double)? compact; // برچسب کوتاه بالای میله (پیش‌فرض: ریال)
  const GroupedBarChart({
    super.key,
    required this.groups,
    required this.series,
    required this.format,
    this.compact,
    this.height = 210,
  });

  @override
  State<GroupedBarChart> createState() => _GroupedBarChartState();
}

class _GroupedBarChartState extends State<GroupedBarChart> {
  int? _sel;

  @override
  Widget build(BuildContext context) {
    final n = widget.groups.length;
    final sel = (_sel != null && _sel! < n) ? _sel : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        height: widget.height,
        child: LayoutBuilder(builder: (context, cons) {
          final w = cons.maxWidth;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) {
              if (n == 0) return;
              final slot = w / n;
              final visual = (d.localPosition.dx / slot).floor().clamp(0, n - 1);
              final idx = n - 1 - visual; // چپ‌به‌راست معکوس (زمان از راست شروع می‌شود)
              setState(() => _sel = _sel == idx ? null : idx);
            },
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: const Duration(milliseconds: 650),
              curve: Curves.easeOutCubic,
              builder: (_, t, __) => CustomPaint(
                size: Size(w, widget.height),
                painter: _BarPainter(
                  groups: widget.groups,
                  series: widget.series,
                  selected: sel,
                  progress: t,
                  format: widget.format,
                  compact: widget.compact,
                ),
              ),
            ),
          );
        }),
      ),
      const SizedBox(height: 8),
      if (widget.series.length > 1)
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          for (final s in widget.series) ...[
            Container(width: 10, height: 10, decoration: BoxDecoration(color: s.color, borderRadius: BorderRadius.circular(3))),
            const SizedBox(width: 5),
            Text(s.name, style: const TextStyle(fontSize: 12)),
            const SizedBox(width: 16),
          ],
        ]),
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: sel == null
            ? const Padding(
                key: ValueKey('hint'),
                padding: EdgeInsets.only(top: 4),
                child: Text('برای دیدن مبلغ دقیق، روی هر میله بزنید',
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 11.5, color: Colors.black45)),
              )
            : Container(
                key: ValueKey('sel$sel'),
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Wrap(alignment: WrapAlignment.center, spacing: 14, runSpacing: 2, children: [
                  Text(widget.groups[sel].fullLabel, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
                  for (var i = 0; i < widget.series.length; i++)
                    Text('${widget.series[i].name}: ${widget.format(widget.groups[sel].values[i])}',
                        style: TextStyle(
                            fontSize: 12.5,
                            color: (widget.series[i].negativeColor != null && widget.groups[sel].values[i] < 0)
                                ? widget.series[i].negativeColor
                                : widget.series[i].color,
                            fontWeight: FontWeight.w600)),
                ]),
              ),
      ),
    ]);
  }
}

class _BarPainter extends CustomPainter {
  final List<BarGroup> groups;
  final List<BarSeries> series;
  final int? selected;
  final double progress;
  final String Function(double) format;
  final String Function(double)? compact;
  _BarPainter({
    this.compact,
    required this.groups,
    required this.series,
    required this.selected,
    required this.progress,
    required this.format,
  });

  void _text(Canvas canvas, String s, Offset center, {double size = 10.5, Color color = Colors.black54, bool bold = false, double maxW = 80}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(fontSize: size, color: color, fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
      textDirection: TextDirection.rtl,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxW);
    tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy - tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final n = groups.length;
    if (n == 0) return;
    const topPad = 18.0;
    const bottomPad = 24.0;
    final chartH = size.height - topPad - bottomPad;

    double maxV = 0, minV = 0;
    for (final g in groups) {
      for (final v in g.values) {
        if (v > maxV) maxV = v;
        if (v < minV) minV = v;
      }
    }
    if (maxV == 0 && minV == 0) maxV = 1;
    final range = maxV - minV;
    double yOf(double v) => topPad + chartH * (maxV - v) / range;
    final zeroY = yOf(0);

    // خطوط راهنمای ملایم
    final grid = Paint()
      ..color = const Color(0x14000000)
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = topPad + chartH * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    canvas.drawLine(
        Offset(0, zeroY), Offset(size.width, zeroY), Paint()..color = const Color(0x33000000)..strokeWidth = 1.2);

    final slot = size.width / n;
    final groupW = math.min(slot * 0.78, 64.0 * series.length);
    final barW = groupW / series.length;
    final showValues = n <= 6;
    final labelEvery = n <= 8 ? 1 : (n / 7).ceil();

    for (var i = 0; i < n; i++) {
      final visual = n - 1 - i; // راست‌به‌چپ
      final cx = visual * slot + slot / 2;
      if (selected == i) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(visual * slot + 2, topPad - 6, slot - 4, chartH + 12), const Radius.circular(10)),
          Paint()..color = const Color(0x0D000000),
        );
      }
      final left0 = cx - groupW / 2;
      for (var s = 0; s < series.length; s++) {
        final raw = groups[i].values[s];
        final v = raw * progress;
        final neg = raw < 0 && series[s].negativeColor != null;
        final paint = Paint()..color = neg ? series[s].negativeColor! : series[s].color;
        final y = yOf(v);
        final top = math.min(zeroY, y);
        final bottom = math.max(zeroY, y);
        final l = left0 + s * barW + barW * 0.10;
        final r = left0 + (s + 1) * barW - barW * 0.10;
        if (bottom - top > 0.5) {
          final rr = v >= 0
              ? RRect.fromRectAndCorners(Rect.fromLTRB(l, top, r, bottom),
                  topLeft: const Radius.circular(5), topRight: const Radius.circular(5))
              : RRect.fromRectAndCorners(Rect.fromLTRB(l, top, r, bottom),
                  bottomLeft: const Radius.circular(5), bottomRight: const Radius.circular(5));
          canvas.drawRRect(rr, paint);
        }
        if (showValues && raw != 0 && progress > 0.95) {
          final ty = raw >= 0 ? top - 8 : bottom + 8;
          _text(canvas, (compact ?? faCompact)(raw), Offset((l + r) / 2, ty), size: 9.5, color: paint.color, bold: true, maxW: slot);
        }
      }
      if (i % labelEvery == 0 || selected == i) {
        _text(canvas, groups[i].label, Offset(cx, size.height - 8),
            color: selected == i ? Colors.black87 : Colors.black54, bold: selected == i, maxW: slot * labelEvery);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BarPainter old) =>
      old.progress != progress || old.selected != selected || old.groups != groups || old.series != series;
}

// ----------------------------------------------------------------------------
// بازه‌های زمانی: روزانه (تا ۳۱ روز) یا ماهانه شمسی
// ----------------------------------------------------------------------------
class TimeBucket {
  final DateTime start; // شامل
  final DateTime endExclusive;
  final String label;
  final String fullLabel;
  const TimeBucket(this.start, this.endExclusive, this.label, this.fullLabel);
  bool contains(DateTime d) => !d.isBefore(start) && d.isBefore(endExclusive);
}

DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

List<TimeBucket> buildBuckets(DateTime from, DateTime to) {
  var a = _dayOnly(from);
  var b = _dayOnly(to);
  if (b.isBefore(a)) {
    final t = a;
    a = b;
    b = t;
  }
  final days = b.difference(a).inDays + 1;
  final out = <TimeBucket>[];
  if (days <= 31) {
    for (var i = 0; i < days; i++) {
      final d = DateTime(a.year, a.month, a.day + i);
      final next = DateTime(a.year, a.month, a.day + i + 1);
      final j = gregorianToJalali(d.year, d.month, d.day);
      out.add(TimeBucket(d, next, toFaDigits('${j[2]}'), jalaliDateFromDt(d)));
    }
    return out;
  }
  final ja = gregorianToJalali(a.year, a.month, a.day);
  final jb = gregorianToJalali(b.year, b.month, b.day);
  var y = ja[0];
  var m = ja[1];
  while (y < jb[0] || (y == jb[0] && m <= jb[1])) {
    final s = jalaliToGregorian(y, m, 1);
    final ny = m == 12 ? y + 1 : y;
    final nm = m == 12 ? 1 : m + 1;
    final e = jalaliToGregorian(ny, nm, 1);
    out.add(TimeBucket(s, e, kJalaliMonthNames[m - 1], '${kJalaliMonthNames[m - 1]} ${toFaDigits('$y')}'));
    y = ny;
    m = nm;
    if (out.length > 60) break;
  }
  // حداکثر ۱۲ ماه آخر تا نمودار شلوغ نشود
  return out.length > 12 ? out.sublist(out.length - 12) : out;
}
