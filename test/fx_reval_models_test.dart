import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pesteh_bazar/fx_reval_models.dart';

// تسعیر ارز — مرحلهٔ ۹: تست مدل‌ها روی test/fx_reval_api_samples.json
// (نمونه‌ها با آینهٔ پایتونیِ pb_fxr_build/pb_fxr_export_build ساخته شده‌اند، نه ضبط از سرور زنده).
// سناریو: as_of=2026-03-19، ۴ فاکتور فروش + ۲ خرید، USD/EUR.
//   ar: #101 USD علی رضایی (مانده ۶۰۰، +۱۸٬۰۰۰٬۰۰۰)، #102 USD علی رضایی (۵۰۰، −۵٬۰۰۰٬۰۰۰)، #107 EUR شرکت پارس (۲۰۰، +۴٬۰۰۰٬۰۰۰)، #110 USD مریم احمدی (۱۰۰، −۲٬۰۰۰٬۰۰۰)
//   ap: P-33 USD بازار طلا (۳۰۰، +۶٬۰۰۰٬۰۰۰ = زیان)، #55 EUR بدون طرف‌حساب (۱۰۰، −۱٬۰۰۰٬۰۰۰ = سود)
//   ⇒ ar_up 17M، ar_down 2M، ap_up 6M، ap_down 1M، خالص سود = (18−5+4−2) − (6−1) = ۱۰٬۰۰۰٬۰۰۰ ریال.

Map<String, dynamic> _sample(Map<String, dynamic> all, String k) => Map<String, dynamic>.from(all[k] as Map);

void main() {
  final Map<String, dynamic> all = jsonDecode(File('test/fx_reval_api_samples.json').readAsStringSync()) as Map<String, dynamic>;

  group('preview', () {
    final FxRevalPreview p = FxRevalPreview.fromJson(_sample(all, 'preview'));

    test('parse کامل', () {
      expect(p.asOf, '2026-03-19');
      expect(p.asOfDate, DateTime(2026, 3, 19));
      expect(p.docCount, 6);
      expect(p.arUp, 17000000);
      expect(p.arDown, 2000000);
      expect(p.apUp, 6000000);
      expect(p.apDown, 1000000);
      expect(p.netDelta, 10000000);
      expect(p.fingerprint.length, 40);
      expect(p.items.length, 4);
      expect(p.docs.length, 6);
      expect(p.parties.length, 5);
      expect(p.hasChanges, isTrue);
      expect(p.totalGain, 18000000); // ar_up + ap_down
      expect(p.totalLoss, 8000000); // ar_down + ap_up
    });

    test('نرخ‌ها: نگاشت ارز→نرخ، مرتب بر اساس ارز', () {
      expect(p.rates.map((FxRevalRate r) => r.ccy).toList(), <String>['EUR', 'USD']);
      expect(p.rateOf('usd')!.rate, 1010000.0);
      expect(p.rateOf('USD')!.rateDate, '2026-03-18');
      expect(p.rateOf('USD')!.missing, isFalse);
      expect(p.rateOf('GBP'), isNull);
      expect(p.missingCcys, isEmpty);
    });

    test('ریز فاکتور و برچسب سود/زیان طلب و بدهی', () {
      final FxRevalDoc d101 = p.docs.firstWhere((FxRevalDoc d) => d.docId == 101 && d.side == 'ar');
      expect(d101.ref, '#101');
      expect(d101.party, 'علی رضایی');
      expect(d101.remCcy, 600.0);
      expect(d101.paidCcy, 400.0);
      expect(d101.delta, 18000000);
      expect(d101.isGain, isTrue);
      expect(d101.sideLabel, 'طلب (فروش)');

      final FxRevalDoc d102 = p.docs.firstWhere((FxRevalDoc d) => d.docId == 102);
      expect(d102.delta, -5000000);
      expect(d102.isLoss, isTrue);
      expect(d102.isGain, isFalse);

      final FxRevalDoc p33 = p.docs.firstWhere((FxRevalDoc d) => d.ref == 'P-33');
      expect(p33.side, 'ap');
      expect(p33.delta, 6000000);
      expect(p33.effect, -6000000); // بدهی: بالا رفتن نرخ = زیان
      expect(p33.isLoss, isTrue);
      expect(p33.sideLabel, 'بدهی (خرید)');

      final FxRevalDoc d55 = p.docs.firstWhere((FxRevalDoc d) => d.docId == 55);
      expect(d55.party, 'بدون طرف‌حساب');
      expect(d55.delta, -1000000);
      expect(d55.isGain, isTrue); // بدهی: پایین آمدن نرخ = سود
    });

    test('طرف‌حساب‌ها: up/down، delta، بدون طرف‌حساب', () {
      final FxRevalParty ali = p.parties.firstWhere((FxRevalParty x) => x.party == 'علی رضایی');
      expect(ali.side, 'ar');
      expect(ali.up, 13000000);
      expect(ali.down, 0);
      expect(ali.delta, 13000000);
      expect(ali.isGain, isTrue);
      expect(ali.tafsiliId, isNull); // preview هنوز تفصیلی ندارد

      final FxRevalParty maryam = p.parties.firstWhere((FxRevalParty x) => x.party == 'مریم احمدی');
      expect(maryam.down, 2000000);
      expect(maryam.isLoss, isTrue);

      final FxRevalParty none = p.parties.firstWhere((FxRevalParty x) => x.noParty);
      expect(none.side, 'ap');
      expect(none.down, 1000000);
      expect(none.effect, 1000000);
      expect(none.isGain, isTrue);

      final FxRevalParty bazar = p.parties.firstWhere((FxRevalParty x) => x.party == 'بازار طلا');
      expect(bazar.up, 6000000);
      expect(bazar.isLoss, isTrue); // بدهی بالا رفته
    });

    test('netGain = طلب delta − بدهی delta و با net_delta سرور برابر است', () {
      expect(p.netGain, 10000000);
      expect(p.netGain, p.netDelta);
      expect(p.isGain, isTrue);
      expect(p.isLoss, isFalse);
      final int ar = p.docs.where((FxRevalDoc d) => d.side == 'ar').fold<int>(0, (int a, FxRevalDoc d) => a + d.delta);
      final int ap = p.docs.where((FxRevalDoc d) => d.side == 'ap').fold<int>(0, (int a, FxRevalDoc d) => a + d.delta);
      expect(ar, 15000000);
      expect(ap, 5000000);
      expect(ar - ap, p.netGain);
      expect(fxRevalNetGainOfDocs(p.docs), 10000000);
    });

    test('netGain: بازگشت به items و سپس ستون‌های up/down وقتی docs نیست', () {
      final Map<String, dynamic> j = _sample(all, 'preview')..remove('docs');
      expect(FxRevalPreview.fromJson(j).netGain, 10000000); // از items
      j.remove('items');
      expect(FxRevalPreview.fromJson(j).netGain, 10000000); // (17−2) − (6−1)
    });

    test('گروه‌بندی docs: ارز × طرف × طرف‌حساب، مرتب (ارز، طلب قبل از بدهی، نام)', () {
      final List<FxRevalDocGroup> g = p.groupDocs();
      expect(g.length, 5);
      expect(g.map((FxRevalDocGroup x) => '${x.ccy}/${x.side}/${x.party}').toList(), <String>[
        'EUR/ar/شرکت پارس',
        'EUR/ap/بدون طرف‌حساب',
        'USD/ar/علی رضایی',
        'USD/ar/مریم احمدی',
        'USD/ap/بازار طلا',
      ]);
      final FxRevalDocGroup ali = g[2];
      expect(ali.docs.length, 2);
      expect(ali.remCcy, 1100.0);
      expect(ali.delta, 13000000);
      expect(ali.isGain, isTrue);
      expect(g[1].isGain, isTrue); // بدهی با delta منفی
      expect(g[4].isLoss, isTrue);
      expect(g.fold<int>(0, (int a, FxRevalDocGroup x) => a + x.docs.length), 6);
      expect(g.fold<int>(0, (int a, FxRevalDocGroup x) => a + x.effect), p.netGain);
    });

    test('گروه‌بندی فقط ارز × طرف', () {
      final List<FxRevalDocGroup> g = p.groupDocs(byParty: false);
      expect(g.map((FxRevalDocGroup x) => '${x.ccy}/${x.side}').toList(), <String>['EUR/ar', 'EUR/ap', 'USD/ar', 'USD/ap']);
      expect(g.every((FxRevalDocGroup x) => x.party == null), isTrue);
      expect(g[2].remCcy, 1200.0);
      expect(g[2].delta, 11000000);
      expect(g[3].remCcy, 300.0);
    });

    test('ریز آیتم‌ها (ارز×طرف)', () {
      final FxRevalItem arUsd = p.items.firstWhere((FxRevalItem i) => i.side == 'ar' && i.ccy == 'USD');
      expect(arUsd.openCcy, 1200.0);
      expect(arUsd.delta, 11000000);
      expect(arUsd.isGain, isTrue);
      final FxRevalItem apEur = p.items.firstWhere((FxRevalItem i) => i.side == 'ap' && i.ccy == 'EUR');
      expect(apEur.delta, -1000000);
      expect(apEur.isGain, isTrue);
    });
  });

  group('candidates (انتخاب فاکتور)', () {
    final List<FxRevalCandidate> c = FxRevalCandidate.listFrom(<dynamic>[
      <String, dynamic>{'key': 'ar:12', 'side': 'ar', 'doc_id': 12, 'ref': '#12', 'party': 'علی', 'ccy': 'usd', 'date': '2026-01-05 10:00:00', 'booked_rate': '500000', 'rem_ccy': '40', 'rate': 510000.0, 'delta': '400000', 'rate_missing': false, 'covered_by': null},
      <String, dynamic>{'key': 'ap:7', 'side': 'ap', 'doc_id': 7, 'ref': 'P-7', 'party': 'بدون طرف‌حساب', 'ccy': 'EUR', 'booked_rate': 600000, 'rem_ccy': 10, 'rate': null, 'delta': null, 'rate_missing': true, 'covered_by': null},
      <String, dynamic>{'side': 'ap', 'doc_id': 9, 'ccy': 'USD', 'booked_rate': 1, 'rem_ccy': 1, 'rate': 2, 'delta': '3', 'covered_by': '4'},
    ]);

    test('parse: رشته‌های PDO، ارز بزرگ، تاریخ کوتاه', () {
      expect(c.length, 3);
      expect(c[0].key, 'ar:12');
      expect(c[0].ccy, 'USD');
      expect(c[0].date, '2026-01-05');
      expect(c[0].remCcy, 40.0);
      expect(c[0].rate, 510000.0);
      expect(c[0].delta, 400000);
      expect(c[0].isCovered, isFalse);
      expect(c[0].selectable, isTrue);
    });

    test('سود/زیان: طلب delta، بدهی −delta؛ بدون نرخ ⇒ null', () {
      expect(c[0].effect, 400000);
      expect(c[1].rateMissing, isTrue);
      expect(c[1].rate, isNull);
      expect(c[1].effect, isNull);
      expect(c[2].effect, -3);
    });

    test('تسعیرشده: coveredBy و غیرقابل‌انتخاب؛ کلید پیش‌فرض side:id', () {
      expect(c[2].coveredBy, 4);
      expect(c[2].isCovered, isTrue);
      expect(c[2].selectable, isFalse);
      expect(c[2].key, 'ap:9');
      expect(c[2].ref, '#9');
    });

    test('فهرست خالی/نامعتبر', () {
      expect(FxRevalCandidate.listFrom(null), isEmpty);
      expect(FxRevalCandidate.listFrom(<dynamic>['x', 3]), isEmpty);
    });
  });

  group('apply', () {
    test('نتیجهٔ apply: شناسه، برگشت خودکار در انتظار، پیش‌نمایش داخلی', () {
      final FxRevalApplyResult r = FxRevalApplyResult.fromJson(_sample(all, 'apply_pending'));
      expect(r.id, 9);
      expect(r.revDate, '2026-03-20');
      expect(r.revStatus, 'pending');
      expect(r.reversalPending, isTrue);
      expect(r.reversalPosted, isFalse);
      expect(r.note, 'تسعیر پایان سال ۱۴۰۴');
      expect(r.preview.docs.length, 6);
      expect(r.preview.netGain, 10000000);
    });

    test('rev_status=posted و note خالی', () {
      final Map<String, dynamic> j = _sample(all, 'apply_pending')
        ..['rev_status'] = 'posted'
        ..['note'] = null;
      final FxRevalApplyResult r = FxRevalApplyResult.fromJson(j);
      expect(r.reversalPosted, isTrue);
      expect(r.note, isNull);
    });
  });

  group('check', () {
    test('بدون مشکل', () {
      final FxRevalCheck c = FxRevalCheck.fromJson(_sample(all, 'check_ok'));
      expect(c.canApply, isTrue);
      expect(c.problems, isEmpty);
      expect(c.rates.map((FxRevalRate r) => r.ccy).toList(), <String>['EUR', 'USD']);
      expect(c.rates.every((FxRevalRate r) => !r.missing), isTrue);
      expect(c.openDocsAr, 4);
      expect(c.openDocsAp, 2);
      expect(c.openDocs, 6);
      expect(c.hasActiveReval, isFalse);
      expect(c.activeRevalId, isNull);
      expect(c.fiscalOk, isTrue);
      expect(c.fiscalName, '۱۴۰۴');
      expect(c.fiscalStatus, 'open');
      expect(c.periodLocked, isFalse);
      expect(c.inFuture, isFalse);
      expect(c.ignoredCheques, 3);
      expect(c.missingCcys, isEmpty);
    });

    test('نرخ ناموجود + تسعیر فعال تکراری', () {
      final FxRevalCheck c = FxRevalCheck.fromJson(_sample(all, 'check_blocked'));
      expect(c.canApply, isFalse);
      expect(c.missingCcys, <String>['EUR', 'GBP']);
      expect(c.rateOf('EUR')!.missing, isTrue);
      expect(c.rateOf('EUR')!.rate, isNull);
      expect(c.rateOf('USD')!.rate, 1010000.0);
      expect(c.hasActiveReval, isTrue);
      expect(c.activeRevalId, 7);
      expect(c.activeRevalStatus, 'active');
      expect(c.hasProblem('duplicate'), isTrue);
      expect(c.hasProblem('locked'), isFalse);
      expect(c.problem('rate_missing')!.ccys, <String>['EUR', 'GBP']);
      expect(c.problems.map((FxRevalProblem x) => x.code).toList(), <String>['rate_missing', 'duplicate']);
    });

    test('آینده / بدون سال مالی / بدون فاکتور', () {
      final FxRevalCheck c = FxRevalCheck.fromJson(_sample(all, 'check_locked'));
      expect(c.inFuture, isTrue);
      expect(c.fiscalOk, isFalse);
      expect(c.fiscalName, isNull);
      expect(c.fiscalStatus, isNull);
      expect(c.openDocs, 0);
      expect(c.rates, isEmpty);
      expect(c.problems.map((FxRevalProblem x) => x.code).toList(), <String>['in_future', 'no_fiscal_year', 'nothing_to_reval']);
    });

    test('missingCcys از problem rate_missing هم می‌آید (حتی اگر rates نباشد)', () {
      final FxRevalCheck c = FxRevalCheck.fromJson(<String, dynamic>{
        'problems': <dynamic>[
          <String, dynamic>{'code': 'rate_missing', 'message': 'x', 'ccys': <dynamic>['gbp', 'EUR']}
        ],
      });
      expect(c.missingCcys, <String>['EUR', 'GBP']);
    });
  });

  group('record (list / detail)', () {
    final List<FxRevalRecord> rows = FxRevalRecord.listFrom((all['list'] as Map)['revals']);

    test('پنج ردیف و parse مقدارهای رشته‌ای PDO', () {
      expect(rows.map((FxRevalRecord r) => r.id).toList(), <int>[9, 8, 7, 3, 2]);
      final FxRevalRecord r8 = rows[1]; // همهٔ عددها رشته‌اند
      expect(r8.arUp, 4000000);
      expect(r8.apDown, 1500000);
      expect(r8.netDelta, 5500000);
      expect(r8.docCount, 3);
      expect(r8.asOf, '2026-02-19');
      expect(r8.revDate, '2026-02-20');
      expect(r8.note, isNull);
      expect(r8.createdBy, 'فاطمه حسابدار');
      expect(r8.snapshot, isNull); // list = بدون detail
    });

    test('برچسب وضعیت فارسی', () {
      expect(rows[0].statusLabel, 'در انتظار برگشت خودکار');
      expect(rows[1].statusLabel, 'برگشت خودکار شده');
      expect(rows[2].statusLabel, 'ابطال شده');
      expect(rows[3].statusLabel, 'فعال'); // قدیمی: active + none
      expect(rows[4].statusLabel, 'ابطال شده'); // قدیمی: reversed + none
    });

    test('canReverse / isEffective / پرچم‌ها', () {
      expect(rows.map((FxRevalRecord r) => r.canReverse).toList(), <bool>[true, false, false, true, false]);
      expect(rows[0].isPending, isTrue);
      expect(rows[1].isAutoReversed, isTrue);
      expect(rows[1].isActive, isTrue); // پس از برگشت خودکار status همچنان active است
      expect(rows[2].isCancelled, isTrue);
      expect(rows[2].reversedAt, '2026-01-20 17:05:00');
      expect(rows[4].isCancelled, isTrue);
    });

    test('netGain و isGain؛ ردیف قدیمی بدون net_delta از ستون‌ها', () {
      expect(rows[0].netGain, 10000000);
      expect(rows[0].isGain, isTrue);
      expect(rows[2].netGain, -3400000); // −2.5M − 0.9M
      expect(rows[2].isLoss, isTrue);
      expect(rows[3].netDelta, 0);
      expect(rows[3].netGain, 1500000); // 1.2M − (0 − 0.3M)
      expect(rows[3].totalGain, 1500000);
      expect(rows[2].totalLoss, 3400000);
    });

    test('detail جدید: snapshot کامل، تفصیلی طرف‌حساب، stale=false', () {
      final FxRevalRecord d = FxRevalRecord.fromJson(_sample(all, 'detail_new'));
      expect(d.id, 9);
      expect(d.stale, isFalse);
      expect(d.snapshot, isNotNull);
      final FxRevalPreview s = d.snapshot!;
      expect(s.asOf, '2026-03-19');
      expect(s.docs.length, 6);
      expect(s.docCount, 6);
      expect(s.netGain, d.netGain);
      expect(s.fingerprint.length, 40);
      expect(s.parties.firstWhere((FxRevalParty p) => p.party == 'علی رضایی').tafsiliId, 1201);
      expect(s.parties.firstWhere((FxRevalParty p) => p.noParty).tafsiliId, 0);
      expect(s.rateOf('EUR')!.rate, 1120000.0);
      expect(d.reversedAt, isNull);
    });

    test('detail با stale=true', () {
      final FxRevalRecord d = FxRevalRecord.fromJson(_sample(all, 'detail_stale'));
      expect(d.stale, isTrue);
      expect(d.snapshot!.docs.length, 6);
    });

    test('detail قدیمی: detail آرایهٔ items', () {
      final FxRevalRecord d = FxRevalRecord.fromJson(_sample(all, 'detail_legacy_items'));
      expect(d.revStatus, 'none');
      expect(d.snapshot, isNotNull);
      expect(d.snapshot!.items.length, 1);
      expect(d.snapshot!.items.first.ccy, 'USD');
      expect(d.snapshot!.items.first.openCcy, 800.0);
      expect(d.snapshot!.docs, isEmpty);
      expect(d.snapshot!.parties, isEmpty);
      expect(d.snapshot!.arUp, 1200000); // مبالغ کل از ستون‌های ردیف می‌آید
    });

    test('detail قدیمی: detail=null', () {
      final FxRevalRecord d = FxRevalRecord.fromJson(_sample(all, 'detail_legacy_null'));
      expect(d.snapshot, isNull);
      expect(d.statusLabel, 'ابطال شده');
      expect(d.reversedBy, 'مدیر');
      expect(d.canReverse, isFalse);
    });
  });

  group('export', () {
    final FxRevalExport e = FxRevalExport.fromJson(_sample(all, 'export'));

    test('صفحهٔ اصلی و جمع‌ها', () {
      expect(e.title, 'گزارش تسعیر ارز شمارهٔ 9');
      expect(e.asOf, '2026-03-19');
      expect(e.headers.length, 7);
      expect(e.rows.length, 2);
      expect(e.rows[0][0], 'EUR');
      expect(e.rows[1][0], 'USD');
      expect(e.rows[1][6], 5000000);
      expect(e.totals.arUp, 17000000);
      expect(e.totals.arDown, 2000000);
      expect(e.totals.apUp, 6000000);
      expect(e.totals.apDown, 1000000);
      expect(e.totals.gain, 18000000);
      expect(e.totals.loss, 8000000);
      expect(e.totals.netDelta, 10000000);
      expect(e.totals.gain - e.totals.loss, e.totals.netDelta);
      expect(e.totals.docCount, 6);
      expect(e.isEmpty, isFalse);
    });

    test('برگه‌ها: docs / parties / items', () {
      expect(e.docsSheet.headers.length, 10);
      expect(e.docsSheet.rows.length, 6);
      expect(e.docsSheet.rows.every((List<Object?> r) => r.length == e.docsSheet.headers.length), isTrue);
      expect(e.partiesSheet.headers.length, 5);
      expect(e.partiesSheet.rows.length, 5);
      expect(e.itemsSheet.headers.length, 5);
      expect(e.itemsSheet.rows.length, 4);
      final List<Object?> noParty = e.partiesSheet.rows.firstWhere((List<Object?> r) => r[1] == 'بدون طرف‌حساب');
      expect(noParty[4], 1000000); // بدهی با کاهش ⇒ سود
    });

    test('ردیف‌های export تغییرناپذیرند', () {
      expect(() => e.rows.add(<Object?>[1]), throwsUnsupportedError);
      expect(() => e.rows[0].add(1), throwsUnsupportedError);
    });
  });

  group('برچسب وضعیت', () {
    test('جدول وضعیت × برگشت', () {
      expect(fxRevalStatusLabel('active', 'none'), 'فعال');
      expect(fxRevalStatusLabel('active', 'pending'), 'در انتظار برگشت خودکار');
      expect(fxRevalStatusLabel('active', 'posted'), 'برگشت خودکار شده');
      expect(fxRevalStatusLabel('reversed', 'cancelled'), 'ابطال شده');
      expect(fxRevalStatusLabel('reversed', 'none'), 'ابطال شده');
      expect(fxRevalStatusLabel('', 'none'), 'نامشخص');
    });
  });

  group('فیلد ناموجود / نوع اشتباه (بدون استثنا)', () {
    test('JSON خالی', () {
      expect(() => FxRevalPreview.fromJson(const <String, dynamic>{}), returnsNormally);
      final FxRevalPreview p = FxRevalPreview.fromJson(_sample(<String, dynamic>{'x': <String, dynamic>{}}, 'x'));
      expect(p.docs, isEmpty);
      expect(p.netGain, 0);
      expect(p.hasChanges, isFalse);
      expect(p.groupDocs(), isEmpty);
      expect(p.asOfDate, isNull);

      final FxRevalCheck c = FxRevalCheck.fromJson(_sample(all['sparse'] as Map<String, dynamic>, 'check_empty'));
      expect(c.canApply, isFalse);
      expect(c.hasActiveReval, isFalse);
      expect(c.rates, isEmpty);

      final FxRevalExport e = FxRevalExport.fromJson(_sample(all['sparse'] as Map<String, dynamic>, 'export_empty'));
      expect(e.isEmpty, isTrue);
      expect(e.totals.netDelta, 0);
    });

    test('ردیف فقط با id', () {
      final FxRevalRecord r = FxRevalRecord.fromJson(_sample(all['sparse'] as Map<String, dynamic>, 'record_only_id'));
      expect(r.id, 5);
      expect(r.asOf, '');
      expect(r.revStatus, 'none');
      expect(r.status, '');
      expect(r.statusLabel, 'نامشخص');
      expect(r.netGain, 0);
      expect(r.canReverse, isFalse);
      expect(r.snapshot, isNull);
    });

    test('نوع اشتباه: رشته/عدد/لیست به‌جای شیء و برعکس', () {
      final FxRevalPreview p = FxRevalPreview.fromJson(<String, dynamic>{
        'docs': 'x',
        'items': 5,
        'parties': <dynamic>[1, 'a', null, <String, dynamic>{'party': 'ب', 'up': '12', 'down': 'abc'}],
        'rates': 7,
        'ar_up': 'abc',
        'ap_up': '2500.0',
        'ap_down': null,
        'net_delta': double.nan,
        'fingerprint': 123,
      });
      expect(p.docs, isEmpty);
      expect(p.items, isEmpty);
      expect(p.parties.length, 1);
      expect(p.parties.first.up, 12);
      expect(p.parties.first.down, 0);
      expect(p.rates, isEmpty);
      expect(p.arUp, 0);
      expect(p.apUp, 2500);
      expect(p.apDown, 0);
      expect(p.netDelta, 0);
      expect(p.fingerprint, '123');

      final FxRevalCheck c = FxRevalCheck.fromJson(<String, dynamic>{
        'open_docs': 'x',
        'has_active_reval': 'x',
        'fiscal': <dynamic>[],
        'problems': <String, dynamic>{'a': 1},
        'rates': <String, dynamic>{'usd': 1010000, 'EUR': <String, dynamic>{'rate': '1120000', 'rate_date': '2026-03-19 00:00:00'}},
        'ignored_cheques': 4,
      });
      expect(c.openDocs, 0);
      expect(c.activeRevalId, isNull);
      expect(c.problems, isEmpty);
      expect(c.ignoredCheques, 0);
      expect(c.rates.map((FxRevalRate r) => '${r.ccy}:${r.rate}:${r.rateDate}').toList(), <String>['EUR:1120000.0:2026-03-19', 'USD:1010000.0:null']);
    });

    test('doc بدون ref: شمارهٔ #id', () {
      final FxRevalDoc d = FxRevalDoc.fromJson(<String, dynamic>{'doc_id': 5, 'ccy': 'usd', 'side': 'zzz'});
      expect(d.ref, '#5');
      expect(d.ccy, 'USD');
      expect(d.side, 'ar');
      expect(d.delta, 0);
      expect(d.isGain, isFalse);
      expect(d.isLoss, isFalse);
    });

    test('نرخ: شکل لیست و شکل نگاشت یکسان parse می‌شوند', () {
      final List<FxRevalRate> a = FxRevalRate.listFrom(<dynamic>[
        <String, dynamic>{'ccy': 'USD', 'rate': 10.5, 'rate_date': '2026-01-01', 'missing': false}
      ]);
      final List<FxRevalRate> b = FxRevalRate.listFrom(<String, dynamic>{
        'USD': <String, dynamic>{'rate': 10.5, 'rate_date': '2026-01-01', 'missing': false}
      });
      expect(a.single.ccy, b.single.ccy);
      expect(a.single.rate, b.single.rate);
      expect(a.single.rateDate, b.single.rateDate);
      expect(a.single.rateDateTime, DateTime(2026, 1, 1));
      // missing=false ولی rate=null ⇒ در عمل ناموجود است
      expect(FxRevalRate.fromJson(<String, dynamic>{'ccy': 'EUR', 'missing': false}).missing, isTrue);
    });
  });

  group('FxRevalException.fromResponse', () {
    final Map<String, dynamic> errs = _sample(all, 'errors');

    FxRevalException map(String k) {
      final Map<String, dynamic> e = _sample(errs, k);
      return FxRevalException.fromResponse(
        message: e['message'] as String,
        httpCode: e['http'] as int,
        network: e['network'] == true,
        data: e['data'] == null ? null : Map<String, dynamic>.from(e['data'] as Map),
      );
    }

    test('rate_missing با همهٔ ارزها', () {
      final FxRevalException x = map('rate_missing');
      expect(x.code, FxRevalException.codeRateMissing);
      expect(x.code, 'rate_missing');
      expect(x.isRateMissing, isTrue);
      expect(x.ccys, <String>['EUR', 'GBP']);
      expect(x.httpCode, 422);
      expect(x.message, contains('EUR'));
      expect(x.problems.single.code, 'rate_missing');
    });

    test('rate_missing فقط با ccy (بدون ccys)', () {
      final FxRevalException x = FxRevalException.fromResponse(
          message: 'm', httpCode: 422, data: <String, dynamic>{'error': 'rate_missing', 'ccy': 'eur'});
      expect(x.ccys, <String>['EUR']);
    });

    test('conflict ۴۰۹ با زیرکد', () {
      final FxRevalException x = map('duplicate');
      expect(x.code, 'conflict');
      expect(x.isConflict, isTrue);
      expect(x.reason, 'duplicate');
      expect(x.httpCode, 409);
      expect(x.problems.single.code, 'duplicate');
      expect(x.toString(), x.message);

      final FxRevalException y = map('already_reversed');
      expect(y.code, 'conflict');
      expect(y.reason, isNull);
      expect(y.message, 'این تسعیر قبلاً خودکار برگشت شده است');
    });

    test('forbidden و edition_required', () {
      final FxRevalException f = map('forbidden');
      expect(f.code, 'forbidden');
      expect(f.message, 'دسترسی لازم را ندارید');
      final FxRevalException e = map('edition');
      expect(e.code, 'edition_required');
      expect(e.message, isNot('edition_required')); // پیام فارسی، نه کد خام
      expect(e.httpCode, 403);
    });

    test('network', () {
      final FxRevalException x = map('network');
      expect(x.code, 'network');
      expect(x.isNetwork, isTrue);
      expect(x.httpCode, 0);
      expect(FxRevalException.fromResponse(message: '', network: true).message, isNotEmpty);
    });

    test('سایر خطاها ⇒ server (با زیرکد nothing_to_reval)', () {
      final FxRevalException a = map('nothing');
      expect(a.code, 'server');
      expect(a.reason, 'nothing_to_reval');
      expect(a.httpCode, 400);
      expect(map('not_found').code, 'server');
      final FxRevalException h = map('html_500');
      expect(h.code, 'server');
      expect(h.message, 'خطای سرور (کد 500)');
      expect(h.reason, isNull);
    });

    test('بدون بدنه و بدون پیام', () {
      expect(FxRevalException.fromResponse(message: '', httpCode: 403).message, 'دسترسی لازم را ندارید');
      expect(FxRevalException.fromResponse(message: '', httpCode: 409).code, 'conflict');
      expect(FxRevalException.fromResponse(message: '').message, isNotEmpty);
    });
  });
  // مرحلهٔ ۱۳: خروجی محلی پیش‌نمایش باید با خروجی سرور (sample `export`، ساخته‌شده از همان داده) هم‌ساختار و هم‌مقدار باشد.
  group('FxRevalExport.fromPreview (مرحلهٔ ۱۳)', () {
    final FxRevalPreview p = FxRevalPreview.fromJson(_sample(all, 'preview'));
    final FxRevalExport local = FxRevalExport.fromPreview(p);
    final FxRevalExport server = FxRevalExport.fromJson(_sample(all, 'export'));

    test('پرچم پیش‌نمایش و تاریخ', () {
      expect(local.isPreview, isTrue);
      expect(server.isPreview, isFalse);
      expect(local.asOf, '2026-03-19');
      expect(local.title.isNotEmpty, isTrue);
    });

    test('صفحهٔ اصلی (یک سطر برای هر ارز) عیناً مثل سرور', () {
      expect(local.headers, server.headers);
      expect(local.rows, server.rows);
      expect(local.rows.map((List<Object?> r) => r[0]).toList(), <Object?>['EUR', 'USD']);
    });

    test('جمع‌ها', () {
      expect(local.totals.arUp, 17000000);
      expect(local.totals.arDown, 2000000);
      expect(local.totals.apUp, 6000000);
      expect(local.totals.apDown, 1000000);
      expect(local.totals.gain, 18000000);
      expect(local.totals.loss, 8000000);
      expect(local.totals.netDelta, 10000000);
      expect(local.totals.docCount, 6);
    });

    test('برگه‌های ریز، طرف‌حساب و items عیناً مثل سرور', () {
      expect(local.docsSheet.headers, server.docsSheet.headers);
      expect(local.docsSheet.rows, server.docsSheet.rows);
      expect(local.partiesSheet.headers, server.partiesSheet.headers);
      expect(local.partiesSheet.rows, server.partiesSheet.rows);
      expect(local.itemsSheet.headers, server.itemsSheet.headers);
      expect(local.itemsSheet.rows, server.itemsSheet.rows);
    });

    test('پیش‌نمایش خالی ⇒ خروجی خالی بدون استثنا', () {
      final FxRevalExport e = FxRevalExport.fromPreview(const FxRevalPreview(asOf: '2026-03-19'));
      expect(e.rows, isEmpty);
      expect(e.docsSheet.rows, isEmpty);
      expect(e.totals.netDelta, 0);
      expect(e.totals.docCount, 0);
    });
  });
}
