-- Tenant-scoped sales/purchase returns with stock reversal, account credits and tender refunds.
-- Returns are append-only and every operation is idempotent.

-- Composite unique indexes allow every return line to enforce same-tenant source references.
create unique index if not exists cloud_sale_items_id_business_unique
  on public.cloud_sale_items(id, business_id);
create unique index if not exists cloud_purchase_items_id_business_unique
  on public.cloud_purchase_items(id, business_id);

-- PostgreSQL foreign keys require an explicit unique constraint (not merely
-- a same-named pre-existing standalone index) for the referenced column pair.
do $
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'cloud_sale_items_id_business_key'
      and conrelid = 'public.cloud_sale_items'::regclass
  ) then
    alter table public.cloud_sale_items
      add constraint cloud_sale_items_id_business_key unique (id, business_id);
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'cloud_purchase_items_id_business_key'
      and conrelid = 'public.cloud_purchase_items'::regclass
  ) then
    alter table public.cloud_purchase_items
      add constraint cloud_purchase_items_id_business_key unique (id, business_id);
  end if;
end;
$;
create table if not exists public.cloud_sale_returns (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  sale_id uuid not null,
  customer_id uuid,
  total_minor bigint not null check (total_minor > 0),
  refunded_minor bigint not null check (refunded_minor >= 0 and refunded_minor <= total_minor),
  operation_id uuid not null,
  request_hash text not null,
  actor_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (id, business_id),
  unique (business_id, operation_id),
  foreign key (sale_id, business_id)
    references public.cloud_sales(id, business_id) on delete restrict,
  foreign key (customer_id, business_id)
    references public.cloud_customers(id, business_id) on delete restrict
);

create table if not exists public.cloud_sale_return_items (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  return_id uuid not null,
  sale_item_id uuid not null,
  product_id uuid not null,
  quantity_scaled bigint not null check (quantity_scaled > 0),
  amount_minor bigint not null check (amount_minor >= 0),
  created_at timestamptz not null default now(),
  unique (return_id, sale_item_id),
  foreign key (return_id, business_id)
    references public.cloud_sale_returns(id, business_id) on delete restrict,
  foreign key (sale_item_id, business_id)
    references public.cloud_sale_items(id, business_id) on delete restrict,
  foreign key (product_id, business_id)
    references public.cloud_products(id, business_id) on delete restrict
);

create table if not exists public.cloud_sale_return_refunds (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  return_id uuid not null,
  sale_id uuid not null,
  amount_minor bigint not null check (amount_minor > 0),
  payment_method text not null check (payment_method in ('cash', 'card', 'bank_transfer', 'wallet')),
  cash_session_id uuid,
  operation_id uuid not null,
  request_hash text not null,
  actor_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (business_id, operation_id),
  foreign key (return_id, business_id)
    references public.cloud_sale_returns(id, business_id) on delete restrict,
  foreign key (sale_id, business_id)
    references public.cloud_sales(id, business_id) on delete restrict,
  foreign key (cash_session_id, business_id)
    references public.cloud_cash_sessions(id, business_id) on delete restrict,
  check (cash_session_id is null or payment_method = 'cash')
);

create table if not exists public.cloud_purchase_returns (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  purchase_id uuid not null,
  supplier_id uuid not null,
  total_minor bigint not null check (total_minor > 0),
  refunded_minor bigint not null check (refunded_minor >= 0 and refunded_minor <= total_minor),
  operation_id uuid not null,
  request_hash text not null,
  actor_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (id, business_id),
  unique (business_id, operation_id),
  foreign key (purchase_id, business_id)
    references public.cloud_purchases(id, business_id) on delete restrict,
  foreign key (supplier_id, business_id)
    references public.cloud_suppliers(id, business_id) on delete restrict
);

create table if not exists public.cloud_purchase_return_items (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  return_id uuid not null,
  purchase_item_id uuid not null,
  product_id uuid not null,
  quantity_scaled bigint not null check (quantity_scaled > 0),
  amount_minor bigint not null check (amount_minor >= 0),
  created_at timestamptz not null default now(),
  unique (return_id, purchase_item_id),
  foreign key (return_id, business_id)
    references public.cloud_purchase_returns(id, business_id) on delete restrict,
  foreign key (purchase_item_id, business_id)
    references public.cloud_purchase_items(id, business_id) on delete restrict,
  foreign key (product_id, business_id)
    references public.cloud_products(id, business_id) on delete restrict
);

create table if not exists public.cloud_purchase_return_refunds (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  return_id uuid not null,
  purchase_id uuid not null,
  amount_minor bigint not null check (amount_minor > 0),
  payment_method text not null check (payment_method in ('cash', 'card', 'bank_transfer', 'wallet')),
  cash_session_id uuid,
  operation_id uuid not null,
  request_hash text not null,
  actor_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (business_id, operation_id),
  foreign key (return_id, business_id)
    references public.cloud_purchase_returns(id, business_id) on delete restrict,
  foreign key (purchase_id, business_id)
    references public.cloud_purchases(id, business_id) on delete restrict,
  foreign key (cash_session_id, business_id)
    references public.cloud_cash_sessions(id, business_id) on delete restrict,
  check (cash_session_id is null or payment_method = 'cash')
);

create index if not exists cloud_sale_returns_sale_idx
  on public.cloud_sale_returns(business_id, sale_id, created_at);
create index if not exists cloud_purchase_returns_purchase_idx
  on public.cloud_purchase_returns(business_id, purchase_id, created_at);

alter table public.cloud_sale_returns enable row level security;
alter table public.cloud_sale_return_items enable row level security;
alter table public.cloud_sale_return_refunds enable row level security;
alter table public.cloud_purchase_returns enable row level security;
alter table public.cloud_purchase_return_items enable row level security;
alter table public.cloud_purchase_return_refunds enable row level security;

drop policy if exists cloud_sale_returns_select_authorized on public.cloud_sale_returns;
create policy cloud_sale_returns_select_authorized on public.cloud_sale_returns
  for select to authenticated using (
    public.has_business_permission(business_id, 'sales.view')
    or public.has_business_permission(business_id, 'sales.return')
    or public.has_business_permission(business_id, 'accounts.view')
  );
drop policy if exists cloud_sale_return_items_select_authorized on public.cloud_sale_return_items;
create policy cloud_sale_return_items_select_authorized on public.cloud_sale_return_items
  for select to authenticated using (
    public.has_business_permission(business_id, 'sales.view')
    or public.has_business_permission(business_id, 'sales.return')
  );
drop policy if exists cloud_sale_return_refunds_select_authorized on public.cloud_sale_return_refunds;
create policy cloud_sale_return_refunds_select_authorized on public.cloud_sale_return_refunds
  for select to authenticated using (
    public.has_business_permission(business_id, 'sales.view')
    or public.has_business_permission(business_id, 'sales.return')
    or public.has_business_permission(business_id, 'cashbook.view')
  );
drop policy if exists cloud_purchase_returns_select_authorized on public.cloud_purchase_returns;
create policy cloud_purchase_returns_select_authorized on public.cloud_purchase_returns
  for select to authenticated using (
    public.has_business_permission(business_id, 'purchases.view')
    or public.has_business_permission(business_id, 'purchases.return')
    or public.has_business_permission(business_id, 'accounts.view')
  );
drop policy if exists cloud_purchase_return_items_select_authorized on public.cloud_purchase_return_items;
create policy cloud_purchase_return_items_select_authorized on public.cloud_purchase_return_items
  for select to authenticated using (
    public.has_business_permission(business_id, 'purchases.view')
    or public.has_business_permission(business_id, 'purchases.return')
  );
drop policy if exists cloud_purchase_return_refunds_select_authorized on public.cloud_purchase_return_refunds;
create policy cloud_purchase_return_refunds_select_authorized on public.cloud_purchase_return_refunds
  for select to authenticated using (
    public.has_business_permission(business_id, 'purchases.view')
    or public.has_business_permission(business_id, 'purchases.return')
    or public.has_business_permission(business_id, 'cashbook.view')
  );

revoke all on public.cloud_sale_returns, public.cloud_sale_return_items,
  public.cloud_sale_return_refunds, public.cloud_purchase_returns,
  public.cloud_purchase_return_items, public.cloud_purchase_return_refunds
  from anon, authenticated;
grant select on public.cloud_sale_returns, public.cloud_sale_return_items,
  public.cloud_sale_return_refunds, public.cloud_purchase_returns,
  public.cloud_purchase_return_items, public.cloud_purchase_return_refunds
  to authenticated;

create or replace function public.create_cloud_sale_return(
  p_business_id uuid,
  p_sale_id uuid,
  p_items jsonb,
  p_refunded_minor bigint,
  p_refund_method text,
  p_cash_session_id uuid,
  p_operation_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sale record;
  v_item record;
  v_return_id uuid;
  v_existing_hash text;
  v_hash text;
  v_items jsonb;
  v_item_count integer;
  v_found_count integer;
  v_previous_quantity bigint;
  v_return_quantity bigint;
  v_remaining_quantity bigint;
  v_amount bigint;
  v_total_minor bigint := 0;
  v_paid_remaining bigint;
  v_prior_refunds bigint;
  v_refund_id uuid;
  v_cash_hash text;
  v_cash_movement_id uuid;
  v_stamp timestamptz := now();
begin
  if auth.uid() is null or p_business_id is null or p_sale_id is null
     or p_operation_id is null or p_items is null
     or jsonb_typeof(p_items) is distinct from 'array'
     or jsonb_array_length(p_items) = 0
     or p_refunded_minor is null or p_refunded_minor < 0
     or p_refund_method is null
     or p_refund_method not in ('cash', 'card', 'bank_transfer', 'wallet')
     or (p_refunded_minor > 0 and p_refund_method = 'cash' and p_cash_session_id is null)
     or (p_refund_method <> 'cash' and p_cash_session_id is not null)
     or (p_refunded_minor = 0 and p_cash_session_id is not null) then
    raise exception 'invalid sales return payload' using errcode = '22023';
  end if;
  if not public.has_business_permission(p_business_id, 'sales.return') then
    raise exception 'sales return is not allowed' using errcode = '42501';
  end if;

  select count(*), count(distinct x.sale_item_id)
  into v_item_count, v_found_count
  from jsonb_to_recordset(p_items) as x(sale_item_id uuid, quantity_scaled bigint);
  if v_item_count = 0 or v_item_count <> jsonb_array_length(p_items)
     or v_item_count <> v_found_count
     or exists (
       select 1 from jsonb_to_recordset(p_items) as x(sale_item_id uuid, quantity_scaled bigint)
       where x.sale_item_id is null or x.quantity_scaled is null or x.quantity_scaled <= 0
     ) then
    raise exception 'invalid or duplicate sales return items' using errcode = '22023';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'sale_item_id', x.sale_item_id, 'quantity_scaled', x.quantity_scaled
  ) order by x.sale_item_id), '[]'::jsonb)
  into v_items
  from jsonb_to_recordset(p_items) as x(sale_item_id uuid, quantity_scaled bigint);

  v_hash := encode(public.digest(jsonb_build_object(
    'sale_id', p_sale_id, 'items', v_items,
    'refunded_minor', p_refunded_minor,
    'refund_method', p_refund_method,
    'cash_session_id', p_cash_session_id
  )::text, 'sha256'), 'hex');

  perform pg_advisory_xact_lock(hashtextextended(
    p_business_id::text || ':sale-return:' || p_operation_id::text, 0
  ));
  select id, request_hash into v_return_id, v_existing_hash
  from public.cloud_sale_returns
  where business_id = p_business_id and operation_id = p_operation_id;
  if v_return_id is not null then
    if v_existing_hash is distinct from v_hash then
      raise exception 'sales return key reused with different payload' using errcode = '22023';
    end if;
    return v_return_id;
  end if;

  select * into v_sale from public.cloud_sales
  where id = p_sale_id and business_id = p_business_id
  for update;
  if not found then
    raise exception 'sale unavailable' using errcode = '23514';
  end if;

  select count(*) into v_found_count
  from jsonb_to_recordset(v_items) as x(sale_item_id uuid, quantity_scaled bigint)
  join public.cloud_sale_items si
    on si.id = x.sale_item_id and si.sale_id = p_sale_id
   and si.business_id = p_business_id;
  if v_found_count <> v_item_count then
    raise exception 'sales return contains items outside the invoice' using errcode = '23514';
  end if;

  perform 1 from public.cloud_sale_items si
  join jsonb_to_recordset(v_items) as x(sale_item_id uuid, quantity_scaled bigint)
    on x.sale_item_id = si.id
  where si.sale_id = p_sale_id and si.business_id = p_business_id
  order by si.id for update of si;

  for v_item in
    select si.id as sale_item_id, si.product_id, si.quantity_scaled,
      si.unit_price_minor, si.unit_cost_minor, x.quantity_scaled as return_quantity
    from public.cloud_sale_items si
    join jsonb_to_recordset(v_items) as x(sale_item_id uuid, quantity_scaled bigint)
      on x.sale_item_id = si.id
    where si.sale_id = p_sale_id and si.business_id = p_business_id
    order by si.id
  loop
    select coalesce(sum(ri.quantity_scaled), 0) into v_previous_quantity
    from public.cloud_sale_return_items ri
    join public.cloud_sale_returns r
      on r.id = ri.return_id and r.business_id = ri.business_id
    where ri.business_id = p_business_id and ri.sale_item_id = v_item.sale_item_id;

    v_return_quantity := v_item.return_quantity;
    v_remaining_quantity := v_item.quantity_scaled - v_previous_quantity;
    if v_return_quantity > v_remaining_quantity then
      raise exception 'returned quantity exceeds sold quantity' using errcode = '23514';
    end if;

    v_amount := round(v_item.unit_price_minor::numeric
      * (v_previous_quantity + v_return_quantity) / 1000)::bigint
      - round(v_item.unit_price_minor::numeric * v_previous_quantity / 1000)::bigint;
    v_total_minor := v_total_minor + v_amount;
  end loop;

  if v_total_minor <= 0 or p_refunded_minor > v_total_minor then
    raise exception 'invalid sales return amount or refund exceeds return value' using errcode = '22023';
  end if;

  select coalesce(sum(sp.amount_minor), 0) into v_paid_remaining
  from public.cloud_sale_payments sp
  where sp.business_id = p_business_id and sp.sale_id = p_sale_id;
  select coalesce(sum(rf.amount_minor), 0) into v_prior_refunds
  from public.cloud_sale_return_refunds rf
  join public.cloud_sale_returns r
    on r.id = rf.return_id and r.business_id = rf.business_id
  where rf.business_id = p_business_id and rf.sale_id = p_sale_id;
  if p_refunded_minor > v_paid_remaining - v_prior_refunds then
    raise exception 'refund exceeds unrefunded sale payments' using errcode = '23514';
  end if;

  if p_refunded_minor > 0 and p_refund_method = 'cash' then
    perform 1 from public.cloud_cash_sessions
    where id = p_cash_session_id and business_id = p_business_id
      and branch_id = v_sale.branch_id and status = 'open'
    for update;
    if not found then
      raise exception 'cash refund requires an open register in the sale branch'
        using errcode = '23514';
    end if;
  end if;

  insert into public.cloud_sale_returns (
    business_id, sale_id, customer_id, total_minor, refunded_minor,
    operation_id, request_hash, actor_user_id, created_at
  ) values (
    p_business_id, p_sale_id, v_sale.customer_id, v_total_minor, p_refunded_minor,
    p_operation_id, v_hash, auth.uid(), v_stamp
  ) returning id into v_return_id;

  for v_item in
    select si.id as sale_item_id, si.product_id, si.quantity_scaled,
      si.unit_price_minor, si.unit_cost_minor, x.quantity_scaled as return_quantity
    from public.cloud_sale_items si
    join jsonb_to_recordset(v_items) as x(sale_item_id uuid, quantity_scaled bigint)
      on x.sale_item_id = si.id
    where si.sale_id = p_sale_id and si.business_id = p_business_id
    order by si.id
  loop
    select coalesce(sum(ri.quantity_scaled), 0) into v_previous_quantity
    from public.cloud_sale_return_items ri
    join public.cloud_sale_returns r on r.id = ri.return_id and r.business_id = ri.business_id
    where ri.business_id = p_business_id and ri.sale_item_id = v_item.sale_item_id
      and ri.return_id <> v_return_id;

    v_amount := round(v_item.unit_price_minor::numeric
      * (v_previous_quantity + v_item.return_quantity) / 1000)::bigint
      - round(v_item.unit_price_minor::numeric * v_previous_quantity / 1000)::bigint;

    insert into public.cloud_sale_return_items (
      business_id, return_id, sale_item_id, product_id,
      quantity_scaled, amount_minor, created_at
    ) values (
      p_business_id, v_return_id, v_item.sale_item_id, v_item.product_id,
      v_item.return_quantity, v_amount, v_stamp
    );

    insert into public.cloud_product_warehouse_stock (
      business_id, branch_id, warehouse_id, product_id, quantity_scaled, updated_at
    ) values (
      p_business_id, v_sale.branch_id, v_sale.warehouse_id, v_item.product_id, 0, v_stamp
    ) on conflict (business_id, warehouse_id, product_id) do nothing;

    update public.cloud_product_warehouse_stock
    set quantity_scaled = quantity_scaled + v_item.return_quantity, updated_at = v_stamp
    where business_id = p_business_id and branch_id = v_sale.branch_id
      and warehouse_id = v_sale.warehouse_id and product_id = v_item.product_id;
    if not found then raise exception 'warehouse return stock update failed' using errcode = '23514'; end if;

    update public.cloud_products
    set stock_quantity = stock_quantity + v_item.return_quantity, updated_at = v_stamp
    where id = v_item.product_id and business_id = p_business_id;
    if not found then raise exception 'aggregate return stock update failed' using errcode = '23514'; end if;

    insert into public.cloud_inventory_movements (
      business_id, branch_id, warehouse_id, product_id, quantity_delta,
      reason, operation_id, actor_user_id, request_hash, source_type, source_id, created_at
    ) values (
      p_business_id, v_sale.branch_id, v_sale.warehouse_id, v_item.product_id,
      v_item.return_quantity, 'مرتجع مبيعات ' || v_return_id::text,
      p_operation_id, auth.uid(),
      encode(public.digest(jsonb_build_object(
        'return_id', v_return_id, 'product_id', v_item.product_id,
        'quantity_scaled', v_item.return_quantity
      )::text, 'sha256'), 'hex'),
      'sale_return', v_return_id, v_stamp
    );
  end loop;

  if v_sale.customer_id is not null
     and (-v_total_minor + p_refunded_minor) <> 0 then
    insert into public.cloud_customer_account_entries (
      business_id, customer_id, amount_minor, entry_type, reference_type,
      reference_id, operation_id, note, actor_user_id, created_at
    ) values (
      p_business_id, v_sale.customer_id, -v_total_minor + p_refunded_minor,
      'return', 'sale_return', v_return_id, p_operation_id,
      'صافي تخفيض حساب العميل بعد رد المبلغ النقدي/الإلكتروني',
      auth.uid(), v_stamp
    );
  end if;

  if p_refunded_minor > 0 then
    insert into public.cloud_sale_return_refunds (
      business_id, return_id, sale_id, amount_minor, payment_method,
      cash_session_id, operation_id, request_hash, actor_user_id, created_at
    ) values (
      p_business_id, v_return_id, p_sale_id, p_refunded_minor, p_refund_method,
      p_cash_session_id, p_operation_id, v_hash, auth.uid(), v_stamp
    ) returning id into v_refund_id;

    if p_refund_method = 'cash' then
      v_cash_hash := encode(public.digest(jsonb_build_object(
        'cash_session_id', p_cash_session_id, 'direction', 'out',
        'category', 'sale_return_refund', 'amount_minor', p_refunded_minor,
        'refund_id', v_refund_id
      )::text, 'sha256'), 'hex');
      insert into public.cloud_cash_movements (
        business_id, branch_id, cash_session_id, direction, category,
        amount_minor, source_type, source_id, operation_id, request_hash,
        note, actor_user_id, created_at
      ) values (
        p_business_id, v_sale.branch_id, p_cash_session_id, 'out', 'sale_return_refund',
        p_refunded_minor, 'sale_return_refund', v_refund_id, p_operation_id, v_cash_hash,
        'رد نقدي عن مرتجع مبيعات', auth.uid(), v_stamp
      ) returning id into v_cash_movement_id;
    end if;
  end if;

  insert into public.audit_events (
    business_id, actor_user_id, action_key, entity_type, entity_id, metadata, created_at
  ) values (
    p_business_id, auth.uid(), 'sales.return', 'cloud_sale_return', v_return_id::text,
    jsonb_build_object('sale_id', p_sale_id, 'total_minor', v_total_minor,
      'refunded_minor', p_refunded_minor, 'refund_method', p_refund_method,
      'cash_session_id', p_cash_session_id), v_stamp
  );
  return v_return_id;
end;
$$;

create or replace function public.create_cloud_purchase_return(
  p_business_id uuid,
  p_purchase_id uuid,
  p_items jsonb,
  p_refunded_minor bigint,
  p_refund_method text,
  p_cash_session_id uuid,
  p_operation_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_purchase record;
  v_item record;
  v_return_id uuid;
  v_existing_hash text;
  v_hash text;
  v_items jsonb;
  v_item_count integer;
  v_found_count integer;
  v_previous_quantity bigint;
  v_remaining_quantity bigint;
  v_amount bigint;
  v_total_minor bigint := 0;
  v_paid_total bigint;
  v_prior_refunds bigint;
  v_refund_id uuid;
  v_cash_hash text;
  v_cash_movement_id uuid;
  v_stamp timestamptz := now();
begin
  if auth.uid() is null or p_business_id is null or p_purchase_id is null
     or p_operation_id is null or p_items is null
     or jsonb_typeof(p_items) is distinct from 'array'
     or jsonb_array_length(p_items) = 0
     or p_refunded_minor is null or p_refunded_minor < 0
     or p_refund_method is null
     or p_refund_method not in ('cash', 'card', 'bank_transfer', 'wallet')
     or (p_refunded_minor > 0 and p_refund_method = 'cash' and p_cash_session_id is null)
     or (p_refund_method <> 'cash' and p_cash_session_id is not null)
     or (p_refunded_minor = 0 and p_cash_session_id is not null) then
    raise exception 'invalid purchase return payload' using errcode = '22023';
  end if;
  if not public.has_business_permission(p_business_id, 'purchases.return') then
    raise exception 'purchase return is not allowed' using errcode = '42501';
  end if;

  select count(*), count(distinct x.purchase_item_id)
  into v_item_count, v_found_count
  from jsonb_to_recordset(p_items) as x(purchase_item_id uuid, quantity_scaled bigint);
  if v_item_count = 0 or v_item_count <> jsonb_array_length(p_items)
     or v_item_count <> v_found_count
     or exists (
       select 1 from jsonb_to_recordset(p_items) as x(purchase_item_id uuid, quantity_scaled bigint)
       where x.purchase_item_id is null or x.quantity_scaled is null or x.quantity_scaled <= 0
     ) then
    raise exception 'invalid or duplicate purchase return items' using errcode = '22023';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'purchase_item_id', x.purchase_item_id, 'quantity_scaled', x.quantity_scaled
  ) order by x.purchase_item_id), '[]'::jsonb)
  into v_items
  from jsonb_to_recordset(p_items) as x(purchase_item_id uuid, quantity_scaled bigint);

  v_hash := encode(public.digest(jsonb_build_object(
    'purchase_id', p_purchase_id, 'items', v_items,
    'refunded_minor', p_refunded_minor,
    'refund_method', p_refund_method,
    'cash_session_id', p_cash_session_id
  )::text, 'sha256'), 'hex');

  perform pg_advisory_xact_lock(hashtextextended(
    p_business_id::text || ':purchase-return:' || p_operation_id::text, 0
  ));
  select id, request_hash into v_return_id, v_existing_hash
  from public.cloud_purchase_returns
  where business_id = p_business_id and operation_id = p_operation_id;
  if v_return_id is not null then
    if v_existing_hash is distinct from v_hash then
      raise exception 'purchase return key reused with different payload' using errcode = '22023';
    end if;
    return v_return_id;
  end if;

  select * into v_purchase from public.cloud_purchases
  where id = p_purchase_id and business_id = p_business_id
  for update;
  if not found then raise exception 'purchase unavailable' using errcode = '23514'; end if;

  select count(*) into v_found_count
  from jsonb_to_recordset(v_items) as x(purchase_item_id uuid, quantity_scaled bigint)
  join public.cloud_purchase_items pi
    on pi.id = x.purchase_item_id and pi.purchase_id = p_purchase_id
   and pi.business_id = p_business_id;
  if v_found_count <> v_item_count then
    raise exception 'purchase return contains items outside the invoice' using errcode = '23514';
  end if;

  perform 1 from public.cloud_purchase_items pi
  join jsonb_to_recordset(v_items) as x(purchase_item_id uuid, quantity_scaled bigint)
    on x.purchase_item_id = pi.id
  where pi.purchase_id = p_purchase_id and pi.business_id = p_business_id
  order by pi.id for update of pi;

  for v_item in
    select pi.id as purchase_item_id, pi.product_id, pi.quantity_scaled,
      pi.unit_cost_minor, x.quantity_scaled as return_quantity
    from public.cloud_purchase_items pi
    join jsonb_to_recordset(v_items) as x(purchase_item_id uuid, quantity_scaled bigint)
      on x.purchase_item_id = pi.id
    where pi.purchase_id = p_purchase_id and pi.business_id = p_business_id
    order by pi.id
  loop
    select coalesce(sum(ri.quantity_scaled), 0) into v_previous_quantity
    from public.cloud_purchase_return_items ri
    join public.cloud_purchase_returns r on r.id = ri.return_id and r.business_id = ri.business_id
    where ri.business_id = p_business_id and ri.purchase_item_id = v_item.purchase_item_id;
    v_remaining_quantity := v_item.quantity_scaled - v_previous_quantity;
    if v_item.return_quantity > v_remaining_quantity then
      raise exception 'returned quantity exceeds purchased quantity' using errcode = '23514';
    end if;
    v_amount := round(v_item.unit_cost_minor::numeric
      * (v_previous_quantity + v_item.return_quantity) / 1000)::bigint
      - round(v_item.unit_cost_minor::numeric * v_previous_quantity / 1000)::bigint;
    v_total_minor := v_total_minor + v_amount;
  end loop;

  if v_total_minor <= 0 or p_refunded_minor > v_total_minor then
    raise exception 'invalid purchase return amount or refund exceeds return value' using errcode = '22023';
  end if;

  select coalesce(sum(pp.amount_minor), 0) into v_paid_total
  from public.cloud_purchase_payments pp
  where pp.business_id = p_business_id and pp.purchase_id = p_purchase_id;
  select coalesce(sum(rf.amount_minor), 0) into v_prior_refunds
  from public.cloud_purchase_return_refunds rf
  where rf.business_id = p_business_id and rf.purchase_id = p_purchase_id;
  if p_refunded_minor > v_paid_total - v_prior_refunds then
    raise exception 'refund exceeds unrefunded purchase payments' using errcode = '23514';
  end if;

  if p_refunded_minor > 0 and p_refund_method = 'cash' then
    perform 1 from public.cloud_cash_sessions
    where id = p_cash_session_id and business_id = p_business_id
      and branch_id = v_purchase.branch_id and status = 'open'
    for update;
    if not found then
      raise exception 'cash refund requires an open register in the purchase branch'
        using errcode = '23514';
    end if;
  end if;

  insert into public.cloud_purchase_returns (
    business_id, purchase_id, supplier_id, total_minor, refunded_minor,
    operation_id, request_hash, actor_user_id, created_at
  ) values (
    p_business_id, p_purchase_id, v_purchase.supplier_id, v_total_minor, p_refunded_minor,
    p_operation_id, v_hash, auth.uid(), v_stamp
  ) returning id into v_return_id;

  for v_item in
    select pi.id as purchase_item_id, pi.product_id, pi.quantity_scaled,
      pi.unit_cost_minor, x.quantity_scaled as return_quantity
    from public.cloud_purchase_items pi
    join jsonb_to_recordset(v_items) as x(purchase_item_id uuid, quantity_scaled bigint)
      on x.purchase_item_id = pi.id
    where pi.purchase_id = p_purchase_id and pi.business_id = p_business_id
    order by pi.id
  loop
    select coalesce(sum(ri.quantity_scaled), 0) into v_previous_quantity
    from public.cloud_purchase_return_items ri
    join public.cloud_purchase_returns r on r.id = ri.return_id and r.business_id = ri.business_id
    where ri.business_id = p_business_id and ri.purchase_item_id = v_item.purchase_item_id
      and ri.return_id <> v_return_id;
    v_amount := round(v_item.unit_cost_minor::numeric
      * (v_previous_quantity + v_item.return_quantity) / 1000)::bigint
      - round(v_item.unit_cost_minor::numeric * v_previous_quantity / 1000)::bigint;

    insert into public.cloud_purchase_return_items (
      business_id, return_id, purchase_item_id, product_id,
      quantity_scaled, amount_minor, created_at
    ) values (
      p_business_id, v_return_id, v_item.purchase_item_id, v_item.product_id,
      v_item.return_quantity, v_amount, v_stamp
    );

    perform 1 from public.cloud_product_warehouse_stock
    where business_id = p_business_id and branch_id = v_purchase.branch_id
      and warehouse_id = v_purchase.warehouse_id and product_id = v_item.product_id
    for update;
    if not found then raise exception 'purchase return warehouse stock unavailable' using errcode = '23514'; end if;

    update public.cloud_product_warehouse_stock
    set quantity_scaled = quantity_scaled - v_item.return_quantity, updated_at = v_stamp
    where business_id = p_business_id and branch_id = v_purchase.branch_id
      and warehouse_id = v_purchase.warehouse_id and product_id = v_item.product_id
      and quantity_scaled >= v_item.return_quantity;
    if not found then raise exception 'insufficient stock for purchase return' using errcode = '23514'; end if;

    update public.cloud_products
    set stock_quantity = stock_quantity - v_item.return_quantity, updated_at = v_stamp
    where id = v_item.product_id and business_id = p_business_id
      and stock_quantity >= v_item.return_quantity;
    if not found then raise exception 'aggregate stock insufficient for purchase return' using errcode = '23514'; end if;

    insert into public.cloud_inventory_movements (
      business_id, branch_id, warehouse_id, product_id, quantity_delta,
      reason, operation_id, actor_user_id, request_hash, source_type, source_id, created_at
    ) values (
      p_business_id, v_purchase.branch_id, v_purchase.warehouse_id, v_item.product_id,
      -v_item.return_quantity, 'مرتجع مشتريات ' || v_return_id::text,
      p_operation_id, auth.uid(),
      encode(public.digest(jsonb_build_object(
        'return_id', v_return_id, 'product_id', v_item.product_id,
        'quantity_scaled', -v_item.return_quantity
      )::text, 'sha256'), 'hex'),
      'purchase_return', v_return_id, v_stamp
    );
  end loop;

  if (-v_total_minor + p_refunded_minor) <> 0 then
    insert into public.cloud_supplier_account_entries (
      business_id, supplier_id, amount_minor, entry_type, reference_type,
      reference_id, operation_id, note, actor_user_id, created_at
    ) values (
      p_business_id, v_purchase.supplier_id, -v_total_minor + p_refunded_minor,
      'return', 'purchase_return', v_return_id, p_operation_id,
      'صافي تخفيض مستحقات المورد بعد استرداد المبلغ',
      auth.uid(), v_stamp
    );
  end if;

  if p_refunded_minor > 0 then
    insert into public.cloud_purchase_return_refunds (
      business_id, return_id, purchase_id, amount_minor, payment_method,
      cash_session_id, operation_id, request_hash, actor_user_id, created_at
    ) values (
      p_business_id, v_return_id, p_purchase_id, p_refunded_minor, p_refund_method,
      p_cash_session_id, p_operation_id, v_hash, auth.uid(), v_stamp
    ) returning id into v_refund_id;

    if p_refund_method = 'cash' then
      v_cash_hash := encode(public.digest(jsonb_build_object(
        'cash_session_id', p_cash_session_id, 'direction', 'in',
        'category', 'purchase_return_refund', 'amount_minor', p_refunded_minor,
        'refund_id', v_refund_id
      )::text, 'sha256'), 'hex');
      insert into public.cloud_cash_movements (
        business_id, branch_id, cash_session_id, direction, category,
        amount_minor, source_type, source_id, operation_id, request_hash,
        note, actor_user_id, created_at
      ) values (
        p_business_id, v_purchase.branch_id, p_cash_session_id, 'in', 'purchase_return_refund',
        p_refunded_minor, 'purchase_return_refund', v_refund_id, p_operation_id, v_cash_hash,
        'استرداد نقدي من المورد عن مرتجع مشتريات', auth.uid(), v_stamp
      ) returning id into v_cash_movement_id;
    end if;
  end if;

  insert into public.audit_events (
    business_id, actor_user_id, action_key, entity_type, entity_id, metadata, created_at
  ) values (
    p_business_id, auth.uid(), 'purchases.return', 'cloud_purchase_return', v_return_id::text,
    jsonb_build_object('purchase_id', p_purchase_id, 'total_minor', v_total_minor,
      'refunded_minor', p_refunded_minor, 'refund_method', p_refund_method,
      'cash_session_id', p_cash_session_id), v_stamp
  );
  return v_return_id;
end;
$$;

revoke all on function public.create_cloud_sale_return(uuid, uuid, jsonb, bigint, text, uuid, uuid)
  from public, anon;
revoke all on function public.create_cloud_purchase_return(uuid, uuid, jsonb, bigint, text, uuid, uuid)
  from public, anon;
grant execute on function public.create_cloud_sale_return(uuid, uuid, jsonb, bigint, text, uuid, uuid)
  to authenticated;
grant execute on function public.create_cloud_purchase_return(uuid, uuid, jsonb, bigint, text, uuid, uuid)
  to authenticated;
