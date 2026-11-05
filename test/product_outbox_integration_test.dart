import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/data/business_database_identity.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:smart_merchant_suite/data/product_repository.dart';
import 'package:smart_merchant_suite/domain/product.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  const businessId = '6f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';
  late Database database;
  late ProductRepository products;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(database);
    products = ProductRepository(database);
  });

  tearDown(() async {
    await database.close();
  });

  Future<void> bindBusiness() =>
      ensureBusinessDatabaseIdentity(database, businessId);

  test('legacy offline database remains local without outbox events', () async {
    await products.add(const Product(
      name: 'قلم',
      costMinor: 100,
      priceMinor: 150,
      stockQuantity: 2000,
    ));

    expect(await database.query('sync_outbox'), isEmpty);
  });

  test('product creation and opening stock are queued in the same transaction', () async {
    await bindBusiness();
    final id = await products.add(const Product(
      name: 'قلم',
      sku: 'PEN-01',
      costMinor: 100,
      priceMinor: 150,
      stockQuantity: 2000,
    ));

    final events = await database.query(
      'sync_outbox',
      orderBy: 'created_at ASC, rowid ASC',
    );
    expect(events, hasLength(2));
    expect(events.map((e) => e['business_id']).toSet(), {businessId});
    expect(events[0]['entity_type'], 'product');
    expect(events[0]['action'], 'create');
    expect(events[0]['local_entity_id'], id.toString());
    final productPayload = events[0]['payload_json'] as String;
    expect(productPayload, contains('"payload_schema_version":1'));
    expect(productPayload, contains('"price_minor":150'));
    expect(productPayload, isNot(contains('"unit_id"')));
    expect(events[1]['entity_type'], 'inventory_movement');
    expect(events[1]['action'], 'adjust');
    expect(events[1]['depends_on_event_id'], events[0]['event_id']);
    final stockPayload = events[1]['payload_json'] as String;
    expect(stockPayload, contains('"local_product_id":"$id"'));
    expect(stockPayload, contains('"local_warehouse_id"'));
    expect(stockPayload, contains('"quantity_delta":2000'));
  });

  test('product edits preserve a base snapshot for future conflict checks', () async {
    await bindBusiness();
    final id = await products.add(const Product(
      name: 'قلم',
      costMinor: 100,
      priceMinor: 150,
    ));
    await database.delete('sync_outbox');
    await products.update(const Product(
      id: 1,
      name: 'قلم أزرق',
      costMinor: 110,
      priceMinor: 175,
    ));

    final event = (await database.query('sync_outbox')).single;
    expect(event['business_id'], businessId);
    expect(event['entity_type'], 'product');
    expect(event['action'], 'update');
    expect(event['local_entity_id'], id.toString());
    final payload = event['payload_json'] as String;
    expect(payload, contains('"base":{"name":"قلم"'));
    expect(payload, contains('"record":{"name":"قلم أزرق"'));
    expect(payload, contains('"price_minor":175'));
  });

  test('direct stock adjustments create a tenant-scoped movement event', () async {
    await bindBusiness();
    final id = await products.add(const Product(
      name: 'قلم',
      costMinor: 100,
      priceMinor: 150,
    ));
    final parent = (await database.query('sync_outbox')).single;

    await products.changeStock(
      productId: id,
      quantityDelta: 3000,
      reason: 'جرد',
    );

    final events = await database.query('sync_outbox', orderBy: 'created_at ASC, rowid ASC');
    final event = events.last;
    expect(events, hasLength(2));
    expect(event['depends_on_event_id'], parent['event_id']);
    expect(event['business_id'], businessId);
    expect(event['entity_type'], 'inventory_movement');
    expect(event['action'], 'adjust');
    expect(event['payload_json'], contains('"quantity_delta":3000'));
    expect(event['payload_json'], contains('"reason":"جرد"'));
  });

  test('outbox failure rolls back product and opening stock writes', () async {
    await bindBusiness();
    await database.execute('''
      CREATE TRIGGER reject_outbox_insert
      BEFORE INSERT ON sync_outbox
      BEGIN
        SELECT RAISE(ABORT, 'outbox unavailable');
      END
    ''');

    await expectLater(
      products.add(const Product(
        name: 'منتج يجب ألا يحفظ',
        costMinor: 100,
        priceMinor: 150,
        stockQuantity: 2000,
      )),
      throwsA(anything),
    );

    expect(await database.query('products'), isEmpty);
    expect(await database.query('product_warehouse_stock'), isEmpty);
    expect(await database.query('inventory_movements'), isEmpty);
  });
}
