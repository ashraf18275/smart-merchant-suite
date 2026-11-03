-- Keep membership, permission and audit writes behind audited server-side APIs.
-- create-member uses the service-role client; service_role bypasses these client grants.
revoke insert, update, delete on public.business_members from anon, authenticated;
revoke insert, update, delete on public.member_permissions from anon, authenticated;
revoke insert, update, delete on public.audit_events from anon, authenticated;

comment on table public.business_members is
  'Client-side membership mutations are disabled. Use authenticated server-side workflows that enforce delegation rules and write audit events.';
comment on table public.member_permissions is
  'Client-side permission mutations are disabled. Use authenticated server-side workflows that enforce delegation rules and write audit events.';
comment on table public.audit_events is
  'Audit events are append-only and written by trusted server-side workflows only.';
