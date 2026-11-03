import '../../domain/product_category.dart';
import '../../domain/product_unit.dart';

abstract interface class CatalogStore {
  Future<List<ProductCategory>> categories({bool includeInactive = false});
  Future<int> addCategory(String name);
  Future<void> updateCategory({required int id, required String name});
  Future<void> setCategoryActive({required int id, required bool isActive});

  Future<List<ProductUnit>> units({bool includeInactive = false});
  Future<int> addUnit({
    required String name,
    required String abbreviation,
    required bool allowsFraction,
  });
  Future<void> updateUnit({
    required int id,
    required String name,
    required String abbreviation,
    required bool allowsFraction,
  });
  Future<void> setUnitActive({required int id, required bool isActive});
}
