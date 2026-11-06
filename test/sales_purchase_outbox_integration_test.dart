import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/data/account_repository.dart';
import 'package:smart_merchant_suite/data/business_database_identity.dart';
import 'package:smart_merchant_suite/data/cashbook_repository.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:smart_merchant_suite/data/product_repository.dart';
import 'package:smart_merchant_suite/data/purchase_repository.dart';
import 'package:smart_merchant_suite/data/sales_repository.dart';
import 'package:smart_merchant_suite/data/warehouse_repository.dart';
import 'package:smart_merchant_suite/domain/payment_method.dart';
import 'package:smart_merchant_suite/domain/product.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _businessId = '6f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';

void main() {
  late Database database;
  late ProductRepository products;
  late SalesRepository sales;
  late PurchaseRepository purchases;
  late AccountRepository accounts;
  late CashbookRepository cashbook;
  late int productId;
  late int warehouseId;
  late int branchId;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(database);
    await ensureBusinessDatabaseIdentity(database, _businessId);
    products = ProductRepository(database);
    sales = SalesRepository(database);
    purchases = PurchaseRepository(database);
    accounts = AccountRepository(database);
    cashbook = CashbookRepository(database);
    final warehouse = (await WarehouseRepository(database).warehouses()).single;
    warehouseId = warehouse.id;
    branchId = warehouse.branchId;
    productId = await products.add(const Product(
      name: 'منتج مزامنة',
      costMinor: 700,
      priceMinor: 1500,
      stockQuantity: 5000,
    ));
  });

  tearDown(() async => database.close());

  Future<int> openCashSession() async {
    final drawer = await cashbook.ensureDrawer(branchId: branchId);
    return cashbook.openSession(
      branchId: branchId,
      cashDrawerId: drawer['id']! as int,
      openingBalanceMinor: 10000,
    );
  }

  Future<Set<String>> dependenciesOf(String eventId) async {
    final rows = await database.query(
      'sync_outbox_dependencies',
      columns: ['depends_on_event_id'],
      where: 'event_id = ?',
      whereArgs: [eventId],
    );
    return rows.map((row) => row['depends_on_event_id']! as String).toSet();
  }

  test('sale Outbox event contains branch, warehouse, line snapshots and dependencies', () async {
    await openCashSession();
    final customerId = await accounts.addCustomer(name: 'عميل اختبار');
    final productEvent = (await database.query(
      'sync_outbox',
      where: "entity_type = 'product' AND local_entity_id = ?",
      whereArgs: [productId.toString()],
      orderBy: 'rowid DESC',
      limit: 1,
    )).single;
    final sessionEvent = (await database.query(
      'sync_outbox',
      where: "entity_type = 'cash_session' AND action = 'create'",
    )).single;

    final saleId = await sales.createSale(
      quantities: {productId: 2000},
      paidMinor: 1500,
      warehouseId: warehouseId,
      customerId: customerId,
    );
    final event = (await database.query(
      'sync_outbox',
      where: 'entity_type = ? AND local_entity_id = ?',
      whereArgs: ['sale', saleId.toString()],
    )).single;

    expect(event['action'], 'create');
    expect(event['business_id'], _businessId);
    expect(event['payload_json'], contains('"local_branch_id":$branchId'));
    expect(event['payload_json'], contains('"local_warehouse_id":$warehouseId'));
    expect(event['payload_json'], contains('"local_customer_id":$customerId'));
    expect(event['payload_json'], contains('"payment_method":"cash"'));
    expect(event['payload_json'], contains('"quantity_scaled":2000'));
    expect(event['payload_json'], contains('"unit_price_minor":1500'));
    expect(event['payload_json'], contains('"unit_cost_minor":700'));
    expect(
      await dependenciesOf(event['event_id']! as String),
      {productEvent['event_id'], sessionEvent['event_id']},
    );
  });

  test('purchase Outbox event contains supplier and cost snapshots and dependencies', () async {
    await openCashSession();
    final supplierId = await purchases.addSupplier(name: 'مورد اختبار');
    final productEvent = (await database.query(
      'sync_outbox',
      where: "entity_type = 'product' AND local_entity_id = ?",
      whereArgs: [productId.toString()],
      orderBy: 'rowid DESC',
      limit: 1,
    )).single;
    final sessionEvent = (await database.query(
      'sync_outbox',
      where: "entity_type = 'cash_session' AND action = 'create'",
    )).single;

    final purchaseId = await purchases.createPurchase(
      supplierId: supplierId,
      warehouseId: warehouseId,
      items: [
        PurchaseLineInput(
          productId: productId,
          quantity: 1000,
          unitCostMinor: 900,
        ),
      ],
      paidMinor: 400,
    );
    final event = (await database.query(
      'sync_outbox',
      where: 'entity_type = ? AND local_entity_id = ?',
      whereArgs: ['purchase', purchaseId.toString()],
    )).single;

    expect(event['action'], 'create');
    expect(event['business_id'], _businessId);
    expect(event['payload_json'], contains('"local_branch_id":$branchId'));
    expect(event['payload_json'], contains('"local_warehouse_id":$warehouseId'));
    expect(event['payload_json'], contains('"local_supplier_id":$supplierId'));
    expect(event['payload_json'], contains('"unit_cost_minor":900'));
    expect(event['payload_json'], contains('"quantity_scaled":1000'));
    expect(
      await dependenciesOf(event['event_id']! as String),
      {productEvent['event_id'], sessionEvent['event_id']},
    );
  });

  test('cloud cash sale is rejected without an open register session', () async {
    await expectLater(
      sales.createSale(
        quantities: {productId: 1000},
        paidMinor: 1500,
        warehouseId: warehouseId,
      ),
      throwsA(isA<Exception>()),
    );
    expect(await database.query('sales'), isEmpty);
    expect(await database.query('sale_items'), isEmpty);
    expect(await database.query('payment_records'), isEmpty);
    expect(
      await database.query('sync_outbox', where: "entity_type = 'sale'"),
      isEmpty,
    );
  });

  test('cloud cash purchase is rejected without an open register session', () async {
    final supplierId = await purchases.addSupplier(name: 'مورد دون وردية');
    await expectLater(
      purchases.createPurchase(
        supplierId: supplierId,
        warehouseId: warehouseId,
        items: [
          PurchaseLineInput(
            productId: productId,
            quantity: 1000,
            unitCostMinor: 900,
          ),
        ],
        paidMinor: 400,
      ),
      throwsA(isA<Exception>()),
    );
    expect(await database.query('purchases'), isEmpty);
    expect(await database.query('purchase_items'), isEmpty);
    expect(await database.query('payment_records'), isEmpty);
    expect(
      await database.query('sync_outbox', where: "entity_type = 'purchase'"),
      isEmpty,
    );
  });

  test('sale business rows and Outbox event roll back together', () async {
    await openCashSession();
    await database.execute('''
      CREATE TRIGGER reject_sale_outbox
      BEFORE INSERT ON sync_outbox
      WHEN NEW.entity_type = 'sale'
      BEGIN
        SELECT RAISE(ABORT, 'forced sale outbox failure');
      END
    ''');

    await expectLater(
      sales.createSale(
        quantities: {productId: 1000},
        paidMinor: 1500,
        warehouseId: warehouseId,
      ),
      throwsA(anything),
    );

    expect(await database.query('sales'), isEmpty);
    expect(await database.query('sale_items'), isEmpty);
    expect(await database.query('payment_records'), isEmpty);
    expect(await database.query('cash_transactions'), isEmpty);
    expect(
      await database.query('inventory_movements', where: 'reason LIKE ?', whereArgs: ['بيع%']),
      isEmpty,
    );
    expect(
      await database.query('sync_outbox', where: "entity_type = 'sale'"),
      isEmpty,
    );
  });

  test('non-cash cloud sale does not require a cash session', () async {
    final saleId = await sales.createSale(
      quantities: {productId: 1000},
      paidMinor: 1500,
      warehouseId: warehouseId,
      paymentMethod: PaymentMethod.card,
    );
    final event = (await database.query(
      'sync_outbox',
      where: 'entity_type = ? AND local_entity_id = ?',
      whereArgs: ['sale', saleId.toString()],
    )).single;
    expect(event['payload_json'], contains('"payment_method":"card"'));
    expect(event['payload_json'], contains('"local_cash_session_id":null'));
    expect(await database.query('cash_transactions'), isEmpty);
  });
}
