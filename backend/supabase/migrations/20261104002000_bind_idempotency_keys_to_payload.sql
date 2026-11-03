-- Bind idempotency keys to canonical request payloads.
-- Reusing an operation id with different data must fail instead of returning
-- a successful result for a different operation.
alter table public.cloud_sales
  add column if not exists request_hash text;

update public.cloud_sales s
set request_hash = encode(
  public.digest(
    jsonb_build_object(
      'paid_minor', s.paid_minor,
      'items', coalesce((
        select jsonb_agg(
          jsonb_build_object('product_id', i.product_id, 'quantity', i.quantity)
          order by i.product_id
        )
        from public.cloud_sale_items i
        where i.sale_id = s.id and i.business_id = s.business_id
      ), '[]'::jsonb)
    )::text,
    'sha256'
  ),
  'hex'
)
where request_hash is null;

alter table public.cloud_sales
  alter column request_hash set not null;

alter table public.cloud_inventory_movements
  add column if not exists request_hash text;

update public.cloud_inventory_movements m
set request_hash = encode(
  public.digest(
    jsonb_build_object(
      'product_id', m.product_id,
      'quantity_delta', m.quantity_delta,
      'reason', m.reason
    )::text,
    'sha256'
  ),
  'hex'
)
where request_hash is null;

alter table public.cloud_inventory_movements
  alter column request_hash set not null;

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
  v_movement_id uuid;
  v_existing_hash text;
  v_request_hash text;
begin
  if p_business_id is null or p_product_id is null or p_operation_id is null
     or p_quantity_delta is null or p_quantity_delta = 0
     or length(trim(coalesce(p_reason, ''))) = 0 then
    raise exception 'invalid inventory adjustment' using errcode = '22023';
  end if;

  if not public.has_business_permission(p_business_id, 'inventory.adjust') then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  v_request_hash := encode(
    public.digest(
      jsonb_build_object(
        'product_id', p_product_id,
        'quantity_delta', p_quantity_delta,
        'reason', trim(p_reason)
      )::text,
      'sha256'
    ),
    'hex'
  );

  -- Serialize retries that use the same operation identity.
  perform pg_advisory_xact_lock(hashtextextended(
    p_business_id::text || ':' || p_operation_id::text || ':' || p_product_id::text,
    0
  ));

  select id, request_hash
  into v_movement_id, v_existing_hash
  from public.cloud_inventory_movements
  where business_id = p_business_id
    and operation_id = p_operation_id
    and product_id = p_product_id;

  if v_movement_id is not null then
    if v_existing_hash is distinct from v_request_hash then
      raise exception 'idempotency key reused with different inventory payload'
        using errcode = '22023';
    end if;
    return v_movement_id;
  end if;

  update public.cloud_products
  set stock_quantity = stock_quantity + p_quantity_delta,
      updated_at = now()
  where id = p_product_id
    and business_id = p_business_id
    and is_active = true
    and stock_quantity + p_quantity_delta >= 0;

  if not found then
    raise exception 'product unavailable or insufficient stock' using errcode = '23514';
  end if;

  insert into public.cloud_inventory_movements (
    business_id, product_id, quantity_delta, reason, operation_id, actor_user_id, request_hash
  ) values (
    p_business_id, p_product_id, p_quantity_delta, trim(p_reason),
    p_operation_id, auth.uid(), v_request_hash
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
  v_sale_id uuid;
  v_existing_hash text;
  v_request_hash text;
  v_total bigint;
  v_item_count integer;
  v_found_count integer;
  v_item record;
begin
  if p_business_id is null or p_operation_id is null or p_paid_minor is null
     or p_paid_minor < 0 or p_items is null
     or jsonb_typeof(p_items) is distinct from 'array' then
    raise exception 'invalid sale payload' using errcode = '22023';
  end if;

  if jsonb_array_length(p_items) = 0 then
    raise exception 'invalid sale payload' using errcode = '22023';
  end if;

  if not public.has_business_permission(p_business_id, 'sales.create') then
    raise exception 'permission denied' using errcode = '42501';
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

  -- Canonicalize item order so equivalent payloads have the same fingerprint.
  select encode(
    public.digest(
      jsonb_build_object(
        'paid_minor', p_paid_minor,
        'items', jsonb_agg(
          jsonb_build_object('product_id', x.product_id, 'quantity', x.quantity)
          order by x.product_id
        )
      )::text,
      'sha256'
    ),
    'hex'
  )
  into v_request_hash
  from jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer);

  -- Serialize calls sharing the same tenant-scoped operation id.
  perform pg_advisory_xact_lock(hashtextextended(
    p_business_id::text || ':' || p_operation_id::text,
    0
  ));

  select id, request_hash
  into v_sale_id, v_existing_hash
  from public.cloud_sales
  where business_id = p_business_id and operation_id = p_operation_id;

  if v_sale_id is not null then
    if v_existing_hash is distinct from v_request_hash then
      raise exception 'idempotency key reused with different sale payload'
        using errcode = '22023';
    end if;
    return v_sale_id;
  end if;

  -- Lock all involved products in a stable order before checking and deducting stock.
  perform p.id
  from public.cloud_products p
  join jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer)
    on x.product_id = p.id
  where p.business_id = p_business_id and p.is_active = true
  order by p.id
  for update of p;

  select count(*) into v_found_count
  from jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer)
  join public.cloud_products p
    on p.id = x.product_id
   and p.business_id = p_business_id
   and p.is_active = true;

  if v_found_count <> v_item_count then
    raise exception 'product unavailable' using errcode = '23514';
  end if;

  select sum(p.price_minor * x.quantity)
  into v_total
  from jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer)
  join public.cloud_products p
    on p.id = x.product_id and p.business_id = p_business_id and p.is_active = true;

  if p_paid_minor > v_total then
    raise exception 'paid amount exceeds sale total' using errcode = '22023';
  end if;

  insert into public.cloud_sales (
    business_id, total_minor, paid_minor, operation_id, created_by, request_hash
  ) values (
    p_business_id, v_total, p_paid_minor, p_operation_id, auth.uid(), v_request_hash
  )
  on conflict (business_id, operation_id) do nothing
  returning id into v_sale_id;

  if v_sale_id is null then
    select id, request_hash
    into v_sale_id, v_existing_hash
    from public.cloud_sales
    where business_id = p_business_id and operation_id = p_operation_id;

    if v_existing_hash is distinct from v_request_hash then
      raise exception 'idempotency key reused with different sale payload'
        using errcode = '22023';
    end if;
    return v_sale_id;
  end if;

  for v_item in
    select p.id as product_id, p.stock_quantity, p.cost_minor, p.price_minor, x.quantity
    from jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer)
    join public.cloud_products p
      on p.id = x.product_id and p.business_id = p_business_id and p.is_active = true
    order by p.id
  loop
    if v_item.stock_quantity < v_item.quantity then
      raise exception 'insufficient stock' using errcode = '23514';
    end if;

    update public.cloud_products
    set stock_quantity = stock_quantity - v_item.quantity,
        updated_at = now()
    where id = v_item.product_id and business_id = p_business_id;

    insert into public.cloud_sale_items (
      business_id, sale_id, product_id, quantity,
      unit_price_minor, unit_cost_minor, line_total_minor
    ) values (
      p_business_id, v_sale_id, v_item.product_id, v_item.quantity,
      v_item.price_minor, v_item.cost_minor, v_item.price_minor * v_item.quantity
    );

    insert into public.cloud_inventory_movements (
      business_id, product_id, quantity_delta, reason, operation_id, actor_user_id, request_hash
    ) values (
      p_business_id, v_item.product_id, -v_item.quantity,
      'بيع فاتورة ' || v_sale_id::text, p_operation_id, auth.uid(),
      encode(
        public.digest(
          jsonb_build_object(
            'product_id', v_item.product_id,
            'quantity_delta', -v_item.quantity,
            'reason', 'بيع فاتورة ' || v_sale_id::text
          )::text,
          'sha256'
        ),
        'hex'
      )
    );
  end loop;

  return v_sale_id;
end;
$$;
