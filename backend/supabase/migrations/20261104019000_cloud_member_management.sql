-- Expose permission assignments to authorized user managers and add audited
-- member activation/deactivation with open-register protection.
drop policy if exists permissions_select_authorized on public.member_permissions;
create policy permissions_select_authorized on public.member_permissions
  for select to authenticated
  using (
    public.is_business_owner(business_id)
    or public.has_business_permission(business_id, 'users.view')
    or exists (
      select 1 from public.business_members m
      where m.id = member_id
        and m.business_id = member_permissions.business_id
        and m.user_id = (select auth.uid())
        and m.is_active = true
    )
  );

create or replace function public.set_business_member_active(
  p_business_id uuid,
  p_member_id uuid,
  p_is_active boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_actor_is_owner boolean;
  v_target_user_id uuid;
  v_target_is_owner boolean;
  v_before_active boolean;
begin
  if auth.uid() is null or p_business_id is null
     or p_member_id is null or p_is_active is null then
    raise exception 'invalid member status payload' using errcode = '22023';
  end if;

  select id, is_owner into v_actor_id, v_actor_is_owner
  from public.business_members
  where business_id = p_business_id
    and user_id = auth.uid()
    and is_active = true;

  if v_actor_id is null then
    raise exception 'not an active business member' using errcode = '42501';
  end if;

  select user_id, is_owner, is_active
  into v_target_user_id, v_target_is_owner, v_before_active
  from public.business_members
  where id = p_member_id and business_id = p_business_id
  for update;

  if v_target_user_id is null then
    raise exception 'member not found' using errcode = 'P0002';
  end if;
  if v_target_is_owner or v_target_user_id = auth.uid() then
    raise exception 'owner or own membership cannot be deactivated' using errcode = '42501';
  end if;

  if not v_actor_is_owner then
    if p_is_active and not public.has_business_permission(p_business_id, 'users.edit') then
      raise exception 'member activation is not allowed' using errcode = '42501';
    end if;
    if not p_is_active and not public.has_business_permission(p_business_id, 'users.deactivate') then
      raise exception 'member deactivation is not allowed' using errcode = '42501';
    end if;
  end if;

  if not p_is_active and exists (
    select 1 from public.cloud_cash_sessions cs
    where cs.business_id = p_business_id
      and cs.opened_by = v_target_user_id
      and cs.status = 'open'
  ) then
    raise exception 'member has an open cash session; close it before deactivation'
      using errcode = '23514';
  end if;

  if v_before_active is distinct from p_is_active then
    update public.business_members
    set is_active = p_is_active
    where id = p_member_id and business_id = p_business_id;

    insert into public.audit_events (
      business_id, actor_user_id, action_key, entity_type, entity_id, metadata
    ) values (
      p_business_id, auth.uid(),
      case when p_is_active then 'users.activate' else 'users.deactivate' end,
      'business_member', p_member_id::text,
      jsonb_build_object(
        'target_user_id', v_target_user_id,
        'before_active', v_before_active,
        'after_active', p_is_active
      )
    );
  end if;
end;
$$;

revoke all on function public.set_business_member_active(uuid, uuid, boolean)
  from public, anon;
grant execute on function public.set_business_member_active(uuid, uuid, boolean)
  to authenticated;
