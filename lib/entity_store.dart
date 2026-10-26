import 'dart:convert';
import 'dart:math' as math;

import 'package:sqflite/sqflite.dart';

import 'db.dart';

/// Bump when [kEntityRegistry] changes in a way the server must know about (informational; the server
/// stays the authority: only entities it exports/lists are shown, see [EntityStore.visibleNames]).
const int kEntityRegistryVersion = 1;

/// One field of an entity (mirrors a column spec of `server/backend/api/entities.php`).
/// type: string | text | int | bigint | decimal | bool | date | datetime | enum | ref | json
class EntityField {
  final String key;
  final String label;
  final String type;
  final bool required;
  final int? max;
  final num? vmin;
  final num? vmax;
  final int scale;
  final List<String> values;
  final Map<String, String> valueLabels;
  final String? ref;
  final Object? defaultValue;

  /// UI hint only: format with thousands separators (stored as plain integer, unit = toman).
  final bool money;

  /// UI hint only: a string field that holds a party name (autocomplete from existing parties).
  final bool party;

  const EntityField(
    this.key,
    this.label,
    this.type, {
    this.required = false,
    this.max,
    this.vmin,
    this.vmax,
    this.scale = 4,
    this.values = const <String>[],
    this.valueLabels = const <String, String>{},
    this.ref,
    this.defaultValue,
    this.money = false,
    this.party = false,
  });

  bool get isNumeric => type == 'int' || type == 'bigint' || type == 'decimal';
  bool get isLong => type == 'text';
}

class EntitySpec {
  final String name;
  final String label;
  final List<EntityField> fields;
  final List<String> search;

  /// column used for ordering in lists ('' = newest first)
  final String orderCol;
  final bool orderDesc;

  /// permission keys (client hides only; the server enforces)
  final String? permCreate;
  final String? permEdit;
  final String? permDelete;

  /// fields shown in the list tile: first = title, second = subtitle, rest = trailing text
  final List<String> listFields;

  const EntitySpec(
    this.name,
    this.label,
    this.fields, {
    this.search = const <String>[],
    this.orderCol = '',
    this.orderDesc = true,
    this.permCreate,
    this.permEdit,
    this.permDelete,
    this.listFields = const <String>[],
  });

  EntityField? field(String key) {
    for (final f in fields) {
      if (f.key == key) return f;
    }
    return null;
  }
}

/// Bundled static registry (same names/types as the server registry). Later stages append entries.
/// Never rename/remove a released entry or field.
const Map<String, EntitySpec> kEntityRegistry = <String, EntitySpec>{
  // S01.T01.1 (mirror of server `warehouses`)
  'warehouses': EntitySpec(
    'warehouses',
    'انبار',
    <EntityField>[
      EntityField('name', 'نام انبار', 'string', required: true, max: 100),
      EntityField('type', 'نوع', 'enum',
          values: <String>['main', 'consignment', 'processing', 'virtual'],
          valueLabels: <String, String>{
            'main': 'اصلی',
            'consignment': 'امانی',
            'processing': 'فراوری',
            'virtual': 'مجازی'
          },
          defaultValue: 'main'),
      EntityField('active', 'فعال', 'bool', defaultValue: true),
      EntityField('address', 'نشانی', 'string', max: 250),
      EntityField('is_default', 'پیش‌فرض', 'bool', defaultValue: false),
    ],
    search: <String>['name', 'address'],
    listFields: <String>['name', 'address'],
    permCreate: 'warehouses.manage',
    permEdit: 'warehouses.manage',
    permDelete: 'warehouses.manage',
  ),
  // S01.T01.1 (mirror of server `ounces`)
  'ounces': EntitySpec(
    'ounces',
    'درجه‌بندی اونس',
    <EntityField>[
      EntityField('code', 'کد', 'string', required: true, max: 40),
      EntityField('from_val', 'از', 'decimal', scale: 3, vmin: 0),
      EntityField('to_val', 'تا', 'decimal', scale: 3, vmin: 0),
      EntityField('note', 'توضیح', 'string', max: 250),
    ],
    search: <String>['code', 'note'],
    listFields: <String>['code', 'note'],
    permCreate: 'ounces.manage',
    permEdit: 'ounces.manage',
    permDelete: 'ounces.manage',
  ),
  // S03.T03.3/T03.4 (mirror of server `crm_notes` / `crm_tasks`)
  'crm_notes': EntitySpec(
    'crm_notes',
    'یادداشت ارتباط با طرف‌حساب',
    <EntityField>[
      EntityField('party', 'طرف‌حساب', 'string', required: true, max: 150, party: true),
      EntityField('kind', 'نوع', 'enum',
          values: <String>['call', 'visit', 'message', 'other'],
          valueLabels: <String, String>{'call': 'تماس', 'visit': 'بازدید', 'message': 'پیام', 'other': 'سایر'},
          defaultValue: 'other'),
      EntityField('text', 'متن', 'text', required: true, max: 5000),
      EntityField('date', 'تاریخ', 'date'),
    ],
    search: <String>['party', 'text'],
    listFields: <String>['party', 'text'],
    permCreate: 'crm.edit',
    permEdit: 'crm.edit',
    permDelete: 'crm.edit',
  ),
  'crm_tasks': EntitySpec(
    'crm_tasks',
    'پیگیری طرف‌حساب',
    <EntityField>[
      EntityField('party', 'طرف‌حساب', 'string', required: true, max: 150, party: true),
      EntityField('due_at', 'موعد پیگیری', 'datetime'),
      EntityField('text', 'شرح', 'string', required: true, max: 500),
      EntityField('done', 'انجام شد', 'bool', defaultValue: false),
      EntityField('assignee_staff', 'مسئول', 'string', max: 100),
    ],
    search: <String>['party', 'text'],
    listFields: <String>['party', 'text'],
    permCreate: 'crm.edit',
    permEdit: 'crm.edit',
    permDelete: 'crm.edit',
  ),
  // S12.T12.1 (mirror of server `company_profile` / `doc_sequences`)
  'company_profile': EntitySpec(
    'company_profile',
    'مشخصات شرکت',
    <EntityField>[
      EntityField('name', 'نام شرکت', 'string', required: true, max: 150),
      EntityField('logo', 'لوگو', 'text', max: 120000),
      EntityField('address', 'نشانی', 'string', max: 300),
      EntityField('phones', 'تلفن‌ها', 'string', max: 150),
      EntityField('economic_code', 'کد اقتصادی', 'string', max: 30),
      EntityField('national_id', 'شناسه ملی', 'string', max: 30),
      EntityField('postal_code', 'کد پستی', 'string', max: 20),
      EntityField('registration_no', 'شمارهٔ ثبت', 'string', max: 30),
      EntityField('footer_text', 'متن پای فاکتور', 'string', max: 300),
    ],
    search: <String>['name'],
    listFields: <String>['name', 'address'],
    permCreate: 'settings.manage',
    permEdit: 'settings.manage',
    permDelete: 'settings.manage',
  ),
  // S15.T15.3/T15.5 gold entities (mirror of server treasury.php; visible only to gold accounts)
  'cost_centers': EntitySpec(
    'cost_centers',
    'مراکز هزینه',
    <EntityField>[
      EntityField('code', 'کد', 'string', required: true, max: 20),
      EntityField('name', 'نام', 'string', required: true, max: 120),
      EntityField('parent', 'والد', 'ref', ref: 'cost_centers'),
      EntityField('active', 'فعال', 'bool', defaultValue: true),
    ],
    search: <String>['code', 'name'],
    orderCol: 'code',
    orderDesc: false,
    listFields: <String>['code', 'name'],
    permCreate: 'settings.manage',
    permEdit: 'settings.manage',
    permDelete: 'settings.manage',
  ),
  'cash_boxes': EntitySpec(
    'cash_boxes',
    'صندوق‌ها',
    <EntityField>[
      EntityField('name', 'نام صندوق', 'string', required: true, max: 100),
      EntityField('active', 'فعال', 'bool', defaultValue: true),
      EntityField('note', 'توضیح', 'string', max: 250),
    ],
    search: <String>['name'],
    listFields: <String>['name', 'note'],
    permCreate: 'settings.manage',
    permEdit: 'settings.manage',
    permDelete: 'settings.manage',
  ),
  'bank_accounts': EntitySpec(
    'bank_accounts',
    'حساب‌های بانکی',
    <EntityField>[
      EntityField('name', 'عنوان حساب', 'string', required: true, max: 100),
      EntityField('bank_name', 'بانک', 'string', max: 100),
      EntityField('branch', 'شعبه', 'string', max: 100),
      EntityField('account_no', 'شمارهٔ حساب', 'string', max: 40),
      EntityField('iban', 'شبا', 'string', max: 34),
      EntityField('ccy', 'ارز', 'string', max: 8, defaultValue: 'IRR'),
      EntityField('opening_balance', 'مانده اول دوره', 'bigint', money: true, defaultValue: 0),
      EntityField('active', 'فعال', 'bool', defaultValue: true),
    ],
    search: <String>['name', 'bank_name', 'account_no', 'iban'],
    listFields: <String>['name', 'bank_name', 'account_no'],
    permCreate: 'settings.manage',
    permEdit: 'settings.manage',
    permDelete: 'settings.manage',
  ),
  'expenses': EntitySpec(
    'expenses',
    'هزینه‌های عمومی',
    <EntityField>[
      EntityField('date', 'تاریخ', 'date', required: true),
      EntityField('amount', 'مبلغ', 'bigint', required: true, vmin: 1, money: true),
      EntityField('category', 'دسته', 'string', max: 100),
      EntityField('account_code', 'کد حساب هزینه', 'string', max: 20),
      EntityField('cost_center', 'مرکز هزینه', 'ref', ref: 'cost_centers'),
      EntityField('payer', 'پرداخت از', 'enum',
          values: <String>['cash', 'bank', 'credit'],
          valueLabels: <String, String>{'cash': 'صندوق', 'bank': 'بانک', 'credit': 'نسیه'},
          defaultValue: 'cash'),
      EntityField('cash_box', 'صندوق', 'ref', ref: 'cash_boxes'),
      EntityField('bank_account', 'حساب بانکی', 'ref', ref: 'bank_accounts'),
      EntityField('party', 'طرف‌حساب', 'string', max: 150),
      EntityField('note', 'توضیح', 'string', max: 500),
    ],
    search: <String>['category', 'party', 'note'],
    listFields: <String>['date', 'category', 'amount'],
    permCreate: 'accounting.post',
    permEdit: 'accounting.post',
    permDelete: 'accounting.post',
  ),
  'owner_draws': EntitySpec(
    'owner_draws',
    'برداشت/آورده صاحب سرمایه',
    <EntityField>[
      EntityField('date', 'تاریخ', 'date', required: true),
      EntityField('amount', 'مبلغ', 'bigint', required: true, vmin: 1, money: true),
      EntityField('kind', 'نوع', 'enum',
          values: <String>['draw', 'contribution'],
          valueLabels: <String, String>{'draw': 'برداشت', 'contribution': 'آورده'},
          defaultValue: 'draw'),
      EntityField('payer', 'از/به', 'enum',
          values: <String>['cash', 'bank'],
          valueLabels: <String, String>{'cash': 'صندوق', 'bank': 'بانک'},
          defaultValue: 'cash'),
      EntityField('cash_box', 'صندوق', 'ref', ref: 'cash_boxes'),
      EntityField('bank_account', 'حساب بانکی', 'ref', ref: 'bank_accounts'),
      EntityField('note', 'توضیح', 'string', max: 500),
    ],
    search: <String>['note'],
    listFields: <String>['date', 'kind', 'amount'],
    permCreate: 'accounting.post',
    permEdit: 'accounting.post',
    permDelete: 'accounting.post',
  ),
  'doc_sequences': EntitySpec(
    'doc_sequences',
    'شمارندهٔ اسناد',
    <EntityField>[
      EntityField('doc_type', 'نوع سند', 'string', required: true, max: 20),
      EntityField('fy', 'سال مالی', 'int', vmin: 0, vmax: 9999, defaultValue: 0),
      EntityField('prefix', 'پیشوند', 'string', max: 12),
      EntityField('next_no', 'شمارهٔ بعدی', 'int', vmin: 1, defaultValue: 1),
      EntityField('padding', 'تعداد ارقام', 'int', vmin: 0, vmax: 12, defaultValue: 5),
    ],
    search: <String>['doc_type', 'prefix'],
    listFields: <String>['doc_type', 'prefix'],
    permDelete: 'settings.manage',
  ),
  'dev_notes': EntitySpec(
    'dev_notes',
    'یادداشت آزمایشی',
    <EntityField>[
      EntityField('title', 'عنوان', 'string', required: true, max: 120),
      EntityField('body', 'متن', 'text', max: 5000),
      EntityField('kind', 'نوع', 'enum',
          values: <String>['note', 'todo'],
          valueLabels: <String, String>{'note': 'یادداشت', 'todo': 'کار'},
          defaultValue: 'note'),
      EntityField('done', 'انجام شد', 'bool', defaultValue: false),
      EntityField('due', 'سررسید', 'date'),
      EntityField('amount', 'مبلغ', 'bigint', vmin: 0, money: true),
    ],
    search: <String>['title', 'body'],
    listFields: <String>['title', 'body', 'amount'],
    permCreate: 'dev_notes.create',
    permEdit: 'dev_notes.edit',
    permDelete: 'dev_notes.delete',
  ),
};

/// Local mirror of generic entities (table `entity_rows`, one JSON blob per row) + offline queue hooks.
///
/// * Rows are identified by `uid` (client UUID). `rev` = server revision (0 = never confirmed by the server).
/// * Writes are applied locally at once and queued as `entity.save` / `entity.delete` ops in `sync_ops`
///   (the same queue/idempotency/retry as every other op). The server is the authority: a full pull
///   (`backup.export` -> `entities`) replaces local rows when the queue is empty.
/// * Conflict policy: last write wins (no expected_rev is sent).
class EntityStore {
  EntityStore._();
  static final EntityStore I = EntityStore._();

  static const String table = 'entity_rows';
  static const String _kVisibleKey = 'entity_visible';

  static final math.Random _rng = math.Random.secure();

  /// Creates the table (idempotent). Called from AppDb `_onCreate` and `_onUpgrade`.
  static Future<void> createTable(DatabaseExecutor d) async {
    await d.execute('''
      CREATE TABLE IF NOT EXISTS $table(
        entity TEXT NOT NULL,
        uid TEXT NOT NULL,
        rev INTEGER NOT NULL DEFAULT 0,
        data TEXT NOT NULL,
        created_at TEXT,
        updated_at TEXT,
        PRIMARY KEY(entity, uid)
      )''');
  }

  /// RFC-4122 v4 UUID (lowercase), accepted by the server (`pb_is_uid`).
  static String newUid() {
    final b = List<int>.generate(16, (_) => _rng.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  // ======================= visibility =======================

  /// Entities this account may use: those the server last reported (export keys) that the app also knows.
  Future<List<String>> visibleNames() async {
    final raw = await AppDb.I.metaGet(_kVisibleKey);
    if (raw == null || raw.isEmpty) return <String>[];
    try {
      final l = jsonDecode(raw);
      if (l is! List) return <String>[];
      final out = <String>[];
      for (final x in l) {
        if (x is String && kEntityRegistry.containsKey(x)) out.add(x);
      }
      return out;
    } catch (_) {
      return <String>[];
    }
  }

  Future<bool> isVisible(String entity) async => (await visibleNames()).contains(entity);

  // ======================= read =======================

  Map<String, dynamic> _decode(Map<String, Object?> r) {
    Map<String, dynamic> m = <String, dynamic>{};
    try {
      final j = jsonDecode(r['data'] as String);
      if (j is Map) m = Map<String, dynamic>.from(j);
    } catch (_) {}
    m['uid'] = r['uid'];
    m['rev'] = (r['rev'] as num?)?.toInt() ?? 0;
    m['created_at'] = r['created_at'];
    m['updated_at'] = r['updated_at'];
    return m;
  }

  Future<Map<String, dynamic>?> get(String entity, String uid) async {
    final d = await AppDb.I.db;
    final r = await d.query(table, where: 'entity=? AND uid=?', whereArgs: [entity, uid], limit: 1);
    return r.isEmpty ? null : _decode(r.first);
  }

  /// All rows of [entity], filtered by [q] over the spec's search fields, ordered per the spec.
  Future<List<Map<String, dynamic>>> list(String entity, {String q = ''}) async {
    final spec = kEntityRegistry[entity];
    if (spec == null) return <Map<String, dynamic>>[];
    final d = await AppDb.I.db;
    final rows = await d.query(table, where: 'entity=?', whereArgs: [entity], orderBy: 'rowid DESC');
    var out = rows.map(_decode).toList();
    final needle = q.trim().toLowerCase();
    if (needle.isNotEmpty && spec.search.isNotEmpty) {
      out = out.where((m) {
        for (final k in spec.search) {
          final v = m[k];
          if (v != null && v.toString().toLowerCase().contains(needle)) return true;
        }
        return false;
      }).toList();
    }
    final oc = spec.orderCol;
    if (oc.isNotEmpty) {
      int cmp(Map<String, dynamic> a, Map<String, dynamic> b) {
        final x = a[oc];
        final y = b[oc];
        if (x == null && y == null) return 0;
        if (x == null) return -1;
        if (y == null) return 1;
        if (x is num && y is num) return x.compareTo(y);
        return x.toString().compareTo(y.toString());
      }

      out.sort((a, b) => spec.orderDesc ? cmp(b, a) : cmp(a, b));
    }
    return out;
  }

  // ======================= write (local + queue) =======================

  /// Client-side validation mirroring the server rules. Returns a Persian message or null when OK.
  String? validate(EntitySpec spec, Map<String, dynamic> data) {
    for (final f in spec.fields) {
      final v = data[f.key];
      final empty = v == null || (v is String && v.trim().isEmpty);
      if (empty) {
        if (f.required) return '«${f.label}» الزامی است';
        continue;
      }
      if (f.type == 'string' || f.type == 'text') {
        final mx = f.max ?? (f.type == 'string' ? 255 : 20000);
        if (v.toString().trim().length > mx) return '«${f.label}» حداکثر $mx حرف می‌تواند باشد';
      } else if (f.isNumeric) {
        if (v is! num) return '«${f.label}» باید عدد باشد';
        if (f.vmin != null && v < f.vmin!) return '«${f.label}» نمی‌تواند کمتر از ${f.vmin} باشد';
        if (f.vmax != null && v > f.vmax!) return '«${f.label}» نمی‌تواند بیشتر از ${f.vmax} باشد';
        if (f.type != 'decimal' && v is double && v != v.roundToDouble()) return '«${f.label}» باید عدد صحیح باشد';
      } else if (f.type == 'enum') {
        if (!f.values.contains(v)) return '«${f.label}» نامعتبر است';
      }
    }
    return null;
  }

  /// Keeps only known fields, normalizes types and drops empty values (null = cleared).
  Map<String, dynamic> _clean(EntitySpec spec, Map<String, dynamic> data) {
    final out = <String, dynamic>{};
    for (final f in spec.fields) {
      if (!data.containsKey(f.key)) continue;
      var v = data[f.key];
      if (v is String) {
        v = v.trim();
        if (v == '') v = null;
      }
      if (v != null) {
        switch (f.type) {
          case 'int':
          case 'bigint':
            if (v is num) v = v.round();
            break;
          case 'decimal':
            if (v is num) v = v.toDouble();
            break;
          case 'bool':
            v = (v == true || v == 1 || v == '1');
            break;
        }
      }
      out[f.key] = v;
    }
    return out;
  }

  /// Save (create when [uid] is null). Returns the row uid. Throws [ArgumentError] with a Persian message
  /// when validation fails. The row is stored locally at once and queued for the server.
  Future<String> save(String entity, Map<String, dynamic> data, {String? uid}) async {
    final spec = kEntityRegistry[entity];
    if (spec == null) throw ArgumentError('بخش نامعتبر است');
    final clean = _clean(spec, data);
    final err = validate(spec, clean);
    if (err != null) throw ArgumentError(err);
    final id = uid ?? newUid();
    final d = await AppDb.I.db;
    final now = DateTime.now().toIso8601String();
    await d.transaction((t) async {
      final ex = await t.query(table, where: 'entity=? AND uid=?', whereArgs: [entity, id], limit: 1);
      var merged = <String, dynamic>{};
      var rev = 0;
      String? created = now;
      if (ex.isNotEmpty) {
        merged = Map<String, dynamic>.from(jsonDecode(ex.first['data'] as String) as Map);
        rev = (ex.first['rev'] as num?)?.toInt() ?? 0;
        created = ex.first['created_at'] as String?;
      } else {
        // defaults on create (the server applies the same defaults)
        for (final f in spec.fields) {
          if (f.defaultValue != null) merged[f.key] = f.defaultValue;
        }
      }
      merged.addAll(clean);
      await t.insert(
          table,
          {
            'entity': entity,
            'uid': id,
            'rev': rev,
            'data': jsonEncode(merged),
            'created_at': created,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      // send the full merged state (last write wins)
      final payload = <String, dynamic>{'entity': entity, 'uid': id, 'data': merged};
      await _upsertSaveOp(t, id, payload);
    });
    AppDb.I.version.value++;
    return id;
  }

  Future<void> delete(String entity, String uid) async {
    final d = await AppDb.I.db;
    await d.transaction((t) async {
      final ex = await t.query(table, columns: ['rev'], where: 'entity=? AND uid=?', whereArgs: [entity, uid], limit: 1);
      if (ex.isEmpty) return;
      final rev = (ex.first['rev'] as num?)?.toInt() ?? 0;
      await t.delete(table, where: 'entity=? AND uid=?', whereArgs: [entity, uid]);
      await t.delete('sync_ops',
          where: "action='entity.save' AND state='pending' AND payload LIKE ?", whereArgs: ['%"uid":"$uid"%']);
      // rev 0 = the server never confirmed it; an in-flight save is handled in [onSaved]
      if (rev > 0) {
        await AppDb.I.entityEnqueue(t, 'entity.delete', {'entity': entity, 'uid': uid});
      }
    });
    AppDb.I.version.value++;
  }

  Future<void> _upsertSaveOp(DatabaseExecutor t, String uid, Map<String, dynamic> payload) async {
    final ex = await t.query('sync_ops',
        columns: ['seq'],
        where: "action='entity.save' AND state='pending' AND payload LIKE ?",
        whereArgs: ['%"uid":"$uid"%'],
        limit: 1);
    if (ex.isNotEmpty) {
      await AppDb.I.entityUpdateOp(t, (ex.first['seq'] as num).toInt(), payload);
    } else {
      await AppDb.I.entityEnqueue(t, 'entity.save', payload);
    }
  }

  // ======================= sync hooks =======================

  /// Called by SyncService after the server accepted an `entity.save`. Stores the server revision.
  /// If the user deleted the row meanwhile, a delete op is queued so the server copy goes too.
  Future<void> onSaved(Map<String, dynamic> payload, Map<String, dynamic>? response) async {
    final entity = payload['entity'];
    final uid = payload['uid'];
    if (entity is! String || uid is! String) return;
    final item = response == null ? null : response['item'];
    final srvRev = item is Map ? (item['rev'] as num?)?.toInt() : null;
    final d = await AppDb.I.db;
    await d.transaction((t) async {
      final ex = await t.query(table, columns: ['rev'], where: 'entity=? AND uid=?', whereArgs: [entity, uid], limit: 1);
      if (ex.isEmpty) {
        await AppDb.I.entityEnqueue(t, 'entity.delete', {'entity': entity, 'uid': uid});
        return;
      }
      if (srvRev != null) {
        await t.update(table, {'rev': srvRev}, where: 'entity=? AND uid=?', whereArgs: [entity, uid]);
      }
    });
  }

  /// Replaces local rows with the server snapshot (`backup.export` -> `entities`), inside the caller's
  /// transaction. [entities] = {entity: [rawRow,...]}. Only entities present in the map are replaced
  /// (all local rows are dropped first when [discardAll]). Records which entities the server exposes.
  static Future<void> applySnapshot(DatabaseExecutor t, Map<String, dynamic> entities, {bool discardAll = false}) async {
    if (discardAll) {
      await t.delete(table);
    }
    final visible = <String>[];
    for (final e in entities.entries) {
      final name = e.key;
      visible.add(name);
      final spec = kEntityRegistry[name];
      if (spec == null) continue; // newer server entity this app version does not know: ignore
      await t.delete(table, where: 'entity=?', whereArgs: [name]);
      final rows = e.value;
      if (rows is! List) continue;
      final b = t.batch();
      for (final raw in rows) {
        if (raw is! Map) continue;
        final uid = raw['uid'];
        if (uid is! String || uid.isEmpty) continue;
        if (raw['deleted_at'] != null) continue; // soft-deleted on the server
        final data = <String, dynamic>{};
        for (final f in spec.fields) {
          data[f.key] = _fromServer(f, raw[f.key]);
        }
        b.insert(
            table,
            {
              'entity': name,
              'uid': uid,
              'rev': int.tryParse('${raw['rev']}') ?? 0,
              'data': jsonEncode(data),
              'created_at': raw['created_at']?.toString(),
              'updated_at': raw['updated_at']?.toString(),
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await b.commit(noResult: true);
    }
    await t.insert('meta', {'k': _kVisibleKey, 'v': jsonEncode(visible)}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Raw server value (PDO may give strings) -> typed client value.
  static Object? _fromServer(EntityField f, Object? v) {
    if (v == null) return null;
    switch (f.type) {
      case 'int':
      case 'bigint':
        if (v is num) return v.toInt();
        return int.tryParse(v.toString());
      case 'decimal':
        if (v is num) return v.toDouble();
        return double.tryParse(v.toString());
      case 'bool':
        return v == true || v == 1 || v == '1' || v == 'true';
      case 'json':
        if (v is String) {
          try {
            return jsonDecode(v);
          } catch (_) {
            return null;
          }
        }
        return v;
      case 'date':
        final s = v.toString();
        return s.length >= 10 ? s.substring(0, 10) : s;
      default:
        return v.toString();
    }
  }
}
