/// One quantity line selected from an original sale invoice for return.
class SaleReturnLineInput {
  const SaleReturnLineInput({required this.saleItemId, required this.quantity});

  final int saleItemId;
  /// Positive integer thousandths, matching persisted inventory quantities.
  final int quantity;
}
