import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/data/business_database_identity.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database database;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(database);
  });

  tearDown(() async => database.close());

  test('pins a new database to one business and allows the same identity', () async {
    await ensureBusinessDatabaseIdentity(
      database,
      '6F8F5771-3A1B-4B2A-9C7D-1D0E4A5B6C7D',
    );
    await ensureBusinessDatabaseIdentity(
      database,
      '6f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d',
    );

    final rows = await database.query(
      'sync_metadata',
      where: 'key = ?',
      whereArgs: ['database_business_id'],
    );
    expect(rows, hasLength(1));
    expect(rows.single['value'], '6f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d');
  });

  test('refuses to reuse a database for a different business', () async {
    await ensureBusinessDatabaseIdentity(
      database,
      '6f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d',
    );

    await expectLater(
      ensureBusinessDatabaseIdentity(
        database,
        '7f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d',
      ),
      throwsStateError,
    );
  });
}
