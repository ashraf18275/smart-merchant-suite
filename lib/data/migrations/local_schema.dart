import 'package:sqflite_common/sqlite_api.dart';

/// Creates the current local schema for a new database.
Future<void> createLocalSchema(Database db) async {
  await db.execute('''
    CREATE TABLE products (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL CHECK (length(trim(name)) > 0),
      sku TEXT UNIQUE,
      cost_minor INTEGER NOT NULL CHECK (cost_minor >= 0),
      price_minor INTEGER NOT NULL CHECK (price_minor >= 0),
      stock_quantity INTEGER NOT NULL DEFAULT 0 CHECK (stock_quantity >= 0),
      is_active INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
      created_at TEXT NOT NULL
    )
  ''');

  await db.execute('''
    CREATE TABLE inventory_movements (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      product_id INTEGER NOT NULL,
      quantity_delta INTEGER NOT NULL CHECK (quantity_delta != 0),
      reason TEXT NOT NULL,
      created_at TEXT NOT NULL,
      FOREIGN KEY (product_id) REFERENCES products (id)
    )
  ''');

  await db.execute('''
    CREATE TABLE schema_migrations (
      version INTEGER PRIMARY KEY,
      applied_at TEXT NOT NULL
    )
  ''');

  await db.insert('schema_migrations', {
    'version': 1,
    'applied_at': DateTime.now().toUtc().toIso8601String(),
  });
  await createSalesSchema(db);
  await createExpensesSchema(db);
  await createCatalogSchema(db);
  await createBranchWarehouseSchema(db);
  await createSaleWarehouseSchema(db);
  await createFractionalQuantitiesSchema(db);
  await createPurchaseSchema(db);
  await createAccountSchema(db);
  await createSupplierReturnsSchema(db);
  await createCustomerReturnsSchema(db);
}



/// Adds customer records and append-only account ledgers.
/// Positive entries increase the balance owed; negative entries reduce it.
Future<void> createAccountSchema(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS customers (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL CHECK (length(trim(name)) > 0),
      phone TEXT,
      address TEXT,
      is_active INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
      created_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS supplier_account_entries (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      supplier_id INTEGER NOT NULL,
      amount_minor INTEGER NOT NULL CHECK (amount_minor != 0),
      entry_type TEXT NOT NULL CHECK (entry_type IN ('purchase', 'payment', 'adjustment')),
      reference_id INTEGER,
      note TEXT,
      created_at TEXT NOT NULL,
      FOREIGN KEY (supplier_id) REFERENCES suppliers(id)
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS customer_account_entries (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      customer_id INTEGER NOT NULL,
      amount_minor INTEGER NOT NULL CHECK (amount_minor != 0),
      entry_type TEXT NOT NULL CHECK (entry_type IN ('sale', 'receipt', 'adjustment')),
      reference_id INTEGER,
      note TEXT,
      created_at TEXT NOT NULL,
      FOREIGN KEY (customer_id) REFERENCES customers(id)
    )
  ''');
  final salesColumns = await db.rawQuery('PRAGMA table_info(sales)');
  if (!salesColumns.any((row) => row['name'] == 'customer_id')) {
    await db.execute(
      'ALTER TABLE sales ADD COLUMN customer_id INTEGER REFERENCES customers(id)',
    );
  }
  await db.insert('schema_migrations', {
    'version': 9,
    'applied_at': DateTime.now().toUtc().toIso8601String(),
  }, conflictAlgorithm: ConflictAlgorithm.ignore);
}


/// Adds sales tables for databases that were created at version 1.
Future<void> createSalesSchema(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS sales (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      total_minor INTEGER NOT NULL CHECK (total_minor >= 0),
      paid_minor INTEGER NOT NULL CHECK (paid_minor >= 0 AND paid_minor <= total_minor),
      created_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS sale_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sale_id INTEGER NOT NULL,
      product_id INTEGER NOT NULL,
      quantity INTEGER NOT NULL CHECK (quantity > 0),
      unit_price_minor INTEGER NOT NULL CHECK (unit_price_minor >= 0),
      unit_cost_minor INTEGER NOT NULL CHECK (unit_cost_minor >= 0),
      line_total_minor INTEGER NOT NULL CHECK (line_total_minor >= 0),
      FOREIGN KEY (sale_id) REFERENCES sales (id),
      FOREIGN KEY (product_id) REFERENCES products (id)
    )
  ''');

  final applied = await db.query(
    'schema_migrations',
    columns: ['version'],
    where: 'version = ?',
    whereArgs: [2],
    limit: 1,
  );
  if (applied.isEmpty) {
    await db.insert('schema_migrations', {
      'version': 2,
      'applied_at': DateTime.now().toUtc().toIso8601String(),
    });
  }
}

/// Adds the expense table for databases that were created before version 3.
Future<void> createExpensesSchema(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS expenses (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      description TEXT NOT NULL CHECK (length(trim(description)) > 0),
      category TEXT NOT NULL,
      amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
      created_at TEXT NOT NULL
    )
  ''');

  final applied = await db.query(
    'schema_migrations',
    columns: ['version'],
    where: 'version = ?',
    whereArgs: [3],
    limit: 1,
  );
  if (applied.isEmpty) {
    await db.insert('schema_migrations', {
      'version': 3,
      'applied_at': DateTime.now().toUtc().toIso8601String(),
    });
  }
}


/// Adds normalized product categories and units without discarding existing stock.
Future<void> createCatalogSchema(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS product_categories (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL UNIQUE CHECK (length(trim(name)) > 0),
      is_active INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
      created_at TEXT NOT NULL
    )
  ''');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS product_units (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL UNIQUE CHECK (length(trim(name)) > 0),
      abbreviation TEXT NOT NULL CHECK (length(trim(abbreviation)) > 0),
      allows_fraction INTEGER NOT NULL DEFAULT 0 CHECK (allows_fraction IN (0, 1)),
      is_active INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
      created_at TEXT NOT NULL
    )
  ''');

  final now = DateTime.now().toUtc().toIso8601String();
  await db.insert(
    'product_units',
    {
      'name': 'قطعة',
      'abbreviation': 'قطعة',
      'allows_fraction': 0,
      'is_active': 1,
      'created_at': now,
    },
    conflictAlgorithm: ConflictAlgorithm.ignore,
  );

  final productColumns = await db.rawQuery('PRAGMA table_info(products)');
  final existingColumns = productColumns.map((row) => row['name']).toSet();
  if (!existingColumns.contains('category_id')) {
    await db.execute(
      'ALTER TABLE products ADD COLUMN category_id INTEGER '
      'REFERENCES product_categories(id)',
    );
  }
  if (!existingColumns.contains('unit_id')) {
    await db.execute(
      'ALTER TABLE products ADD COLUMN unit_id INTEGER '
      'REFERENCES product_units(id)',
    );
  }

  final defaultUnit = await db.query(
    'product_units',
    columns: ['id'],
    where: 'name = ?',
    whereArgs: ['قطعة'],
    limit: 1,
  );
  final defaultUnitId = defaultUnit.single['id']! as int;
  await db.update(
    'products',
    {'unit_id': defaultUnitId},
    where: 'unit_id IS NULL',
  );

  final applied = await db.query(
    'schema_migrations',
    columns: ['version'],
    where: 'version = ?',
    whereArgs: [4],
    limit: 1,
  );
  if (applied.isEmpty) {
    await db.insert('schema_migrations', {
      'version': 4,
      'applied_at': now,
    });
  }
}


/// Introduces branches, warehouses and per-warehouse product balances.
/// Existing stock and movement history are assigned to the main warehouse.
Future<void> createBranchWarehouseSchema(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS branches (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL UNIQUE CHECK (length(trim(name)) > 0),
      address TEXT,
      phone TEXT,
      is_active INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
      created_at TEXT NOT NULL
    )
  ''');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS warehouses (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      branch_id INTEGER NOT NULL,
      name TEXT NOT NULL CHECK (length(trim(name)) > 0),
      is_active INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
      created_at TEXT NOT NULL,
      UNIQUE (branch_id, name),
      FOREIGN KEY (branch_id) REFERENCES branches (id)
    )
  ''');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS product_warehouse_stock (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      product_id INTEGER NOT NULL,
      warehouse_id INTEGER NOT NULL,
      quantity INTEGER NOT NULL DEFAULT 0 CHECK (quantity >= 0),
      updated_at TEXT NOT NULL,
      UNIQUE (product_id, warehouse_id),
      FOREIGN KEY (product_id) REFERENCES products (id),
      FOREIGN KEY (warehouse_id) REFERENCES warehouses (id)
    )
  ''');

  final now = DateTime.now().toUtc().toIso8601String();
  await db.insert('branches', {
    'name': 'الفرع الرئيسي',
    'is_active': 1,
    'created_at': now,
  }, conflictAlgorithm: ConflictAlgorithm.ignore);
  final branchRows = await db.query(
    'branches',
    columns: ['id'],
    where: 'name = ?',
    whereArgs: ['الفرع الرئيسي'],
    limit: 1,
  );
  final branchId = branchRows.single['id']! as int;

  await db.insert('warehouses', {
    'branch_id': branchId,
    'name': 'المخزن الرئيسي',
    'is_active': 1,
    'created_at': now,
  }, conflictAlgorithm: ConflictAlgorithm.ignore);
  final warehouseRows = await db.query(
    'warehouses',
    columns: ['id'],
    where: 'branch_id = ? AND name = ?',
    whereArgs: [branchId, 'المخزن الرئيسي'],
    limit: 1,
  );
  final warehouseId = warehouseRows.single['id']! as int;

  final movementColumns = await db.rawQuery('PRAGMA table_info(inventory_movements)');
  if (!movementColumns.any((row) => row['name'] == 'warehouse_id')) {
    await db.execute(
      'ALTER TABLE inventory_movements ADD COLUMN warehouse_id INTEGER '
      'REFERENCES warehouses(id)',
    );
  }

  final products = await db.query(
    'products',
    columns: ['id', 'stock_quantity'],
    orderBy: 'id ASC',
  );
  for (final product in products) {
    await db.insert('product_warehouse_stock', {
      'product_id': product['id'],
      'warehouse_id': warehouseId,
      'quantity': product['stock_quantity'],
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }
  await db.update(
    'inventory_movements',
    {'warehouse_id': warehouseId},
    where: 'warehouse_id IS NULL',
  );

  final applied = await db.query(
    'schema_migrations',
    columns: ['version'],
    where: 'version = ?',
    whereArgs: [5],
    limit: 1,
  );
  if (applied.isEmpty) {
    await db.insert('schema_migrations', {
      'version': 5,
      'applied_at': now,
    });
  }
}

/// Adds the warehouse reference to each new sale. Historical sales remain
/// nullable because their source warehouse cannot be inferred safely.
Future<void> createSaleWarehouseSchema(Database db) async {
  final columns = await db.rawQuery('PRAGMA table_info(sales)');
  if (!columns.any((row) => row['name'] == 'warehouse_id')) {
    await db.execute(
      'ALTER TABLE sales ADD COLUMN warehouse_id INTEGER REFERENCES warehouses(id)',
    );
  }
  final applied = await db.query(
    'schema_migrations',
    columns: ['version'],
    where: 'version = ?',
    whereArgs: [6],
    limit: 1,
  );
  if (applied.isEmpty) {
    await db.insert('schema_migrations', {
      'version': 6,
      'applied_at': DateTime.now().toUtc().toIso8601String(),
    });
  }
}


/// Converts every persisted quantity from whole units to integer thousandths.
/// Monetary columns are deliberately untouched. The migration marker prevents
/// accidental double scaling when this helper is safely re-entered.
Future<void> createFractionalQuantitiesSchema(Database db) async {
  final applied = await db.query(
    'schema_migrations',
    columns: ['version'],
    where: 'version = ?',
    whereArgs: [7],
    limit: 1,
  );
  if (applied.isNotEmpty) return;

  const maxWholeQuantity = 9223372036854775;
  final overflow = await db.rawQuery('''
    SELECT
      (SELECT COUNT(*) FROM products WHERE stock_quantity > ?) +
      (SELECT COUNT(*) FROM product_warehouse_stock WHERE quantity > ?) +
      (SELECT COUNT(*) FROM sale_items WHERE quantity > ?) +
      (SELECT COUNT(*) FROM inventory_movements
        WHERE quantity_delta > ? OR quantity_delta < -?) AS count
  ''', [
    maxWholeQuantity,
    maxWholeQuantity,
    maxWholeQuantity,
    maxWholeQuantity,
    maxWholeQuantity,
  ]);
  if ((overflow.single['count'] as num).toInt() > 0) {
    throw StateError('A stored quantity is too large to migrate safely to thousandths.');
  }

  await db.execute('UPDATE products SET stock_quantity = stock_quantity * 1000');
  await db.execute('UPDATE product_warehouse_stock SET quantity = quantity * 1000');
  await db.execute('UPDATE sale_items SET quantity = quantity * 1000');
  await db.execute('UPDATE inventory_movements SET quantity_delta = quantity_delta * 1000');
  await db.insert('schema_migrations', {
    'version': 7,
    'applied_at': DateTime.now().toUtc().toIso8601String(),
  });
}


/// Adds supplier and purchase documents with immutable purchase-line costs.
Future<void> createPurchaseSchema(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS suppliers (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL CHECK (length(trim(name)) > 0),
      phone TEXT,
      address TEXT,
      is_active INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
      created_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS purchases (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      supplier_id INTEGER NOT NULL,
      warehouse_id INTEGER NOT NULL,
      total_minor INTEGER NOT NULL CHECK (total_minor > 0),
      paid_minor INTEGER NOT NULL CHECK (paid_minor >= 0 AND paid_minor <= total_minor),
      created_at TEXT NOT NULL,
      FOREIGN KEY (supplier_id) REFERENCES suppliers(id),
      FOREIGN KEY (warehouse_id) REFERENCES warehouses(id)
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS purchase_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      purchase_id INTEGER NOT NULL,
      product_id INTEGER NOT NULL,
      quantity INTEGER NOT NULL CHECK (quantity > 0),
      unit_cost_minor INTEGER NOT NULL CHECK (unit_cost_minor >= 0),
      line_total_minor INTEGER NOT NULL CHECK (line_total_minor > 0),
      FOREIGN KEY (purchase_id) REFERENCES purchases(id),
      FOREIGN KEY (product_id) REFERENCES products(id)
    )
  ''');
  await db.insert('schema_migrations', {
    'version': 8,
    'applied_at': DateTime.now().toUtc().toIso8601String(),
  }, conflictAlgorithm: ConflictAlgorithm.ignore);
}


/// Adds auditable supplier returns linked to their original purchase lines.
Future<void> createSupplierReturnsSchema(Database db) async {
  final itemColumns = await db.rawQuery('PRAGMA table_info(purchase_items)');
  if (!itemColumns.any((row) => row['name'] == 'returned_quantity')) {
    await db.execute(
      'ALTER TABLE purchase_items ADD COLUMN returned_quantity INTEGER NOT NULL DEFAULT 0 CHECK (returned_quantity >= 0)',
    );
  }

  await db.execute('''
    CREATE TABLE IF NOT EXISTS supplier_returns (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      purchase_id INTEGER NOT NULL,
      supplier_id INTEGER NOT NULL,
      warehouse_id INTEGER NOT NULL,
      total_minor INTEGER NOT NULL CHECK (total_minor > 0),
      reason TEXT NOT NULL CHECK (length(trim(reason)) > 0),
      created_at TEXT NOT NULL,
      FOREIGN KEY (purchase_id) REFERENCES purchases(id),
      FOREIGN KEY (supplier_id) REFERENCES suppliers(id),
      FOREIGN KEY (warehouse_id) REFERENCES warehouses(id)
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS supplier_return_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      supplier_return_id INTEGER NOT NULL,
      purchase_item_id INTEGER NOT NULL,
      product_id INTEGER NOT NULL,
      quantity INTEGER NOT NULL CHECK (quantity > 0),
      unit_cost_minor INTEGER NOT NULL CHECK (unit_cost_minor >= 0),
      line_total_minor INTEGER NOT NULL CHECK (line_total_minor > 0),
      FOREIGN KEY (supplier_return_id) REFERENCES supplier_returns(id),
      FOREIGN KEY (purchase_item_id) REFERENCES purchase_items(id),
      FOREIGN KEY (product_id) REFERENCES products(id)
    )
  ''');

  final ledgerSql = await db.rawQuery(
    "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'supplier_account_entries'",
  );
  final definition = ledgerSql.isEmpty ? '' : ledgerSql.single['sql'] as String;
  if (!definition.contains("'return'")) {
    await db.execute('''
      CREATE TABLE supplier_account_entries_v10 (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        supplier_id INTEGER NOT NULL,
        amount_minor INTEGER NOT NULL CHECK (amount_minor != 0),
        entry_type TEXT NOT NULL CHECK (entry_type IN ('purchase', 'payment', 'adjustment', 'return')),
        reference_id INTEGER,
        note TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY (supplier_id) REFERENCES suppliers(id)
      )
    ''');
    await db.execute('''
      INSERT INTO supplier_account_entries_v10
        (id, supplier_id, amount_minor, entry_type, reference_id, note, created_at)
      SELECT id, supplier_id, amount_minor, entry_type, reference_id, note, created_at
      FROM supplier_account_entries
    ''');
    await db.execute('DROP TABLE supplier_account_entries');
    await db.execute('ALTER TABLE supplier_account_entries_v10 RENAME TO supplier_account_entries');
  }

  await db.insert('schema_migrations', {
    'version': 10,
    'applied_at': DateTime.now().toUtc().toIso8601String(),
  }, conflictAlgorithm: ConflictAlgorithm.ignore);
}


/// Adds auditable customer returns linked to original sale lines.
Future<void> createCustomerReturnsSchema(Database db) async {
  final itemColumns = await db.rawQuery('PRAGMA table_info(sale_items)');
  final names = itemColumns.map((row) => row['name']).toSet();
  if (!names.contains('returned_quantity')) {
    await db.execute(
      'ALTER TABLE sale_items ADD COLUMN returned_quantity INTEGER NOT NULL DEFAULT 0 CHECK (returned_quantity >= 0)',
    );
  }
  if (!names.contains('returned_minor')) {
    await db.execute(
      'ALTER TABLE sale_items ADD COLUMN returned_minor INTEGER NOT NULL DEFAULT 0 CHECK (returned_minor >= 0)',
    );
  }
  if (!names.contains('returned_cost_minor')) {
    await db.execute(
      'ALTER TABLE sale_items ADD COLUMN returned_cost_minor INTEGER NOT NULL DEFAULT 0 CHECK (returned_cost_minor >= 0)',
    );
  }

  await db.execute('''
    CREATE TABLE IF NOT EXISTS customer_returns (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sale_id INTEGER NOT NULL,
      customer_id INTEGER,
      warehouse_id INTEGER NOT NULL,
      total_minor INTEGER NOT NULL CHECK (total_minor >= 0),
      refunded_minor INTEGER NOT NULL DEFAULT 0 CHECK (refunded_minor >= 0 AND refunded_minor <= total_minor),
      reason TEXT NOT NULL CHECK (length(trim(reason)) > 0),
      created_at TEXT NOT NULL,
      FOREIGN KEY (sale_id) REFERENCES sales(id),
      FOREIGN KEY (customer_id) REFERENCES customers(id),
      FOREIGN KEY (warehouse_id) REFERENCES warehouses(id)
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS customer_return_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      customer_return_id INTEGER NOT NULL,
      sale_item_id INTEGER NOT NULL,
      product_id INTEGER NOT NULL,
      quantity INTEGER NOT NULL CHECK (quantity > 0),
      unit_price_minor INTEGER NOT NULL CHECK (unit_price_minor >= 0),
      unit_cost_minor INTEGER NOT NULL CHECK (unit_cost_minor >= 0),
      line_total_minor INTEGER NOT NULL CHECK (line_total_minor >= 0),
      line_cost_minor INTEGER NOT NULL CHECK (line_cost_minor >= 0),
      FOREIGN KEY (customer_return_id) REFERENCES customer_returns(id),
      FOREIGN KEY (sale_item_id) REFERENCES sale_items(id),
      FOREIGN KEY (product_id) REFERENCES products(id)
    )
  ''');

  final ledgerSql = await db.rawQuery(
    "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'customer_account_entries'",
  );
  final definition = ledgerSql.isEmpty ? '' : ledgerSql.single['sql'] as String;
  if (!definition.contains("'return'") || !definition.contains("'refund'")) {
    await db.execute('''
      CREATE TABLE customer_account_entries_v11 (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        customer_id INTEGER NOT NULL,
        amount_minor INTEGER NOT NULL CHECK (amount_minor != 0),
        entry_type TEXT NOT NULL CHECK (entry_type IN ('sale', 'receipt', 'adjustment', 'return', 'refund')),
        reference_id INTEGER,
        note TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY (customer_id) REFERENCES customers(id)
      )
    ''');
    await db.execute('''
      INSERT INTO customer_account_entries_v11
        (id, customer_id, amount_minor, entry_type, reference_id, note, created_at)
      SELECT id, customer_id, amount_minor, entry_type, reference_id, note, created_at
      FROM customer_account_entries
    ''');
    await db.execute('DROP TABLE customer_account_entries');
    await db.execute('ALTER TABLE customer_account_entries_v11 RENAME TO customer_account_entries');
  }

  await db.insert('schema_migrations', {
    'version': 11,
    'applied_at': DateTime.now().toUtc().toIso8601String(),
  }, conflictAlgorithm: ConflictAlgorithm.ignore);
}
