/// Fine-grained capabilities assigned individually to each account.
/// Keep these stable keys in sync with backend/supabase/migrations.
enum AppPermission {
  dashboardView('dashboard.view', 'عرض لوحة المتابعة'),
  productsView('products.view', 'عرض المنتجات'),
  productsCreate('products.create', 'إضافة المنتجات'),
  productsEdit('products.edit', 'تعديل المنتجات'),
  productsArchive('products.archive', 'إيقاف المنتجات'),
  inventoryView('inventory.view', 'عرض المخزون'),
  inventoryAdjust('inventory.adjust', 'تعديل حركات المخزون'),
  inventoryCount('inventory.count', 'الجرد'),
  salesView('sales.view', 'عرض المبيعات والفواتير'),
  salesCreate('sales.create', 'تسجيل المبيعات'),
  salesCancel('sales.cancel', 'إلغاء الفواتير'),
  salesReturn('sales.return', 'تسجيل المرتجعات'),
  expensesView('expenses.view', 'عرض المصروفات'),
  expensesCreate('expenses.create', 'إضافة المصروفات'),
  expensesEdit('expenses.edit', 'تعديل المصروفات'),
  expensesDelete('expenses.delete', 'حذف المصروفات'),
  reportsView('reports.view', 'عرض التقارير'),
  reportsProfitView('reports.profit.view', 'عرض الأرباح'),
  dataExport('data.export', 'تصدير البيانات'),
  dataBackup('data.backup', 'النسخ الاحتياطي'),
  usersView('users.view', 'عرض المستخدمين'),
  usersCreate('users.create', 'إضافة المستخدمين'),
  usersEdit('users.edit', 'تعديل المستخدمين'),
  usersDeactivate('users.deactivate', 'تعطيل المستخدمين'),
  settingsView('settings.view', 'عرض الإعدادات'),
  settingsEdit('settings.edit', 'تعديل الإعدادات'),
  auditView('audit.view', 'عرض سجل العمليات');

  const AppPermission(this.key, this.label);

  /// Stable key stored by the cloud authorization layer.
  final String key;

  /// Arabic label for the future permission checklist UI.
  final String label;

  static AppPermission? fromKey(String key) {
    for (final permission in AppPermission.values) {
      if (permission.key == key) return permission;
    }
    return null;
  }
}

/// A read-only snapshot of permissions for one signed-in member.
/// The server remains authoritative; this object is for client-side UI gating.
class UserAccess {
  UserAccess({
    required this.userId,
    required this.isOwner,
    required Set<AppPermission> permissions,
  }) : permissions = Set.unmodifiable(permissions);

  final String userId;
  final bool isOwner;
  final Set<AppPermission> permissions;

  bool can(AppPermission permission) =>
      isOwner || permissions.contains(permission);

  bool get canManageUsers =>
      isOwner || can(AppPermission.usersCreate) && can(AppPermission.usersEdit);
}
