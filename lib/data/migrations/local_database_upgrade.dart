import 'package:sqflite_common/sqlite_api.dart';

import 'cash_sessions_schema.dart';
import 'local_schema.dart';
import 'payment_methods_schema.dart';
import 'sync_outbox_dependencies_schema.dart';
import 'sync_outbox_dependency_edges_schema.dart';
import 'sync_outbox_schema.dart';

/// Applies every schema migration after [oldVersion] in the same order on
/// Android and desktop. Keep this list aligned with the database version.
Future<void> upgradeLocalDatabaseSchema(
  Database db,
  int oldVersion,
  int newVersion,
) async {
  if (oldVersion < 2) await createSalesSchema(db);
  if (oldVersion < 3) await createExpensesSchema(db);
  if (oldVersion < 4) await createCatalogSchema(db);
  if (oldVersion < 5) await createBranchWarehouseSchema(db);
  if (oldVersion < 6) await createSaleWarehouseSchema(db);
  if (oldVersion < 7) await createFractionalQuantitiesSchema(db);
  if (oldVersion < 8) await createPurchaseSchema(db);
  if (oldVersion < 9) await createAccountSchema(db);
  if (oldVersion < 10) await createSupplierReturnsSchema(db);
  if (oldVersion < 11) await createCustomerReturnsSchema(db);
  if (oldVersion < 12) await createSalesCancellationSchema(db);
  if (oldVersion < 13) await createAuditCashSchema(db);
  if (oldVersion < 14) await createPaymentMethodsSchema(db);
  if (oldVersion < 15) await createCashSessionsSchema(db);
  if (oldVersion < 16) await createSyncOutboxSchema(db);
  if (oldVersion < 17) await createSyncOutboxDependenciesSchema(db);
  if (oldVersion < 18) await createSyncOutboxDependencyEdgesSchema(db);
}
