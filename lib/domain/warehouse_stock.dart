class WarehouseStock {
  const WarehouseStock({
    required this.productId,
    required this.productName,
    this.sku,
    required this.unitName,
    required this.quantity,
  });

  final int productId;
  final String productName;
  final String? sku;
  final String unitName;
  final int quantity;
}
