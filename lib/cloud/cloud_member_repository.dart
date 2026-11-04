import 'package:supabase_flutter/supabase_flutter.dart';

import '../security/permission_catalog.dart';

class CloudMember {
  const CloudMember({
    required this.id,
    required this.userId,
    required this.displayName,
    required this.isOwner,
    required this.isActive,
    required this.username,
    required this.permissionKeys,
  });

  final String id;
  final String userId;
  final String displayName;
  final bool isOwner;
  final bool isActive;
  final String? username;
  final Set<String> permissionKeys;
}

class CloudMemberWorkspace {
  const CloudMemberWorkspace({
    required this.members,
    required this.actorIsOwner,
    required this.actorPermissions,
  });

  final List<CloudMember> members;
  final bool actorIsOwner;
  final Set<String> actorPermissions;

  bool get canViewUsers => actorIsOwner || actorPermissions.contains('users.view');
  bool get canCreateUsers =>
      actorIsOwner ||
      (actorPermissions.contains('users.create') &&
          actorPermissions.contains('users.edit'));
  bool get canEditPermissions =>
      actorIsOwner || actorPermissions.contains('users.edit');
  bool get canDeactivateUsers =>
      actorIsOwner || actorPermissions.contains('users.deactivate');

  Set<AppPermission> get assignablePermissions => actorIsOwner
      ? AppPermission.values.toSet()
      : AppPermission.values
          .where((permission) => actorPermissions.contains(permission.key))
          .toSet();
}

class CloudMemberRepository {
  CloudMemberRepository(this._client);

  final SupabaseClient _client;

  Future<CloudMemberWorkspace> load(String businessId) async {
    final user = _client.auth.currentUser;
    if (user == null) throw StateError('authentication_required');

    final actor = await _client
        .from('business_members')
        .select('id,is_owner')
        .eq('business_id', businessId)
        .eq('user_id', user.id)
        .eq('is_active', true)
        .single();

    final actorIsOwner = actor['is_owner'] == true;
    final actorPermissions = <String>{};
    if (!actorIsOwner) {
      final grants = await _client
          .from('member_permissions')
          .select('permission_key')
          .eq('business_id', businessId)
          .eq('member_id', actor['id'])
          .eq('allowed', true);
      actorPermissions.addAll(
        grants.map((row) => row['permission_key'] as String),
      );
    }

    if (!actorIsOwner && !actorPermissions.contains('users.view')) {
      throw StateError('users_view_permission_required');
    }

    final rows = await _client
        .from('business_members')
        .select('id,user_id,display_name,is_owner,is_active')
        .eq('business_id', businessId)
        .order('created_at');
    final names = await _client
        .from('member_login_names')
        .select('member_id,username')
        .eq('business_id', businessId);
    final grants = await _client
        .from('member_permissions')
        .select('member_id,permission_key')
        .eq('business_id', businessId)
        .eq('allowed', true);

    final usernames = <String, String>{
      for (final row in names)
        row['member_id'] as String: row['username'] as String,
    };
    final permissions = <String, Set<String>>{};
    for (final row in grants) {
      final memberId = row['member_id'] as String;
      permissions.putIfAbsent(memberId, () => <String>{}).add(
            row['permission_key'] as String,
          );
    }

    return CloudMemberWorkspace(
      actorIsOwner: actorIsOwner,
      actorPermissions: actorPermissions,
      members: rows
          .map((row) {
            final id = row['id'] as String;
            return CloudMember(
              id: id,
              userId: row['user_id'] as String,
              displayName: row['display_name'] as String,
              isOwner: row['is_owner'] == true,
              isActive: row['is_active'] == true,
              username: usernames[id],
              permissionKeys: Set.unmodifiable(permissions[id] ?? const {}),
            );
          })
          .toList(growable: false),
    );
  }

  Future<void> createMember({
    required String businessId,
    required String username,
    required String displayName,
    required String password,
    required Set<AppPermission> permissions,
  }) async {
    await _client.functions.invoke(
      'create-member',
      body: {
        'business_id': businessId,
        'username': username.trim().toLowerCase(),
        'display_name': displayName.trim(),
        'password': password,
        'permission_keys': permissions.map((permission) => permission.key).toList(),
      },
    );
  }

  Future<void> replacePermissions({
    required String businessId,
    required String memberId,
    required Set<AppPermission> permissions,
  }) async {
    await _client.rpc(
      'replace_member_permissions',
      params: {
        'p_business_id': businessId,
        'p_member_id': memberId,
        'p_permission_keys':
            permissions.map((permission) => permission.key).toList(),
      },
    );
  }

  Future<void> setMemberActive({
    required String businessId,
    required String memberId,
    required bool isActive,
  }) async {
    await _client.rpc(
      'set_business_member_active',
      params: {
        'p_business_id': businessId,
        'p_member_id': memberId,
        'p_is_active': isActive,
      },
    );
  }
}
