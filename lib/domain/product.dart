/// Product values used by the current local application.
///
/// Stock is kept here temporarily for compatibility with the first local
/// schema. The inventory phase will move balances into warehouse-scoped
/// inventory records.
class Product {
  const Product({
    this.id,
    required this.name,
    this.sku,
    required this.costMinor,
    required this.priceMinor,
    this.stockQuantity = 0,
    this.isActive = true,
    this.createdAt,
  });

  final int? id;
  final String name;
  final String? sku;
  final int costMinor;
  final int priceMinor;
  final int stockQuantity;
  final bool isActive;
  final DateTime? createdAt;
}
