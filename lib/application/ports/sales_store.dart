import '../../domain/sale_record.dart';

abstract interface class SalesStore {
  /// Quantity values are positive integer thousandths, keyed by product ID.
  Future<int> createSale({
    required Map<int, int> quantities,
    required int paidMinor,
    required int warehouseId,
    int? customerId,
  });

  Future<List<SaleRecord>> all();
}
