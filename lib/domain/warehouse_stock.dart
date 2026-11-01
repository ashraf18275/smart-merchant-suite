class WarehouseStock {
  const WarehouseStock({
    required this.productId,
    required this.productName,
    this.sku,
    required this.unitName,
    required this.quantity,
    this.allowsFraction = false,
  });

  final int productId;
  final String productName;
  final String? sku;
  final String unitName;
  /// Warehouse balance in integer thousandths (1000 = one whole unit).
  final int quantity;
  final bool allowsFraction;
}
