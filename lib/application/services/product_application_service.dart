import '../../core/app_error.dart';
import '../../domain/product.dart';
import '../ports/product_catalog.dart';
import '../ports/product_store.dart';

class ProductApplicationService implements ProductCatalog {
  ProductApplicationService(this._store);

  final ProductStore _store;

  @override
  Future<int> add(Product product) async {
    _validateProduct(product);
    if (product.stockQuantity < 0) {
      throw AppException('كمية المخزون لا يمكن أن تكون سالبة');
    }
    return _store.add(product);
  }

  @override
  Future<void> update(Product product) async {
    if (product.id == null) throw AppException('معرّف المنتج مطلوب للتعديل');
    _validateProduct(product);
    await _store.update(product);
  }

  @override
  Future<void> setActive({
    required int productId,
    required bool isActive,
  }) => _store.setActive(productId: productId, isActive: isActive);

  @override
  Future<List<Product>> all({
    String search = '',
    bool includeInactive = false,
  }) => _store.all(search: search, includeInactive: includeInactive);

  @override
  Future<void> changeStock({
    required int productId,
    required int quantityDelta,
    required String reason,
  }) async {
    if (quantityDelta == 0) {
      throw AppException('يجب أن تكون حركة المخزون أكبر من صفر أو أقل من صفر');
    }
    if (reason.trim().isEmpty) throw AppException('سبب حركة المخزون مطلوب');
    await _store.changeStock(
      productId: productId,
      quantityDelta: quantityDelta,
      reason: reason,
    );
  }

  void _validateProduct(Product product) {
    if (product.name.trim().isEmpty) throw AppException('اسم المنتج مطلوب');
    if (product.costMinor < 0 || product.priceMinor < 0) {
      throw AppException('السعر والتكلفة لا يمكن أن يكونا سالبين');
    }
  }
}
