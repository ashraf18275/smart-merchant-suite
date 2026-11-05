import 'package:sqflite_common/sqlite_api.dart';

Future<void> ensureBusinessDatabaseIdentity(
  Database database,
  String businessId,
) async {
  final normalized = businessId.trim().toLowerCase();
  if (normalized.isEmpty) {
    throw ArgumentError.value(businessId, 'businessId');
  }

  await database.transaction((txn) async {
    final rows = await txn.query(
      'sync_metadata',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['database_business_id'],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      if (rows.single['value'] as String != normalized) {
        throw StateError('business_database_identity_mismatch');
      }
      return;
    }
    await txn.insert('sync_metadata', {
      'key': 'database_business_id',
      'value': normalized,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  });
}
