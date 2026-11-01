/// Product values used by the current local application.
///
/// Stock balances are stored as integer thousandths and synchronized with
/// the product's warehouse-scoped inventory records.
class Product {
  const Product({
    this.id,
    required this.name,
    this.sku,
    required this.costMinor,
    required this.priceMinor,
    this.stockQuantity = 0,
    this.defaultWarehouseStock,
    this.categoryId,
    this.unitId,
    this.unitAllowsFraction = false,
    this.isActive = true,
    this.createdAt,
  });

  final int? id;
  final String name;
  final String? sku;
  final int costMinor;
  final int priceMinor;
  /// Total stock in integer thousandths (1000 = one whole unit).
  final int stockQuantity;
  final int? defaultWarehouseStock;
  final int? categoryId;
  final int? unitId;
  final bool unitAllowsFraction;
  final bool isActive;
  final DateTime? createdAt;
}
