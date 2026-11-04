import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../cloud/cloud_member_repository.dart';
import '../security/permission_catalog.dart';

class CloudMembersPage extends StatefulWidget {
  const CloudMembersPage({
    super.key,
    required this.client,
    required this.businessId,
    required this.businessName,
  });

  final SupabaseClient client;
  final String businessId;
  final String businessName;

  @override
  State<CloudMembersPage> createState() => _CloudMembersPageState();
}

class _CloudMembersPageState extends State<CloudMembersPage> {
  late final CloudMemberRepository _repository =
      CloudMemberRepository(widget.client);
  CloudMemberWorkspace? _workspace;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final workspace = await _repository.load(widget.businessId);
      if (mounted) setState(() => _workspace = workspace);
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _friendlyError(Object error) {
    final message = error.toString();
    if (message.contains('users_view_permission_required')) {
      return 'لا تملك صلاحية عرض المستخدمين في هذا النشاط.';
    }
    if (message.contains('not found') || message.contains('No rows')) {
      return 'تعذر العثور على عضوية المستخدم في هذا النشاط.';
    }
    return 'تعذر تحميل المستخدمين. تحقق من الاتصال والصلاحيات.';
  }

  Future<void> _createMember() async {
    final workspace = _workspace;
    if (workspace == null || !workspace.canCreateUsers) return;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => _MemberEditorDialog(
        title: 'إضافة مستخدم',
        availablePermissions: workspace.assignablePermissions,
        onSave: (username, displayName, password, permissions) async {
          await _repository.createMember(
            businessId: widget.businessId,
            username: username,
            displayName: displayName,
            password: password,
            permissions: permissions,
          );
        },
      ),
    );
    if (result == true) await _reload();
  }

  Future<void> _editPermissions(CloudMember member) async {
    final workspace = _workspace;
    if (workspace == null || !workspace.canEditPermissions || member.isOwner) {
      return;
    }
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => _PermissionEditorDialog(
        title: 'صلاحيات ${member.displayName}',
        availablePermissions: workspace.assignablePermissions,
        initialPermissions: member.permissionKeys
            .map(AppPermission.fromKey)
            .whereType<AppPermission>()
            .toSet(),
        onSave: (permissions) => _repository.replacePermissions(
          businessId: widget.businessId,
          memberId: member.id,
          permissions: permissions,
        ),
      ),
    );
    if (result == true) await _reload();
  }

  Future<void> _toggleMember(CloudMember member) async {
    final workspace = _workspace;
    if (workspace == null || member.isOwner) return;
    final activating = !member.isActive;
    if (activating
        ? !workspace.canEditPermissions
        : !workspace.canDeactivateUsers) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(activating ? 'إعادة تفعيل المستخدم' : 'تعطيل المستخدم'),
        content: Text(activating
            ? 'سيتمكن ${member.displayName} من تسجيل الدخول مجددًا.'
            : 'سيُمنع ${member.displayName} من تسجيل الدخول لهذا النشاط.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('رجوع'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(activating ? 'تفعيل' : 'تعطيل'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _repository.setMemberActive(
        businessId: widget.businessId,
        memberId: member.id,
        isActive: activating,
      );
      await _reload();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_friendlyError(error))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final workspace = _workspace;
    return Scaffold(
      appBar: AppBar(
        title: const Text('المستخدمون والصلاحيات'),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            onPressed: _loading ? null : _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: workspace?.canCreateUsers == true
          ? FloatingActionButton.extended(
              onPressed: _loading ? null : _createMember,
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('إضافة مستخدم'),
            )
          : null,
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error!, textAlign: TextAlign.center),
                    ),
                  )
                : workspace == null
                    ? const Center(child: Text('لا توجد بيانات مستخدمين.'))
                    : RefreshIndicator(
                        onRefresh: _reload,
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                          children: [
                            Card(
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      widget.businessName,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'عدد الحسابات: ${workspace.members.length}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            ...workspace.members.map((member) {
                              final canEdit = workspace.canEditPermissions &&
                                  !member.isOwner;
                              final canToggle = !member.isOwner &&
                                  (member.isActive
                                      ? workspace.canDeactivateUsers
                                      : workspace.canEditPermissions);
                              return Card(
                                margin: const EdgeInsets.only(bottom: 10),
                                child: ListTile(
                                  leading: CircleAvatar(
                                    child: Icon(member.isOwner
                                        ? Icons.storefront_outlined
                                        : Icons.person_outline),
                                  ),
                                  title: Text(member.displayName),
                                  subtitle: Text([
                                    if (member.username != null)
                                      '@${member.username}',
                                    member.isOwner
                                        ? 'المالك'
                                        : member.isActive
                                            ? 'نشط'
                                            : 'معطّل',
                                    member.isOwner
                                        ? 'صلاحيات كاملة'
                                        : '${member.permissionKeys.length} صلاحية',
                                  ].join(' • ')),
                                  isThreeLine: true,
                                  trailing: PopupMenuButton<String>(
                                    enabled: canEdit || canToggle,
                                    onSelected: (value) {
                                      if (value == 'permissions') {
                                        _editPermissions(member);
                                      } else {
                                        _toggleMember(member);
                                      }
                                    },
                                    itemBuilder: (context) => [
                                      if (canEdit)
                                        const PopupMenuItem(
                                          value: 'permissions',
                                          child: Text('تعديل الصلاحيات'),
                                        ),
                                      if (canToggle)
                                        PopupMenuItem(
                                          value: 'status',
                                          child: Text(member.isActive
                                              ? 'تعطيل الحساب'
                                              : 'إعادة التفعيل'),
                                        ),
                                    ],
                                  ),
                                ),
                              );
                            }),
                            if (workspace.members.isEmpty)
                              const Padding(
                                padding: EdgeInsets.all(28),
                                child: Text(
                                  'لا يوجد مستخدمون بعد. أضف أول حساب للموظف.',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                          ],
                        ),
                      ),
      ),
    );
  }
}

typedef _CreateMemberCallback = Future<void> Function(
  String username,
  String displayName,
  String password,
  Set<AppPermission> permissions,
);

class _MemberEditorDialog extends StatefulWidget {
  const _MemberEditorDialog({
    required this.title,
    required this.availablePermissions,
    required this.onSave,
  });

  final String title;
  final Set<AppPermission> availablePermissions;
  final _CreateMemberCallback onSave;

  @override
  State<_MemberEditorDialog> createState() => _MemberEditorDialogState();
}

class _MemberEditorDialogState extends State<_MemberEditorDialog> {
  final _username = TextEditingController();
  final _displayName = TextEditingController();
  final _password = TextEditingController();
  final Set<AppPermission> _selected = {};
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _displayName.dispose();
    _password.dispose();
    super.dispose();
  }

  List<Widget> _permissionTiles() {
    final permissions = widget.availablePermissions.toList()
      ..sort((a, b) => a.label.compareTo(b.label));
    return permissions
        .map((permission) => CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(permission.label),
              value: _selected.contains(permission),
              onChanged: _saving
                  ? null
                  : (checked) => setState(() {
                        if (checked == true) {
                          _selected.add(permission);
                        } else {
                          _selected.remove(permission);
                        }
                      }),
            ))
        .toList();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(
        _username.text,
        _displayName.text,
        _password.text,
        Set.unmodifiable(_selected),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error.toString().contains('username_unavailable')
              ? 'اسم المستخدم مستخدم بالفعل.'
              : 'تعذر إنشاء الحساب. راجع البيانات والصلاحيات.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: SizedBox(
          width: 520,
          height: 560,
          child: Column(
            children: [
              TextField(
                controller: _username,
                textDirection: TextDirection.ltr,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'اسم المستخدم'),
              ),
              TextField(
                controller: _displayName,
                decoration: const InputDecoration(labelText: 'اسم الموظف'),
              ),
              TextField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'كلمة المرور (10 أحرف على الأقل)',
                ),
              ),
              const Divider(height: 24),
              const Align(
                alignment: Alignment.centerRight,
                child: Text('حدد الصلاحيات المطلوبة لهذا الحساب'),
              ),
              const SizedBox(height: 6),
              Expanded(child: ListView(children: _permissionTiles())),
              if (_error != null)
                Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'جارٍ الإنشاء...' : 'إنشاء الحساب'),
          ),
        ],
      );
}

typedef _UpdatePermissionsCallback = Future<void> Function(
  Set<AppPermission> permissions,
);

class _PermissionEditorDialog extends StatefulWidget {
  const _PermissionEditorDialog({
    required this.title,
    required this.availablePermissions,
    required this.initialPermissions,
    required this.onSave,
  });

  final String title;
  final Set<AppPermission> availablePermissions;
  final Set<AppPermission> initialPermissions;
  final _UpdatePermissionsCallback onSave;

  @override
  State<_PermissionEditorDialog> createState() =>
      _PermissionEditorDialogState();
}

class _PermissionEditorDialogState extends State<_PermissionEditorDialog> {
  late final Set<AppPermission> _selected =
      Set<AppPermission>.of(widget.initialPermissions);
  bool _saving = false;
  String? _error;

  List<Widget> _permissionTiles() {
    final permissions = widget.availablePermissions.toList()
      ..sort((a, b) => a.label.compareTo(b.label));
    return permissions
        .map((permission) => CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(permission.label),
              value: _selected.contains(permission),
              onChanged: _saving
                  ? null
                  : (checked) => setState(() {
                        if (checked == true) {
                          _selected.add(permission);
                        } else {
                          _selected.remove(permission);
                        }
                      }),
            ))
        .toList();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(Set.unmodifiable(_selected));
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'تعذر حفظ الصلاحيات. قد تكون الصلاحية خارج نطاق تفويضك.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: SizedBox(
          width: 520,
          height: 560,
          child: Column(
            children: [
              const Text('كل صلاحية مستقلة ويمكن تعديلها دون استخدام أدوار ثابتة.'),
              const SizedBox(height: 8),
              Expanded(child: ListView(children: _permissionTiles())),
              if (_error != null)
                Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'جارٍ الحفظ...' : 'حفظ الصلاحيات'),
          ),
        ],
      );
}
