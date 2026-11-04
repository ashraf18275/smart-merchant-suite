# Multi-user and cloud synchronization implementation plan

## Accepted requirements
- Unlimited user accounts per business; no fixed job roles.
- Each user has an independent login and a permission checklist managed by the business owner.
- Enforce authorization in the data/API layer, not only by hiding UI controls.
- Multiple computers and phones use one shared source of truth concurrently.
- The owner can view current business activity remotely.
- Preserve the existing Flutter/SQLite work and do not merge changes into `main` without explicit approval.
- Prefer a low-cost setup, but do not promise a free tier or production readiness before checking current limits and testing.

## Architecture
- Flutter remains the Android/desktop client.
- Supabase Auth provides identity; PostgreSQL stores shared business data; Row Level Security (RLS) protects tenant data.
- The app must never contain a Supabase service-role key. Privileged account creation must be implemented through a server-side Edge Function; the app creates username/password accounts in place and does not send email invitations.
- Existing SQLite remains local storage/cache during transition. It is not yet synchronized by this migration.
- Business operations need server-side transactions and idempotency keys before concurrent sales/inventory are production-safe.
- Offline-first operation is a target: queued writes should be synchronized after reconnection, with conflict handling and duplicate-sale prevention. This is not implemented yet.

## Permission keys
The initial permission catalogue is deliberately granular and editable per user:
- dashboard.view
- products.view/create/edit/archive
- inventory.view/adjust/count
- sales.view/create/cancel/return
- expenses.view/create/edit/delete
- reports.view, reports.profit.view
- data.export, data.backup
- users.view/create/edit/deactivate
- settings.view/edit
- audit.view

The business owner always retains administrative access. Delegated users may create accounts only when granted both users.create and users.edit, and may grant only permissions they themselves hold. No non-owner can create another owner account. Usernames are globally unique, lowercase 3-32 character identifiers; users sign in with username/password. Supabase Auth uses a reserved non-deliverable .invalid address internally, and no invitation email is sent.

## Delivery stages
1. Database access-control foundation and permission catalogue.
2. Secure owner onboarding and server-side member invitation/creation.
3. The `create-member` Edge Function creates username/password accounts in-app, validates the caller's permissions, prevents delegated privilege escalation, and assigns selected permissions. The email invitation function was removed. A Dart helper maps usernames to an internal reserved .invalid Auth identity; unit tests cover normalization and validation. Next: wire Flutter sign-in/session handling and build the in-app user list, account form, and permission checklist.
4. Move business entities to tenant-scoped cloud tables and enforce RLS for every table.
5. Implement realtime updates, server transactions, idempotent writes, and concurrency tests.
6. Add offline outbox, retry policy, conflict resolution, and reconnection tests.
7. Add owner remote dashboard, audit history, deployment configuration, and device testing.

## Current status
The first two SQL migrations have been added on the feature branch. They establish businesses, members, per-member permissions, audit-event storage, tenant-scoped cloud tables for products, stock movements, sales, sale items, and expenses, plus initial RLS policies and transactional RPCs for stock adjustments and multi-item sales. Sale writes use an operation ID to prevent duplicate invoices on retry and lock product rows before checking stock. They include the server-side account-creation endpoint and username mapping helper, but the Flutter login screen is not yet connected to Supabase, initial owner setup is not yet implemented, existing SQLite records are not migrated, and end-to-end multi-device synchronization is not enabled. SQL must be applied to a disposable/test Supabase project, reviewed, and exercised with concurrency/security tests before production use.


## Expanded granular permission catalogue — 4 November 2026

The initial permission list has been expanded to cover the retail modules that already exist locally and the modules planned for cloud synchronization. Stable keys now include:

- Customers: `customers.view`, `customers.create`, `customers.edit`.
- Suppliers: `suppliers.view`, `suppliers.create`, `suppliers.edit`.
- Purchases: `purchases.view`, `purchases.create`, `purchases.return`.
- Account ledgers: `accounts.view`, `accounts.customer.receipt`, `accounts.supplier.payment`, `accounts.adjust`.
- Cashbook: `cashbook.view`, `cashbook.session.open`, `cashbook.session.close`, `cashbook.adjust`.
- Branches and warehouses: `branches.view`, `branches.manage`, `warehouses.view`, `warehouses.manage`.
- Inventory transfer: `inventory.transfer`.
- Sales discount approval: `sales.discount`.
- Data import: `data.import`.

These keys are now aligned across the Dart permission catalogue, the member-creation Edge Function, the database constraint, and the audited `replace_member_permissions` RPC. Existing grants are preserved by the migration. The permission checklist UI and enforcement at every local/cloud operation are still pending; the presence of a key in the catalogue does not mean the corresponding feature is already secured end-to-end.


## تحديث التنفيذ — توصيل تسجيل الدخول السحابي وتهيئة المالك (4 نوفمبر 2026)

- أضيفت تبعية `supabase_flutter 2.18.x` مع Dart SDK `>=3.9.0`.
- أضيفت `CloudConfig` لقراءة `SUPABASE_URL` و`SUPABASE_PUBLISHABLE_KEY` من build-time defines؛ لا يوجد service-role key في تطبيق Flutter.
- عند غياب إعدادات السحابة أو فشل تهيئتها، يظل التطبيق المحلي متاحًا.
- أضيفت شاشة الحساب السحابي لتسجيل الدخول باسم المستخدم وكلمة المرور، وتسجيل حساب مالك جديد، وعرض الأنشطة المتاحة، وإنشاء نشاط إضافي.
- اسم المستخدم يحول إلى البريد الداخلي المحجوز `.invalid` وفق سياسة تسجيل الدخول الحالية؛ لا يُطلب من المستخدم بريد حقيقي ولا ترسل دعوات.
- تسجيل المالك ينشئ صف النشاط؛ مشغلات قاعدة البيانات تنشئ عضوية المالك والفرع والمخزن الرئيسيين تلقائيًا.
- أضيفت سياسة تسمح للمالك المسجل فقط بربط اسم دخوله بعضويته؛ القراءة متاحة وفق RLS. لا يستطيع الموظف انتحال اسم المالك.
- أُخذ في الاعتبار أن مالكًا واحدًا قد يملك عدة أنشطة: اسم الدخول العالمي يرتبط مرة واحدة بحساب Auth ولا يتكرر لكل نشاط.
- شاشة السحابة تعرض صراحة أن بيانات SQLite لا تزال محلية وأن مزامنة الأجهزة لم تُفعّل بعد.

**إعداد المشروع قبل استخدام تسجيل المالك:**
- تمرير `SUPABASE_URL` و`SUPABASE_PUBLISHABLE_KEY` وقت البناء باستخدام `--dart-define`.
- لأن أسماء الدخول تستخدم نطاق `.invalid` لا يمكنه استقبال رسالة تأكيد، يجب تعطيل تأكيد البريد الإلكتروني في إعدادات Auth بالمشروع؛ وإلا سيُنشأ المستخدم دون جلسة فورية ولن تكتمل تهيئة النشاط من الشاشة.
- لا تضع مفتاح `service_role` في التطبيق أو في build defines.

**التحقق:**
- Flutter CI run #610: https://github.com/ashraf18275/smart-merchant-suite/actions/runs/41917807534 — Analyze success و**160 اختبارًا ناجحًا**.
- Supabase/PostgreSQL run #110: https://github.com/ashraf18275/smart-merchant-suite/actions/runs/41917228779 — جميع الهجرات واختبارات الأمان وترحيل الكميات القديمة وDeno checks: success.
- Flutter lockfile المحدّث جرى حله داخل CI وأُرفق مع artifact `resolved-engineering-inputs`; يجب حفظ النسخة المقفلة في المستودع قبل التسليم النهائي.
- هذه الخطوة لا تعني اكتمال مزامنة البيانات أو صلاحيات واجهات التطبيق؛ إنها تأسيس اتصال الهوية وتهيئة المالك فقط.


## تحديث التنفيذ — إدارة المستخدمين والصلاحيات من Flutter (4 نوفمبر 2026)

- أضيف `CloudMemberRepository` لقراءة أعضاء النشاط وأسماء دخولهم وصلاحياتهم وفق RLS.
- أضيفت شاشة `CloudMembersPage` وتُفتح من بطاقة النشاط في الحساب السحابي.
- المالك يستطيع إضافة حساب موظف باسم مستخدم وكلمة مرور، دون بريد أو دعوة.
- قائمة الصلاحيات مبنية على `AppPermission.values`؛ لا توجد أدوار ثابتة مفروضة.
- الموظف المفوض لا يرى إلا الصلاحيات التي تسمح بها RLS، ولا يمكنه منح صلاحية لا يملكها هو.
- تحديث الصلاحيات يستخدم RPC `replace_member_permissions` المدققة، وإنشاء المستخدم يستخدم Edge Function `create-member` ذات التعويض عند فشل إنشاء العضوية/التدقيق.
- أضيفت RPC `set_business_member_active` لتفعيل/تعطيل الحساب مع سجل تدقيق، ومنع تعطيل المالك أو الحساب الحالي، ومنع تعطيل مستخدم لديه وردية صندوق مفتوحة.
- توسعت سياسة قراءة `member_permissions` لتسمح للمالك ومدير المستخدمين ذي `users.view` برؤية صلاحيات أعضاء النشاط، مع بقاء المستخدم العادي قادرًا على قراءة صلاحياته فقط.
- تم منح صلاحية SELECT على `member_permissions` للمستخدم المصادق عليه، لكن RLS تحدد نطاق الصفوف المسموح بها.

**التحقق:**
- Flutter CI run #616: https://github.com/ashraf18275/smart-merchant-suite/actions/runs/41919236546 — Analyze success و**163 اختبارًا ناجحًا**.
- Supabase/PostgreSQL run #114: https://github.com/ashraf18275/smart-merchant-suite/actions/runs/41919630572 — جميع الهجرات واختبارات الأمان وترحيل الكميات القديمة وDeno checks: success.
- شملت الاختبارات قراءة صلاحيات الأعضاء وفق RLS، ورفض الموظف غير المفوض تعطيل مستخدم، والسماح للمالك بالتفعيل/التعطيل وتسجيل التدقيق.
- إدارة المستخدمين تعمل عبر الخدمات السحابية عند إعدادها؛ التطبيق لم يربط بعد بيانات المبيعات والمخزون والصندوق المحلية بالمزامنة.
