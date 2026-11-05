import 'package:sqflite_common/sqlite_api.dart';

import '../domain/payment_method.dart';

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
  int? branchId,
}) async {
  if (amountMinor <= 0) return;
  if (direction != 'in' && direction != 'out') {
    throw ArgumentError.value(direction, 'direction');
  }
  if (!PaymentMethod.isValid(paymentMethod)) {
    throw ArgumentError.value(paymentMethod, 'paymentMethod');
  }
  final stamp = createdAt ?? DateTime.now().toUtc().toIso8601String();
  await executor.insert('payment_records', {
    'direction': direction,
    'payment_method': paymentMethod,
    'amount_minor': amountMinor,
    'source_type': sourceType,
    'source_id': sourceId,
    'note': note,
    'created_at': stamp,
  });
  // Only physical cash belongs in the cash drawer journal.
  if (paymentMethod != PaymentMethod.cash) return;
  // Never guess which open drawer owns a movement. If the caller has not
  // supplied an explicit session context, leave it unassigned for reconciliation.
  await executor.insert('cash_transactions', {
    'direction': direction,
    'category': category,
    'amount_minor': amountMinor,
    'source_type': sourceType,
    'source_id': sourceId,
    'cash_session_id': null,
    'branch_id': branchId,
    'note': note,
    'created_at': stamp,
  });
}
