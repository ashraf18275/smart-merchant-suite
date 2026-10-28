import '../../domain/sale_record.dart';

abstract interface class SalesStore {
  Future<int> createSale({
    required Map<int, int> quantities,
    required int paidMinor,
  });

  Future<List<SaleRecord>> all();
}
