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

/// Records actual cash received or paid. Zero-value operations are omitted.
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
  await executor.insert('cash_transactions', {
    'direction': direction,
    'category': category,
    'amount_minor': amountMinor,
    'source_type': sourceType,
    'source_id': sourceId,
    'note': note,
    'created_at': stamp,
  });
}
