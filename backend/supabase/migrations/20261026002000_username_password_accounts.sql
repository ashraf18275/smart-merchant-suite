-- Username/password accounts without email invitations.
-- Usernames are globally unique because Supabase Auth requires a unique login identifier.
create table if not exists public.member_login_names (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  member_id uuid not null,
  username text not null check (username ~ '^[a-z0-9][a-z0-9_.-]{2,31}$'),
  created_at timestamptz not null default now(),
  unique (username),
  unique (member_id),
  foreign key (member_id, business_id)
    references public.business_members(id, business_id) on delete cascade
);

create index if not exists member_login_names_business_idx
  on public.member_login_names(business_id);

alter table public.member_login_names enable row level security;

drop policy if exists login_names_select_authorized on public.member_login_names;
create policy login_names_select_authorized on public.member_login_names
  for select to authenticated
  using (
    exists (
      select 1 from public.business_members m
      where m.id = member_id and m.user_id = (select auth.uid()) and m.is_active = true
    )
    or public.is_business_owner(business_id)
    or public.has_business_permission(business_id, 'users.view')
  );

revoke all on public.member_login_names from anon, authenticated;

-- The app converts a username into username@users.smart-merchant.invalid for Supabase Auth.
-- The reserved .invalid domain is never used for email delivery; accounts are created confirmed.
