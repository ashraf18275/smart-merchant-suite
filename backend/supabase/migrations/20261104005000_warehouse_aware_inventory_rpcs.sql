-- Recompute historical request fingerprints after assigning each document
-- to its default branch and warehouse.
update public.cloud_sales s
set request_hash = encode(public.digest(jsonb_build_object(
  'branch_id', s.branch_id,
  'warehouse_id', s.warehouse_id,
  'paid_minor', s.paid_minor,
  'items', coalesce((
    select jsonb_agg(jsonb_build_object(
      'product_id', i.product_id, 'quantity', i.quantity
    ) order by i.product_id)
    from public.cloud_sale_items i
    where i.sale_id = s.id and i.business_id = s.business_id
  ), '[]'::jsonb)
)::text, 'sha256'), 'hex');

update public.cloud_inventory_movements m
set request_hash = encode(public.digest(jsonb_build_object(
  'branch_id', m.branch_id,
  'warehouse_id', m.warehouse_id,
  'product_id', m.product_id,
  'quantity_delta', m.quantity_delta,
  'reason', m.reason
)::text, 'sha256'), 'hex');

-- Keep aggregate product stock and per-warehouse balances in sync.
-- Legacy RPC signatures remain as wrappers targeting the business default warehouse.
create or replace function public.assign_cloud_product_default_warehouse()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_branch_id uuid;
  v_warehouse_id uuid;
begin
  if new.default_branch_id is null or new.default_warehouse_id is null then
    select b.id, w.id into v_branch_id, v_warehouse_id
    from public.cloud_branches b
    join public.cloud_warehouses w
      on w.business_id = b.business_id and w.branch_id = b.id
    where b.business_id = new.business_id and b.is_active and w.is_active
    order by b.created_at, w.created_at
    limit 1;
    new.default_branch_id := coalesce(new.default_branch_id, v_branch_id);
    new.default_warehouse_id := coalesce(new.default_warehouse_id, v_warehouse_id);
  end if;
  if new.default_branch_id is null or new.default_warehouse_id is null then
    raise exception 'business requires an active branch and warehouse';
  end if;
  return new;
end;
$$;

create or replace function public.create_cloud_product_default_balance()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.cloud_product_warehouse_stock (
    business_id, branch_id, warehouse_id, product_id, quantity
  ) values (
    new.business_id, new.default_branch_id, new.default_warehouse_id,
    new.id, new.stock_quantity
  );
  return new;
end;
$$;

drop trigger if exists cloud_products_assign_default_warehouse on public.cloud_products;
create trigger cloud_products_assign_default_warehouse
  before insert on public.cloud_products
  for each row execute function public.assign_cloud_product_default_warehouse();

drop trigger if exists cloud_products_create_default_balance on public.cloud_products;
create trigger cloud_products_create_default_balance
  after insert on public.cloud_products
  for each row execute function public.create_cloud_product_default_balance();

create or replace function public.adjust_cloud_inventory(
  p_business_id uuid,
  p_product_id uuid,
  p_quantity_delta bigint,
  p_reason text,
  p_operation_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_branch_id uuid;
  v_warehouse_id uuid;
begin
  select default_branch_id, default_warehouse_id
  into v_branch_id, v_warehouse_id
  from public.cloud_products
  where id = p_product_id and business_id = p_business_id;
  if v_branch_id is null or v_warehouse_id is null then
    raise exception 'product or default warehouse unavailable' using errcode = '23514';
  end if;
  return public.adjust_cloud_inventory(
    p_business_id, v_branch_id, v_warehouse_id, p_product_id,
    p_quantity_delta, p_reason, p_operation_id
  );
end;
$$;

create or replace function public.adjust_cloud_inventory(
  p_business_id uuid,
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_product_id uuid,
  p_quantity_delta bigint,
  p_reason text,
  p_operation_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_movement_id uuid;
  v_existing_hash text;
  v_request_hash text;
begin
  if p_business_id is null or p_branch_id is null or p_warehouse_id is null
     or p_product_id is null or p_operation_id is null
     or p_quantity_delta is null or p_quantity_delta = 0
     or length(trim(coalesce(p_reason, ''))) = 0 then
    raise exception 'invalid inventory adjustment' using errcode = '22023';
  end if;
  if not public.has_business_permission(p_business_id, 'inventory.adjust') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.cloud_warehouses w
    where w.id = p_warehouse_id and w.business_id = p_business_id
      and w.branch_id = p_branch_id and w.is_active
  ) then
    raise exception 'warehouse unavailable' using errcode = '23514';
  end if;

  v_request_hash := encode(public.digest(jsonb_build_object(
    'branch_id', p_branch_id, 'warehouse_id', p_warehouse_id,
    'product_id', p_product_id, 'quantity_delta', p_quantity_delta,
    'reason', trim(p_reason)
  )::text, 'sha256'), 'hex');

  perform pg_advisory_xact_lock(hashtextextended(
    p_business_id::text || ':' || p_operation_id::text || ':' || p_product_id::text, 0
  ));

  select id, request_hash into v_movement_id, v_existing_hash
  from public.cloud_inventory_movements
  where business_id = p_business_id and operation_id = p_operation_id
    and product_id = p_product_id;
  if v_movement_id is not null then
    if v_existing_hash is distinct from v_request_hash then
      raise exception 'idempotency key reused with different inventory payload'
        using errcode = '22023';
    end if;
    return v_movement_id;
  end if;

  perform 1 from public.cloud_products p
  where p.id = p_product_id and p.business_id = p_business_id and p.is_active
  for update;
  if not found then
    raise exception 'product unavailable' using errcode = '23514';
  end if;

  update public.cloud_product_warehouse_stock
  set quantity = quantity + p_quantity_delta, updated_at = now()
  where business_id = p_business_id and branch_id = p_branch_id
    and warehouse_id = p_warehouse_id and product_id = p_product_id
    and quantity + p_quantity_delta >= 0;
  if not found then
    raise exception 'warehouse stock unavailable or insufficient' using errcode = '23514';
  end if;

  update public.cloud_products
  set stock_quantity = stock_quantity + p_quantity_delta, updated_at = now()
  where id = p_product_id and business_id = p_business_id
    and stock_quantity + p_quantity_delta >= 0;
  if not found then
    raise exception 'aggregate stock update failed' using errcode = '23514';
  end if;

  insert into public.cloud_inventory_movements (
    business_id, branch_id, warehouse_id, product_id, quantity_delta,
    reason, operation_id, actor_user_id, request_hash
  ) values (
    p_business_id, p_branch_id, p_warehouse_id, p_product_id, p_quantity_delta,
    trim(p_reason), p_operation_id, auth.uid(), v_request_hash
  ) returning id into v_movement_id;
  return v_movement_id;
end;
$$;

create or replace function public.create_cloud_sale(
  p_business_id uuid,
  p_items jsonb,
  p_paid_minor bigint,
  p_operation_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_branch_id uuid;
  v_warehouse_id uuid;
begin
  select b.id, w.id into v_branch_id, v_warehouse_id
  from public.cloud_branches b
  join public.cloud_warehouses w
    on w.business_id = b.business_id and w.branch_id = b.id
  where b.business_id = p_business_id and b.is_active and w.is_active
  order by b.created_at, w.created_at limit 1;
  return public.create_cloud_sale(
    p_business_id, v_branch_id, v_warehouse_id, p_items, p_paid_minor, p_operation_id
  );
end;
$$;

create or replace function public.create_cloud_sale(
  p_business_id uuid,
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_items jsonb,
  p_paid_minor bigint,
  p_operation_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sale_id uuid;
  v_existing_hash text;
  v_request_hash text;
  v_total bigint;
  v_item_count integer;
  v_found_count integer;
  v_item record;
begin
  if p_business_id is null or p_branch_id is null or p_warehouse_id is null
     or p_operation_id is null or p_paid_minor is null or p_paid_minor < 0
     or p_items is null or jsonb_typeof(p_items) is distinct from 'array'
     or jsonb_array_length(p_items) = 0 then
    raise exception 'invalid sale payload' using errcode = '22023';
  end if;
  if not public.has_business_permission(p_business_id, 'sales.create') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.cloud_warehouses w
    where w.id = p_warehouse_id and w.business_id = p_business_id
      and w.branch_id = p_branch_id and w.is_active
  ) then
    raise exception 'warehouse unavailable' using errcode = '23514';
  end if;

  select count(*), count(distinct x.product_id)
  into v_item_count, v_found_count
  from jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer);
  if v_item_count = 0 or v_item_count <> v_found_count
     or exists (
       select 1 from jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer)
       where x.product_id is null or x.quantity is null or x.quantity <= 0
     ) then
    raise exception 'invalid or duplicate sale items' using errcode = '22023';
  end if;

  select encode(public.digest(jsonb_build_object(
    'branch_id', p_branch_id, 'warehouse_id', p_warehouse_id,
    'paid_minor', p_paid_minor,
    'items', jsonb_agg(jsonb_build_object(
      'product_id', x.product_id, 'quantity', x.quantity
    ) order by x.product_id)
  )::text, 'sha256'), 'hex')
  into v_request_hash
  from jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer);

  perform pg_advisory_xact_lock(hashtextextended(
    p_business_id::text || ':' || p_operation_id::text, 0
  ));

  select id, request_hash into v_sale_id, v_existing_hash
  from public.cloud_sales
  where business_id = p_business_id and operation_id = p_operation_id;
  if v_sale_id is not null then
    if v_existing_hash is distinct from v_request_hash then
      raise exception 'idempotency key reused with different sale payload'
        using errcode = '22023';
    end if;
    return v_sale_id;
  end if;

  insert into public.cloud_product_warehouse_stock (
    business_id, branch_id, warehouse_id, product_id, quantity
  )
  select p_business_id, p_branch_id, p_warehouse_id, p.id, 0
  from public.cloud_products p
  join jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer)
    on x.product_id = p.id
  where p.business_id = p_business_id
  on conflict (business_id, warehouse_id, product_id) do nothing;

  perform p.id
  from public.cloud_products p
  join jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer)
    on x.product_id = p.id
  where p.business_id = p_business_id and p.is_active
  order by p.id for update of p;

  select count(*) into v_found_count
  from jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer)
  join public.cloud_products p
    on p.id = x.product_id and p.business_id = p_business_id and p.is_active;
  if v_found_count <> v_item_count then
    raise exception 'product unavailable' using errcode = '23514';
  end if;

  select sum(p.price_minor * x.quantity)
  into v_total
  from jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer)
  join public.cloud_products p
    on p.id = x.product_id and p.business_id = p_business_id and p.is_active;
  if p_paid_minor > v_total then
    raise exception 'paid amount exceeds sale total' using errcode = '22023';
  end if;

  insert into public.cloud_sales (
    business_id, branch_id, warehouse_id, total_minor, paid_minor,
    operation_id, created_by, request_hash
  ) values (
    p_business_id, p_branch_id, p_warehouse_id, v_total, p_paid_minor,
    p_operation_id, auth.uid(), v_request_hash
  ) on conflict (business_id, operation_id) do nothing
  returning id into v_sale_id;

  if v_sale_id is null then
    select id, request_hash into v_sale_id, v_existing_hash
    from public.cloud_sales
    where business_id = p_business_id and operation_id = p_operation_id;
    if v_existing_hash is distinct from v_request_hash then
      raise exception 'idempotency key reused with different sale payload'
        using errcode = '22023';
    end if;
    return v_sale_id;
  end if;

  for v_item in
    select p.id as product_id, p.stock_quantity, p.cost_minor, p.price_minor,
      x.quantity, s.quantity as warehouse_quantity
    from jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer)
    join public.cloud_products p
      on p.id = x.product_id and p.business_id = p_business_id and p.is_active
    join public.cloud_product_warehouse_stock s
      on s.business_id = p_business_id and s.branch_id = p_branch_id
     and s.warehouse_id = p_warehouse_id and s.product_id = p.id
    order by p.id
  loop
    if v_item.warehouse_quantity < v_item.quantity
       or v_item.stock_quantity < v_item.quantity then
      raise exception 'insufficient warehouse stock' using errcode = '23514';
    end if;

    update public.cloud_product_warehouse_stock
    set quantity = quantity - v_item.quantity, updated_at = now()
    where business_id = p_business_id and branch_id = p_branch_id
      and warehouse_id = p_warehouse_id and product_id = v_item.product_id
      and quantity >= v_item.quantity;
    if not found then
      raise exception 'insufficient warehouse stock' using errcode = '23514';
    end if;

    update public.cloud_products
    set stock_quantity = stock_quantity - v_item.quantity, updated_at = now()
    where id = v_item.product_id and business_id = p_business_id
      and stock_quantity >= v_item.quantity;
    if not found then
      raise exception 'aggregate stock update failed' using errcode = '23514';
    end if;

    insert into public.cloud_sale_items (
      business_id, sale_id, product_id, quantity,
      unit_price_minor, unit_cost_minor, line_total_minor
    ) values (
      p_business_id, v_sale_id, v_item.product_id, v_item.quantity,
      v_item.price_minor, v_item.cost_minor, v_item.price_minor * v_item.quantity
    );

    insert into public.cloud_inventory_movements (
      business_id, branch_id, warehouse_id, product_id, quantity_delta,
      reason, operation_id, actor_user_id, request_hash
    ) values (
      p_business_id, p_branch_id, p_warehouse_id, v_item.product_id,
      -v_item.quantity, 'بيع فاتورة ' || v_sale_id::text,
      p_operation_id, auth.uid(),
      encode(public.digest(jsonb_build_object(
        'branch_id', p_branch_id, 'warehouse_id', p_warehouse_id,
        'product_id', v_item.product_id, 'quantity_delta', -v_item.quantity,
        'reason', 'بيع فاتورة ' || v_sale_id::text
      )::text, 'sha256'), 'hex')
    );
  end loop;
  return v_sale_id;
end;
$$;

revoke all on function public.adjust_cloud_inventory(uuid, uuid, bigint, text, uuid) from public;
revoke all on function public.adjust_cloud_inventory(uuid, uuid, uuid, uuid, bigint, text, uuid) from public;
revoke all on function public.create_cloud_sale(uuid, jsonb, bigint, uuid) from public;
revoke all on function public.create_cloud_sale(uuid, uuid, uuid, jsonb, bigint, uuid) from public;
grant execute on function public.adjust_cloud_inventory(uuid, uuid, bigint, text, uuid) to authenticated;
grant execute on function public.adjust_cloud_inventory(uuid, uuid, uuid, uuid, bigint, text, uuid) to authenticated;
grant execute on function public.create_cloud_sale(uuid, jsonb, bigint, uuid) to authenticated;
grant execute on function public.create_cloud_sale(uuid, uuid, uuid, jsonb, bigint, uuid) to authenticated;
