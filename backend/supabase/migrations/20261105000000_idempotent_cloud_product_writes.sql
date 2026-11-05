-- Product writes must be transactional and idempotent; clients may only read products.
-- The receipt table is intentionally inaccessible to client roles.
create table if not exists public.cloud_product_write_receipts (
  business_id uuid not null references public.businesses(id) on delete cascade,
  operation_id uuid not null,
  operation_type text not null check (operation_type in ('create', 'update')),
  product_id uuid not null,
  request_hash text not null check (length(request_hash) = 64),
  created_at timestamptz not null default now(),
  primary key (business_id, operation_id),
  foreign key (product_id, business_id)
    references public.cloud_products(id, business_id) on delete cascade
);

alter table public.cloud_product_write_receipts enable row level security;
revoke all on public.cloud_product_write_receipts from public, anon, authenticated;

-- Remove the earlier column-level write grants. All product mutations now pass
-- through the audited, tenant-scoped RPCs below.
revoke insert (business_id, name, sku, cost_minor, price_minor)
  on public.cloud_products from anon, authenticated;
revoke update (name, sku, cost_minor, price_minor)
  on public.cloud_products from anon, authenticated;
revoke update (is_active)
  on public.cloud_products from anon, authenticated;

create or replace function public.create_cloud_product(
  p_business_id uuid,
  p_operation_id uuid,
  p_name text,
  p_sku text,
  p_cost_minor bigint,
  p_price_minor bigint
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_sku text := nullif(btrim(coalesce(p_sku, '')), '');
  v_request_hash text;
  v_product_id uuid;
  v_existing_hash text;
  v_existing_type text;
begin
  if auth.uid() is null
     or p_business_id is null
     or p_operation_id is null
     or length(v_name) = 0
     or length(v_name) > 250
     or length(coalesce(v_sku, '')) > 120
     or p_cost_minor is null or p_cost_minor < 0
     or p_price_minor is null or p_price_minor < 0 then
    raise exception 'invalid cloud product payload' using errcode = '22023';
  end if;

  if not public.has_business_permission(p_business_id, 'products.create') then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  v_request_hash := encode(
    public.digest(
      jsonb_build_object(
        'operation_type', 'create',
        'name', v_name,
        'sku', v_sku,
        'cost_minor', p_cost_minor,
        'price_minor', p_price_minor
      )::text,
      'sha256'
    ),
    'hex'
  );

  perform pg_advisory_xact_lock(hashtextextended(
    p_business_id::text || ':' || p_operation_id::text,
    0
  ));

  select product_id, request_hash, operation_type
  into v_product_id, v_existing_hash, v_existing_type
  from public.cloud_product_write_receipts
  where business_id = p_business_id and operation_id = p_operation_id;

  if v_product_id is not null then
    if v_existing_type is distinct from 'create'
       or v_existing_hash is distinct from v_request_hash then
      raise exception 'idempotency key reused with different product payload'
        using errcode = '22023';
    end if;
    return v_product_id;
  end if;

  insert into public.cloud_products (
    business_id, name, sku, cost_minor, price_minor, created_by
  ) values (
    p_business_id, v_name, v_sku, p_cost_minor, p_price_minor, auth.uid()
  )
  returning id into v_product_id;

  insert into public.cloud_product_write_receipts (
    business_id, operation_id, operation_type, product_id, request_hash
  ) values (
    p_business_id, p_operation_id, 'create', v_product_id, v_request_hash
  );

  insert into public.audit_events (
    business_id, actor_user_id, action_key, entity_type, entity_id, metadata
  ) values (
    p_business_id, auth.uid(), 'products.create', 'cloud_product',
    v_product_id::text,
    jsonb_build_object(
      'name', v_name, 'sku', v_sku,
      'cost_minor', p_cost_minor, 'price_minor', p_price_minor
    )
  );

  return v_product_id;
end;
$function$;

create or replace function public.update_cloud_product(
  p_business_id uuid,
  p_operation_id uuid,
  p_product_id uuid,
  p_base_name text,
  p_base_sku text,
  p_base_cost_minor bigint,
  p_base_price_minor bigint,
  p_base_is_active boolean,
  p_name text,
  p_sku text,
  p_cost_minor bigint,
  p_price_minor bigint,
  p_is_active boolean
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_sku text := nullif(btrim(coalesce(p_sku, '')), '');
  v_base_name text := btrim(coalesce(p_base_name, ''));
  v_base_sku text := nullif(btrim(coalesce(p_base_sku, '')), '');
  v_request_hash text;
  v_product_id uuid;
  v_existing_hash text;
  v_existing_type text;
  v_current_name text;
  v_current_sku text;
  v_current_cost bigint;
  v_current_price bigint;
  v_current_active boolean;
begin
  if auth.uid() is null
     or p_business_id is null
     or p_operation_id is null
     or p_product_id is null
     or length(v_base_name) = 0
     or length(v_base_name) > 250
     or length(v_name) = 0
     or length(v_name) > 250
     or length(coalesce(v_base_sku, '')) > 120
     or length(coalesce(v_sku, '')) > 120
     or p_base_cost_minor is null or p_base_cost_minor < 0
     or p_base_price_minor is null or p_base_price_minor < 0
     or p_base_is_active is null
     or p_cost_minor is null or p_cost_minor < 0
     or p_price_minor is null or p_price_minor < 0
     or p_is_active is null then
    raise exception 'invalid cloud product update payload' using errcode = '22023';
  end if;

  if not public.has_business_permission(p_business_id, 'products.edit') then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  v_request_hash := encode(
    public.digest(
      jsonb_build_object(
        'operation_type', 'update',
        'product_id', p_product_id,
        'base', jsonb_build_object(
          'name', v_base_name,
          'sku', v_base_sku,
          'cost_minor', p_base_cost_minor,
          'price_minor', p_base_price_minor,
          'is_active', p_base_is_active
        ),
        'record', jsonb_build_object(
          'name', v_name,
          'sku', v_sku,
          'cost_minor', p_cost_minor,
          'price_minor', p_price_minor,
          'is_active', p_is_active
        )
      )::text,
      'sha256'
    ),
    'hex'
  );

  perform pg_advisory_xact_lock(hashtextextended(
    p_business_id::text || ':' || p_operation_id::text,
    0
  ));

  select product_id, request_hash, operation_type
  into v_product_id, v_existing_hash, v_existing_type
  from public.cloud_product_write_receipts
  where business_id = p_business_id and operation_id = p_operation_id;

  if v_product_id is not null then
    if v_existing_type is distinct from 'update'
       or v_existing_hash is distinct from v_request_hash then
      raise exception 'idempotency key reused with different product payload'
        using errcode = '22023';
    end if;
    return v_product_id;
  end if;

  select p.name, p.sku, p.cost_minor, p.price_minor, p.is_active
  into v_current_name, v_current_sku, v_current_cost, v_current_price, v_current_active
  from public.cloud_products p
  where p.id = p_product_id and p.business_id = p_business_id
  for update;

  if not found then
    raise exception 'product not found in business' using errcode = 'P0002';
  end if;

  if v_current_name is distinct from v_base_name
     or v_current_sku is distinct from v_base_sku
     or v_current_cost is distinct from p_base_cost_minor
     or v_current_price is distinct from p_base_price_minor
     or v_current_active is distinct from p_base_is_active then
    raise exception 'cloud product changed since the local base snapshot'
      using errcode = '40001';
  end if;

  update public.cloud_products
  set name = v_name,
      sku = v_sku,
      cost_minor = p_cost_minor,
      price_minor = p_price_minor,
      is_active = p_is_active,
      updated_at = now()
  where id = p_product_id and business_id = p_business_id;

  insert into public.cloud_product_write_receipts (
    business_id, operation_id, operation_type, product_id, request_hash
  ) values (
    p_business_id, p_operation_id, 'update', p_product_id, v_request_hash
  );

  insert into public.audit_events (
    business_id, actor_user_id, action_key, entity_type, entity_id, metadata
  ) values (
    p_business_id, auth.uid(), 'products.edit', 'cloud_product',
    p_product_id::text,
    jsonb_build_object(
      'before', jsonb_build_object(
        'name', v_current_name, 'sku', v_current_sku,
        'cost_minor', v_current_cost, 'price_minor', v_current_price,
        'is_active', v_current_active
      ),
      'after', jsonb_build_object(
        'name', v_name, 'sku', v_sku,
        'cost_minor', p_cost_minor, 'price_minor', p_price_minor,
        'is_active', p_is_active
      )
    )
  );

  return p_product_id;
end;
$function$;

revoke all on function public.create_cloud_product(uuid, uuid, text, text, bigint, bigint)
  from public, anon;
revoke all on function public.update_cloud_product(
  uuid, uuid, uuid, text, text, bigint, bigint, boolean,
  text, text, bigint, bigint, boolean
) from public, anon;

grant execute on function public.create_cloud_product(uuid, uuid, text, text, bigint, bigint)
  to authenticated;
grant execute on function public.update_cloud_product(
  uuid, uuid, uuid, text, text, bigint, bigint, boolean,
  text, text, bigint, bigint, boolean
) to authenticated;

comment on table public.cloud_product_write_receipts is
  'Tenant-scoped idempotency receipts for cloud product create and optimistic-concurrency update RPCs.';
