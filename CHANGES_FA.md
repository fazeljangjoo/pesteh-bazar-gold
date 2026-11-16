# گزارش جایگزینی فایل‌های اصلاح‌شده
ترتیب اعمال: single (اولین) ← file17 ← file16 ← … ← file2 ← file (آخرین). هر فایل نسخهٔ جدیدترین مرحله را گرفت.

## پروژهٔ ویندوز — فایل‌های تغییرکرده (۲۰ فایل Dart)
| فایل | از کدام مرحله | روش | توضیح |
|---|---|---|---|
| barcode_utils.dart | file9 | جایگزینی مستقیم |  |
| broker_ui.dart | file4 | جایگزینی مستقیم |  |
| cheque_ui.dart | file5 | جایگزینی مستقیم |  |
| consignment_ui.dart | file7 | جایگزینی مستقیم |  |
| db.dart | file12 | ادغام سه‌طرفه (واژه‌های مخصوص پلتفرم حفظ شد) | آینهٔ محلی: ویرایشِ «بدون انبار» مقدار قبلی انبار را نگه می‌دارد |
| excel_io.dart | file (آخرین) | جایگزینی مستقیم |  |
| export_docs_pdf.dart | file (آخرین) | جایگزینی مستقیم |  |
| home_screen.dart | file16 | ادغام سه‌طرفه (واژه‌های مخصوص پلتفرم حفظ شد) | هشدار پررنگ برای موارد خطادارِ همگام‌سازی |
| lot_chain_calc.dart | file8 | جایگزینی مستقیم |  |
| official_invoice.dart | file (آخرین) | جایگزینی مستقیم |  |
| offline_docs.dart | file16 | جایگزینی مستقیم |  |
| payroll_ui.dart | file2 | جایگزینی مستقیم |  |
| processing_ui.dart | file7 | جایگزینی مستقیم |  |
| reports_screen.dart | file (آخرین) | جایگزینی مستقیم |  |
| returns_ui.dart | file17 | جایگزینی مستقیم | اصلاح صفحهٔ مرجوعی (مرحلهٔ اول) |
| separation_form.dart | file7 | جایگزینی مستقیم |  |
| stock_count_local.dart | file10 | جایگزینی مستقیم |  |
| stock_reports_screen.dart | file8 | جایگزینی مستقیم |  |
| sync_service.dart | file13 | ادغام سه‌طرفه (واژه‌های مخصوص پلتفرم حفظ شد) | ۴۰۴ حذفِ از‌قبل‌حذف‌شده موفق حساب می‌شود؛ ۴۰۹ فقط وقتی «در حال پردازش» باشد تکرار می‌شود (صف گیر نمی‌کند) |
| warehouse_ui.dart | file7 | جایگزینی مستقیم | uid ثابت در تلاش دوبارهٔ انتقال (جلوگیری از ثبت دوبارهٔ انتقال) + کد HTTP در خطا |

### مرتب‌سازی
- `intake_*.dart` و `entity_store.dart` در lib ویندوز از قبل نسخهٔ جدید بود (بدون تغییر).
- کپی‌های سرگردان `home_screen.dart` و `license_gate_screen.dart` از ریشهٔ پروژه حذف شد (فقط نسخه‌ی `lib/` معتبر است).
- نسخه‌های جدید بر پایهٔ اندروید ساخته شده بودند؛ با ادغام سه‌طرفه، تفاوت‌های ویندوز حفظ شد (مثلاً «روی سیستم» به‌جای «روی گوشی»، نبودن import مربوط به perms در home_screen).

## چه چیزهایی انجام *نشد* / باید خودتان بررسی کنید
1. **کامپایل و تست انجام نشد.** در این محیط Flutter/Dart و PHP نصب نیست؛ فقط بررسی ساختاری (نبودن علامت تداخل ادغام، مقایسه با نسخه‌ی قبل) انجام شد. قبل از انتشار حتماً `flutter analyze` / `flutter test` و `php -l` را اجرا کنید.
2. فایل‌های `mnt_user-data_outputs_stageN_...` داخل زیپ دوم **استفاده نشدند**؛ آن‌ها عکس‌های مرحلهٔ قبلیِ همان فایل‌اند (۱۰ تا کاملاً یکسان با فایل بی‌پیشوند، ۷ تا قدیمی‌تر).
3. اگر مرحله‌ای تغییرِ پایگاه‌داده (SQL migration) لازم داشته باشد، در فایل‌های شما نبود؛ پوشهٔ `backend/sql` دست نخورد.
4. شماره‌ی نسخه (`pubspec.yaml`) و CHANGELOG داخل خود برنامه تغییر نکرد.


---
## جمع‌بندی نهایی ۱۲ مرحله (ویندوز)
| مرحله | تغییر | فایل‌های اصلی |
|---|---|---|
| ۱ | تاریخ شمسی در فرم‌های فراوری/اپراتور/امانی/باغ | `widgets.dart` (`JalaliDateField`), `processing_ui`, `workshop_ui`, `consignment_ui`, `orchard_ui` |
| ۲ | نام فروشنده/خریدار در عنوان کارت لیست | `purchases_screen`, `sales_screen` |
| ۳ | برچسب تب «موجودی» ⇒ «انبار» | `desktop_shell`, `main`, `inventory_screen` |
| ۴–۵ | خروجی پویا (grade `custom`) + بهای هر خروجی (بک‌اند + Dart/UI) | `workshop_calc.dart`, `workshop_ui`, `processing_ui`, تست `workshop_cost_test` |
| ۶ | زیربنای فرم فشرده + خرید/فروش | `form_layout.dart` (جدید), `purchase_form`, `sale_form`, `desktop_shell` (تم) |
| ۷ | فرم فشرده: مخلوط/جداسازی/ورودی | `mix_form`, `separation_form`, `intake_form`, `intake_confirm_screen` |
| ۸ | فرم فشرده: کارگاه/شکست/فراوری/امانی/برگشت | `workshop_ui`, `crack_ui`, `processing_ui`, `consignment_ui`, `outside_ui`, `returns_ui` |
| ۹ | فرم فشرده: سایر فرم‌ها | `lc_ui`, `proforma_ui`, `party_master_screen`, `company_settings_ui`, `warehouse_ui`, `orchard_ui`, `vouchers_ui` |
| ۱۰ | کارتکس لات (بک‌اند؛ تست مشترک JSON) | `test/lot_cartex_cases.json` |
| ۱۱ | کارتکس لات: آینهٔ محاسبه + UI | `lot_cartex_calc.dart`, `lot_cartex_ui.dart`, `test/lot_cartex_test.dart` |
| ۱۲ | یکپارچه‌سازی: زیرتب «کارتکس» در انبار؛ پنهان بدون مجوز `stock.view` | `inventory_screen.dart` |

### چه چیزهایی تست نشد (مهم)
- **هیچ‌چیز کامپایل یا اجرا نشد**: در محیط توسعه dart/flutter نصب نبود (فقط تعادل پرانتز/کروشه/آکولاد). قبل از build حتماً: `flutter pub get && flutter analyze && flutter test` (به‌ویژه `workshop_cost_test.dart` و `lot_cartex_test.dart`).
- بررسی چشمی در ~۱۱۰۰px لازم است: فرم‌های دوستونه (Row/Expanded) و `DataTable` داخل `ExpansionTile` + `TabBarView` تودرتوی کارتکس.
- ترتیب Tab فرم خرید تغییر کرد (مشخصات ⇒ وزن ⇒ قیمت ⇒ توضیحات).
- کارتکس در حالت آفلاین فراوری/شکست را نشان نمی‌دهد؛ لینک شمارهٔ سفارش فقط صفحهٔ فراوری را باز می‌کند.
- گزارش‌های کارگاه (`workshop_report/cartex`) وزن grade `custom` را در ستون جدا نمی‌آورند.
- زیرتب کارتکس: فرمت تاریخ `purchases.date` محلی ISO فرض شد.
- اندروید لمس نشد (با سرور جدید سازگار عقب‌رو؛ فیلدهای جدید API اختیاری‌اند).
