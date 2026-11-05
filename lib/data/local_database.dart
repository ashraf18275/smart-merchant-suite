import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'business_database_identity.dart';
import 'local_database_path.dart';
import 'migrations/local_schema.dart';
import 'migrations/local_database_upgrade.dart';

/// Opens the app's private local database on Android and desktop.
/// Desktop uses SQLite FFI; mobile uses the platform SQLite plugin.
Future<sqflite.Database> openLocalDatabase({String? businessId}) async {
  final supportDirectory = await getApplicationSupportDirectory();
  await supportDirectory.create(recursive: true);
  final databasePath = LocalDatabasePath.resolve(
    supportDirectory.path,
    businessId: businessId,
  );
  if (businessId != null) {
    await Directory(p.dirname(databasePath)).create(recursive: true);
  }

  final isMobile = !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  if (isMobile) {
    final database = await sqflite.openDatabase(
      databasePath,
      version: 20,
      onCreate: (db, version) => createLocalSchema(db),
      onUpgrade: upgradeLocalDatabaseSchema,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
    );
    if (businessId != null) {
      try {
        await ensureBusinessDatabaseIdentity(database, businessId);
      } catch (_) {
        await database.close();
        rethrow;
      }
    }
    return database;
  }

  if (kIsWeb) {
    throw UnsupportedError('قاعدة البيانات المحلية لا تدعم نسخة الويب حاليًا');
  }

  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final database = await databaseFactoryFfi.openDatabase(
    databasePath,
    options: OpenDatabaseOptions(
      version: 20,
      onCreate: (db, version) => createLocalSchema(db),
      onUpgrade: upgradeLocalDatabaseSchema,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
    ),
  );
  if (businessId != null) {
    try {
      await ensureBusinessDatabaseIdentity(database, businessId);
    } catch (_) {
      await database.close();
      rethrow;
    }
  }
  return database;
}
