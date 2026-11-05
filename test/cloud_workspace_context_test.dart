import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/cloud/cloud_location_repository.dart';
import 'package:smart_merchant_suite/cloud/cloud_workspace_context.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database database;
  late CloudWorkspaceContextRepository repository;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(database);
    repository = CloudWorkspaceContextRepository(database);
  });

  tearDown(() async {
    await database.close();
  });

  final branches = [
    const CloudBranch(id: 'branch-a', name: 'الفرع الأول', isActive: true),
    const CloudBranch(id: 'branch-b', name: 'الفرع الثاني', isActive: true),
    const CloudBranch(id: 'branch-disabled', name: 'فرع متوقف', isActive: false),
  ];
  final warehouses = [
    const CloudWarehouse(
      id: 'warehouse-a1',
      branchId: 'branch-a',
      name: 'مخزن أول',
      isActive: true,
    ),
    const CloudWarehouse(
      id: 'warehouse-a2',
      branchId: 'branch-a',
      name: 'مخزن متوقف',
      isActive: false,
    ),
    const CloudWarehouse(
      id: 'warehouse-b1',
      branchId: 'branch-b',
      name: 'مخزن ثان',
      isActive: true,
    ),
    const CloudWarehouse(
      id: 'warehouse-wrong-parent',
      branchId: 'branch-b',
      name: 'مخزن تابع لفرع آخر',
      isActive: true,
    ),
  ];

  test('resolves the first active branch and its active warehouse', () {
    final resolved = CloudWorkspaceContext.resolve(
      businessId: 'business-cloud',
      branches: branches,
      warehouses: warehouses,
    );

    expect(resolved, const CloudWorkspaceContext(
      businessId: 'business-cloud',
      branchId: 'branch-a',
      warehouseId: 'warehouse-a1',
    ));
  });

  test('preserves a valid selection for the same business', () {
    const previous = CloudWorkspaceContext(
      businessId: 'business-cloud',
      branchId: 'branch-b',
      warehouseId: 'warehouse-b1',
    );

    final resolved = CloudWorkspaceContext.resolve(
      businessId: 'business-cloud',
      branches: branches,
      warehouses: warehouses,
      previous: previous,
    );

    expect(resolved, previous);
  });

  test('replaces an inactive or cross-branch warehouse safely', () {
    const previous = CloudWorkspaceContext(
      businessId: 'business-cloud',
      branchId: 'branch-a',
      warehouseId: 'warehouse-b1',
    );

    final resolved = CloudWorkspaceContext.resolve(
      businessId: 'business-cloud',
      branches: branches,
      warehouses: warehouses,
      previous: previous,
    );

    expect(resolved?.branchId, 'branch-a');
    expect(resolved?.warehouseId, 'warehouse-a1');
  });

  test('does not carry a selection across businesses', () {
    const previous = CloudWorkspaceContext(
      businessId: 'another-business',
      branchId: 'branch-b',
      warehouseId: 'warehouse-b1',
    );

    final resolved = CloudWorkspaceContext.resolve(
      businessId: 'business-cloud',
      branches: branches,
      warehouses: warehouses,
      previous: previous,
    );

    expect(resolved?.branchId, 'branch-a');
    expect(resolved?.warehouseId, 'warehouse-a1');
  });

  test('allows a branch with no active warehouse without inventing one', () {
    final resolved = CloudWorkspaceContext.resolve(
      businessId: 'business-cloud',
      branches: const [
        CloudBranch(
          id: 'empty-branch',
          name: 'فرع بلا مخزن نشط',
          isActive: true,
        ),
      ],
      warehouses: const [
        CloudWarehouse(
          id: 'disabled-warehouse',
          branchId: 'empty-branch',
          name: 'مخزن متوقف',
          isActive: false,
        ),
      ],
    );

    expect(resolved?.branchId, 'empty-branch');
    expect(resolved?.warehouseId, isNull);
  });

  test('persists cloud UUIDs per user and business without mixing tenants', () async {
    const first = CloudWorkspaceContext(
      businessId: 'business-a',
      branchId: 'branch-cloud-a',
      warehouseId: 'warehouse-cloud-a',
    );
    const second = CloudWorkspaceContext(
      businessId: 'business-b',
      branchId: 'branch-cloud-b',
      warehouseId: 'warehouse-cloud-b',
    );

    await repository.save(userId: 'user-a', selection: first);
    await repository.save(userId: 'user-a', selection: second);
    await repository.save(userId: 'user-b', selection: first);

    expect(await repository.load(userId: 'user-a', businessId: 'business-a'), first);
    expect(await repository.load(userId: 'user-a', businessId: 'business-b'), second);
    expect(await repository.load(userId: 'user-b', businessId: 'business-a'), first);
    expect(await repository.load(userId: 'user-b', businessId: 'business-b'), isNull);
  });

  test('rejects empty context identifiers', () async {
    await expectLater(
      repository.save(
        userId: 'user-a',
        selection: const CloudWorkspaceContext(
          businessId: 'business-a',
          branchId: ' ',
          warehouseId: null,
        ),
      ),
      throwsArgumentError,
    );
  });

  test('validates warehouse ownership by selected branch and business', () {
    const selection = CloudWorkspaceContext(
      businessId: 'business-cloud',
      branchId: 'branch-a',
      warehouseId: 'warehouse-b1',
    );

    expect(selection.isValidFor(
      expectedBusinessId: 'business-cloud',
      branches: branches,
      warehouses: warehouses,
    ), isFalse);
  });
}
