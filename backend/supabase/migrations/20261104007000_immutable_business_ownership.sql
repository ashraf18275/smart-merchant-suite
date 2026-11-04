-- Business ownership is established by the owner membership created at onboarding.
-- Authenticated clients may rename a business, but must not transfer ownership by
-- changing owner_user_id or delete the business and cascade its operational data.
revoke update on public.businesses from anon, authenticated;
grant update (name) on public.businesses to authenticated;
revoke delete on public.businesses from anon, authenticated;

comment on column public.businesses.owner_user_id is
  'Immutable through client APIs. Ownership transfer requires a dedicated audited server-side workflow.';
