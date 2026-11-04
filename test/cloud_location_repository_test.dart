import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/cloud/cloud_location_repository.dart';

void main() {
  group('Cloud location models', () {
    test('parses branch identity and active state', () {
      final branch = CloudBranch.fromMap({
        'id': 'branch-1',
        'name': 'الفرع الرئيسي',
        'address': null,
        'phone': null,
        'is_active': true,
      });

      expect(branch.id, 'branch-1');
      expect(branch.name, 'الفرع الرئيسي');
      expect(branch.isActive, isTrue);
      expect(branch.address, isNull);
    });

    test('parses warehouse and keeps its parent branch identity', () {
      final warehouse = CloudWarehouse.fromMap({
        'id': 'warehouse-1',
        'branch_id': 'branch-1',
        'name': 'المخزن الرئيسي',
        'is_active': false,
      });

      expect(warehouse.id, 'warehouse-1');
      expect(warehouse.branchId, 'branch-1');
      expect(warehouse.isActive, isFalse);
    });
  });

  group('Cloud location permissions', () {
    test('owner can view and manage both location types', () {
      const workspace = CloudLocationWorkspace(
        branches: [],
        warehouses: [],
        actorIsOwner: true,
        permissions: {},
      );

      expect(workspace.canView, isTrue);
      expect(workspace.canManageBranches, isTrue);
      expect(workspace.canManageWarehouses, isTrue);
    });

    test('branch viewer can view locations but cannot manage them', () {
      const workspace = CloudLocationWorkspace(
        branches: [],
        warehouses: [],
        actorIsOwner: false,
        permissions: {'branches.view'},
      );

      expect(workspace.canView, isTrue);
      expect(workspace.canManageBranches, isFalse);
      expect(workspace.canManageWarehouses, isFalse);
    });

    test('warehouse manager cannot manage branches', () {
      const workspace = CloudLocationWorkspace(
        branches: [],
        warehouses: [],
        actorIsOwner: false,
        permissions: {'warehouses.view', 'warehouses.manage'},
      );

      expect(workspace.canView, isTrue);
      expect(workspace.canManageBranches, isFalse);
      expect(workspace.canManageWarehouses, isTrue);
    });

    test('operational viewers can read locations for selectors without managing them', () {
      const operationalPermissions = [
        'inventory.view',
        'sales.create',
        'products.view',
        'purchases.view',
        'purchases.create',
      ];

      for (final permission in operationalPermissions) {
        final workspace = CloudLocationWorkspace(
          branches: const [],
          warehouses: const [],
          actorIsOwner: false,
          permissions: {permission},
        );

        expect(workspace.canView, isTrue, reason: permission);
        expect(workspace.canManageBranches, isFalse, reason: permission);
        expect(workspace.canManageWarehouses, isFalse, reason: permission);
      }
    });

    test('member without any RLS location read permission is denied', () {
      const workspace = CloudLocationWorkspace(
        branches: [],
        warehouses: [],
        actorIsOwner: false,
        permissions: {'customers.view', 'reports.view'},
      );

      expect(workspace.canView, isFalse);
    });
  });
}
