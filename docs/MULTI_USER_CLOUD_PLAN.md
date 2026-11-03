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
