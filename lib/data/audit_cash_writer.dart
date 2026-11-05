import 'package:sqflite_common/sqlite_api.dart';

import '../domain/payment_method.dart';
import 'sync_outbox_repository.dart';

Future<void> writeAuditEvent(
  DatabaseExecutor executor, {
  required String action,
  required String entityType,
  int? entityId,
  int? amountMinor,
  String? details,
  String? createdAt,
}) async {
  await executor.insert('audit_events', {
    'action': action,
    'entity_type': entityType,
    'entity_id': entityId,
    'amount_minor': amountMinor,
    'details': details,
    'created_at': createdAt ?? DateTime.now().toUtc().toIso8601String(),
  });
}

/// Records a settlement method and mirrors physical cash into the drawer journal.
/// Zero-value operations are omitted; unpaid credit is not a payment record.
/// Creates or returns the cash drawer owned by this SQLite installation
/// for the selected branch. The device identity is stable across restarts.
Future<Map<String, Object?>> ensureCashDrawerForCurrentDevice(
  DatabaseExecutor executor, {
  required int branchId,
}) async {
  final branches = await executor.query(
    'branches',
    columns: ['id'],
    where: 'id = ? AND is_active = 1',
    whereArgs: [branchId],
    limit: 1,
  );
  if (branches.isEmpty) throw StateError('cash_drawer_branch_missing_or_inactive');

  final deviceId = await SyncOutboxRepository.ensureDeviceIdFor(executor);
  var drawers = await executor.query(
    'cash_drawers',
    where: 'branch_id = ? AND device_id = ?',
    whereArgs: [branchId, deviceId],
    limit: 1,
  );
  if (drawers.isEmpty) {
    final stamp = DateTime.now().toUtc().toIso8601String();
    final drawerId = await executor.insert('cash_drawers', {
      'branch_id': branchId,
      'device_id': deviceId,
      'label': 'جهاز ${deviceId.substring(0, 8)}',
      'is_active': 1,
      'created_at': stamp,
    });
    drawers = await executor.query(
      'cash_drawers',
      where: 'id = ?',
      whereArgs: [drawerId],
      limit: 1,
    );
  }
  final drawer = drawers.single;
  if (drawer['is_active'] != 1) {
    throw StateError('cash_drawer_inactive');
  }
  return drawer;
}

Future<void> writeCashMovement(
  DatabaseExecutor executor, {
  required String direction,
  required String category,
  required int amountMinor,
  required String sourceType,
  int? sourceId,
  String? note,
  String? createdAt,
  String paymentMethod = PaymentMethod.cash,
  required int branchId,
  int? cashSessionId,
  int? cashDrawerId,
}) async {
  if (amountMinor <= 0) return;
  if (direction != 'in' && direction != 'out') {
    throw ArgumentError.value(direction, 'direction');
  }
  if (!PaymentMethod.isValid(paymentMethod)) {
    throw ArgumentError.value(paymentMethod, 'paymentMethod');
  }
  if (branchId <= 0) {
    throw ArgumentError.value(branchId, 'branchId');
  }
  final activeBranches = await executor.query(
    'branches',
    columns: ['id'],
    where: 'id = ? AND is_active = 1',
    whereArgs: [branchId],
    limit: 1,
  );
  if (activeBranches.isEmpty) {
    throw StateError('cash_movement_branch_missing_or_inactive');
  }
  final stamp = createdAt ?? DateTime.now().toUtc().toIso8601String();
  await executor.insert('payment_records', {
    'direction': direction,
    'payment_method': paymentMethod,
    'amount_minor': amountMinor,
    'source_type': sourceType,
    'source_id': sourceId,
    'branch_id': branchId,
    'note': note,
    'created_at': stamp,
  });
  // Only physical cash belongs in the cash drawer journal.
  if (paymentMethod != PaymentMethod.cash) return;
  final drawer = await ensureCashDrawerForCurrentDevice(
    executor,
    branchId: branchId,
  );
  final resolvedDrawerId = cashDrawerId ?? drawer['id']! as int;
  if (drawer['id'] != resolvedDrawerId) {
    throw StateError('cash_drawer_device_mismatch');
  }

  Map<String, Object?>? session;
  var resolvedSessionId = cashSessionId;
  if (cashSessionId != null) {
    final sessions = await executor.query(
      'cash_sessions',
      where: "id = ? AND status = 'open'",
      whereArgs: [cashSessionId],
      limit: 1,
    );
    if (sessions.isEmpty) {
      throw StateError('cash_session_not_open_or_missing');
    }
    session = sessions.single;
    if (session['branch_id'] != branchId) {
      throw StateError('cash_session_branch_mismatch');
    }
    if (session['cash_drawer_id'] != resolvedDrawerId) {
      throw StateError('cash_session_drawer_mismatch');
    }
  } else {
    final sessions = await executor.query(
      'cash_sessions',
      columns: ['id'],
      where: "branch_id = ? AND cash_drawer_id = ? AND status = 'open'",
      whereArgs: [branchId, resolvedDrawerId],
      limit: 1,
    );
    if (sessions.isNotEmpty) {
      resolvedSessionId = sessions.single['id']! as int;
    }
  }

  await executor.insert('cash_transactions', {
    'direction': direction,
    'category': category,
    'amount_minor': amountMinor,
    'source_type': sourceType,
    'source_id': sourceId,
    'cash_session_id': resolvedSessionId,
    'branch_id': branchId,
    'cash_drawer_id': resolvedDrawerId,
    'note': note,
    'created_at': stamp,
  });
}
