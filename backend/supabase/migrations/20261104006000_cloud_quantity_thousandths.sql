-- Convert all cloud stock quantities to the same thousandths scale as SQLite.
-- 1000 = one whole unit. Monetary amounts are not changed.
do $$
begin
  if exists (select 1 from public.cloud_products where stock_quantity > 9223372036854775)
     or exists (select 1 from public.cloud_inventory_movements
       where quantity_delta > 9223372036854775 or quantity_delta < -9223372036854775)
     or exists (select 1 from public.cloud_product_warehouse_stock
       where quantity > 9223372036854775)
     or exists (select 1 from public.cloud_sale_items where quantity > 9223372036854775) then
    raise exception 'quantity scale migration would overflow bigint';
  end if;
end;
$$;

alter table public.cloud_product_warehouse_stock rename column quantity to quantity_scaled;
alter table public.cloud_sale_items rename column quantity to quantity_scaled;
alter table public.cloud_sale_items alter column quantity_scaled type bigint using quantity_scaled::bigint;

update public.cloud_products set stock_quantity = stock_quantity * 1000;
update public.cloud_inventory_movements set quantity_delta = quantity_delta * 1000;
update public.cloud_product_warehouse_stock set quantity_scaled = quantity_scaled * 1000;
update public.cloud_sale_items set quantity_scaled = quantity_scaled * 1000;

update public.cloud_sales s
set request_hash = encode(public.digest(jsonb_build_object(
  'branch_id', s.branch_id,
  'warehouse_id', s.warehouse_id,
  'paid_minor', s.paid_minor,
  'items', coalesce((
    select jsonb_agg(jsonb_build_object(
      'product_id', i.product_id, 'quantity_scaled', i.quantity_scaled
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
  'quantity_delta_scaled', m.quantity_delta,
  'reason', m.reason
)::text, 'sha256'), 'hex');

comment on column public.cloud_products.stock_quantity is
  'Aggregate stock in integer thousandths; 1000 represents one whole unit.';
comment on column public.cloud_inventory_movements.quantity_delta is
  'Stock movement in integer thousandths; 1000 represents one whole unit.';
comment on column public.cloud_product_warehouse_stock.quantity_scaled is
  'Warehouse stock in integer thousandths; 1000 represents one whole unit.';
comment on column public.cloud_sale_items.quantity_scaled is
  'Sold quantity in integer thousandths; 1000 represents one whole unit.';

-- Keep newly inserted product opening balances in the renamed scaled column.
create or replace function public.create_cloud_product_default_balance()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.cloud_product_warehouse_stock (
    business_id, branch_id, warehouse_id, product_id, quantity_scaled
  ) values (
    new.business_id, new.default_branch_id, new.default_warehouse_id,
    new.id, new.stock_quantity
  );
  return new;
end;
$$;

-- Legacy adjustment callers pass whole units. New clients must pass scaled values
-- to the warehouse-aware overload.
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
    p_quantity_delta * 1000, p_reason, p_operation_id
  );
end;
$$;

create or replace function public.adjust_cloud_inventory(
  p_business_id uuid,
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_product_id uuid,
  p_quantity_delta_scaled bigint,
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
     or p_quantity_delta_scaled is null or p_quantity_delta_scaled = 0
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
    'product_id', p_product_id, 'quantity_delta_scaled', p_quantity_delta_scaled,
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

  insert into public.cloud_product_warehouse_stock (
    business_id, branch_id, warehouse_id, product_id, quantity_scaled
  ) values (
    p_business_id, p_branch_id, p_warehouse_id, p_product_id, 0
  ) on conflict (business_id, warehouse_id, product_id) do nothing;

  update public.cloud_product_warehouse_stock
  set quantity_scaled = quantity_scaled + p_quantity_delta_scaled,
      updated_at = now()
  where business_id = p_business_id and branch_id = p_branch_id
    and warehouse_id = p_warehouse_id and product_id = p_product_id
    and quantity_scaled + p_quantity_delta_scaled >= 0;
  if not found then
    raise exception 'warehouse stock unavailable or insufficient' using errcode = '23514';
  end if;

  update public.cloud_products
  set stock_quantity = stock_quantity + p_quantity_delta_scaled, updated_at = now()
  where id = p_product_id and business_id = p_business_id
    and stock_quantity + p_quantity_delta_scaled >= 0;
  if not found then
    raise exception 'aggregate stock update failed' using errcode = '23514';
  end if;

  insert into public.cloud_inventory_movements (
    business_id, branch_id, warehouse_id, product_id, quantity_delta,
    reason, operation_id, actor_user_id, request_hash
  ) values (
    p_business_id, p_branch_id, p_warehouse_id, p_product_id, p_quantity_delta_scaled,
    trim(p_reason), p_operation_id, auth.uid(), v_request_hash
  ) returning id into v_movement_id;
  return v_movement_id;
end;
$$;

-- Compatibility wrapper converts whole-unit legacy JSON into thousandths.
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
  v_scaled_items jsonb;
begin
  select b.id, w.id into v_branch_id, v_warehouse_id
  from public.cloud_branches b
  join public.cloud_warehouses w
    on w.business_id = b.business_id and w.branch_id = b.id
  where b.business_id = p_business_id and b.is_active and w.is_active
  order by b.created_at, w.created_at limit 1;

  select coalesce(jsonb_agg(jsonb_build_object(
    'product_id', x.product_id,
    'quantity_scaled', x.quantity::bigint * 1000
  )), '[]'::jsonb)
  into v_scaled_items
  from jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer);

  return public.create_cloud_sale(
    p_business_id, v_branch_id, v_warehouse_id,
    v_scaled_items, p_paid_minor, p_operation_id
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
  v_total numeric;
  v_item_count integer;
  v_found_count integer;
  v_item record;
  v_line_total bigint;
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
  from jsonb_to_recordset(p_items) as x(product_id uuid, quantity_scaled bigint);
  if v_item_count = 0 or v_item_count <> v_found_count
     or exists (
       select 1 from jsonb_to_recordset(p_items) as x(product_id uuid, quantity_scaled bigint)
       where x.product_id is null or x.quantity_scaled is null or x.quantity_scaled <= 0
     ) then
    raise exception 'invalid or duplicate sale items' using errcode = '22023';
  end if;

  select encode(public.digest(jsonb_build_object(
    'branch_id', p_branch_id, 'warehouse_id', p_warehouse_id,
    'paid_minor', p_paid_minor,
    'items', jsonb_agg(jsonb_build_object(
      'product_id', x.product_id, 'quantity_scaled', x.quantity_scaled
    ) order by x.product_id)
  )::text, 'sha256'), 'hex')
  into v_request_hash
  from jsonb_to_recordset(p_items) as x(product_id uuid, quantity_scaled bigint);

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
    business_id, branch_id, warehouse_id, product_id, quantity_scaled
  )
  select p_business_id, p_branch_id, p_warehouse_id, p.id, 0
  from public.cloud_products p
  join jsonb_to_recordset(p_items) as x(product_id uuid, quantity_scaled bigint)
    on x.product_id = p.id
  where p.business_id = p_business_id
  on conflict (business_id, warehouse_id, product_id) do nothing;

  perform p.id
  from public.cloud_products p
  join jsonb_to_recordset(p_items) as x(product_id uuid, quantity_scaled bigint)
    on x.product_id = p.id
  where p.business_id = p_business_id and p.is_active
  order by p.id for update of p;

  select count(*) into v_found_count
  from jsonb_to_recordset(p_items) as x(product_id uuid, quantity_scaled bigint)
  join public.cloud_products p
    on p.id = x.product_id and p.business_id = p_business_id and p.is_active;
  if v_found_count <> v_item_count then
    raise exception 'product unavailable' using errcode = '23514';
  end if;

  select sum(((p.price_minor::numeric * x.quantity_scaled) + 500) / 1000)
  into v_total
  from jsonb_to_recordset(p_items) as x(product_id uuid, quantity_scaled bigint)
  join public.cloud_products p
    on p.id = x.product_id and p.business_id = p_business_id and p.is_active;
  if p_paid_minor > v_total then
    raise exception 'paid amount exceeds sale total' using errcode = '22023';
  end if;

  insert into public.cloud_sales (
    business_id, branch_id, warehouse_id, total_minor, paid_minor,
    operation_id, created_by, request_hash
  ) values (
    p_business_id, p_branch_id, p_warehouse_id, v_total::bigint,
    p_paid_minor, p_operation_id, auth.uid(), v_request_hash
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
      x.quantity_scaled, s.quantity_scaled as warehouse_quantity_scaled
    from jsonb_to_recordset(p_items) as x(product_id uuid, quantity_scaled bigint)
    join public.cloud_products p
      on p.id = x.product_id and p.business_id = p_business_id and p.is_active
    join public.cloud_product_warehouse_stock s
      on s.business_id = p_business_id and s.branch_id = p_branch_id
     and s.warehouse_id = p_warehouse_id and s.product_id = p.id
    order by p.id
  loop
    if v_item.warehouse_quantity_scaled < v_item.quantity_scaled
       or v_item.stock_quantity < v_item.quantity_scaled then
      raise exception 'insufficient warehouse stock' using errcode = '23514';
    end if;

    v_line_total := (((v_item.price_minor::numeric * v_item.quantity_scaled) + 500) / 1000)::bigint;

    update public.cloud_product_warehouse_stock
    set quantity_scaled = quantity_scaled - v_item.quantity_scaled,
        updated_at = now()
    where business_id = p_business_id and branch_id = p_branch_id
      and warehouse_id = p_warehouse_id and product_id = v_item.product_id
      and quantity_scaled >= v_item.quantity_scaled;
    if not found then
      raise exception 'insufficient warehouse stock' using errcode = '23514';
    end if;

    update public.cloud_products
    set stock_quantity = stock_quantity - v_item.quantity_scaled, updated_at = now()
    where id = v_item.product_id and business_id = p_business_id
      and stock_quantity >= v_item.quantity_scaled;
    if not found then
      raise exception 'aggregate stock update failed' using errcode = '23514';
    end if;

    insert into public.cloud_sale_items (
      business_id, sale_id, product_id, quantity_scaled,
      unit_price_minor, unit_cost_minor, line_total_minor
    ) values (
      p_business_id, v_sale_id, v_item.product_id, v_item.quantity_scaled,
      v_item.price_minor, v_item.cost_minor, v_line_total
    );

    insert into public.cloud_inventory_movements (
      business_id, branch_id, warehouse_id, product_id, quantity_delta,
      reason, operation_id, actor_user_id, request_hash
    ) values (
      p_business_id, p_branch_id, p_warehouse_id, v_item.product_id,
      -v_item.quantity_scaled, 'بيع فاتورة ' || v_sale_id::text,
      p_operation_id, auth.uid(),
      encode(public.digest(jsonb_build_object(
        'branch_id', p_branch_id, 'warehouse_id', p_warehouse_id,
        'product_id', v_item.product_id,
        'quantity_delta_scaled', -v_item.quantity_scaled,
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
