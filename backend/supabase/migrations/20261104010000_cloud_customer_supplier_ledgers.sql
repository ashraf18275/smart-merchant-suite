-- Tenant-scoped customer/supplier ledgers and independently tracked account payments.
-- All financial writes are append-only, transactional and idempotent.
create table if not exists public.cloud_customers (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 160),
  phone text,
  address text,
  is_active boolean not null default true,
  operation_id uuid not null,
  request_hash text not null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (id, business_id),
  unique (business_id, operation_id)
);

create table if not exists public.cloud_suppliers (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 160),
  phone text,
  address text,
  is_active boolean not null default true,
  operation_id uuid not null,
  request_hash text not null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (id, business_id),
  unique (business_id, operation_id)
);

create table if not exists public.cloud_customer_account_entries (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  customer_id uuid not null,
  amount_minor bigint not null check (amount_minor <> 0),
  entry_type text not null check (entry_type in (
    'opening_balance', 'sale', 'receipt', 'return', 'refund', 'adjustment', 'sale_cancel'
  )),
  reference_type text,
  reference_id uuid,
  operation_id uuid not null,
  note text,
  actor_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (id, business_id),
  unique (business_id, operation_id),
  foreign key (customer_id, business_id)
    references public.cloud_customers(id, business_id) on delete restrict
);

create table if not exists public.cloud_supplier_account_entries (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  supplier_id uuid not null,
  amount_minor bigint not null check (amount_minor <> 0),
  entry_type text not null check (entry_type in (
    'opening_balance', 'purchase', 'payment', 'return', 'refund', 'adjustment', 'purchase_cancel'
  )),
  reference_type text,
  reference_id uuid,
  operation_id uuid not null,
  note text,
  actor_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (id, business_id),
  unique (business_id, operation_id),
  foreign key (supplier_id, business_id)
    references public.cloud_suppliers(id, business_id) on delete restrict
);

create table if not exists public.cloud_customer_payments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  customer_id uuid not null,
  account_entry_id uuid not null,
  amount_minor bigint not null check (amount_minor > 0),
  payment_method text not null check (payment_method in ('cash', 'card', 'bank_transfer', 'wallet')),
  operation_id uuid not null,
  request_hash text not null,
  note text,
  actor_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (id, business_id),
  unique (business_id, operation_id),
  foreign key (customer_id, business_id)
    references public.cloud_customers(id, business_id) on delete restrict,
  foreign key (account_entry_id, business_id)
    references public.cloud_customer_account_entries(id, business_id) on delete restrict
);

create table if not exists public.cloud_supplier_payments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  supplier_id uuid not null,
  account_entry_id uuid not null,
  amount_minor bigint not null check (amount_minor > 0),
  payment_method text not null check (payment_method in ('cash', 'card', 'bank_transfer', 'wallet')),
  operation_id uuid not null,
  request_hash text not null,
  note text,
  actor_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (id, business_id),
  unique (business_id, operation_id),
  foreign key (supplier_id, business_id)
    references public.cloud_suppliers(id, business_id) on delete restrict,
  foreign key (account_entry_id, business_id)
    references public.cloud_supplier_account_entries(id, business_id) on delete restrict
);

create index if not exists cloud_customers_business_name_idx
  on public.cloud_customers(business_id, name);
create index if not exists cloud_suppliers_business_name_idx
  on public.cloud_suppliers(business_id, name);
create index if not exists cloud_customer_entries_statement_idx
  on public.cloud_customer_account_entries(business_id, customer_id, created_at, id);
create index if not exists cloud_supplier_entries_statement_idx
  on public.cloud_supplier_account_entries(business_id, supplier_id, created_at, id);

alter table public.cloud_customers enable row level security;
alter table public.cloud_suppliers enable row level security;
alter table public.cloud_customer_account_entries enable row level security;
alter table public.cloud_supplier_account_entries enable row level security;
alter table public.cloud_customer_payments enable row level security;
alter table public.cloud_supplier_payments enable row level security;

drop policy if exists cloud_customers_select_authorized on public.cloud_customers;
create policy cloud_customers_select_authorized on public.cloud_customers
  for select to authenticated
  using (
    public.has_business_permission(business_id, 'customers.view')
    or public.has_business_permission(business_id, 'sales.view')
    or public.has_business_permission(business_id, 'sales.create')
    or public.has_business_permission(business_id, 'accounts.view')
  );

drop policy if exists cloud_suppliers_select_authorized on public.cloud_suppliers;
create policy cloud_suppliers_select_authorized on public.cloud_suppliers
  for select to authenticated
  using (
    public.has_business_permission(business_id, 'suppliers.view')
    or public.has_business_permission(business_id, 'purchases.view')
    or public.has_business_permission(business_id, 'purchases.create')
    or public.has_business_permission(business_id, 'accounts.view')
  );

drop policy if exists cloud_customer_entries_select_authorized on public.cloud_customer_account_entries;
create policy cloud_customer_entries_select_authorized on public.cloud_customer_account_entries
  for select to authenticated
  using (
    public.has_business_permission(business_id, 'accounts.view')
    or public.has_business_permission(business_id, 'customers.view')
    or public.has_business_permission(business_id, 'reports.view')
  );

drop policy if exists cloud_supplier_entries_select_authorized on public.cloud_supplier_account_entries;
create policy cloud_supplier_entries_select_authorized on public.cloud_supplier_account_entries
  for select to authenticated
  using (
    public.has_business_permission(business_id, 'accounts.view')
    or public.has_business_permission(business_id, 'suppliers.view')
    or public.has_business_permission(business_id, 'reports.view')
  );

drop policy if exists cloud_customer_payments_select_authorized on public.cloud_customer_payments;
create policy cloud_customer_payments_select_authorized on public.cloud_customer_payments
  for select to authenticated
  using (
    public.has_business_permission(business_id, 'accounts.view')
    or public.has_business_permission(business_id, 'cashbook.view')
  );

drop policy if exists cloud_supplier_payments_select_authorized on public.cloud_supplier_payments;
create policy cloud_supplier_payments_select_authorized on public.cloud_supplier_payments
  for select to authenticated
  using (
    public.has_business_permission(business_id, 'accounts.view')
    or public.has_business_permission(business_id, 'cashbook.view')
  );

revoke all on public.cloud_customers, public.cloud_suppliers,
  public.cloud_customer_account_entries, public.cloud_supplier_account_entries,
  public.cloud_customer_payments, public.cloud_supplier_payments
  from anon, authenticated;
grant select on public.cloud_customers, public.cloud_suppliers,
  public.cloud_customer_account_entries, public.cloud_supplier_account_entries,
  public.cloud_customer_payments, public.cloud_supplier_payments
  to authenticated;

create or replace function public.create_cloud_customer(
  p_business_id uuid,
  p_name text,
  p_phone text,
  p_address text,
  p_opening_balance_minor bigint,
  p_operation_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_phone text := nullif(btrim(coalesce(p_phone, '')), '');
  v_address text := nullif(btrim(coalesce(p_address, '')), '');
  v_hash text;
  v_existing_id uuid;
  v_existing_hash text;
  v_customer_id uuid;
  v_stamp timestamptz := now();
begin
  if auth.uid() is null or p_business_id is null or p_operation_id is null
     or length(v_name) < 1 or length(v_name) > 160
     or length(coalesce(v_phone, '')) > 40
     or length(coalesce(v_address, '')) > 250
     or p_opening_balance_minor is null then
    raise exception 'invalid customer details' using errcode = '22023';
  end if;
  if not public.has_business_permission(p_business_id, 'customers.create') then
    raise exception 'customer creation is not allowed' using errcode = '42501';
  end if;
  if p_opening_balance_minor <> 0
     and not public.has_business_permission(p_business_id, 'accounts.adjust') then
    raise exception 'opening balance adjustment is not allowed' using errcode = '42501';
  end if;

  v_hash := encode(public.digest(jsonb_build_object(
    'name', v_name, 'phone', v_phone, 'address', v_address,
    'opening_balance_minor', p_opening_balance_minor
  )::text, 'sha256'), 'hex');
  perform pg_advisory_xact_lock(hashtextextended(
    p_business_id::text || ':customer:' || p_operation_id::text, 0
  ));
  select id, request_hash into v_existing_id, v_existing_hash
  from public.cloud_customers
  where business_id = p_business_id and operation_id = p_operation_id;
  if v_existing_id is not null then
    if v_existing_hash is distinct from v_hash then
      raise exception 'customer operation key reused with different payload'
        using errcode = '22023';
    end if;
    return v_existing_id;
  end if;

  insert into public.cloud_customers (
    business_id, name, phone, address, operation_id, request_hash, created_by, created_at
  ) values (
    p_business_id, v_name, v_phone, v_address, p_operation_id, v_hash, auth.uid(), v_stamp
  ) returning id into v_customer_id;

  if p_opening_balance_minor <> 0 then
    insert into public.cloud_customer_account_entries (
      business_id, customer_id, amount_minor, entry_type, reference_type,
      reference_id, operation_id, note, actor_user_id, created_at
    ) values (
      p_business_id, v_customer_id, p_opening_balance_minor, 'opening_balance',
      'customer_opening_balance', v_customer_id, p_operation_id,
      'رصيد افتتاحي عند إنشاء حساب العميل', auth.uid(), v_stamp
    );
  end if;

  insert into public.audit_events (
    business_id, actor_user_id, action_key, entity_type, entity_id, metadata, created_at
  ) values (
    p_business_id, auth.uid(), 'customers.create', 'cloud_customer', v_customer_id::text,
    jsonb_build_object('name', v_name, 'opening_balance_minor', p_opening_balance_minor), v_stamp
  );
  return v_customer_id;
end;
$$;

create or replace function public.create_cloud_supplier(
  p_business_id uuid,
  p_name text,
  p_phone text,
  p_address text,
  p_opening_balance_minor bigint,
  p_operation_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_phone text := nullif(btrim(coalesce(p_phone, '')), '');
  v_address text := nullif(btrim(coalesce(p_address, '')), '');
  v_hash text;
  v_existing_id uuid;
  v_existing_hash text;
  v_supplier_id uuid;
  v_stamp timestamptz := now();
begin
  if auth.uid() is null or p_business_id is null or p_operation_id is null
     or length(v_name) < 1 or length(v_name) > 160
     or length(coalesce(v_phone, '')) > 40
     or length(coalesce(v_address, '')) > 250
     or p_opening_balance_minor is null then
    raise exception 'invalid supplier details' using errcode = '22023';
  end if;
  if not public.has_business_permission(p_business_id, 'suppliers.create') then
    raise exception 'supplier creation is not allowed' using errcode = '42501';
  end if;
  if p_opening_balance_minor <> 0
     and not public.has_business_permission(p_business_id, 'accounts.adjust') then
    raise exception 'opening balance adjustment is not allowed' using errcode = '42501';
  end if;

  v_hash := encode(public.digest(jsonb_build_object(
    'name', v_name, 'phone', v_phone, 'address', v_address,
    'opening_balance_minor', p_opening_balance_minor
  )::text, 'sha256'), 'hex');
  perform pg_advisory_xact_lock(hashtextextended(
    p_business_id::text || ':supplier:' || p_operation_id::text, 0
  ));
  select id, request_hash into v_existing_id, v_existing_hash
  from public.cloud_suppliers
  where business_id = p_business_id and operation_id = p_operation_id;
  if v_existing_id is not null then
    if v_existing_hash is distinct from v_hash then
      raise exception 'supplier operation key reused with different payload'
        using errcode = '22023';
    end if;
    return v_existing_id;
  end if;

  insert into public.cloud_suppliers (
    business_id, name, phone, address, operation_id, request_hash, created_by, created_at
  ) values (
    p_business_id, v_name, v_phone, v_address, p_operation_id, v_hash, auth.uid(), v_stamp
  ) returning id into v_supplier_id;

  if p_opening_balance_minor <> 0 then
    insert into public.cloud_supplier_account_entries (
      business_id, supplier_id, amount_minor, entry_type, reference_type,
      reference_id, operation_id, note, actor_user_id, created_at
    ) values (
      p_business_id, v_supplier_id, p_opening_balance_minor, 'opening_balance',
      'supplier_opening_balance', v_supplier_id, p_operation_id,
      'رصيد افتتاحي عند إنشاء حساب المورد', auth.uid(), v_stamp
    );
  end if;

  insert into public.audit_events (
    business_id, actor_user_id, action_key, entity_type, entity_id, metadata, created_at
  ) values (
    p_business_id, auth.uid(), 'suppliers.create', 'cloud_supplier', v_supplier_id::text,
    jsonb_build_object('name', v_name, 'opening_balance_minor', p_opening_balance_minor), v_stamp
  );
  return v_supplier_id;
end;
$$;

create or replace function public.record_cloud_customer_receipt(
  p_business_id uuid,
  p_customer_id uuid,
  p_amount_minor bigint,
  p_payment_method text,
  p_note text,
  p_operation_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_balance bigint;
  v_hash text;
  v_existing_id uuid;
  v_existing_hash text;
  v_entry_id uuid;
  v_payment_id uuid;
  v_stamp timestamptz := now();
begin
  if auth.uid() is null or p_business_id is null or p_customer_id is null
     or p_operation_id is null or p_amount_minor is null or p_amount_minor <= 0
     or p_payment_method not in ('cash', 'card', 'bank_transfer', 'wallet')
     or length(coalesce(p_note, '')) > 500 then
    raise exception 'invalid customer receipt' using errcode = '22023';
  end if;
  if not public.has_business_permission(p_business_id, 'accounts.customer.receipt') then
    raise exception 'customer receipt is not allowed' using errcode = '42501';
  end if;

  v_hash := encode(public.digest(jsonb_build_object(
    'customer_id', p_customer_id, 'amount_minor', p_amount_minor,
    'payment_method', p_payment_method, 'note', nullif(btrim(coalesce(p_note, '')), '')
  )::text, 'sha256'), 'hex');
  perform pg_advisory_xact_lock(hashtextextended(
    p_business_id::text || ':customer-receipt:' || p_operation_id::text, 0
  ));
  select id, request_hash into v_existing_id, v_existing_hash
  from public.cloud_customer_payments
  where business_id = p_business_id and operation_id = p_operation_id;
  if v_existing_id is not null then
    if v_existing_hash is distinct from v_hash then
      raise exception 'customer receipt key reused with different payload'
        using errcode = '22023';
    end if;
    return v_existing_id;
  end if;

  perform 1 from public.cloud_customers
  where id = p_customer_id and business_id = p_business_id and is_active
  for update;
  if not found then
    raise exception 'customer unavailable' using errcode = '23514';
  end if;
  select coalesce(sum(amount_minor), 0) into v_balance
  from public.cloud_customer_account_entries
  where business_id = p_business_id and customer_id = p_customer_id;
  if p_amount_minor > v_balance then
    raise exception 'customer balance is lower than receipt amount' using errcode = '23514';
  end if;

  insert into public.cloud_customer_account_entries (
    business_id, customer_id, amount_minor, entry_type, reference_type,
    reference_id, operation_id, note, actor_user_id, created_at
  ) values (
    p_business_id, p_customer_id, -p_amount_minor, 'receipt', 'customer_receipt',
    p_operation_id, p_operation_id, nullif(btrim(coalesce(p_note, '')), ''),
    auth.uid(), v_stamp
  ) returning id into v_entry_id;

  insert into public.cloud_customer_payments (
    business_id, customer_id, account_entry_id, amount_minor, payment_method,
    operation_id, request_hash, note, actor_user_id, created_at
  ) values (
    p_business_id, p_customer_id, v_entry_id, p_amount_minor, p_payment_method,
    p_operation_id, v_hash, nullif(btrim(coalesce(p_note, '')), ''), auth.uid(), v_stamp
  ) returning id into v_payment_id;

  insert into public.audit_events (
    business_id, actor_user_id, action_key, entity_type, entity_id, metadata, created_at
  ) values (
    p_business_id, auth.uid(), 'accounts.customer.receipt', 'cloud_customer_payment',
    v_payment_id::text,
    jsonb_build_object('customer_id', p_customer_id, 'amount_minor', p_amount_minor,
      'payment_method', p_payment_method, 'account_entry_id', v_entry_id), v_stamp
  );
  return v_payment_id;
end;
$$;

create or replace function public.record_cloud_supplier_payment(
  p_business_id uuid,
  p_supplier_id uuid,
  p_amount_minor bigint,
  p_payment_method text,
  p_note text,
  p_operation_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_balance bigint;
  v_hash text;
  v_existing_id uuid;
  v_existing_hash text;
  v_entry_id uuid;
  v_payment_id uuid;
  v_stamp timestamptz := now();
begin
  if auth.uid() is null or p_business_id is null or p_supplier_id is null
     or p_operation_id is null or p_amount_minor is null or p_amount_minor <= 0
     or p_payment_method not in ('cash', 'card', 'bank_transfer', 'wallet')
     or length(coalesce(p_note, '')) > 500 then
    raise exception 'invalid supplier payment' using errcode = '22023';
  end if;
  if not public.has_business_permission(p_business_id, 'accounts.supplier.payment') then
    raise exception 'supplier payment is not allowed' using errcode = '42501';
  end if;

  v_hash := encode(public.digest(jsonb_build_object(
    'supplier_id', p_supplier_id, 'amount_minor', p_amount_minor,
    'payment_method', p_payment_method, 'note', nullif(btrim(coalesce(p_note, '')), '')
  )::text, 'sha256'), 'hex');
  perform pg_advisory_xact_lock(hashtextextended(
    p_business_id::text || ':supplier-payment:' || p_operation_id::text, 0
  ));
  select id, request_hash into v_existing_id, v_existing_hash
  from public.cloud_supplier_payments
  where business_id = p_business_id and operation_id = p_operation_id;
  if v_existing_id is not null then
    if v_existing_hash is distinct from v_hash then
      raise exception 'supplier payment key reused with different payload'
        using errcode = '22023';
    end if;
    return v_existing_id;
  end if;

  perform 1 from public.cloud_suppliers
  where id = p_supplier_id and business_id = p_business_id and is_active
  for update;
  if not found then
    raise exception 'supplier unavailable' using errcode = '23514';
  end if;
  select coalesce(sum(amount_minor), 0) into v_balance
  from public.cloud_supplier_account_entries
  where business_id = p_business_id and supplier_id = p_supplier_id;
  if p_amount_minor > v_balance then
    raise exception 'supplier balance is lower than payment amount' using errcode = '23514';
  end if;

  insert into public.cloud_supplier_account_entries (
    business_id, supplier_id, amount_minor, entry_type, reference_type,
    reference_id, operation_id, note, actor_user_id, created_at
  ) values (
    p_business_id, p_supplier_id, -p_amount_minor, 'payment', 'supplier_payment',
    p_operation_id, p_operation_id, nullif(btrim(coalesce(p_note, '')), ''),
    auth.uid(), v_stamp
  ) returning id into v_entry_id;

  insert into public.cloud_supplier_payments (
    business_id, supplier_id, account_entry_id, amount_minor, payment_method,
    operation_id, request_hash, note, actor_user_id, created_at
  ) values (
    p_business_id, p_supplier_id, v_entry_id, p_amount_minor, p_payment_method,
    p_operation_id, v_hash, nullif(btrim(coalesce(p_note, '')), ''), auth.uid(), v_stamp
  ) returning id into v_payment_id;

  insert into public.audit_events (
    business_id, actor_user_id, action_key, entity_type, entity_id, metadata, created_at
  ) values (
    p_business_id, auth.uid(), 'accounts.supplier.payment', 'cloud_supplier_payment',
    v_payment_id::text,
    jsonb_build_object('supplier_id', p_supplier_id, 'amount_minor', p_amount_minor,
      'payment_method', p_payment_method, 'account_entry_id', v_entry_id), v_stamp
  );
  return v_payment_id;
end;
$$;

revoke all on function public.create_cloud_customer(uuid, text, text, text, bigint, uuid) from public;
revoke all on function public.create_cloud_supplier(uuid, text, text, text, bigint, uuid) from public;
revoke all on function public.record_cloud_customer_receipt(uuid, uuid, bigint, text, text, uuid) from public;
revoke all on function public.record_cloud_supplier_payment(uuid, uuid, bigint, text, text, uuid) from public;
grant execute on function public.create_cloud_customer(uuid, text, text, text, bigint, uuid) to authenticated;
grant execute on function public.create_cloud_supplier(uuid, text, text, text, bigint, uuid) to authenticated;
grant execute on function public.record_cloud_customer_receipt(uuid, uuid, bigint, text, text, uuid) to authenticated;
grant execute on function public.record_cloud_supplier_payment(uuid, uuid, bigint, text, text, uuid) to authenticated;
