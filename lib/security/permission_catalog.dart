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
  salesDiscount('sales.discount', 'اعتماد الخصومات'),
  customersView('customers.view', 'عرض العملاء'),
  customersCreate('customers.create', 'إضافة العملاء'),
  customersEdit('customers.edit', 'تعديل العملاء'),
  suppliersView('suppliers.view', 'عرض الموردين'),
  suppliersCreate('suppliers.create', 'إضافة الموردين'),
  suppliersEdit('suppliers.edit', 'تعديل الموردين'),
  purchasesView('purchases.view', 'عرض المشتريات'),
  purchasesCreate('purchases.create', 'تسجيل المشتريات'),
  purchasesReturn('purchases.return', 'مرتجعات المشتريات'),
  accountsView('accounts.view', 'عرض الحسابات وكشوفها'),
  customerReceipt('accounts.customer.receipt', 'تحصيل مستحقات العملاء'),
  supplierPayment('accounts.supplier.payment', 'سداد مستحقات الموردين'),
  accountsAdjust('accounts.adjust', 'تسوية الحسابات'),
  cashbookView('cashbook.view', 'عرض دفتر النقدية'),
  cashbookSessionOpen('cashbook.session.open', 'فتح وردية الصندوق'),
  cashbookSessionClose('cashbook.session.close', 'إغلاق وردية الصندوق'),
  cashbookAdjust('cashbook.adjust', 'تسجيل حركات الصندوق'),
  branchesView('branches.view', 'عرض الفروع'),
  branchesManage('branches.manage', 'إدارة الفروع'),
  warehousesView('warehouses.view', 'عرض المخازن'),
  warehousesManage('warehouses.manage', 'إدارة المخازن'),
  inventoryTransfer('inventory.transfer', 'التحويل بين المخازن'),
  expensesView('expenses.view', 'عرض المصروفات'),
  expensesCreate('expenses.create', 'إضافة المصروفات'),
  expensesEdit('expenses.edit', 'تعديل المصروفات'),
  expensesDelete('expenses.delete', 'حذف المصروفات'),
  reportsView('reports.view', 'عرض التقارير'),
  reportsProfitView('reports.profit.view', 'عرض الأرباح'),
  dataExport('data.export', 'تصدير البيانات'),
  dataImport('data.import', 'استيراد البيانات'),
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
