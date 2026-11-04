/// Compatibility and referential ordering for full SQLite backups.
abstract final class BackupSchema {
  static const currentVersion = 11;

  static bool supports(int version) => version >= 3 && version <= currentVersion;
  static bool hasPurchaseData(int version) => version >= 8;
  static bool hasAccountData(int version) => version >= 9;
  static bool hasSupplierReturnData(int version) => version >= 10;
  static bool hasCustomerReturnData(int version) => version >= 11;

  /// Every business-data table that a current backup must preserve.
  static const currentTableNames = <String>{
    'branches',
    'warehouses',
    'product_categories',
    'product_units',
    'products',
    'product_warehouse_stock',
    'customers',
    'sales',
    'sale_items',
    'expenses',
    'inventory_movements',
    'suppliers',
    'purchases',
    'purchase_items',
    'customer_returns',
    'customer_return_items',
    'supplier_returns',
    'supplier_return_items',
    'customer_returns',
    'customer_return_items',
    'supplier_account_entries',
    'customer_account_entries',
  };

  /// Delete child rows before parent rows while foreign keys are enabled.
  static const restoreDeleteOrder = <String>[
    'customer_return_items',
    'customer_returns',
    'supplier_return_items',
    'supplier_returns',
    'inventory_movements',
    'sale_items',
    'supplier_account_entries',
    'customer_account_entries',
    'purchase_items',
    'sales',
    'purchases',
    'expenses',
    'product_warehouse_stock',
    'products',
    'product_categories',
    'product_units',
    'warehouses',
    'branches',
    'customers',
    'suppliers',
  ];

  /// Insert parent rows before child rows while foreign keys are enabled.
  static const restoreInsertOrder = <String>[
    'branches',
    'warehouses',
    'product_categories',
    'product_units',
    'products',
    'product_warehouse_stock',
    'customers',
    'sales',
    'sale_items',
    'expenses',
    'inventory_movements',
    'suppliers',
    'purchases',
    'purchase_items',
    'supplier_returns',
    'supplier_return_items',
    'customer_returns',
    'customer_return_items',
    'supplier_account_entries',
    'customer_account_entries',
  ];
}
