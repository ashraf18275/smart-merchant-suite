-- Cash payments from cloud sales must post to the exact open register session.
create unique index if not exists cloud_cash_sessions_id_business_unique
  on public.cloud_cash_sessions(id, business_id);

alter table public.cloud_sale_payments
  add column if not exists cash_session_id uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'cloud_sale_payments_cash_session_business_fk'
      and conrelid = 'public.cloud_sale_payments'::regclass
  ) then
    alter table public.cloud_sale_payments
      add constraint cloud_sale_payments_cash_session_business_fk
      foreign key (cash_session_id, business_id)
      references public.cloud_cash_sessions(id, business_id)
      on delete restrict;
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'cloud_sale_payments_cash_session_method_check'
      and conrelid = 'public.cloud_sale_payments'::regclass
  ) then
    alter table public.cloud_sale_payments
      add constraint cloud_sale_payments_cash_session_method_check
      check (cash_session_id is null or payment_method = 'cash');
  end if;
end;
$$;

create or replace function public.create_cloud_sale_with_account(
  p_business_id uuid,
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_items jsonb,
  p_paid_minor bigint,
  p_customer_id uuid,
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
  v_hash text;
  v_items jsonb;
  v_existing_hash text;
  v_sale_id uuid;
  v_total_minor bigint;
  v_due_minor bigint;
  v_payment_id uuid;
  v_cash_movement_id uuid;
  v_cash_hash text;
  v_stamp timestamptz := now();
begin
  if auth.uid() is null or p_business_id is null or p_branch_id is null
     or p_warehouse_id is null or p_operation_id is null
     or p_paid_minor is null or p_paid_minor < 0
     or p_items is null or jsonb_typeof(p_items) is distinct from 'array'
     or jsonb_array_length(p_items) = 0
     or p_payment_method is null
     or p_payment_method not in ('cash', 'card', 'bank_transfer', 'wallet')
     or (p_paid_minor > 0 and p_payment_method = 'cash' and p_cash_session_id is null)
     or (p_payment_method <> 'cash' and p_cash_session_id is not null)
     or (p_paid_minor = 0 and p_cash_session_id is not null) then
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
    'payment_method', p_payment_method,
    'cash_session_id', p_cash_session_id
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

  if p_paid_minor > 0 and p_payment_method = 'cash' then
    perform 1 from public.cloud_cash_sessions
    where id = p_cash_session_id
      and business_id = p_business_id
      and branch_id = p_branch_id
      and status = 'open'
    for update;
    if not found then
      raise exception 'cash session is not open in the selected branch'
        using errcode = '23514';
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
      cash_session_id, operation_id, request_hash, actor_user_id, created_at
    ) values (
      p_business_id, v_sale_id, p_customer_id, p_paid_minor, p_payment_method,
      p_cash_session_id, p_operation_id, v_hash, auth.uid(), v_stamp
    ) returning id into v_payment_id;

    if p_payment_method = 'cash' then
      v_cash_hash := encode(public.digest(jsonb_build_object(
        'cash_session_id', p_cash_session_id,
        'direction', 'in',
        'category', 'sale_receipt',
        'amount_minor', p_paid_minor,
        'source_type', 'sale_payment',
        'source_id', v_payment_id
      )::text, 'sha256'), 'hex');

      insert into public.cloud_cash_movements (
        business_id, branch_id, cash_session_id, direction, category,
        amount_minor, source_type, source_id, operation_id, request_hash,
        note, actor_user_id, created_at
      ) values (
        p_business_id, p_branch_id, p_cash_session_id, 'in', 'sale_receipt',
        p_paid_minor, 'sale_payment', v_payment_id, p_operation_id, v_cash_hash,
        'تحصيل نقدي عن فاتورة سحابية', auth.uid(), v_stamp
      ) returning id into v_cash_movement_id;

      insert into public.audit_events (
        business_id, actor_user_id, action_key, entity_type, entity_id, metadata, created_at
      ) values (
        p_business_id, auth.uid(), 'cashbook.sale_receipt', 'cloud_cash_movement',
        v_cash_movement_id::text,
        jsonb_build_object('cash_session_id', p_cash_session_id,
          'sale_id', v_sale_id, 'payment_id', v_payment_id,
          'amount_minor', p_paid_minor), v_stamp
      );
    end if;
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
      'payment_method', case when p_paid_minor > 0 then p_payment_method else null end,
      'cash_session_id', p_cash_session_id
    ), v_stamp
  );

  insert into public.cloud_sale_account_operations (
    business_id, operation_id, request_hash, sale_id, created_at
  ) values (p_business_id, p_operation_id, v_hash, v_sale_id, v_stamp);

  return v_sale_id;
end;
$$;



-- Legacy entry points do not carry a register session and cannot post sales.
revoke all on function public.create_cloud_sale_with_account(uuid, uuid, uuid, jsonb, bigint, uuid, text, uuid)
  from public, anon, authenticated;
revoke all on function public.create_cloud_sale_with_account(uuid, jsonb, bigint, uuid, text, uuid)
  from public, anon, authenticated;
revoke all on function public.create_cloud_sale(uuid, uuid, uuid, jsonb, bigint, uuid)
  from public, anon, authenticated;
revoke all on function public.create_cloud_sale(uuid, jsonb, bigint, uuid)
  from public, anon, authenticated;

revoke all on function public.create_cloud_sale_with_account(uuid, uuid, uuid, jsonb, bigint, uuid, text, uuid, uuid)
  from public, anon;
grant execute on function public.create_cloud_sale_with_account(uuid, uuid, uuid, jsonb, bigint, uuid, text, uuid, uuid)
  to authenticated;
