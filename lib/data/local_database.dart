import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'product_repository.dart';
import 'sales_repository.dart';

/// Opens the app's private local database on Android and desktop.
/// Desktop uses SQLite FFI; mobile uses the platform SQLite plugin.
Future<sqflite.Database> openLocalDatabase() async {
  final supportDirectory = await getApplicationSupportDirectory();
  await supportDirectory.create(recursive: true);
  final databasePath = p.join(supportDirectory.path, 'smart_merchant_suite.db');

  final isMobile = !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  if (isMobile) {
    return sqflite.openDatabase(
      databasePath,
      version: 2,
      onCreate: (db, version) => createLocalSchema(db),
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) await createSalesSchema(db);
      },
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
    );
  }

  // Flutter web is not a supported target for this SQLite implementation.
  if (kIsWeb) {
    throw UnsupportedError('قاعدة البيانات المحلية لا تدعم نسخة الويب حاليًا');
  }

  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  return databaseFactoryFfi.openDatabase(
    databasePath,
    options: OpenDatabaseOptions(
      version: 2,
      onCreate: (db, version) => createLocalSchema(db),
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) await createSalesSchema(db);
      },
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
    ),
  );
}
