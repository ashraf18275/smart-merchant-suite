-- Multi-user access foundation for Smart Merchant Suite.
-- Apply with Supabase migrations. This does not yet migrate local SQLite business data.
create extension if not exists pgcrypto;

create table if not exists public.businesses (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 160),
  owner_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now()
);

create table if not exists public.business_members (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete restrict,
  display_name text not null check (length(trim(display_name)) between 1 and 120),
  is_owner boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (business_id, user_id),
  unique (id, business_id)
);

-- Automatically create the non-removable owner membership for each new business.
-- This avoids a bootstrap deadlock where RLS would otherwise prevent the first membership.
create or replace function public.bootstrap_business_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.business_members (
    business_id, user_id, display_name, is_owner, is_active
  ) values (
    new.id, new.owner_user_id, 'صاحب المحل', true, true
  );
  return new;
end;
$$;

drop trigger if exists businesses_bootstrap_owner on public.businesses;
create trigger businesses_bootstrap_owner
  after insert on public.businesses
  for each row execute function public.bootstrap_business_owner();

create table if not exists public.member_permissions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  member_id uuid not null,
  permission_key text not null check (permission_key in (
    'dashboard.view',
    'products.view', 'products.create', 'products.edit', 'products.archive',
    'inventory.view', 'inventory.adjust', 'inventory.count',
    'sales.view', 'sales.create', 'sales.cancel', 'sales.return',
    'expenses.view', 'expenses.create', 'expenses.edit', 'expenses.delete',
    'reports.view', 'reports.profit.view', 'data.export', 'data.backup',
    'users.view', 'users.create', 'users.edit', 'users.deactivate',
    'settings.view', 'settings.edit', 'audit.view'
  )),
  allowed boolean not null default false,
  updated_at timestamptz not null default now(),
  unique (member_id, permission_key),
  foreign key (member_id, business_id)
    references public.business_members(id, business_id) on delete cascade
);

create table if not exists public.audit_events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  actor_user_id uuid references auth.users(id) on delete set null,
  action_key text not null,
  entity_type text not null,
  entity_id text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists business_members_user_active_idx
  on public.business_members(user_id, is_active);
create index if not exists member_permissions_lookup_idx
  on public.member_permissions(business_id, member_id, permission_key);
create index if not exists audit_events_business_created_idx
  on public.audit_events(business_id, created_at desc);

-- SECURITY DEFINER helpers avoid recursive row-level security policies.
create or replace function public.is_business_member(p_business_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.business_members m
    where m.business_id = p_business_id
      and m.user_id = (select auth.uid())
      and m.is_active = true
  );
$$;

create or replace function public.is_business_owner(p_business_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.business_members m
    where m.business_id = p_business_id
      and m.user_id = (select auth.uid())
      and m.is_active = true
      and m.is_owner = true
  );
$$;

create or replace function public.has_business_permission(
  p_business_id uuid,
  p_permission_key text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.business_members m
    join public.member_permissions p
      on p.member_id = m.id and p.business_id = m.business_id
    where m.business_id = p_business_id
      and m.user_id = (select auth.uid())
      and m.is_active = true
      and p.permission_key = p_permission_key
      and p.allowed = true
  ) or public.is_business_owner(p_business_id);
$$;

alter table public.businesses enable row level security;
alter table public.business_members enable row level security;
alter table public.member_permissions enable row level security;
alter table public.audit_events enable row level security;

drop policy if exists businesses_select_member on public.businesses;
create policy businesses_select_member on public.businesses
  for select to authenticated
  using (public.is_business_member(id));

drop policy if exists businesses_insert_owner on public.businesses;
create policy businesses_insert_owner on public.businesses
  for insert to authenticated
  with check (owner_user_id = (select auth.uid()));

drop policy if exists businesses_update_owner on public.businesses;
create policy businesses_update_owner on public.businesses
  for update to authenticated
  using (public.is_business_owner(id))
  with check (public.is_business_owner(id));

drop policy if exists members_select_authorized on public.business_members;
create policy members_select_authorized on public.business_members
  for select to authenticated
  using (
    user_id = (select auth.uid())
    or public.is_business_owner(business_id)
    or public.has_business_permission(business_id, 'users.view')
  );

drop policy if exists members_insert_owner on public.business_members;
create policy members_insert_owner on public.business_members
  for insert to authenticated
  with check (public.is_business_owner(business_id) and is_owner = false);

drop policy if exists members_update_owner on public.business_members;
create policy members_update_owner on public.business_members
  for update to authenticated
  using (public.is_business_owner(business_id) and is_owner = false)
  with check (public.is_business_owner(business_id) and is_owner = false);

drop policy if exists members_delete_owner on public.business_members;
create policy members_delete_owner on public.business_members
  for delete to authenticated
  using (public.is_business_owner(business_id) and is_owner = false);

drop policy if exists permissions_select_authorized on public.member_permissions;
create policy permissions_select_authorized on public.member_permissions
  for select to authenticated
  using (
    public.is_business_owner(business_id)
    or exists (
      select 1 from public.business_members m
      where m.id = member_id
        and m.user_id = (select auth.uid())
        and m.is_active = true
    )
  );

drop policy if exists permissions_insert_owner on public.member_permissions;
create policy permissions_insert_owner on public.member_permissions
  for insert to authenticated
  with check (public.is_business_owner(business_id));

drop policy if exists permissions_update_owner on public.member_permissions;
create policy permissions_update_owner on public.member_permissions
  for update to authenticated
  using (public.is_business_owner(business_id))
  with check (public.is_business_owner(business_id));

drop policy if exists permissions_delete_owner on public.member_permissions;
create policy permissions_delete_owner on public.member_permissions
  for delete to authenticated
  using (public.is_business_owner(business_id));

drop policy if exists audit_select_authorized on public.audit_events;
create policy audit_select_authorized on public.audit_events
  for select to authenticated
  using (
    public.is_business_owner(business_id)
    or public.has_business_permission(business_id, 'audit.view')
  );

-- Audit event writes are intentionally service-side only until an audited server API
-- is implemented. Do not expose the Supabase service-role key in the app.

revoke all on function public.is_business_member(uuid) from public;
revoke all on function public.is_business_owner(uuid) from public;
revoke all on function public.has_business_permission(uuid, text) from public;
grant execute on function public.is_business_member(uuid) to authenticated;
grant execute on function public.is_business_owner(uuid) to authenticated;
grant execute on function public.has_business_permission(uuid, text) to authenticated;
