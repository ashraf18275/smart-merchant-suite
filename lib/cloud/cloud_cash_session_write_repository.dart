import 'package:sqflite_common/sqlite_api.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/sync_outbox_repository.dart';

abstract interface class CloudCashSessionRpcClient {
  Future<Object?> call(String function, Map<String, dynamic> parameters);
}

class SupabaseCloudCashSessionRpcClient implements CloudCashSessionRpcClient {
  SupabaseCloudCashSessionRpcClient(this._client);

  final SupabaseClient _client;

  @override
  Future<Object?> call(String function, Map<String, dynamic> parameters) async {
    return await _client.rpc(function, params: parameters);
  }
}

/// Maps local cash-session lifecycle events to the branch/register-scoped
/// cloud RPCs. This adapter is not a dispatcher and never starts network work.
class CloudCashSessionWriteRepository {
  CloudCashSessionWriteRepository({
    required Database database,
    required CloudCashSessionRpcClient rpc,
  })  : _database = database,
        _rpc = rpc,
        _outbox = SyncOutboxRepository(database);

  final Database _database;
  final CloudCashSessionRpcClient _rpc;
  final SyncOutboxRepository _outbox;

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  Future<String> openFromEvent(SyncOutboxEvent event) async {
    _validateEvent(event, expectedAction: 'create');
    final businessId = _requireUuid(event.businessId, 'business_id');
    final operationId = _requireUuid(event.operationId, 'operation_id');
    final localSessionId = _parseLocalId(event.localEntityId, 'cash_session_id');
    final branchId = _parseLocalId(
      event.payload['local_branch_id'],
      'local_branch_id',
    );
    final drawerId = _parseLocalId(
      event.payload['local_cash_drawer_id'],
      'local_cash_drawer_id',
    );
    final openingBalance = event.payload['opening_balance_minor'];
    final deviceId = event.payload['device_id'];
    final note = event.payload['note'];

    if (openingBalance is! int || openingBalance < 0) {
      throw FormatException('invalid_cash_session_opening_balance');
    }
    if (deviceId is! String ||
        deviceId.trim().isEmpty ||
        deviceId.trim().length > 80) {
      throw FormatException('invalid_cash_session_device_id');
    }
    if (note != null && (note is! String || note.length > 500)) {
      throw FormatException('invalid_cash_session_note');
    }

    await _requireCurrentBusiness(businessId);
    final local = await _database.query(
      'cash_sessions',
      columns: ['branch_id', 'cash_drawer_id', 'device_id', 'opening_balance_minor'],
      where: 'id = ?',
      whereArgs: [localSessionId],
      limit: 1,
    );
    if (local.isEmpty ||
        local.single['branch_id'] != branchId ||
        local.single['cash_drawer_id'] != drawerId ||
        local.single['device_id'] != deviceId ||
        local.single['opening_balance_minor'] != openingBalance) {
      throw StateError('local_cash_session_context_mismatch');
    }

    final branch = await _database.query(
      'branches',
      columns: ['is_active'],
      where: 'id = ?',
      whereArgs: [branchId],
      limit: 1,
    );
    final drawer = await _database.query(
      'cash_drawers',
      columns: ['branch_id', 'device_id', 'is_active'],
      where: 'id = ?',
      whereArgs: [drawerId],
      limit: 1,
    );
    if (branch.isEmpty ||
        branch.single['is_active'] != 1 ||
        drawer.isEmpty ||
        drawer.single['is_active'] != 1 ||
        drawer.single['branch_id'] != branchId ||
        drawer.single['device_id'] != deviceId) {
      throw StateError('local_cash_drawer_unavailable_or_mismatched');
    }

    final cloudBranchId = await _mappedUuid(
      businessId: businessId,
      entityType: 'branch',
      localEntityId: branchId.toString(),
      label: 'branch',
    );
    final result = await _rpc.call('open_cloud_cash_session', {
      'p_business_id': businessId,
      'p_branch_id': cloudBranchId,
      'p_register_key': deviceId.trim(),
      'p_opening_balance_minor': openingBalance,
      'p_note': note,
      'p_operation_id': operationId,
    });
    final remoteId = _readRemoteId(result);
    await _outbox.upsertEntityMapping(
      businessId: businessId,
      entityType: 'cash_session',
      localEntityId: localSessionId.toString(),
      remoteEntityId: remoteId,
    );
    return remoteId;
  }

  Future<String> closeFromEvent(SyncOutboxEvent event) async {
    _validateEvent(event, expectedAction: 'update');
    final businessId = _requireUuid(event.businessId, 'business_id');
    final operationId = _requireUuid(event.operationId, 'operation_id');
    final localSessionId = _parseLocalId(event.localEntityId, 'cash_session_id');
    final branchId = _parseLocalId(
      event.payload['local_branch_id'],
      'local_branch_id',
    );
    final drawerId = _parseLocalId(
      event.payload['local_cash_drawer_id'],
      'local_cash_drawer_id',
    );
    final countedBalance = event.payload['counted_balance_minor'];
    final note = event.payload['note'];

    if (countedBalance is! int || countedBalance < 0) {
      throw FormatException('invalid_cash_session_counted_balance');
    }
    if (note != null && (note is! String || note.length > 500)) {
      throw FormatException('invalid_cash_session_note');
    }

    await _requireCurrentBusiness(businessId);
    await _requireDependenciesSynced(event, businessId);
    final local = await _database.query(
      'cash_sessions',
      columns: ['branch_id', 'cash_drawer_id', 'status', 'counted_balance_minor'],
      where: 'id = ?',
      whereArgs: [localSessionId],
      limit: 1,
    );
    if (local.isEmpty ||
        local.single['branch_id'] != branchId ||
        local.single['cash_drawer_id'] != drawerId ||
        local.single['status'] != 'closed' ||
        local.single['counted_balance_minor'] != countedBalance) {
      throw StateError('local_cash_session_close_context_mismatch');
    }

    final remoteSessionId = await _mappedUuid(
      businessId: businessId,
      entityType: 'cash_session',
      localEntityId: localSessionId.toString(),
      label: 'cash_session',
    );
    final result = await _rpc.call('close_cloud_cash_session', {
      'p_business_id': businessId,
      'p_cash_session_id': remoteSessionId,
      'p_counted_balance_minor': countedBalance,
      'p_note': note,
      'p_operation_id': operationId,
    });
    if (result is! Map) {
      throw FormatException('invalid_cloud_cash_session_close_result');
    }
    final returnedId = result['session_id'];
    if (returnedId is! String ||
        _requireUuid(returnedId, 'remote_cash_session_id') != remoteSessionId) {
      throw FormatException('cloud_cash_session_close_id_mismatch');
    }
    return remoteSessionId;
  }

  Future<void> _requireDependenciesSynced(
    SyncOutboxEvent event,
    String businessId,
  ) async {
    final rows = await _database.rawQuery(
      '''
      SELECT parent.business_id, parent.status
      FROM sync_outbox_dependencies dependency
      JOIN sync_outbox parent
        ON parent.event_id = dependency.depends_on_event_id
      WHERE dependency.event_id = ?
      ''',
      [event.eventId],
    );
    if (rows.any((row) =>
        row['business_id'] != businessId || row['status'] != 'synced')) {
      throw StateError('cash_session_dependency_not_synced');
    }
  }

  Future<String> _mappedUuid({
    required String businessId,
    required String entityType,
    required String localEntityId,
    required String label,
  }) async {
    final remoteId = await _outbox.remoteIdFor(
      businessId: businessId,
      entityType: entityType,
      localEntityId: localEntityId,
    );
    if (remoteId == null) throw StateError('missing_${label}_mapping');
    return _requireUuid(remoteId, 'remote_${label}_id');
  }

  Future<void> _requireCurrentBusiness(String businessId) async {
    final rows = await _database.query(
      'sync_metadata',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['database_business_id'],
      limit: 1,
    );
    if (rows.isEmpty ||
        (rows.single['value']! as String).trim().toLowerCase() != businessId) {
      throw StateError('database_business_identity_mismatch');
    }
  }

  void _validateEvent(
    SyncOutboxEvent event, {
    required String expectedAction,
  }) {
    if (event.entityType != 'cash_session' || event.action != expectedAction) {
      throw StateError('unsupported_cash_session_outbox_event');
    }
    if (event.payload['payload_schema_version'] != 1) {
      throw FormatException('unsupported_cash_session_payload_schema');
    }
    _requireUuid(event.businessId, 'business_id');
    _requireUuid(event.operationId, 'operation_id');
  }

  int _parseLocalId(Object? value, String label) {
    final id = value is int ? value : int.tryParse(value?.toString() ?? '');
    if (id == null || id <= 0) throw FormatException('invalid_$label');
    return id;
  }

  String _requireUuid(String? value, String label) {
    final normalized = value?.trim().toLowerCase();
    if (normalized == null || !_uuidPattern.hasMatch(normalized)) {
      throw FormatException('invalid_$label');
    }
    return normalized;
  }

  String _readRemoteId(Object? value) {
    if (value is! String) {
      throw FormatException('invalid_cloud_cash_session_rpc_result');
    }
    return _requireUuid(value, 'remote_cash_session_id');
  }
}
