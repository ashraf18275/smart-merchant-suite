-- Secure branch and warehouse lifecycle operations.
-- Clients may read locations, but all writes go through audited RPCs.
create or replace function public.create_cloud_branch(
  p_business_id uuid,
  p_name text,
  p_address text default null,
  p_phone text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_branch_id uuid;
  v_warehouse_id uuid;
  v_stamp timestamptz := now();
begin
  if auth.uid() is null
     or p_business_id is null
     or not public.has_business_permission(p_business_id, 'branches.manage') then
    raise exception 'branch management is not allowed' using errcode = '42501';
  end if;
  if length(v_name) < 1 or length(v_name) > 120
     or length(coalesce(p_address, '')) > 250
     or length(coalesce(p_phone, '')) > 40 then
    raise exception 'invalid branch details' using errcode = '22023';
  end if;

  perform 1 from public.businesses b
  where b.id = p_business_id
  for update;
  if not found then
    raise exception 'business not found' using errcode = 'P0002';
  end if;

  insert into public.cloud_branches (
    business_id, name, address, phone, is_active
  ) values (
    p_business_id, v_name, nullif(btrim(coalesce(p_address, '')), ''),
    nullif(btrim(coalesce(p_phone, '')), ''), true
  )
  returning id into v_branch_id;

  insert into public.cloud_warehouses (
    business_id, branch_id, name, is_active
  ) values (
    p_business_id, v_branch_id, 'المخزن الرئيسي', true
  )
  returning id into v_warehouse_id;

  insert into public.audit_events (
    business_id, actor_user_id, action_key, entity_type, entity_id, metadata, created_at
  ) values
    (p_business_id, auth.uid(), 'branches.create', 'cloud_branch',
     v_branch_id::text, jsonb_build_object('name', v_name, 'default_warehouse_id', v_warehouse_id), v_stamp),
    (p_business_id, auth.uid(), 'warehouses.create', 'cloud_warehouse',
     v_warehouse_id::text, jsonb_build_object('branch_id', v_branch_id, 'name', 'المخزن الرئيسي'), v_stamp);

  return v_branch_id;
end;
$function$;

create or replace function public.create_cloud_warehouse(
  p_business_id uuid,
  p_branch_id uuid,
  p_name text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_warehouse_id uuid;
begin
  if auth.uid() is null
     or p_business_id is null
     or p_branch_id is null
     or not public.has_business_permission(p_business_id, 'warehouses.manage') then
    raise exception 'warehouse management is not allowed' using errcode = '42501';
  end if;
  if length(v_name) < 1 or length(v_name) > 120 then
    raise exception 'invalid warehouse name' using errcode = '22023';
  end if;

  perform 1 from public.businesses b
  where b.id = p_business_id
  for update;
  if not found then
    raise exception 'business not found' using errcode = 'P0002';
  end if;

  perform 1 from public.cloud_branches b
  where b.id = p_branch_id
    and b.business_id = p_business_id
    and b.is_active = true
  for update;
  if not found then
    raise exception 'active branch not found in this business' using errcode = 'P0002';
  end if;

  insert into public.cloud_warehouses (
    business_id, branch_id, name, is_active
  ) values (p_business_id, p_branch_id, v_name, true)
  returning id into v_warehouse_id;

  insert into public.audit_events (
    business_id, actor_user_id, action_key, entity_type, entity_id, metadata
  ) values (
    p_business_id, auth.uid(), 'warehouses.create', 'cloud_warehouse',
    v_warehouse_id::text, jsonb_build_object('branch_id', p_branch_id, 'name', v_name)
  );

  return v_warehouse_id;
end;
$function$;

create or replace function public.set_cloud_warehouse_active(
  p_business_id uuid,
  p_warehouse_id uuid,
  p_is_active boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_branch_id uuid;
  v_current_active boolean;
  v_active_count integer;
begin
  if auth.uid() is null
     or p_business_id is null
     or p_warehouse_id is null
     or p_is_active is null
     or not public.has_business_permission(p_business_id, 'warehouses.manage') then
    raise exception 'warehouse management is not allowed' using errcode = '42501';
  end if;

  perform 1 from public.businesses b
  where b.id = p_business_id
  for update;
  if not found then
    raise exception 'business not found' using errcode = 'P0002';
  end if;

  select w.branch_id
  into v_branch_id
  from public.cloud_warehouses w
  where w.id = p_warehouse_id and w.business_id = p_business_id;
  if not found then
    raise exception 'warehouse not found in this business' using errcode = 'P0002';
  end if;

  perform 1 from public.cloud_branches b
  where b.id = v_branch_id and b.business_id = p_business_id
  for update;
  if not found then
    raise exception 'warehouse branch not found in this business' using errcode = 'P0002';
  end if;

  select w.is_active
  into v_current_active
  from public.cloud_warehouses w
  where w.id = p_warehouse_id and w.business_id = p_business_id
  for update;

  if p_is_active and not exists (
    select 1 from public.cloud_branches b
    where b.id = v_branch_id and b.business_id = p_business_id
      and b.is_active = true
  ) then
    raise exception 'cannot activate a warehouse under an inactive branch' using errcode = '23514';
  end if;

  if v_current_active = p_is_active then
    return;
  end if;

  if not p_is_active then
    if exists (
      select 1 from public.cloud_product_warehouse_stock s
      where s.business_id = p_business_id
        and s.warehouse_id = p_warehouse_id
        and s.quantity_scaled > 0
    ) then
      raise exception 'warehouse with stock cannot be deactivated' using errcode = '23514';
    end if;

    select count(*) into v_active_count
    from public.cloud_warehouses w
    where w.business_id = p_business_id
      and w.branch_id = v_branch_id
      and w.is_active = true;
    if v_active_count <= 1 then
      raise exception 'branch must keep at least one active warehouse' using errcode = '23514';
    end if;
  end if;

  update public.cloud_warehouses
  set is_active = p_is_active
  where id = p_warehouse_id and business_id = p_business_id;

  insert into public.audit_events (
    business_id, actor_user_id, action_key, entity_type, entity_id, metadata
  ) values (
    p_business_id, auth.uid(),
    case when p_is_active then 'warehouses.activate' else 'warehouses.deactivate' end,
    'cloud_warehouse', p_warehouse_id::text,
    jsonb_build_object('branch_id', v_branch_id, 'is_active', p_is_active)
  );
end;
$function$;

create or replace function public.set_cloud_branch_active(
  p_business_id uuid,
  p_branch_id uuid,
  p_is_active boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_current_active boolean;
  v_active_count integer;
  v_default_warehouse_id uuid;
begin
  if auth.uid() is null
     or p_business_id is null
     or p_branch_id is null
     or p_is_active is null
     or not public.has_business_permission(p_business_id, 'branches.manage') then
    raise exception 'branch management is not allowed' using errcode = '42501';
  end if;

  perform 1 from public.businesses b
  where b.id = p_business_id
  for update;
  if not found then
    raise exception 'business not found' using errcode = 'P0002';
  end if;

  select b.is_active into v_current_active
  from public.cloud_branches b
  where b.id = p_branch_id and b.business_id = p_business_id
  for update;
  if not found then
    raise exception 'branch not found in this business' using errcode = 'P0002';
  end if;

  if v_current_active = p_is_active then
    return;
  end if;

  if not p_is_active then
    if exists (
      select 1
      from public.cloud_product_warehouse_stock s
      join public.cloud_warehouses w
        on w.id = s.warehouse_id
       and w.business_id = s.business_id
      where w.business_id = p_business_id
        and w.branch_id = p_branch_id
        and s.quantity_scaled > 0
    ) then
      raise exception 'branch with stock cannot be deactivated' using errcode = '23514';
    end if;

    select count(*) into v_active_count
    from public.cloud_branches b
    where b.business_id = p_business_id and b.is_active = true;
    if v_active_count <= 1 then
      raise exception 'business must keep at least one active branch' using errcode = '23514';
    end if;

    insert into public.audit_events (
      business_id, actor_user_id, action_key, entity_type, entity_id, metadata
    )
    select p_business_id, auth.uid(), 'warehouses.deactivate',
      'cloud_warehouse', w.id::text,
      jsonb_build_object('branch_id', p_branch_id, 'reason', 'branch_deactivated')
    from public.cloud_warehouses w
    where w.business_id = p_business_id
      and w.branch_id = p_branch_id
      and w.is_active = true;

    update public.cloud_warehouses
    set is_active = false
    where business_id = p_business_id and branch_id = p_branch_id
      and is_active = true;
  else
    select w.id into v_default_warehouse_id
    from public.cloud_warehouses w
    where w.business_id = p_business_id and w.branch_id = p_branch_id
    order by w.created_at, w.id
    limit 1
    for update;

    if v_default_warehouse_id is null then
      raise exception 'branch must contain a warehouse before activation' using errcode = '23514';
    end if;
  end if;

  update public.cloud_branches
  set is_active = p_is_active
  where id = p_branch_id and business_id = p_business_id;

  if p_is_active and not exists (
    select 1 from public.cloud_warehouses w
    where w.business_id = p_business_id
      and w.branch_id = p_branch_id
      and w.is_active = true
  ) then
    update public.cloud_warehouses
    set is_active = true
    where id = v_default_warehouse_id and business_id = p_business_id;
    insert into public.audit_events (
      business_id, actor_user_id, action_key, entity_type, entity_id, metadata
    ) values (
      p_business_id, auth.uid(), 'warehouses.activate', 'cloud_warehouse',
      v_default_warehouse_id::text,
      jsonb_build_object('branch_id', p_branch_id, 'reason', 'branch_activated')
    );
  end if;

  insert into public.audit_events (
    business_id, actor_user_id, action_key, entity_type, entity_id, metadata
  ) values (
    p_business_id, auth.uid(),
    case when p_is_active then 'branches.activate' else 'branches.deactivate' end,
    'cloud_branch', p_branch_id::text,
    jsonb_build_object('is_active', p_is_active)
  );
end;
$function$;

revoke all on function public.create_cloud_branch(uuid, text, text, text) from public, anon;
revoke all on function public.create_cloud_warehouse(uuid, uuid, text) from public, anon;
revoke all on function public.set_cloud_warehouse_active(uuid, uuid, boolean) from public, anon;
revoke all on function public.set_cloud_branch_active(uuid, uuid, boolean) from public, anon;

grant execute on function public.create_cloud_branch(uuid, text, text, text) to authenticated;
grant execute on function public.create_cloud_warehouse(uuid, uuid, text) to authenticated;
grant execute on function public.set_cloud_warehouse_active(uuid, uuid, boolean) to authenticated;
grant execute on function public.set_cloud_branch_active(uuid, uuid, boolean) to authenticated;
