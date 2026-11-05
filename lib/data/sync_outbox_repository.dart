import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

class SyncOutboxEvent {
  const SyncOutboxEvent({
    required this.eventId,
    required this.operationId,
    required this.businessId,
    required this.entityType,
    required this.localEntityId,
    required this.action,
    required this.payload,
    required this.status,
    required this.attempts,
    this.dependsOnEventId,
  });

  final String eventId;
  final String operationId;
  final String? businessId;
  final String entityType;
  final String localEntityId;
  final String action;
  final Map<String, dynamic> payload;
  final String status;
  final int attempts;
  final String? dependsOnEventId;

  factory SyncOutboxEvent.fromRow(Map<String, Object?> row) {
    final decoded = jsonDecode(row['payload_json']! as String);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Sync event payload must be a JSON object');
    }
    return SyncOutboxEvent(
      eventId: row['event_id']! as String,
      operationId: row['operation_id']! as String,
      businessId: row['business_id'] as String?,
      entityType: row['entity_type']! as String,
      localEntityId: row['local_entity_id']! as String,
      action: row['action']! as String,
      payload: Map<String, dynamic>.unmodifiable(decoded),
      status: row['status']! as String,
      attempts: row['attempts']! as int,
      dependsOnEventId: row['depends_on_event_id'] as String?,
    );
  }
}

/// Transactional local queue. Call [enqueue] with the same transaction that
/// writes the business record so a crash cannot save one without the other.
class SyncOutboxRepository {
  SyncOutboxRepository(this._db);

  final Database _db;
  static const _uuid = Uuid();

  Future<String> ensureDeviceId({DatabaseExecutor? executor}) async {
    final db = executor ?? _db;
    final rows = await db.query(
      'sync_metadata',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['device_id'],
      limit: 1,
    );
    if (rows.isNotEmpty) return rows.single['value']! as String;

    final id = _uuid.v4();
    await db.insert(
      'sync_metadata',
      {
        'key': 'device_id',
        'value': id,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    final saved = await db.query(
      'sync_metadata',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['device_id'],
      limit: 1,
    );
    return saved.single['value']! as String;
  }

  /// Enqueues only when this SQLite file has an immutable cloud-business identity.
  /// A legacy offline database remains local and is never auto-assigned to a tenant.
  Future<String?> enqueueForCurrentBusiness({
    required DatabaseExecutor executor,
    required String entityType,
    required String localEntityId,
    required String action,
    required Map<String, dynamic> payload,
    String? dependsOnEventId,
  }) async {
    final rows = await executor.query(
      'sync_metadata',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['database_business_id'],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final businessId = (rows.single['value']! as String).trim().toLowerCase();
    final isCanonicalUuid = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    ).hasMatch(businessId);
    if (!isCanonicalUuid) {
      throw StateError('invalid_database_business_identity');
    }
    return enqueue(
      executor: executor,
      businessId: businessId,
      entityType: entityType,
      localEntityId: localEntityId,
      action: action,
      payload: payload,
      dependsOnEventId: dependsOnEventId,
    );
  }

  /// Returns the latest unfinished event for this local entity in the current tenant.
  /// Conflict events are excluded because they require an explicit resolution path.
  Future<String?> latestUnfinishedEventIdForCurrentBusiness({
    required DatabaseExecutor executor,
    required String entityType,
    required String localEntityId,
  }) async {
    final identityRows = await executor.query(
      'sync_metadata',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['database_business_id'],
      limit: 1,
    );
    if (identityRows.isEmpty) return null;
    final businessId = (identityRows.single['value']! as String).trim().toLowerCase();
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    ).hasMatch(businessId)) {
      throw StateError('invalid_database_business_identity');
    }
    final rows = await executor.query(
      'sync_outbox',
      columns: ['event_id'],
      where: "business_id = ? AND entity_type = ? AND local_entity_id = ? AND status IN ('pending', 'processing', 'failed')",
      whereArgs: [businessId, entityType, localEntityId],
      orderBy: 'created_at DESC, event_id DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['event_id'] as String;
  }

  /// Low-level enqueue API for controlled migrations and isolated queue tests.
  /// Production business repositories should use enqueueForCurrentBusiness.
  Future<String> enqueue({
    DatabaseExecutor? executor,
    String? businessId,
    required String entityType,
    required String localEntityId,
    required String action,
    required Map<String, dynamic> payload,
    String? dependsOnEventId,
  }) async {
    if (entityType.trim().isEmpty || localEntityId.trim().isEmpty) {
      throw ArgumentError('entityType and localEntityId are required');
    }
    if (!const {'create', 'update', 'delete', 'adjust'}.contains(action)) {
      throw ArgumentError.value(action, 'action', 'Unsupported sync action');
    }

    final db = executor ?? _db;
    if (dependsOnEventId != null) {
      if (businessId == null || businessId.trim().isEmpty) {
        throw ArgumentError('A dependent event must be tenant-scoped');
      }
      final parents = await db.query(
        'sync_outbox',
        columns: ['business_id', 'status'],
        where: 'event_id = ?',
        whereArgs: [dependsOnEventId],
        limit: 1,
      );
      if (parents.isEmpty) throw StateError('Outbox dependency does not exist');
      if (parents.single['business_id'] != businessId) {
        throw StateError('Outbox dependency belongs to another business');
      }
      if (parents.single['status'] == 'conflict') {
        throw StateError('A conflicted event cannot be a dependency');
      }
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final operationId = _uuid.v4();
    final eventId = _uuid.v4();
    await db.insert('sync_outbox', {
      'event_id': eventId,
      'operation_id': operationId,
      'business_id': businessId,
      'entity_type': entityType,
      'local_entity_id': localEntityId,
      'action': action,
      'payload_json': jsonEncode(payload),
      'depends_on_event_id': dependsOnEventId,
      'status': 'pending',
      'attempts': 0,
      'created_at': now,
      'updated_at': now,
    });
    return eventId;
  }

  /// Binds exactly one legacy event after an explicit owner confirmation.
  /// Never bulk-assigns an existing local queue to a tenant.
  Future<void> bindEventToBusiness({
    required String eventId,
    required String businessId,
    required bool explicitlyConfirmed,
  }) async {
    if (eventId.trim().isEmpty || businessId.trim().isEmpty) {
      throw ArgumentError('eventId and businessId are required');
    }
    if (!explicitlyConfirmed) {
      throw StateError('tenant_binding_requires_explicit_confirmation');
    }

    await _db.transaction((txn) async {
      final rows = await txn.query(
        'sync_outbox',
        where: 'event_id = ?',
        whereArgs: [eventId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Sync event not found: $eventId');
      final event = SyncOutboxEvent.fromRow(rows.single);
      if (event.businessId != null) {
        if (event.businessId == businessId) return;
        throw StateError('A sync event cannot be reassigned to another business');
      }
      if (!const {'pending', 'failed'}.contains(event.status)) {
        throw StateError('Only an unbound pending or failed event can be assigned');
      }

      final changed = await txn.update(
        'sync_outbox',
        {
          'business_id': businessId,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: "event_id = ? AND business_id IS NULL AND status IN ('pending', 'failed')",
        whereArgs: [eventId],
      );
      if (changed != 1) {
        throw StateError('Sync event tenant binding changed concurrently');
      }
    });
  }

  Future<List<SyncOutboxEvent>> claimPendingBatch({
    required String businessId,
    int limit = 25,
    int maxAttempts = 5,
    Duration staleProcessingAge = const Duration(minutes: 5),
  }) async {
    if (businessId.trim().isEmpty || limit < 1 || maxAttempts < 1) {
      throw ArgumentError('businessId, limit and maxAttempts must be valid');
    }
    return _db.transaction((txn) async {
      final now = DateTime.now().toUtc();
      final nowIso = now.toIso8601String();
      final staleBefore =
          now.subtract(staleProcessingAge).toIso8601String();

      await txn.update(
        'sync_outbox',
        {
          'status': 'failed',
          'last_error': 'Previous synchronization was interrupted',
          'updated_at': nowIso,
        },
        where: "status = 'processing' AND updated_at < ? AND business_id = ?",
        whereArgs: [staleBefore, businessId],
      );

      final rows = await txn.query(
        'sync_outbox',
        where: "status IN ('pending', 'failed') AND attempts < ? AND business_id = ? AND (depends_on_event_id IS NULL OR EXISTS (SELECT 1 FROM sync_outbox parent WHERE parent.event_id = sync_outbox.depends_on_event_id AND parent.business_id = sync_outbox.business_id AND parent.status = 'synced'))",
        whereArgs: [maxAttempts, businessId],
        orderBy: 'created_at ASC, event_id ASC',
        limit: limit,
      );

      final claimed = <SyncOutboxEvent>[];
      for (final row in rows) {
        final eventId = row['event_id']! as String;
        final attempts = (row['attempts']! as int) + 1;
        await txn.update(
          'sync_outbox',
          {
            'status': 'processing',
            'attempts': attempts,
            'updated_at': nowIso,
            'last_error': null,
          },
          where: "event_id = ? AND status IN ('pending', 'failed')",
          whereArgs: [eventId],
        );
        claimed.add(SyncOutboxEvent.fromRow({
          ...row,
          'status': 'processing',
          'attempts': attempts,
        }));
      }
      return claimed;
    });
  }

  Future<void> markSynced(
    String eventId, {
    String? remoteEntityId,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _db.transaction((txn) async {
      final rows = await txn.query(
        'sync_outbox',
        where: 'event_id = ?',
        whereArgs: [eventId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Sync event not found: $eventId');
      final event = SyncOutboxEvent.fromRow(rows.single);
      if (event.status != 'processing') {
        throw StateError('Only a claimed event can be marked synced');
      }
      if (remoteEntityId != null && event.businessId != null) {
        await _writeEntityMapping(
          txn,
          businessId: event.businessId!,
          entityType: event.entityType,
          localEntityId: event.localEntityId,
          remoteEntityId: remoteEntityId,
          now: now,
        );
      }
      final changed = await txn.update(
        'sync_outbox',
        {
          'status': 'synced',
          'remote_entity_id': remoteEntityId,
          'last_error': null,
          'synced_at': now,
          'updated_at': now,
        },
        where: 'event_id = ? AND status = ?',
        whereArgs: [eventId, 'processing'],
      );
      if (changed != 1) {
        throw StateError('Sync event changed before it could be marked synced');
      }
    });
  }

  Future<void> markFailed(String eventId, Object error) async {
    final message = error.toString();
    final now = DateTime.now().toUtc().toIso8601String();
    final changed = await _db.update(
      'sync_outbox',
      {
        'status': 'failed',
        'last_error': message.length > 1000 ? message.substring(0, 1000) : message,
        'updated_at': now,
      },
      where: 'event_id = ? AND status = ?',
      whereArgs: [eventId, 'processing'],
    );
    if (changed != 1) {
      throw StateError('Only a claimed event can be marked failed');
    }
  }

  Future<void> recordConflict({
    required String eventId,
    required String conflictType,
    Map<String, dynamic>? remotePayload,
  }) async {
    if (conflictType.trim().isEmpty) {
      throw ArgumentError.value(conflictType, 'conflictType');
    }
    final now = DateTime.now().toUtc().toIso8601String();

    await _db.transaction((txn) async {
      final rows = await txn.query(
        'sync_outbox',
        where: 'event_id = ?',
        whereArgs: [eventId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Sync event not found: $eventId');
      final event = SyncOutboxEvent.fromRow(rows.single);
      if (event.status != 'processing') {
        throw StateError('Only a claimed event can be recorded as a conflict');
      }

      await txn.insert(
        'sync_conflicts',
        {
          'id': _uuid.v4(),
          'event_id': event.eventId,
          'business_id': event.businessId,
          'entity_type': event.entityType,
          'local_entity_id': event.localEntityId,
          'conflict_type': conflictType,
          'local_payload_json': jsonEncode(event.payload),
          'remote_payload_json':
              remotePayload == null ? null : jsonEncode(remotePayload),
          'detected_at': now,
        },
      );
      final changed = await txn.update(
        'sync_outbox',
        {
          'status': 'conflict',
          'last_error': conflictType,
          'updated_at': now,
        },
        where: "event_id = ? AND status = 'processing'",
        whereArgs: [eventId],
      );
      if (changed != 1) {
        throw StateError('Sync event changed while recording its conflict');
      }
    });
  }

  Future<void> upsertEntityMapping({
    required String businessId,
    required String entityType,
    required String localEntityId,
    required String remoteEntityId,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _db.transaction((txn) => _writeEntityMapping(
          txn,
          businessId: businessId,
          entityType: entityType,
          localEntityId: localEntityId,
          remoteEntityId: remoteEntityId,
          now: now,
        ));
  }

  Future<void> _writeEntityMapping(
    DatabaseExecutor txn, {
    required String businessId,
    required String entityType,
    required String localEntityId,
    required String remoteEntityId,
    required String now,
  }) async {
    final localRows = await txn.query(
      'sync_entity_map',
      columns: ['remote_entity_id'],
      where: 'business_id = ? AND entity_type = ? AND local_entity_id = ?',
      whereArgs: [businessId, entityType, localEntityId],
      limit: 1,
    );
    if (localRows.isNotEmpty &&
        localRows.single['remote_entity_id'] != remoteEntityId) {
      throw StateError('Local entity is already mapped to another cloud id');
    }

    final remoteRows = await txn.query(
      'sync_entity_map',
      columns: ['local_entity_id'],
      where: 'business_id = ? AND entity_type = ? AND remote_entity_id = ?',
      whereArgs: [businessId, entityType, remoteEntityId],
      limit: 1,
    );
    if (remoteRows.isNotEmpty &&
        remoteRows.single['local_entity_id'] != localEntityId) {
      throw StateError('Cloud entity is already mapped to another local id');
    }

    if (localRows.isEmpty) {
      await txn.insert('sync_entity_map', {
        'business_id': businessId,
        'entity_type': entityType,
        'local_entity_id': localEntityId,
        'remote_entity_id': remoteEntityId,
        'created_at': now,
        'updated_at': now,
      });
    } else {
      await txn.update(
        'sync_entity_map',
        {'updated_at': now},
        where: 'business_id = ? AND entity_type = ? AND local_entity_id = ?',
        whereArgs: [businessId, entityType, localEntityId],
      );
    }
  }

  Future<String?> remoteIdFor({
    required String businessId,
    required String entityType,
    required String localEntityId,
  }) async {
    final rows = await _db.query(
      'sync_entity_map',
      columns: ['remote_entity_id'],
      where: 'business_id = ? AND entity_type = ? AND local_entity_id = ?',
      whereArgs: [businessId, entityType, localEntityId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['remote_entity_id'] as String;
  }

  Future<String?> localIdFor({
    required String businessId,
    required String entityType,
    required String remoteEntityId,
  }) async {
    final rows = await _db.query(
      'sync_entity_map',
      columns: ['local_entity_id'],
      where: 'business_id = ? AND entity_type = ? AND remote_entity_id = ?',
      whereArgs: [businessId, entityType, remoteEntityId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['local_entity_id'] as String;
  }

  Future<void> saveCursor({
    required String businessId,
    required String scope,
    required String? cursor,
  }) async {
    await _db.insert(
      'sync_cursors',
      {
        'business_id': businessId,
        'scope': scope,
        'cursor_value': cursor,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> cursorFor({
    required String businessId,
    required String scope,
  }) async {
    final rows = await _db.query(
      'sync_cursors',
      columns: ['cursor_value'],
      where: 'business_id = ? AND scope = ?',
      whereArgs: [businessId, scope],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['cursor_value'] as String?;
  }

  Future<int> pendingCount({String? businessId}) async {
    return _db.rawQuery(
      "SELECT COUNT(*) AS count FROM sync_outbox WHERE status IN ('pending', 'failed', 'processing') AND (? IS NULL OR business_id = ?)",
      [businessId, businessId],
    ).then((rows) => rows.single['count']! as int);
  }
}
