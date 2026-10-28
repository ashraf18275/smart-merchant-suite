import '../../core/app_error.dart';
import '../../domain/sale_record.dart';
import '../ports/sales_service.dart';
import '../ports/sales_store.dart';

class SalesApplicationService implements SalesService {
  SalesApplicationService(this._store);

  final SalesStore _store;

  @override
  Future<int> createSale({
    required Map<int, int> quantities,
    required int paidMinor,
  }) async {
    if (quantities.isEmpty) throw AppException('أضف صنفًا واحدًا على الأقل');
    if (quantities.values.any((quantity) => quantity <= 0)) {
      throw AppException('كل كميات البيع يجب أن تكون أكبر من صفر');
    }
    if (paidMinor < 0) {
      throw AppException('المبلغ المدفوع لا يمكن أن يكون سالبًا');
    }
    return _store.createSale(quantities: quantities, paidMinor: paidMinor);
  }

  @override
  Future<List<SaleRecord>> all() => _store.all();
}
