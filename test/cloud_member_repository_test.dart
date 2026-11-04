import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/cloud/cloud_member_repository.dart';
import 'package:smart_merchant_suite/security/permission_catalog.dart';

void main() {
  group('CloudMemberWorkspace', () {
    test('owner can manage every registered permission', () {
      final workspace = CloudMemberWorkspace(
        members: const [],
        actorIsOwner: true,
        actorPermissions: const {},
      );

      expect(workspace.canViewUsers, isTrue);
      expect(workspace.canCreateUsers, isTrue);
      expect(workspace.canEditPermissions, isTrue);
      expect(workspace.canDeactivateUsers, isTrue);
      expect(workspace.assignablePermissions, AppPermission.values.toSet());
    });

    test('delegated manager can grant only permissions they hold', () {
      final workspace = CloudMemberWorkspace(
        members: const [],
        actorIsOwner: false,
        actorPermissions: {
          'users.view',
          'users.create',
          'users.edit',
          'products.view',
        },
      );

      expect(workspace.canViewUsers, isTrue);
      expect(workspace.canCreateUsers, isTrue);
      expect(workspace.canEditPermissions, isTrue);
      expect(workspace.canDeactivateUsers, isFalse);
      expect(
        workspace.assignablePermissions,
        {
          AppPermission.usersView,
          AppPermission.usersCreate,
          AppPermission.usersEdit,
          AppPermission.productsView,
        },
      );
    });

    test('view-only member cannot create or change users', () {
      final workspace = CloudMemberWorkspace(
        members: const [],
        actorIsOwner: false,
        actorPermissions: {'users.view'},
      );

      expect(workspace.canViewUsers, isTrue);
      expect(workspace.canCreateUsers, isFalse);
      expect(workspace.canEditPermissions, isFalse);
      expect(workspace.canDeactivateUsers, isFalse);
    });
  });
}
