-- Link new cloud sales to customers, customer receivables and a payment record.
-- The existing stock/sale implementation is retained as a private transactional core.
alter function public.create_cloud_sale(uuid, uuid, uuid, jsonb, bigint, uuid)
  rename to create_cloud_sale_core;

revoke all on function public.create_cloud_sale_core(uuid, uuid, uuid, jsonb, bigint, uuid)
  from public, anon, authenticated;

alter table public.cloud_sales
  add column if not exists customer_id uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'cloud_sales_customer_business_fk'
      and conrelid = 'public.cloud_sales'::regclass
  ) then
    alter table public.cloud_sales
      add constraint cloud_sales_customer_business_fk
      foreign key (customer_id, business_id)
      references public.cloud_customers(id, business_id)
      on delete restrict;
  end if;
end;
$$;

create table if not exists public.cloud_sale_payments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  sale_id uuid not null,
  customer_id uuid,
  amount_minor bigint not null check (amount_minor > 0),
  payment_method text not null check (payment_method in ('cash', 'card', 'bank_transfer', 'wallet')),
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

create table if not exists public.cloud_sale_account_operations (
  business_id uuid not null references public.businesses(id) on delete cascade,
  operation_id uuid not null,
  request_hash text not null,
  sale_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (business_id, operation_id),
  foreign key (sale_id, business_id)
    references public.cloud_sales(id, business_id) on delete restrict
);

create index if not exists cloud_sales_customer_created_idx
  on public.cloud_sales(business_id, customer_id, created_at desc)
  where customer_id is not null;

alter table public.cloud_sale_payments enable row level security;
alter table public.cloud_sale_account_operations enable row level security;

drop policy if exists cloud_sale_payments_select_authorized on public.cloud_sale_payments;
create policy cloud_sale_payments_select_authorized on public.cloud_sale_payments
  for select to authenticated
  using (
    public.has_business_permission(business_id, 'sales.view')
    or public.has_business_permission(business_id, 'accounts.view')
    or public.has_business_permission(business_id, 'cashbook.view')
  );

revoke all on public.cloud_sale_payments, public.cloud_sale_account_operations
  from anon, authenticated;
grant select on public.cloud_sale_payments to authenticated;

create or replace function public.create_cloud_sale_with_account(
  p_business_id uuid,
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_items jsonb,
  p_paid_minor bigint,
  p_customer_id uuid,
  p_payment_method text,
  p_operation_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text;
  v_items jsonb;
  v_existing_hash text;
  v_sale_id uuid;
  v_total_minor bigint;
  v_due_minor bigint;
  v_stamp timestamptz := now();
begin
  if auth.uid() is null or p_business_id is null or p_branch_id is null
     or p_warehouse_id is null or p_operation_id is null
     or p_paid_minor is null or p_paid_minor < 0
     or p_items is null or jsonb_typeof(p_items) is distinct from 'array'
     or jsonb_array_length(p_items) = 0
     or p_payment_method is null
     or p_payment_method not in ('cash', 'card', 'bank_transfer', 'wallet') then
    raise exception 'invalid sale account payload' using errcode = '22023';
  end if;
  if not public.has_business_permission(p_business_id, 'sales.create') then
    raise exception 'sale creation is not allowed' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'product_id', x.product_id,
    'quantity_scaled', x.quantity_scaled
  ) order by x.product_id), '[]'::jsonb)
  into v_items
  from jsonb_to_recordset(p_items) as x(product_id uuid, quantity_scaled bigint);

  v_hash := encode(public.digest(jsonb_build_object(
    'branch_id', p_branch_id,
    'warehouse_id', p_warehouse_id,
    'items', v_items,
    'paid_minor', p_paid_minor,
    'customer_id', p_customer_id,
    'payment_method', p_payment_method
  )::text, 'sha256'), 'hex');

  perform pg_advisory_xact_lock(hashtextextended(
    p_business_id::text || ':sale-account:' || p_operation_id::text, 0
  ));

  select request_hash, sale_id
  into v_existing_hash, v_sale_id
  from public.cloud_sale_account_operations
  where business_id = p_business_id and operation_id = p_operation_id;
  if v_sale_id is not null then
    if v_existing_hash is distinct from v_hash then
      raise exception 'sale operation key reused with different account payload'
        using errcode = '22023';
    end if;
    return v_sale_id;
  end if;

  if p_customer_id is not null then
    perform 1 from public.cloud_customers
    where id = p_customer_id and business_id = p_business_id and is_active
    for update;
    if not found then
      raise exception 'customer unavailable' using errcode = '23514';
    end if;
  end if;

  -- This private core atomically validates the warehouse, locks products,
  -- inserts the invoice/items, and changes stock. Any later error rolls it back.
  v_sale_id := public.create_cloud_sale_core(
    p_business_id, p_branch_id, p_warehouse_id, p_items,
    p_paid_minor, p_operation_id
  );

  select total_minor into v_total_minor
  from public.cloud_sales
  where id = v_sale_id and business_id = p_business_id
  for update;
  if not found then
    raise exception 'sale creation did not return a stored invoice' using errcode = '23514';
  end if;

  if p_paid_minor > v_total_minor then
    raise exception 'paid amount exceeds sale total' using errcode = '22023';
  end if;
  v_due_minor := v_total_minor - p_paid_minor;
  if v_due_minor > 0 and p_customer_id is null then
    raise exception 'credit sale requires a customer' using errcode = '23514';
  end if;

  update public.cloud_sales
  set customer_id = p_customer_id
  where id = v_sale_id and business_id = p_business_id;

  if v_due_minor > 0 then
    insert into public.cloud_customer_account_entries (
      business_id, customer_id, amount_minor, entry_type, reference_type,
      reference_id, operation_id, note, actor_user_id, created_at
    ) values (
      p_business_id, p_customer_id, v_due_minor, 'sale', 'sale',
      v_sale_id, p_operation_id,
      'رصيد مستحق عن فاتورة بيع سحابية', auth.uid(), v_stamp
    );
  end if;

  if p_paid_minor > 0 then
    insert into public.cloud_sale_payments (
      business_id, sale_id, customer_id, amount_minor, payment_method,
      operation_id, request_hash, actor_user_id, created_at
    ) values (
      p_business_id, v_sale_id, p_customer_id, p_paid_minor, p_payment_method,
      p_operation_id, v_hash, auth.uid(), v_stamp
    );
  end if;

  insert into public.audit_events (
    business_id, actor_user_id, action_key, entity_type, entity_id, metadata, created_at
  ) values (
    p_business_id, auth.uid(), 'sales.create', 'cloud_sale', v_sale_id::text,
    jsonb_build_object(
      'customer_id', p_customer_id,
      'total_minor', v_total_minor,
      'paid_minor', p_paid_minor,
      'due_minor', v_due_minor,
      'payment_method', case when p_paid_minor > 0 then p_payment_method else null end
    ), v_stamp
  );

  insert into public.cloud_sale_account_operations (
    business_id, operation_id, request_hash, sale_id, created_at
  ) values (p_business_id, p_operation_id, v_hash, v_sale_id, v_stamp);

  return v_sale_id;
end;
$$;

create or replace function public.create_cloud_sale_with_account(
  p_business_id uuid,
  p_items jsonb,
  p_paid_minor bigint,
  p_customer_id uuid,
  p_payment_method text,
  p_operation_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $
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

  return public.create_cloud_sale_with_account(
    p_business_id, v_branch_id, v_warehouse_id, v_scaled_items,
    p_paid_minor, p_customer_id, p_payment_method, p_operation_id
  );
end;
$;

create or replace function public.create_cloud_sale(
  p_business_id uuid,
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_items jsonb,
  p_paid_minor bigint,
  p_operation_id uuid
)
returns uuid
language sql
security definer
set search_path = ''
as $$
  select public.create_cloud_sale_with_account(
    p_business_id, p_branch_id, p_warehouse_id, p_items,
    p_paid_minor, null, 'cash', p_operation_id
  );
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

  return public.create_cloud_sale_with_account(
    p_business_id, v_branch_id, v_warehouse_id,
    v_scaled_items, p_paid_minor, null, 'cash', p_operation_id
  );
end;
$$;

revoke all on function public.create_cloud_sale_with_account(uuid, uuid, uuid, jsonb, bigint, uuid, text, uuid)
  from public, anon;
revoke all on function public.create_cloud_sale_with_account(uuid, jsonb, bigint, uuid, text, uuid)
  from public, anon;
revoke all on function public.create_cloud_sale(uuid, uuid, uuid, jsonb, bigint, uuid)
  from public, anon;
revoke all on function public.create_cloud_sale(uuid, jsonb, bigint, uuid)
  from public, anon;
grant execute on function public.create_cloud_sale_with_account(uuid, uuid, uuid, jsonb, bigint, uuid, text, uuid)
  to authenticated;
grant execute on function public.create_cloud_sale_with_account(uuid, jsonb, bigint, uuid, text, uuid)
  to authenticated;
grant execute on function public.create_cloud_sale(uuid, uuid, uuid, jsonb, bigint, uuid)
  to authenticated;
grant execute on function public.create_cloud_sale(uuid, jsonb, bigint, uuid)
  to authenticated;
