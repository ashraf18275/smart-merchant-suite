import '../../domain/product.dart';

abstract interface class ProductCatalog {
  Future<int> add(Product product);

  Future<void> update(Product product);

  Future<void> setActive({required int productId, required bool isActive});

  Future<List<Product>> all({String search = '', bool includeInactive = false});

  Future<void> changeStock({
    required int productId,
    required int quantityDelta,
    required String reason,
  });
}
