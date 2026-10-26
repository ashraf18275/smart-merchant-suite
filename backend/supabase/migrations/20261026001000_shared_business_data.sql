-- Tenant-scoped cloud business data.
-- All sale and inventory mutations go through transactional, idempotent RPCs.
create table if not exists public.cloud_products (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  sku text,
  cost_minor bigint not null check (cost_minor >= 0),
  price_minor bigint not null check (price_minor >= 0),
  stock_quantity bigint not null default 0 check (stock_quantity >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id) on delete restrict,
  unique (id, business_id)
);
create unique index if not exists cloud_products_business_sku_unique
  on public.cloud_products(business_id, sku) where sku is not null and length(trim(sku)) > 0;
create index if not exists cloud_products_business_name_idx
  on public.cloud_products(business_id, name);

create table if not exists public.cloud_inventory_movements (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  product_id uuid not null,
  quantity_delta bigint not null check (quantity_delta <> 0),
  reason text not null check (length(trim(reason)) > 0),
  operation_id uuid not null,
  actor_user_id uuid not null default auth.uid() references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  foreign key (product_id, business_id)
    references public.cloud_products(id, business_id) on delete restrict,
  unique (business_id, operation_id, product_id)
);

create table if not exists public.cloud_sales (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  total_minor bigint not null check (total_minor >= 0),
  paid_minor bigint not null check (paid_minor >= 0 and paid_minor <= total_minor),
  operation_id uuid not null,
  created_by uuid not null default auth.uid() references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (business_id, operation_id),
  unique (id, business_id)
);
create index if not exists cloud_sales_business_created_idx
  on public.cloud_sales(business_id, created_at desc);

create table if not exists public.cloud_sale_items (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  sale_id uuid not null,
  product_id uuid not null,
  quantity integer not null check (quantity > 0),
  unit_price_minor bigint not null check (unit_price_minor >= 0),
  unit_cost_minor bigint not null check (unit_cost_minor >= 0),
  line_total_minor bigint not null check (line_total_minor >= 0),
  created_at timestamptz not null default now(),
  foreign key (sale_id, business_id)
    references public.cloud_sales(id, business_id) on delete restrict,
  foreign key (product_id, business_id)
    references public.cloud_products(id, business_id) on delete restrict
);

create table if not exists public.cloud_expenses (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  description text not null check (length(trim(description)) > 0),
  category text not null check (length(trim(category)) > 0),
  amount_minor bigint not null check (amount_minor > 0),
  created_by uuid not null default auth.uid() references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists cloud_expenses_business_created_idx
  on public.cloud_expenses(business_id, created_at desc);

alter table public.cloud_products enable row level security;
alter table public.cloud_inventory_movements enable row level security;
alter table public.cloud_sales enable row level security;
alter table public.cloud_sale_items enable row level security;
alter table public.cloud_expenses enable row level security;

drop policy if exists cloud_products_select_authorized on public.cloud_products;
create policy cloud_products_select_authorized on public.cloud_products
  for select to authenticated
  using (
    public.has_business_permission(business_id, 'products.view')
    or public.has_business_permission(business_id, 'sales.create')
    or public.has_business_permission(business_id, 'inventory.view')
  );

drop policy if exists cloud_products_insert_authorized on public.cloud_products;
create policy cloud_products_insert_authorized on public.cloud_products
  for insert to authenticated
  with check (public.has_business_permission(business_id, 'products.create'));

drop policy if exists cloud_products_update_authorized on public.cloud_products;
create policy cloud_products_update_authorized on public.cloud_products
  for update to authenticated
  using (public.has_business_permission(business_id, 'products.edit'))
  with check (public.has_business_permission(business_id, 'products.edit'));

drop policy if exists cloud_inventory_select_authorized on public.cloud_inventory_movements;
create policy cloud_inventory_select_authorized on public.cloud_inventory_movements
  for select to authenticated
  using (
    public.has_business_permission(business_id, 'inventory.view')
    or public.has_business_permission(business_id, 'audit.view')
  );

drop policy if exists cloud_sales_select_authorized on public.cloud_sales;
create policy cloud_sales_select_authorized on public.cloud_sales
  for select to authenticated
  using (
    public.has_business_permission(business_id, 'sales.view')
    or public.has_business_permission(business_id, 'reports.view')
  );

drop policy if exists cloud_sale_items_select_authorized on public.cloud_sale_items;
create policy cloud_sale_items_select_authorized on public.cloud_sale_items
  for select to authenticated
  using (
    public.has_business_permission(business_id, 'sales.view')
    or public.has_business_permission(business_id, 'reports.view')
  );

drop policy if exists cloud_expenses_select_authorized on public.cloud_expenses;
create policy cloud_expenses_select_authorized on public.cloud_expenses
  for select to authenticated
  using (public.has_business_permission(business_id, 'expenses.view'));

drop policy if exists cloud_expenses_insert_authorized on public.cloud_expenses;
create policy cloud_expenses_insert_authorized on public.cloud_expenses
  for insert to authenticated
  with check (public.has_business_permission(business_id, 'expenses.create'));

drop policy if exists cloud_expenses_update_authorized on public.cloud_expenses;
create policy cloud_expenses_update_authorized on public.cloud_expenses
  for update to authenticated
  using (public.has_business_permission(business_id, 'expenses.edit'))
  with check (public.has_business_permission(business_id, 'expenses.edit'));

drop policy if exists cloud_expenses_delete_authorized on public.cloud_expenses;
create policy cloud_expenses_delete_authorized on public.cloud_expenses
  for delete to authenticated
  using (public.has_business_permission(business_id, 'expenses.delete'));

-- Do not allow clients to change stock balances or create sales/items/movements directly.
-- Revoke table-level grants first; column-level grants below are intentional allowlists.
revoke insert, update, delete on public.cloud_products from anon, authenticated;
revoke insert, update, delete on public.cloud_expenses from anon, authenticated;
revoke insert, update, delete on public.cloud_inventory_movements from anon, authenticated;
revoke insert, update, delete on public.cloud_sales from anon, authenticated;
revoke insert, update, delete on public.cloud_sale_items from anon, authenticated;
revoke update on public.cloud_products from anon, authenticated;
grant insert (business_id, name, sku, cost_minor, price_minor)
  on public.cloud_products to authenticated;
grant update (name, sku, cost_minor, price_minor)
  on public.cloud_products to authenticated;
grant insert (business_id, description, category, amount_minor)
  on public.cloud_expenses to authenticated;
grant update (description, category, amount_minor)
  on public.cloud_expenses to authenticated;
grant delete on public.cloud_expenses to authenticated;

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
begin
  if not public.has_business_permission(p_business_id, 'inventory.adjust') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_quantity_delta = 0 or length(trim(coalesce(p_reason, ''))) = 0 then
    raise exception 'invalid inventory adjustment' using errcode = '22023';
  end if;

  select id into v_movement_id
  from public.cloud_inventory_movements
  where business_id = p_business_id
    and operation_id = p_operation_id
    and product_id = p_product_id;
  if v_movement_id is not null then
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
    business_id, product_id, quantity_delta, reason, operation_id, actor_user_id
  ) values (
    p_business_id, p_product_id, p_quantity_delta, trim(p_reason), p_operation_id, auth.uid()
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
  v_total bigint;
  v_item_count integer;
  v_found_count integer;
  v_item record;
begin
  if not public.has_business_permission(p_business_id, 'sales.create') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_paid_minor < 0
     or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 then
    raise exception 'invalid sale payload' using errcode = '22023';
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

  select id into v_sale_id
  from public.cloud_sales
  where business_id = p_business_id and operation_id = p_operation_id;
  if v_sale_id is not null then
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
    business_id, total_minor, paid_minor, operation_id, created_by
  ) values (
    p_business_id, v_total, p_paid_minor, p_operation_id, auth.uid()
  )
  on conflict (business_id, operation_id) do nothing
  returning id into v_sale_id;

  if v_sale_id is null then
    select id into v_sale_id
    from public.cloud_sales
    where business_id = p_business_id and operation_id = p_operation_id;
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
      business_id, product_id, quantity_delta, reason, operation_id, actor_user_id
    ) values (
      p_business_id, v_item.product_id, -v_item.quantity,
      'بيع فاتورة ' || v_sale_id::text, p_operation_id, auth.uid()
    );
  end loop;

  return v_sale_id;
end;
$$;

create or replace function public.set_cloud_product_active(
  p_business_id uuid,
  p_product_id uuid,
  p_is_active boolean
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.has_business_permission(p_business_id, 'products.archive') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  update public.cloud_products
  set is_active = p_is_active, updated_at = now()
  where id = p_product_id and business_id = p_business_id;
  return found;
end;
$$;

revoke all on function public.adjust_cloud_inventory(uuid, uuid, bigint, text, uuid) from public;
revoke all on function public.create_cloud_sale(uuid, jsonb, bigint, uuid) from public;
revoke all on function public.set_cloud_product_active(uuid, uuid, boolean) from public;
grant execute on function public.adjust_cloud_inventory(uuid, uuid, bigint, text, uuid) to authenticated;
grant execute on function public.create_cloud_sale(uuid, jsonb, bigint, uuid) to authenticated;
grant execute on function public.set_cloud_product_active(uuid, uuid, boolean) to authenticated;
