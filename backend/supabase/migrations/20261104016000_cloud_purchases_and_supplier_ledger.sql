-- Cloud purchases receive stock, create supplier liabilities and record their payment.
-- All financial and stock writes are one tenant-scoped, idempotent transaction.
alter table public.cloud_inventory_movements
  add column if not exists source_type text,
  add column if not exists source_id uuid;

create index if not exists cloud_inventory_movements_source_idx
  on public.cloud_inventory_movements(business_id, source_type, source_id)
  where source_type is not null;

create table if not exists public.cloud_purchases (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  branch_id uuid not null,
  warehouse_id uuid not null,
  supplier_id uuid not null,
  total_minor bigint not null check (total_minor >= 0),
  paid_minor bigint not null check (paid_minor >= 0 and paid_minor <= total_minor),
  due_minor bigint not null check (due_minor >= 0 and due_minor = total_minor - paid_minor),
  operation_id uuid not null,
  request_hash text not null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (id, business_id),
  unique (business_id, operation_id),
  foreign key (branch_id, business_id)
    references public.cloud_branches(id, business_id) on delete restrict,
  foreign key (warehouse_id, business_id, branch_id)
    references public.cloud_warehouses(id, business_id, branch_id) on delete restrict,
  foreign key (supplier_id, business_id)
    references public.cloud_suppliers(id, business_id) on delete restrict
);

create table if not exists public.cloud_purchase_items (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  purchase_id uuid not null,
  product_id uuid not null,
  quantity_scaled bigint not null check (quantity_scaled > 0),
  unit_cost_minor bigint not null check (unit_cost_minor >= 0),
  line_total_minor bigint not null check (line_total_minor >= 0),
  created_at timestamptz not null default now(),
  unique (purchase_id, product_id),
  foreign key (purchase_id, business_id)
    references public.cloud_purchases(id, business_id) on delete restrict,
  foreign key (product_id, business_id)
    references public.cloud_products(id, business_id) on delete restrict
);

create table if not exists public.cloud_purchase_payments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  purchase_id uuid not null,
  supplier_id uuid not null,
  amount_minor bigint not null check (amount_minor > 0),
  payment_method text not null check (payment_method in ('cash', 'card', 'bank_transfer', 'wallet')),
  cash_session_id uuid,
  operation_id uuid not null,
  request_hash text not null,
  actor_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (id, business_id),
  unique (business_id, operation_id),
  foreign key (purchase_id, business_id)
    references public.cloud_purchases(id, business_id) on delete restrict,
  foreign key (supplier_id, business_id)
    references public.cloud_suppliers(id, business_id) on delete restrict,
  foreign key (cash_session_id, business_id)
    references public.cloud_cash_sessions(id, business_id) on delete restrict,
  check (cash_session_id is null or payment_method = 'cash')
);

create index if not exists cloud_purchases_business_created_idx
  on public.cloud_purchases(business_id, created_at desc);
create index if not exists cloud_purchases_supplier_created_idx
  on public.cloud_purchases(business_id, supplier_id, created_at desc);
create index if not exists cloud_purchase_items_purchase_idx
  on public.cloud_purchase_items(business_id, purchase_id);

alter table public.cloud_purchases enable row level security;
alter table public.cloud_purchase_items enable row level security;
alter table public.cloud_purchase_payments enable row level security;

drop policy if exists cloud_purchases_select_authorized on public.cloud_purchases;
create policy cloud_purchases_select_authorized on public.cloud_purchases
  for select to authenticated
  using (
    public.has_business_permission(business_id, 'purchases.view')
    or public.has_business_permission(business_id, 'purchases.create')
    or public.has_business_permission(business_id, 'accounts.view')
    or public.has_business_permission(business_id, 'reports.view')
  );

drop policy if exists cloud_purchase_items_select_authorized on public.cloud_purchase_items;
create policy cloud_purchase_items_select_authorized on public.cloud_purchase_items
  for select to authenticated
  using (
    public.has_business_permission(business_id, 'purchases.view')
    or public.has_business_permission(business_id, 'accounts.view')
    or public.has_business_permission(business_id, 'reports.view')
  );

drop policy if exists cloud_purchase_payments_select_authorized on public.cloud_purchase_payments;
create policy cloud_purchase_payments_select_authorized on public.cloud_purchase_payments
  for select to authenticated
  using (
    public.has_business_permission(business_id, 'purchases.view')
    or public.has_business_permission(business_id, 'purchases.create')
    or public.has_business_permission(business_id, 'accounts.view')
    or public.has_business_permission(business_id, 'cashbook.view')
  );

drop policy if exists cloud_inventory_movements_purchase_select_authorized on public.cloud_inventory_movements;
create policy cloud_inventory_movements_purchase_select_authorized
  on public.cloud_inventory_movements
  for select to authenticated
  using (
    source_type = 'purchase'
    and public.has_business_permission(business_id, 'purchases.view')
  );

revoke all on public.cloud_purchases, public.cloud_purchase_items, public.cloud_purchase_payments
  from anon, authenticated;
grant select on public.cloud_purchases, public.cloud_purchase_items, public.cloud_purchase_payments
  to authenticated;

-- Purchase operators need read access to the catalogue and destination stock they operate on.
drop policy if exists cloud_products_purchases_select_authorized on public.cloud_products;
create policy cloud_products_purchases_select_authorized on public.cloud_products
  for select to authenticated
  using (
    public.has_business_permission(business_id, 'purchases.view')
    or public.has_business_permission(business_id, 'purchases.create')
  );

drop policy if exists cloud_branches_purchases_select_authorized on public.cloud_branches;
create policy cloud_branches_purchases_select_authorized on public.cloud_branches
  for select to authenticated
  using (
    public.has_business_permission(business_id, 'purchases.view')
    or public.has_business_permission(business_id, 'purchases.create')
  );

drop policy if exists cloud_warehouses_purchases_select_authorized on public.cloud_warehouses;
create policy cloud_warehouses_purchases_select_authorized on public.cloud_warehouses
  for select to authenticated
  using (
    public.has_business_permission(business_id, 'purchases.view')
    or public.has_business_permission(business_id, 'purchases.create')
  );

drop policy if exists cloud_stock_purchases_select_authorized on public.cloud_product_warehouse_stock;
create policy cloud_stock_purchases_select_authorized on public.cloud_product_warehouse_stock
  for select to authenticated
  using (
    public.has_business_permission(business_id, 'purchases.view')
    or public.has_business_permission(business_id, 'purchases.create')
  );

drop policy if exists cloud_supplier_entries_purchases_select_authorized
  on public.cloud_supplier_account_entries;
create policy cloud_supplier_entries_purchases_select_authorized
  on public.cloud_supplier_account_entries
  for select to authenticated
  using (
    public.has_business_permission(business_id, 'purchases.view')
    or public.has_business_permission(business_id, 'purchases.create')
  );

create or replace function public.create_cloud_purchase_with_account(
  p_business_id uuid,
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_supplier_id uuid,
  p_items jsonb,
  p_paid_minor bigint,
  p_payment_method text,
  p_cash_session_id uuid,
  p_operation_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_items jsonb;
  v_hash text;
  v_existing_hash text;
  v_purchase_id uuid;
  v_total_minor bigint;
  v_due_minor bigint;
  v_item_count integer;
  v_found_count integer;
  v_item record;
  v_line_total bigint;
  v_stock_movement_hash text;
  v_payment_id uuid;
  v_cash_movement_id uuid;
  v_cash_hash text;
  v_stamp timestamptz := now();
begin
  if auth.uid() is null or p_business_id is null or p_branch_id is null
     or p_warehouse_id is null or p_supplier_id is null or p_operation_id is null
     or p_paid_minor is null or p_paid_minor < 0
     or p_items is null or jsonb_typeof(p_items) is distinct from 'array'
     or jsonb_array_length(p_items) = 0
     or p_payment_method is null
     or p_payment_method not in ('cash', 'card', 'bank_transfer', 'wallet')
     or (p_paid_minor > 0 and p_payment_method = 'cash' and p_cash_session_id is null)
     or (p_payment_method <> 'cash' and p_cash_session_id is not null)
     or (p_paid_minor = 0 and p_cash_session_id is not null) then
    raise exception 'invalid purchase payload' using errcode = '22023';
  end if;
  if not public.has_business_permission(p_business_id, 'purchases.create') then
    raise exception 'purchase creation is not allowed' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.cloud_branches b
    join public.cloud_warehouses w
      on w.business_id = b.business_id and w.branch_id = b.id
    where b.id = p_branch_id and b.business_id = p_business_id and b.is_active
      and w.id = p_warehouse_id and w.is_active
  ) then
    raise exception 'purchase warehouse unavailable' using errcode = '23514';
  end if;

  select count(*), count(distinct x.product_id)
  into v_item_count, v_found_count
  from jsonb_to_recordset(p_items) as x(
    product_id uuid, quantity_scaled bigint, unit_cost_minor bigint
  );
  if v_item_count = 0 or v_item_count <> jsonb_array_length(p_items)
     or v_found_count <> v_item_count
     or exists (
       select 1 from jsonb_to_recordset(p_items) as x(
         product_id uuid, quantity_scaled bigint, unit_cost_minor bigint
       )
       where x.product_id is null or x.quantity_scaled is null or x.quantity_scaled <= 0
          or x.unit_cost_minor is null or x.unit_cost_minor < 0
     ) then
    raise exception 'invalid purchase items' using errcode = '22023';
  end if;

  select count(*) into v_found_count
  from public.cloud_products p
  join jsonb_to_recordset(p_items) as x(
    product_id uuid, quantity_scaled bigint, unit_cost_minor bigint
  ) on x.product_id = p.id
  where p.business_id = p_business_id and p.is_active;
  if v_found_count <> v_item_count then
    raise exception 'purchase contains unavailable products' using errcode = '23514';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'product_id', x.product_id,
    'quantity_scaled', x.quantity_scaled,
    'unit_cost_minor', x.unit_cost_minor
  ) order by x.product_id), '[]'::jsonb)
  into v_items
  from jsonb_to_recordset(p_items) as x(
    product_id uuid, quantity_scaled bigint, unit_cost_minor bigint
  );

  select coalesce(sum(round(x.unit_cost_minor::numeric * x.quantity_scaled / 1000)), 0)::bigint
  into v_total_minor
  from jsonb_to_recordset(v_items) as x(
    product_id uuid, quantity_scaled bigint, unit_cost_minor bigint
  );
  if p_paid_minor > v_total_minor then
    raise exception 'paid amount exceeds purchase total' using errcode = '22023';
  end if;
  v_due_minor := v_total_minor - p_paid_minor;

  v_hash := encode(public.digest(jsonb_build_object(
    'branch_id', p_branch_id,
    'warehouse_id', p_warehouse_id,
    'supplier_id', p_supplier_id,
    'items', v_items,
    'paid_minor', p_paid_minor,
    'payment_method', p_payment_method,
    'cash_session_id', p_cash_session_id
  )::text, 'sha256'), 'hex');

  perform pg_advisory_xact_lock(hashtextextended(
    p_business_id::text || ':purchase:' || p_operation_id::text, 0
  ));
  select id, request_hash into v_purchase_id, v_existing_hash
  from public.cloud_purchases
  where business_id = p_business_id and operation_id = p_operation_id;
  if v_purchase_id is not null then
    if v_existing_hash is distinct from v_hash then
      raise exception 'purchase operation key reused with different payload'
        using errcode = '22023';
    end if;
    return v_purchase_id;
  end if;

  perform 1 from public.cloud_suppliers
  where id = p_supplier_id and business_id = p_business_id and is_active
  for update;
  if not found then
    raise exception 'supplier unavailable' using errcode = '23514';
  end if;

  if p_paid_minor > 0 and p_payment_method = 'cash' then
    perform 1 from public.cloud_cash_sessions
    where id = p_cash_session_id and business_id = p_business_id
      and branch_id = p_branch_id and status = 'open'
    for update;
    if not found then
      raise exception 'cash session is not open in the purchase branch'
        using errcode = '23514';
    end if;
  end if;

  perform 1 from public.cloud_products p
  join jsonb_to_recordset(v_items) as x(
    product_id uuid, quantity_scaled bigint, unit_cost_minor bigint
  ) on x.product_id = p.id
  where p.business_id = p_business_id and p.is_active
  order by p.id
  for update of p;

  insert into public.cloud_purchases (
    business_id, branch_id, warehouse_id, supplier_id,
    total_minor, paid_minor, due_minor, operation_id, request_hash,
    created_by, created_at
  ) values (
    p_business_id, p_branch_id, p_warehouse_id, p_supplier_id,
    v_total_minor, p_paid_minor, v_due_minor, p_operation_id, v_hash,
    auth.uid(), v_stamp
  ) returning id into v_purchase_id;

  for v_item in
    select * from jsonb_to_recordset(v_items) as x(
      product_id uuid, quantity_scaled bigint, unit_cost_minor bigint
    ) order by product_id
  loop
    v_line_total := round(v_item.unit_cost_minor::numeric * v_item.quantity_scaled / 1000)::bigint;

    insert into public.cloud_purchase_items (
      business_id, purchase_id, product_id, quantity_scaled,
      unit_cost_minor, line_total_minor, created_at
    ) values (
      p_business_id, v_purchase_id, v_item.product_id, v_item.quantity_scaled,
      v_item.unit_cost_minor, v_line_total, v_stamp
    );

    insert into public.cloud_product_warehouse_stock (
      business_id, branch_id, warehouse_id, product_id, quantity_scaled, updated_at
    ) values (
      p_business_id, p_branch_id, p_warehouse_id, v_item.product_id, 0, v_stamp
    ) on conflict (business_id, warehouse_id, product_id) do nothing;

    update public.cloud_product_warehouse_stock
    set quantity_scaled = quantity_scaled + v_item.quantity_scaled,
        updated_at = v_stamp
    where business_id = p_business_id and branch_id = p_branch_id
      and warehouse_id = p_warehouse_id and product_id = v_item.product_id;
    if not found then
      raise exception 'warehouse stock update failed' using errcode = '23514';
    end if;

    update public.cloud_products
    set stock_quantity = stock_quantity + v_item.quantity_scaled,
        updated_at = v_stamp
    where id = v_item.product_id and business_id = p_business_id;
    if not found then
      raise exception 'aggregate stock update failed' using errcode = '23514';
    end if;

    v_stock_movement_hash := encode(public.digest(jsonb_build_object(
      'purchase_id', v_purchase_id, 'branch_id', p_branch_id,
      'warehouse_id', p_warehouse_id, 'product_id', v_item.product_id,
      'quantity_scaled', v_item.quantity_scaled,
      'unit_cost_minor', v_item.unit_cost_minor
    )::text, 'sha256'), 'hex');

    insert into public.cloud_inventory_movements (
      business_id, branch_id, warehouse_id, product_id, quantity_delta,
      reason, operation_id, actor_user_id, request_hash, source_type, source_id, created_at
    ) values (
      p_business_id, p_branch_id, p_warehouse_id, v_item.product_id,
      v_item.quantity_scaled, 'شراء سحابي رقم ' || v_purchase_id::text,
      p_operation_id, auth.uid(), v_stock_movement_hash, 'purchase', v_purchase_id, v_stamp
    );
  end loop;

  if v_due_minor > 0 then
    insert into public.cloud_supplier_account_entries (
      business_id, supplier_id, amount_minor, entry_type, reference_type,
      reference_id, operation_id, note, actor_user_id, created_at
    ) values (
      p_business_id, p_supplier_id, v_due_minor, 'purchase', 'purchase',
      v_purchase_id, p_operation_id, 'مستحق للمورد عن فاتورة مشتريات سحابية',
      auth.uid(), v_stamp
    );
  end if;

  if p_paid_minor > 0 then
    insert into public.cloud_purchase_payments (
      business_id, purchase_id, supplier_id, amount_minor, payment_method,
      cash_session_id, operation_id, request_hash, actor_user_id, created_at
    ) values (
      p_business_id, v_purchase_id, p_supplier_id, p_paid_minor, p_payment_method,
      p_cash_session_id, p_operation_id, v_hash, auth.uid(), v_stamp
    ) returning id into v_payment_id;

    if p_payment_method = 'cash' then
      v_cash_hash := encode(public.digest(jsonb_build_object(
        'cash_session_id', p_cash_session_id, 'direction', 'out',
        'category', 'purchase_payment', 'amount_minor', p_paid_minor,
        'source_type', 'purchase_payment', 'source_id', v_payment_id
      )::text, 'sha256'), 'hex');

      insert into public.cloud_cash_movements (
        business_id, branch_id, cash_session_id, direction, category,
        amount_minor, source_type, source_id, operation_id, request_hash,
        note, actor_user_id, created_at
      ) values (
        p_business_id, p_branch_id, p_cash_session_id, 'out', 'purchase_payment',
        p_paid_minor, 'purchase_payment', v_payment_id, p_operation_id, v_cash_hash,
        'سداد نقدي عن فاتورة مشتريات سحابية', auth.uid(), v_stamp
      ) returning id into v_cash_movement_id;

      insert into public.audit_events (
        business_id, actor_user_id, action_key, entity_type, entity_id, metadata, created_at
      ) values (
        p_business_id, auth.uid(), 'cashbook.purchase_payment', 'cloud_cash_movement',
        v_cash_movement_id::text,
        jsonb_build_object('cash_session_id', p_cash_session_id,
          'purchase_id', v_purchase_id, 'payment_id', v_payment_id,
          'amount_minor', p_paid_minor), v_stamp
      );
    end if;
  end if;

  insert into public.audit_events (
    business_id, actor_user_id, action_key, entity_type, entity_id, metadata, created_at
  ) values (
    p_business_id, auth.uid(), 'purchases.create', 'cloud_purchase', v_purchase_id::text,
    jsonb_build_object(
      'supplier_id', p_supplier_id, 'warehouse_id', p_warehouse_id,
      'total_minor', v_total_minor, 'paid_minor', p_paid_minor,
      'due_minor', v_due_minor, 'payment_method', p_payment_method,
      'cash_session_id', p_cash_session_id
    ), v_stamp
  );

  return v_purchase_id;
end;
$$;

revoke all on function public.create_cloud_purchase_with_account(uuid, uuid, uuid, uuid, jsonb, bigint, text, uuid, uuid)
  from public, anon;
grant execute on function public.create_cloud_purchase_with_account(uuid, uuid, uuid, uuid, jsonb, bigint, text, uuid, uuid)
  to authenticated;
