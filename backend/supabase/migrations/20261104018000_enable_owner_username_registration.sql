-- Allow a signed-in business owner to attach their own globally unique login name.
-- The row must reference the authenticated user's active owner membership.
drop policy if exists login_names_insert_owner_self on public.member_login_names;
create policy login_names_insert_owner_self on public.member_login_names
  for insert to authenticated
  with check (
    exists (
      select 1
      from public.business_members m
      where m.id = member_id
        and m.business_id = member_login_names.business_id
        and m.user_id = (select auth.uid())
        and m.is_owner = true
        and m.is_active = true
    )
  );

grant insert on public.member_login_names to authenticated;
