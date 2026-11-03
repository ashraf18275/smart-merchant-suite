import '../../domain/branch.dart';
import '../../domain/warehouse.dart';
import '../../domain/warehouse_stock.dart';

abstract interface class BranchWarehouseStore {
  Future<List<Branch>> branches({bool includeInactive = false});
  Future<int> addBranch({required String name, String? address, String? phone});
  Future<void> updateBranch({
    required int id,
    required String name,
    String? address,
    String? phone,
  });
  Future<void> setBranchActive({required int id, required bool isActive});

  Future<List<Warehouse>> warehouses({
    int? branchId,
    bool includeInactive = false,
  });
  Future<int> addWarehouse({required int branchId, required String name});
  Future<void> updateWarehouse({required int id, required String name});
  Future<void> setWarehouseActive({required int id, required bool isActive});

  Future<List<WarehouseStock>> stock({required int warehouseId});
  Future<void> adjustStock({
    required int warehouseId,
    required int productId,
    required int quantityDelta,
    required String reason,
  });
  /// [quantity] is a positive integer count of thousandths for the product unit.
  Future<void> transferStock({
    required int productId,
    required int fromWarehouseId,
    required int toWarehouseId,
    required int quantity,
    required String reason,
  });
}
