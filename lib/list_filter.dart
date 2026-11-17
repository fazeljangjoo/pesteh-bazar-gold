import 'package:flutter/material.dart';

import 'utils.dart';
import 'widgets.dart' show JalaliDateField;

/// فیلتر لیست خرید/فروش: ترتیب (جدید به قدیم یا برعکس) + بازهٔ زمانی شمسی.
///
/// پیش‌فرض: «سال پسته‌ای» جاری = ۱ مهر تا ۳۱ شهریورِ سال بعد.
/// اگر امروز بین ۱ مهر تا پایان اسفند باشد، سال پسته‌ای از همین مهر شروع شده؛
/// اگر بین فروردین تا شهریور باشد، از مهر سال قبل.
@immutable
class DocListFilter {
  const DocListFilter({required this.newestFirst, this.from, this.to});

  /// true = جدیدترین اول
  final bool newestFirst;

  /// ابتدای بازه (شامل خودِ روز)؛ null = بدون محدودیت
  final DateTime? from;

  /// انتهای بازه (شامل خودِ روز)؛ null = بدون محدودیت
  final DateTime? to;

  /// سال شمسیِ شروعِ سال پسته‌ای که [d] در آن است (مثلاً ۱۴۰۵ برای «۱۴۰۵–۱۴۰۶»)
  static int pistachioYearOf(DateTime d) {
    final List<int> j = gregorianToJalali(d.year, d.month, d.day);
    return j[1] >= 7 ? j[0] : j[0] - 1;
  }

  /// ۱ مهرِ سال [y]
  static DateTime pistachioStart(int y) => jalaliToGregorian(y, 7, 1);

  /// ۳۱ شهریورِ سال [y]+۱ (شهریور همیشه ۳۱ روز است)
  static DateTime pistachioEnd(int y) => jalaliToGregorian(y + 1, 6, 31);

  /// فیلتر پیش‌فرض: سال پسته‌ای جاری، جدیدترین اول
  factory DocListFilter.defaults([DateTime? now]) {
    final int y = pistachioYearOf(now ?? DateTime.now());
    return DocListFilter.forPistachioYear(y);
  }

  factory DocListFilter.forPistachioYear(int y, {bool newestFirst = true}) =>
      DocListFilter(newestFirst: newestFirst, from: pistachioStart(y), to: pistachioEnd(y));

  /// کل تاریخ‌ها (بدون محدودیت بازه)
  DocListFilter all() => DocListFilter(newestFirst: newestFirst);

  DocListFilter withOrder(bool newest) => DocListFilter(newestFirst: newest, from: from, to: to);

  DocListFilter withRange(DateTime? f, DateTime? t) => DocListFilter(newestFirst: newestFirst, from: f, to: t);

  bool get isAll => from == null && to == null;

  static bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  /// اگر بازه دقیقاً یک سال پسته‌ای کامل باشد، سالِ شروعش؛ وگرنه null
  int? get pistachioYear {
    final DateTime? f = from, t = to;
    if (f == null || t == null) return null;
    final int y = pistachioYearOf(f);
    return _sameDay(f, pistachioStart(y)) && _sameDay(t, pistachioEnd(y)) ? y : null;
  }

  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static String _dayKey(Object? raw) {
    final String s = '${raw ?? ''}';
    return s.length >= 10 ? s.substring(0, 10) : s;
  }

  /// آیا تاریخِ ISO (yyyy-mm-dd...) داخل بازه است؟
  bool contains(Object? isoDate) {
    final String k = _dayKey(isoDate);
    if (from != null && k.compareTo(_iso(from!)) < 0) return false;
    if (to != null && k.compareTo(_iso(to!)) > 0) return false;
    return true;
  }

  /// بازهٔ فیلترشده و مرتب‌شده (لیست ورودی تغییر نمی‌کند). کلیدها: `date` و `id`.
  List<Map<String, dynamic>> apply(List<Map<String, dynamic>> src) {
    final List<Map<String, dynamic>> out = src.where((Map<String, dynamic> e) => contains(e['date'])).toList();
    out.sort((Map<String, dynamic> a, Map<String, dynamic> b) {
      int c = _dayKey(a['date']).compareTo(_dayKey(b['date']));
      if (c == 0) {
        final num ia = (a['id'] as num?) ?? 0, ib = (b['id'] as num?) ?? 0;
        c = ia.compareTo(ib);
      }
      return newestFirst ? -c : c;
    });
    return out;
  }

  /// برچسب کوتاه بازه برای نوار بالای لیست
  String get rangeLabel {
    final int? y = pistachioYear;
    if (y != null) return 'سال پسته‌ای ${toFaDigits('$y')}–${toFaDigits('${y + 1}')}';
    if (isAll) return 'همهٔ تاریخ‌ها';
    final String f = from == null ? '...' : jalaliDateFromDt(from!);
    final String t = to == null ? '...' : jalaliDateFromDt(to!);
    return 'از $f تا $t';
  }
}

/// نوار فیلتر بالای لیست: پیکان‌های جابه‌جایی سال پسته‌ای + دکمهٔ فیلتر (ترتیب و بازهٔ دلخواه)
class DocListFilterBar extends StatelessWidget {
  const DocListFilterBar({
    super.key,
    required this.value,
    required this.onChanged,
    required this.shown,
    required this.total,
  });

  final DocListFilter value;
  final ValueChanged<DocListFilter> onChanged;

  /// تعداد ردیف‌های نمایش‌داده‌شده بعد از فیلتر
  final int shown;

  /// تعداد کل ردیف‌ها پیش از فیلتر
  final int total;

  Future<void> _openSheet(BuildContext context) async {
    final DocListFilter? r = await showModalBottomSheet<DocListFilter>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) => _FilterSheet(initial: value),
    );
    if (r != null) onChanged(r);
  }

  @override
  Widget build(BuildContext context) {
    final int? y = value.pistachioYear;
    final bool custom = !value.isAll && y == null;
    final TextTheme tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(children: <Widget>[
        Row(children: <Widget>[
          IconButton(
            tooltip: 'سال پسته‌ای قبل',
            onPressed: y == null ? null : () => onChanged(DocListFilter.forPistachioYear(y - 1, newestFirst: value.newestFirst)),
            icon: const Icon(Icons.arrow_back),
          ),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _openSheet(context),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
                  const Icon(Icons.calendar_month_outlined, size: 18),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(value.rangeLabel,
                        overflow: TextOverflow.ellipsis,
                        style: tt.titleSmall?.copyWith(fontWeight: custom ? FontWeight.bold : null)),
                  ),
                ]),
              ),
            ),
          ),
          IconButton(
            tooltip: 'سال پسته‌ای بعد',
            onPressed: y == null ? null : () => onChanged(DocListFilter.forPistachioYear(y + 1, newestFirst: value.newestFirst)),
            icon: const Icon(Icons.arrow_forward),
          ),
          IconButton(
            tooltip: 'فیلتر و ترتیب',
            onPressed: () => _openSheet(context),
            icon: const Icon(Icons.filter_list),
          ),
        ]),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '${toFaDigits('$shown')} مورد از ${toFaDigits('$total')}  •  ${value.newestFirst ? 'جدیدترین اول' : 'قدیمی‌ترین اول'}',
              style: tt.bodySmall,
            ),
          ),
        ),
      ]),
    );
  }
}

class _FilterSheet extends StatefulWidget {
  const _FilterSheet({required this.initial});
  final DocListFilter initial;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late bool _newest;
  late bool _all;
  late DateTime _from;
  late DateTime _to;

  @override
  void initState() {
    super.initState();
    final DocListFilter d = DocListFilter.defaults();
    _newest = widget.initial.newestFirst;
    _all = widget.initial.isAll;
    _from = widget.initial.from ?? d.from!;
    _to = widget.initial.to ?? d.to!;
  }

  bool get _invalid => !_all && _from.isAfter(_to);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('فیلتر و ترتیب', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            const Text('ترتیب نمایش'),
            const SizedBox(height: 6),
            SegmentedButton<bool>(
              segments: const <ButtonSegment<bool>>[
                ButtonSegment<bool>(value: true, label: Text('جدیدترین اول')),
                ButtonSegment<bool>(value: false, label: Text('قدیمی‌ترین اول')),
              ],
              selected: <bool>{_newest},
              onSelectionChanged: (Set<bool> s) => setState(() => _newest = s.first),
            ),
            const SizedBox(height: 16),
            Row(children: <Widget>[
              const Expanded(child: Text('بازهٔ زمانی (تقویم شمسی)')),
              TextButton(
                onPressed: () {
                  final DocListFilter d = DocListFilter.defaults();
                  setState(() {
                    _all = false;
                    _from = d.from!;
                    _to = d.to!;
                  });
                },
                child: const Text('سال پسته‌ای جاری'),
              ),
            ]),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('همهٔ تاریخ‌ها (بدون محدودیت)'),
              value: _all,
              onChanged: (bool v) => setState(() => _all = v),
            ),
            if (!_all) ...<Widget>[
              const SizedBox(height: 4),
              JalaliDateField(label: 'از تاریخ', value: _from, onChanged: (DateTime d) => setState(() => _from = d)),
              const SizedBox(height: 12),
              JalaliDateField(label: 'تا تاریخ', value: _to, onChanged: (DateTime d) => setState(() => _to = d)),
              if (_invalid)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('«از تاریخ» نباید بعد از «تا تاریخ» باشد',
                      style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
            ],
            const SizedBox(height: 16),
            Row(children: <Widget>[
              Expanded(
                child: OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('انصراف')),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: _invalid
                      ? null
                      : () => Navigator.pop(
                            context,
                            DocListFilter(newestFirst: _newest, from: _all ? null : _from, to: _all ? null : _to),
                          ),
                  child: const Text('اعمال'),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
