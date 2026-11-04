import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/cloud/cloud_product_repository.dart';

void main() {
  group('CloudProduct', () {
    test('parses money and thousandth-scaled stock without floating point', () {
      final product = CloudProduct.fromMap({
        'id': 'cloud-product-1',
        'name': 'أرز',
        'sku': 'RICE-01',
        'cost_minor': 1250,
        'price_minor': 1750,
        'stock_quantity': 12550,
        'is_active': true,
      }, warehouseStockScaled: 2500);

      expect(product.id, 'cloud-product-1');
      expect(product.name, 'أرز');
      expect(product.sku, 'RICE-01');
      expect(product.costMinor, 1250);
      expect(product.priceMinor, 1750);
      expect(product.aggregateStockScaled, 12550);
      expect(product.warehouseStockScaled, 2500);
      expect(product.isActive, isTrue);
    });

    test('accepts integral numeric values returned by PostgREST', () {
      final product = CloudProduct.fromMap({
        'id': 'p-2',
        'name': 'منتج',
        'sku': null,
        'cost_minor': 10.0,
        'price_minor': 20,
        'stock_quantity': 1000.0,
        'is_active': false,
      }, warehouseStockScaled: 0);

      expect(product.costMinor, 10);
      expect(product.aggregateStockScaled, 1000);
      expect(product.warehouseStockScaled, 0);
      expect(product.isActive, isFalse);
    });

    test('rejects fractional or invalid integer fields', () {
      expect(
        () => CloudProduct.fromMap({
          'id': 'p-3',
          'name': 'منتج',
          'sku': null,
          'cost_minor': 1.5,
          'price_minor': 20,
          'stock_quantity': 1000,
          'is_active': true,
        }, warehouseStockScaled: 0),
        throwsFormatException,
      );
    });
  });

  test('workspace preserves cloud scope without local database identifiers', () {
    const workspace = CloudProductWorkspace(
      businessId: 'business-cloud',
      branchId: 'branch-cloud',
      warehouseId: 'warehouse-cloud',
      products: [],
    );

    expect(workspace.businessId, 'business-cloud');
    expect(workspace.branchId, 'branch-cloud');
    expect(workspace.warehouseId, 'warehouse-cloud');
  });
}
