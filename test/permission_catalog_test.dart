import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/security/permission_catalog.dart';

void main() {
  group('AppPermission', () {
    test('has unique stable keys and Arabic labels', () {
      final keys = AppPermission.values.map((permission) => permission.key).toSet();
      expect(keys.length, AppPermission.values.length);
      expect(AppPermission.values.every((permission) => permission.label.isNotEmpty), isTrue);
    });

    test('round-trips every stable key', () {
      for (final permission in AppPermission.values) {
        expect(AppPermission.fromKey(permission.key), permission);
      }
      expect(AppPermission.fromKey('not.a.real.permission'), isNull);
    });
  });

  group('UserAccess', () {
    test('a normal user receives only explicitly granted permissions', () {
      final access = UserAccess(
        userId: 'member-1',
        isOwner: false,
        permissions: {AppPermission.salesCreate, AppPermission.productsView},
      );

      expect(access.can(AppPermission.salesCreate), isTrue);
      expect(access.can(AppPermission.productsView), isTrue);
      expect(access.can(AppPermission.reportsProfitView), isFalse);
      expect(access.can(AppPermission.usersCreate), isFalse);
    });

    test('owner access cannot be accidentally removed by an empty permission set', () {
      final owner = UserAccess(
        userId: 'owner-1',
        isOwner: true,
        permissions: const {},
      );

      for (final permission in AppPermission.values) {
        expect(owner.can(permission), isTrue, reason: permission.key);
      }
      expect(owner.canManageUsers, isTrue);
    });

    test('permission snapshot cannot be changed by callers', () {
      final grants = <AppPermission>{AppPermission.salesCreate};
      final access = UserAccess(
        userId: 'member-1',
        isOwner: false,
        permissions: grants,
      );
      grants.add(AppPermission.usersCreate);

      expect(access.can(AppPermission.usersCreate), isFalse);
    });
  });
}
