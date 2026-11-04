-- Expand the granular permission catalogue before wiring cloud member management.
-- Existing grants are preserved; this only permits the additional stable keys.
alter table public.member_permissions
  drop constraint if exists member_permissions_permission_key_check;

alter table public.member_permissions
  add constraint member_permissions_permission_key_check
  check (permission_key in (
    'dashboard.view',
    'products.view', 'products.create', 'products.edit', 'products.archive',
    'inventory.view', 'inventory.adjust', 'inventory.count', 'inventory.transfer',
    'sales.view', 'sales.create', 'sales.cancel', 'sales.return', 'sales.discount',
    'customers.view', 'customers.create', 'customers.edit',
    'suppliers.view', 'suppliers.create', 'suppliers.edit',
    'purchases.view', 'purchases.create', 'purchases.return',
    'accounts.view', 'accounts.customer.receipt', 'accounts.supplier.payment', 'accounts.adjust',
    'cashbook.view', 'cashbook.session.open', 'cashbook.session.close', 'cashbook.adjust',
    'branches.view', 'branches.manage', 'warehouses.view', 'warehouses.manage',
    'expenses.view', 'expenses.create', 'expenses.edit', 'expenses.delete',
    'reports.view', 'reports.profit.view',
    'data.export', 'data.backup', 'data.import',
    'users.view', 'users.create', 'users.edit', 'users.deactivate',
    'settings.view', 'settings.edit', 'audit.view'
  ));

-- Keep server-side permission replacement in lockstep with the database constraint.
-- Atomically replace a member's permission set and append an audit event.
-- Client-side DML remains revoked; this is the audited server-side path.
create or replace function public.replace_member_permissions(
  p_business_id uuid,
  p_member_id uuid,
  p_permission_keys text[]
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_member_id uuid;
  v_actor_is_owner boolean;
  v_target_user_id uuid;
  v_target_is_owner boolean;
  v_actor_permissions text[] := array[]::text[];
  v_before_permissions text[] := array[]::text[];
  v_after_permissions text[] := array[]::text[];
begin
  if p_business_id is null or p_member_id is null or p_permission_keys is null then
    raise exception 'invalid permission update payload' using errcode = '22023';
  end if;

  if exists (
    select 1
    from unnest(p_permission_keys) as requested(permission_key)
    where requested.permission_key is null
       or requested.permission_key not in (
         'dashboard.view',
    'customers.view',
    'customers.create',
    'customers.edit',
    'suppliers.view',
    'suppliers.create',
    'suppliers.edit',
    'purchases.view',
    'purchases.create',
    'purchases.return',
    'accounts.view',
    'accounts.customer.receipt',
    'accounts.supplier.payment',
    'accounts.adjust',
    'cashbook.view',
    'cashbook.session.open',
    'cashbook.session.close',
    'cashbook.adjust',
    'branches.view',
    'branches.manage',
    'warehouses.view',
    'warehouses.manage',
    'inventory.transfer',
    'sales.discount',
    'data.import',
         'products.view', 'products.create', 'products.edit', 'products.archive',
         'inventory.view', 'inventory.adjust', 'inventory.count',
         'sales.view', 'sales.create', 'sales.cancel', 'sales.return',
         'expenses.view', 'expenses.create', 'expenses.edit', 'expenses.delete',
         'reports.view', 'reports.profit.view', 'data.export', 'data.backup',
         'users.view', 'users.create', 'users.edit', 'users.deactivate',
         'settings.view', 'settings.edit', 'audit.view'
       )
  ) or cardinality(p_permission_keys) <> (
    select count(distinct requested.permission_key)
    from unnest(p_permission_keys) as requested(permission_key)
  ) then
    raise exception 'invalid or duplicate permission key' using errcode = '22023';
  end if;

  select m.id, m.is_owner
  into v_actor_member_id, v_actor_is_owner
  from public.business_members m
  where m.business_id = p_business_id
    and m.user_id = auth.uid()
    and m.is_active = true;

  if v_actor_member_id is null then
    raise exception 'not an active business member' using errcode = '42501';
  end if;

  select m.user_id, m.is_owner
  into v_target_user_id, v_target_is_owner
  from public.business_members m
  where m.id = p_member_id
    and m.business_id = p_business_id
  for update;

  if v_target_user_id is null then
    raise exception 'member not found' using errcode = 'P0002';
  end if;

  if v_target_is_owner then
    raise exception 'owner permissions cannot be changed' using errcode = '42501';
  end if;

  select coalesce(array_agg(p.permission_key order by p.permission_key), array[]::text[])
  into v_before_permissions
  from public.member_permissions p
  where p.business_id = p_business_id
    and p.member_id = p_member_id
    and p.allowed = true;

  if not v_actor_is_owner then
    if v_target_user_id = auth.uid()
       or not public.has_business_permission(p_business_id, 'users.edit') then
      raise exception 'user permission management is not allowed' using errcode = '42501';
    end if;

    select coalesce(array_agg(p.permission_key order by p.permission_key), array[]::text[])
    into v_actor_permissions
    from public.member_permissions p
    where p.business_id = p_business_id
      and p.member_id = v_actor_member_id
      and p.allowed = true;

    -- A delegated administrator can grant only permissions they hold and
    -- cannot silently revoke a capability they do not hold from another member.
    if exists (
      select 1
      from unnest(p_permission_keys) as requested(permission_key)
      where not (requested.permission_key = any(v_actor_permissions))
    ) or exists (
      select 1
      from unnest(v_before_permissions) as existing(permission_key)
      where not (existing.permission_key = any(v_actor_permissions))
        and not (existing.permission_key = any(p_permission_keys))
    ) then
      raise exception 'cannot change permissions outside delegated authority'
        using errcode = '42501';
    end if;
  end if;

  select coalesce(array_agg(requested.permission_key order by requested.permission_key), array[]::text[])
  into v_after_permissions
  from unnest(p_permission_keys) as requested(permission_key);

  delete from public.member_permissions
  where business_id = p_business_id and member_id = p_member_id;

  insert into public.member_permissions (
    business_id, member_id, permission_key, allowed
  )
  select p_business_id, p_member_id, requested.permission_key, true
  from unnest(p_permission_keys) as requested(permission_key);

  insert into public.audit_events (
    business_id, actor_user_id, action_key, entity_type, entity_id, metadata
  ) values (
    p_business_id,
    auth.uid(),
    'users.permissions.update',
    'business_member',
    p_member_id::text,
    jsonb_build_object(
      'target_user_id', v_target_user_id,
      'before', to_jsonb(v_before_permissions),
      'after', to_jsonb(v_after_permissions)
    )
  );
end;
$$;

revoke all on function public.replace_member_permissions(uuid, uuid, text[]) from public;
grant execute on function public.replace_member_permissions(uuid, uuid, text[]) to authenticated;
