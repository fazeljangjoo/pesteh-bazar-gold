import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'db.dart';
import 'entity_store.dart';
import 'utils.dart';

/// شناسه پایه برای اقساط اعتباری و چک‌ها را از هم جدا نگه می‌دارد تا تداخل نداشته باشند
const int _creditBase = 1000000;
const int _chequeBase = 2000000;
const int _receiptCreditBase = 3000000;
const int _receiptChequeBase = 4000000;
const int _loanBase = 6000000;
const int _crmBase = 7000000; // T03.4: due CRM follow-ups (id = base + stable hash of uid)

class NotifyService {
  NotifyService._();
  static final NotifyService I = NotifyService._();

  // lazy: روی ویندوز اصلاً ساخته نمی‌شود (اعلان سیستمی فقط روی گوشی است؛ در ویندوز DueAlertHost هشدار می‌دهد)
  late final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  bool get _supported => Platform.isAndroid || Platform.isIOS;

  Future<void> init() async {
    if (_ready || !_supported) return;
    try {
      tzdata.initializeTimeZones();
      try {
        tz.setLocalLocation(tz.getLocation('Asia/Tehran'));
      } catch (_) {}
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      await _plugin.initialize(const InitializationSettings(android: androidInit));
      final androidImpl = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await androidImpl?.requestNotificationsPermission();
      await androidImpl?.requestExactAlarmsPermission();
      _ready = true;
    } catch (_) {
      // اگر پلتفرم پشتیبانی نکرد، برنامه بدون نوتیفیکیشن کار می‌کند
    }
  }

  Future<void> _schedule(int id, String title, String body, DateTime when) async {
    if (!_supported) return;
    if (when.isBefore(DateTime.now())) return;
    try {
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        tz.TZDateTime.from(when, tz.local),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'due_reminders',
            'یادآوری سررسید',
            channelDescription: 'یادآوری سررسید اقساط و چک‌ها',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      );
    } catch (_) {}
  }

  Future<void> _cancel(int id) async {
    if (!_supported) return;
    try {
      await _plugin.cancel(id);
    } catch (_) {}
  }

  Future<void> _scheduleDue(int baseId, String title, String body, DateTime dueDate) async {
    await _cancel(baseId * 10 + 1);
    await _cancel(baseId * 10 + 2);
    final due9 = DateTime(dueDate.year, dueDate.month, dueDate.day, 9, 0);
    final before9 = due9.subtract(const Duration(days: 1));
    await _schedule(baseId * 10 + 1, title, 'فردا سررسید است — $body', before9);
    await _schedule(baseId * 10 + 2, title, 'امروز سررسید است — $body', due9);
  }

  Future<void> cancelDueByBase(int baseId) async {
    await _cancel(baseId * 10 + 1);
    await _cancel(baseId * 10 + 2);
  }

  Future<void> scheduleCreditRow(Map<String, dynamic> row) async {
    final id = row['id'] as int;
    final dueDate = DateTime.parse(row['due_date'] as String);
    final amount = (row['amount'] as num).toDouble();
    await _scheduleDue(_creditBase + id, 'سررسید قسط', '${faNum(amount, dec: 0)} ریال', dueDate);
  }

  Future<void> cancelCreditRow(int id) => cancelDueByBase(_creditBase + id);

  Future<void> scheduleChequeRow(Map<String, dynamic> row) async {
    final id = row['id'] as int;
    final dueDate = DateTime.parse(row['due_date'] as String);
    final amount = (row['amount'] as num).toDouble();
    final bank = (row['bank_name'] as String?) ?? '';
    await _scheduleDue(_chequeBase + id, 'سررسید چک', '${faNum(amount, dec: 0)} ریال $bank', dueDate);
  }

  Future<void> cancelChequeRow(int id) => cancelDueByBase(_chequeBase + id);

  Future<void> scheduleReceiptCreditRow(Map<String, dynamic> row) async {
    final id = row['id'] as int;
    final dueDate = DateTime.parse(row['due_date'] as String);
    final amount = (row['amount'] as num).toDouble();
    await _scheduleDue(
        _receiptCreditBase + id, 'سررسید وصول مطالبه', '${faNum(amount, dec: 0)} ریال', dueDate);
  }

  Future<void> cancelReceiptCreditRow(int id) => cancelDueByBase(_receiptCreditBase + id);

  Future<void> scheduleReceiptChequeRow(Map<String, dynamic> row) async {
    final id = row['id'] as int;
    final dueDate = DateTime.parse(row['due_date'] as String);
    final amount = (row['amount'] as num).toDouble();
    final bank = (row['bank_name'] as String?) ?? '';
    await _scheduleDue(
        _receiptChequeBase + id, 'سررسید چک دریافتی', '${faNum(amount, dec: 0)} ریال $bank', dueDate);
  }

  Future<void> cancelReceiptChequeRow(int id) => cancelDueByBase(_receiptChequeBase + id);

  /// سررسید قرض: اعطای قرض = وصول طلب، دریافت قرض = بازپرداخت بدهی
  Future<void> scheduleLoanRow(Map<String, dynamic> row) async {
    final id = (row['id'] as int).abs() % 900000;
    final dueDate = DateTime.parse(row['due_date'] as String);
    final amount = (row['amount'] as num).toDouble();
    final given = row['kind'] == 'given';
    final party = (row['party'] as String?) ?? '';
    await _scheduleDue(_loanBase + id, given ? 'سررسید وصول قرض' : 'سررسید بازپرداخت قرض',
        '${faNum(amount, dec: 0)} ریال ${given ? 'از' : 'به'} $party', dueDate);
  }

  Future<void> cancelLoanRow(int id) => cancelDueByBase(_loanBase + id.abs() % 900000);

  int _crmId(String uid) {
    int h = 0;
    for (final int c in uid.codeUnits) {
      h = (h * 31 + c) % 900000;
    }
    return _crmBase + h;
  }

  /// یادآوری پیگیری CRM: فقط در لحظهٔ موعد (اگر موعد گذشته یا انجام‌شده باشد، چیزی زمان‌بندی نمی‌شود)
  Future<void> scheduleCrmTask(Map<String, dynamic> row) async {
    final String uid = (row['uid'] ?? '').toString();
    if (uid.isEmpty) return;
    await _cancel(_crmId(uid));
    if (row['done'] == true || row['done'] == 1) return;
    final String due = (row['due_at'] ?? '').toString().trim();
    if (due.isEmpty) return;
    final DateTime? when = DateTime.tryParse(due.replaceFirst(' ', 'T'));
    if (when == null) return;
    await _schedule(_crmId(uid), 'پیگیری ${(row['party'] ?? '').toString()}', (row['text'] ?? '').toString(), when);
  }

  Future<void> cancelCrmTask(String uid) => _cancel(_crmId(uid));

  /// هنگام باز شدن برنامه همه یادآوری‌های پرداخت‌نشده را دوباره زمان‌بندی می‌کند
  Future<void> rescheduleAll() async {
    if (!_ready) return;
    try {
      for (final row in await AppDb.I.unpaidCreditInst()) {
        await scheduleCreditRow(row);
      }
      for (final row in await AppDb.I.unpaidChequeInst()) {
        await scheduleChequeRow(row);
      }
      for (final row in await AppDb.I.unpaidReceiptCreditInst()) {
        await scheduleReceiptCreditRow(row);
      }
      for (final row in await AppDb.I.unpaidReceiptChequeInst()) {
        await scheduleReceiptChequeRow(row);
      }
      for (final row in await AppDb.I.unpaidLoanDues()) {
        await scheduleLoanRow(row);
      }
      for (final Map<String, dynamic> row in await EntityStore.I.list('crm_tasks')) {
        await scheduleCrmTask(row);
      }
    } catch (_) {}
  }
}
