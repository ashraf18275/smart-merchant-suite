import 'package:sqflite_common/sqlite_api.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/sync_outbox_repository.dart';
import '../domain/payment_method.dart';

abstract interface class CloudExpenseRpcClient {
  Future<Object?> call(String function, Map<String, dynamic> parameters);
}

class SupabaseCloudExpenseRpcClient implements CloudExpenseRpcClient {
  SupabaseCloudExpenseRpcClient(this._client);

  final SupabaseClient _client;

  @override
  Future<Object?> call(String function, Map<String, dynamic> parameters) async {
    return await _client.rpc(function, params: parameters);
  }
}

/// Converts a local expense event to the branch-scoped idempotent RPC.
/// It requires explicit branch/session mappings and is not a sync worker.
class CloudExpenseWriteRepository {
  CloudExpenseWriteRepository({
    required Database database,
    required CloudExpenseRpcClient rpc,
  })  : _database = database,
        _rpc = rpc,
        _outbox = SyncOutboxRepository(database);

  final Database _database;
  final CloudExpenseRpcClient _rpc;
  final SyncOutboxRepository _outbox;

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  Future<String> createFromEvent(SyncOutboxEvent event) async {
    if (event.entityType != 'expense' || event.action != 'create') {
      throw StateError('unsupported_expense_outbox_event');
    }
    if (event.payload['payload_schema_version'] != 1) {
      throw FormatException('unsupported_expense_payload_schema');
    }

    final businessId = _requireUuid(event.businessId, 'business_id');
    final operationId = _requireUuid(event.operationId, 'operation_id');
    final localExpenseId = _parseLocalId(event.localEntityId, 'expense_id');
    final localBranchId = _parseLocalId(
      event.payload['local_branch_id'],
      'local_branch_id',
    );
    final description = event.payload['description'];
    final category = event.payload['category'];
    final amount = event.payload['amount_minor'];
    final paymentMethod = event.payload['payment_method'];

    if (description is! String ||
        description.trim().isEmpty ||
        description.trim().length > 500) {
      throw FormatException('invalid_expense_description');
    }
    if (category is! String ||
        category.trim().isEmpty ||
        category.trim().length > 120) {
      throw FormatException('invalid_expense_category');
    }
    if (amount is! int || amount <= 0) {
      throw FormatException('invalid_expense_amount');
    }
    if (paymentMethod is! String || !PaymentMethod.isValid(paymentMethod)) {
      throw FormatException('invalid_expense_payment_method');
    }

    await _requireCurrentBusiness(businessId);
    await _requireDependenciesSynced(event, businessId);

    final localExpense = await _database.query(
      'expenses',
      columns: ['description', 'category', 'amount_minor', 'branch_id'],
      where: 'id = ?',
      whereArgs: [localExpenseId],
      limit: 1,
    );
    if (localExpense.isEmpty ||
        localExpense.single['description'] != description ||
        localExpense.single['category'] != category ||
        localExpense.single['amount_minor'] != amount ||
        localExpense.single['branch_id'] != localBranchId) {
      throw StateError('local_expense_snapshot_mismatch');
    }

    final localBranch = await _database.query(
      'branches',
      columns: ['is_active'],
      where: 'id = ?',
      whereArgs: [localBranchId],
      limit: 1,
    );
    if (localBranch.isEmpty || localBranch.single['is_active'] != 1) {
      throw StateError('local_expense_branch_unavailable');
    }

    final cloudBranchId = await _mappedUuid(
      businessId: businessId,
      entityType: 'branch',
      localEntityId: localBranchId.toString(),
      label: 'branch',
    );

    String? cloudCashSessionId;
    final localCashSessionValue = event.payload['local_cash_session_id'];
    if (paymentMethod == PaymentMethod.cash) {
      final localCashSessionId =
          _parseLocalId(localCashSessionValue, 'local_cash_session_id');
      final session = await _database.query(
        'cash_sessions',
        columns: ['branch_id', 'cash_drawer_id'],
        where: 'id = ?',
        whereArgs: [localCashSessionId],
        limit: 1,
      );
      if (session.isEmpty || session.single['branch_id'] != localBranchId) {
        throw StateError('local_expense_cash_session_branch_mismatch');
      }
      cloudCashSessionId = await _mappedUuid(
        businessId: businessId,
        entityType: 'cash_session',
        localEntityId: localCashSessionId.toString(),
        label: 'cash_session',
      );
    } else if (localCashSessionValue != null) {
      throw FormatException('non_cash_expense_must_not_reference_cash_session');
    }

    final result = await _rpc.call('create_cloud_expense', {
      'p_business_id': businessId,
      'p_branch_id': cloudBranchId,
      'p_description': description.trim(),
      'p_category': category.trim(),
      'p_amount_minor': amount,
      'p_payment_method': paymentMethod,
      'p_cash_session_id': cloudCashSessionId,
      'p_operation_id': operationId,
    });
    final remoteId = _readRemoteId(result);
    await _outbox.upsertEntityMapping(
      businessId: businessId,
      entityType: 'expense',
      localEntityId: localExpenseId.toString(),
      remoteEntityId: remoteId,
    );
    return remoteId;
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
      throw StateError('expense_dependency_not_synced');
    }
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
      throw FormatException('invalid_cloud_expense_rpc_result');
    }
    return _requireUuid(value, 'remote_expense_id');
  }
}
