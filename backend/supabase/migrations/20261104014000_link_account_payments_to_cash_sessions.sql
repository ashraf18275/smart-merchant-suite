-- Cash account receipts and supplier payments must belong to an open cash session.
-- Electronic payments are recorded in the account payment tables only and never
-- create physical cash movements.
create unique index if not exists cloud_cash_sessions_id_business_uidx
  on public.cloud_cash_sessions(id, business_id);

alter table public.cloud_customer_payments
  add column if not exists cash_session_id uuid;
alter table public.cloud_supplier_payments
  add column if not exists cash_session_id uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'cloud_customer_payments_cash_session_fk'
      and conrelid = 'public.cloud_customer_payments'::regclass
  ) then
    alter table public.cloud_customer_payments
      add constraint cloud_customer_payments_cash_session_fk
      foreign key (cash_session_id, business_id)
      references public.cloud_cash_sessions(id, business_id)
      on delete restrict;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'cloud_supplier_payments_cash_session_fk'
      and conrelid = 'public.cloud_supplier_payments'::regclass
  ) then
    alter table public.cloud_supplier_payments
      add constraint cloud_supplier_payments_cash_session_fk
      foreign key (cash_session_id, business_id)
      references public.cloud_cash_sessions(id, business_id)
      on delete restrict;
  end if;
end;
$$;

drop function if exists public.record_cloud_customer_receipt(uuid, uuid, bigint, text, text, uuid);
drop function if exists public.record_cloud_supplier_payment(uuid, uuid, bigint, text, text, uuid);

create or replace function public.record_cloud_customer_receipt(
  p_business_id uuid,
  p_customer_id uuid,
  p_amount_minor bigint,
  p_payment_method text,
  p_note text,
  p_operation_id uuid,
  p_cash_session_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_balance bigint;
  v_hash text;
  v_existing_id uuid;
  v_existing_hash text;
  v_entry_id uuid;
  v_payment_id uuid;
  v_cash_branch_id uuid;
  v_stamp timestamptz := now();
begin
  if auth.uid() is null or p_business_id is null or p_customer_id is null
     or p_operation_id is null or p_amount_minor is null or p_amount_minor <= 0
     or p_payment_method is null
     or p_payment_method not in ('cash', 'card', 'bank_transfer', 'wallet')
     or length(coalesce(p_note, '')) > 500 then
    raise exception 'invalid customer receipt' using errcode = '22023';
  end if;
  if not public.has_business_permission(p_business_id, 'accounts.customer.receipt') then
    raise exception 'customer receipt is not allowed' using errcode = '42501';
  end if;
  if p_payment_method = 'cash' and p_cash_session_id is null then
    raise exception 'cash receipt requires an open cash session' using errcode = '23514';
  end if;
  if p_payment_method <> 'cash' and p_cash_session_id is not null then
    raise exception 'electronic receipt cannot use a cash session' using errcode = '22023';
  end if;

  v_hash := encode(public.digest(jsonb_build_object(
    'customer_id', p_customer_id,
    'amount_minor', p_amount_minor,
    'payment_method', p_payment_method,
    'cash_session_id', p_cash_session_id,
    'note', nullif(btrim(coalesce(p_note, '')), '')
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

  if p_payment_method = 'cash' then
    select s.branch_id into v_cash_branch_id
    from public.cloud_cash_sessions s
    where s.id = p_cash_session_id
      and s.business_id = p_business_id
      and s.status = 'open'
    for update;
    if not found then
      raise exception 'cash receipt session is not open or unavailable' using errcode = '23514';
    end if;
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
    operation_id, request_hash, note, actor_user_id, cash_session_id, created_at
  ) values (
    p_business_id, p_customer_id, v_entry_id, p_amount_minor, p_payment_method,
    p_operation_id, v_hash, nullif(btrim(coalesce(p_note, '')), ''),
    auth.uid(), p_cash_session_id, v_stamp
  ) returning id into v_payment_id;

  if p_payment_method = 'cash' then
    insert into public.cloud_cash_movements (
      business_id, branch_id, cash_session_id, direction, category,
      amount_minor, source_type, source_id, operation_id, request_hash,
      note, actor_user_id, created_at
    ) values (
      p_business_id, v_cash_branch_id, p_cash_session_id, 'in', 'customer_receipt',
      p_amount_minor, 'customer_receipt', v_payment_id, p_operation_id, v_hash,
      nullif(btrim(coalesce(p_note, '')), ''), auth.uid(), v_stamp
    );
  end if;

  insert into public.audit_events (
    business_id, actor_user_id, action_key, entity_type, entity_id, metadata, created_at
  ) values (
    p_business_id, auth.uid(), 'accounts.customer.receipt', 'cloud_customer_payment',
    v_payment_id::text,
    jsonb_build_object(
      'customer_id', p_customer_id,
      'amount_minor', p_amount_minor,
      'payment_method', p_payment_method,
      'cash_session_id', p_cash_session_id,
      'account_entry_id', v_entry_id
    ),
    v_stamp
  );
  return v_payment_id;
end;
$function$;

create or replace function public.record_cloud_supplier_payment(
  p_business_id uuid,
  p_supplier_id uuid,
  p_amount_minor bigint,
  p_payment_method text,
  p_note text,
  p_operation_id uuid,
  p_cash_session_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_balance bigint;
  v_hash text;
  v_existing_id uuid;
  v_existing_hash text;
  v_entry_id uuid;
  v_payment_id uuid;
  v_cash_branch_id uuid;
  v_stamp timestamptz := now();
begin
  if auth.uid() is null or p_business_id is null or p_supplier_id is null
     or p_operation_id is null or p_amount_minor is null or p_amount_minor <= 0
     or p_payment_method is null
     or p_payment_method not in ('cash', 'card', 'bank_transfer', 'wallet')
     or length(coalesce(p_note, '')) > 500 then
    raise exception 'invalid supplier payment' using errcode = '22023';
  end if;
  if not public.has_business_permission(p_business_id, 'accounts.supplier.payment') then
    raise exception 'supplier payment is not allowed' using errcode = '42501';
  end if;
  if p_payment_method = 'cash' and p_cash_session_id is null then
    raise exception 'cash supplier payment requires an open cash session' using errcode = '23514';
  end if;
  if p_payment_method <> 'cash' and p_cash_session_id is not null then
    raise exception 'electronic supplier payment cannot use a cash session' using errcode = '22023';
  end if;

  v_hash := encode(public.digest(jsonb_build_object(
    'supplier_id', p_supplier_id,
    'amount_minor', p_amount_minor,
    'payment_method', p_payment_method,
    'cash_session_id', p_cash_session_id,
    'note', nullif(btrim(coalesce(p_note, '')), '')
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

  if p_payment_method = 'cash' then
    select s.branch_id into v_cash_branch_id
    from public.cloud_cash_sessions s
    where s.id = p_cash_session_id
      and s.business_id = p_business_id
      and s.status = 'open'
    for update;
    if not found then
      raise exception 'cash supplier payment session is not open or unavailable' using errcode = '23514';
    end if;
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
    operation_id, request_hash, note, actor_user_id, cash_session_id, created_at
  ) values (
    p_business_id, p_supplier_id, v_entry_id, p_amount_minor, p_payment_method,
    p_operation_id, v_hash, nullif(btrim(coalesce(p_note, '')), ''),
    auth.uid(), p_cash_session_id, v_stamp
  ) returning id into v_payment_id;

  if p_payment_method = 'cash' then
    insert into public.cloud_cash_movements (
      business_id, branch_id, cash_session_id, direction, category,
      amount_minor, source_type, source_id, operation_id, request_hash,
      note, actor_user_id, created_at
    ) values (
      p_business_id, v_cash_branch_id, p_cash_session_id, 'out', 'supplier_payment',
      p_amount_minor, 'supplier_payment', v_payment_id, p_operation_id, v_hash,
      nullif(btrim(coalesce(p_note, '')), ''), auth.uid(), v_stamp
    );
  end if;

  insert into public.audit_events (
    business_id, actor_user_id, action_key, entity_type, entity_id, metadata, created_at
  ) values (
    p_business_id, auth.uid(), 'accounts.supplier.payment', 'cloud_supplier_payment',
    v_payment_id::text,
    jsonb_build_object(
      'supplier_id', p_supplier_id,
      'amount_minor', p_amount_minor,
      'payment_method', p_payment_method,
      'cash_session_id', p_cash_session_id,
      'account_entry_id', v_entry_id
    ),
    v_stamp
  );
  return v_payment_id;
end;
$function$;

create or replace function public.record_cloud_customer_receipt(
  p_business_id uuid,
  p_customer_id uuid,
  p_amount_minor bigint,
  p_payment_method text,
  p_note text,
  p_operation_id uuid
)
returns uuid
language sql
security definer
set search_path = ''
as $function$
  select public.record_cloud_customer_receipt(
    p_business_id, p_customer_id, p_amount_minor, p_payment_method,
    p_note, p_operation_id, null::uuid
  );
$function$;

create or replace function public.record_cloud_supplier_payment(
  p_business_id uuid,
  p_supplier_id uuid,
  p_amount_minor bigint,
  p_payment_method text,
  p_note text,
  p_operation_id uuid
)
returns uuid
language sql
security definer
set search_path = ''
as $function$
  select public.record_cloud_supplier_payment(
    p_business_id, p_supplier_id, p_amount_minor, p_payment_method,
    p_note, p_operation_id, null::uuid
  );
$function$;

revoke all on function public.record_cloud_customer_receipt(uuid, uuid, bigint, text, text, uuid, uuid)
  from public, anon;
revoke all on function public.record_cloud_supplier_payment(uuid, uuid, bigint, text, text, uuid, uuid)
  from public, anon;
revoke all on function public.record_cloud_customer_receipt(uuid, uuid, bigint, text, text, uuid)
  from public, anon;
revoke all on function public.record_cloud_supplier_payment(uuid, uuid, bigint, text, text, uuid)
  from public, anon;
grant execute on function public.record_cloud_customer_receipt(uuid, uuid, bigint, text, text, uuid, uuid)
  to authenticated;
grant execute on function public.record_cloud_supplier_payment(uuid, uuid, bigint, text, text, uuid, uuid)
  to authenticated;
grant execute on function public.record_cloud_customer_receipt(uuid, uuid, bigint, text, text, uuid)
  to authenticated;
grant execute on function public.record_cloud_supplier_payment(uuid, uuid, bigint, text, text, uuid)
  to authenticated;
