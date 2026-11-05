import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/data/local_database_path.dart';

void main() {
  const root = '/app/support';
  const businessA = '6f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';
  const businessB = '7f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';

  test('keeps the legacy offline database path unchanged', () {
    expect(
      LocalDatabasePath.resolve(root),
      '$root/smart_merchant_suite.db',
    );
  });

  test('creates a separate deterministic database path per business', () {
    final first = LocalDatabasePath.resolve(root, businessId: businessA);
    final second = LocalDatabasePath.resolve(root, businessId: businessB);

    expect(first, '$root/businesses/business_$businessA.db');
    expect(second, '$root/businesses/business_$businessB.db');
    expect(first, isNot(second));
  });

  test('normalizes UUID casing and surrounding whitespace', () {
    expect(
      LocalDatabasePath.resolve(
        root,
        businessId: '  6F8F5771-3A1B-4B2A-9C7D-1D0E4A5B6C7D  ',
      ),
      '$root/businesses/business_$businessA.db',
    );
  });

  test('rejects non UUID identifiers and path traversal attempts', () {
    for (final invalid in [
      '',
      '../other.db',
      '/tmp/other.db',
      'business-a',
      '6f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7',
    ]) {
      expect(
        () => LocalDatabasePath.resolve(root, businessId: invalid),
        throwsArgumentError,
        reason: invalid,
      );
    }
  });
}
