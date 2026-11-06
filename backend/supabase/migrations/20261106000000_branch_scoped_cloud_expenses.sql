-- Branch-scoped, idempotent cloud expense writes.
-- Existing expenses remain unassigned; no branch/payment/session is inferred.
alter table public.cloud_expenses
  add column if not exists branch_id uuid,
  add column if not exists payment_method text,
  add column if not exists cash_session_id uuid,
  add column if not exists operation_id uuid,
  add column if not exists request_hash text;

do $constraints$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'cloud_expenses_branch_business_fk'
      and conrelid = 'public.cloud_expenses'::regclass
  ) then
    alter table public.cloud_expenses
      add constraint cloud_expenses_branch_business_fk
      foreign key (branch_id, business_id)
      references public.cloud_branches(id, business_id)
      on delete restrict;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'cloud_expenses_cash_session_scope_fk'
      and conrelid = 'public.cloud_expenses'::regclass
  ) then
    alter table public.cloud_expenses
      add constraint cloud_expenses_cash_session_scope_fk
      foreign key (cash_session_id, business_id, branch_id)
      references public.cloud_cash_sessions(id, business_id, branch_id)
      on delete restrict;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'cloud_expenses_payment_method_check'
      and conrelid = 'public.cloud_expenses'::regclass
  ) then
    alter table public.cloud_expenses
      add constraint cloud_expenses_payment_method_check
      check (
        payment_method is null
        or payment_method in ('cash', 'card', 'bank_transfer', 'wallet')
      );
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'cloud_expenses_operation_receipt_check'
      and conrelid = 'public.cloud_expenses'::regclass
  ) then
    alter table public.cloud_expenses
      add constraint cloud_expenses_operation_receipt_check
      check (
        (operation_id is null and request_hash is null)
        or (
          operation_id is not null
          and request_hash is not null
          and branch_id is not null
          and payment_method is not null
        )
      );
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'cloud_expenses_cash_session_method_check'
      and conrelid = 'public.cloud_expenses'::regclass
  ) then
    alter table public.cloud_expenses
      add constraint cloud_expenses_cash_session_method_check
      check (
        (payment_method is null or payment_method <> 'cash' or cash_session_id is not null)
        and (cash_session_id is null or payment_method = 'cash')
      );
  end if;
end;
$constraints$;

create unique index if not exists cloud_expenses_business_operation_unique
  on public.cloud_expenses(business_id, operation_id)
  where operation_id is not null;

create index if not exists cloud_expenses_branch_created_idx
  on public.cloud_expenses(business_id, branch_id, created_at desc, id)
  where branch_id is not null;

-- Historical rows keep NULL branch/payment/operation fields and remain readable
-- through the existing business-level SELECT policy for explicit reconciliation.
revoke insert, update, delete on public.cloud_expenses from anon, authenticated;

create or replace function public.create_cloud_expense(
  p_business_id uuid,
  p_branch_id uuid,
  p_description text,
  p_category text,
  p_amount_minor bigint,
  p_payment_method text,
  p_cash_session_id uuid,
  p_operation_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_description text := btrim(coalesce(p_description, ''));
  v_category text := btrim(coalesce(p_category, ''));
  v_hash text;
  v_existing_id uuid;
  v_existing_hash text;
  v_expense_id uuid;
  v_branch_active boolean;
  v_session public.cloud_cash_sessions%rowtype;
  v_note text;
  v_cash_hash text;
  v_stamp timestamptz := now();
begin
  if auth.uid() is null
     or p_business_id is null
     or p_branch_id is null
     or p_operation_id is null
     or p_amount_minor is null
     or p_amount_minor <= 0
     or length(v_description) < 1
     or length(v_description) > 500
     or length(v_category) < 1
     or length(v_category) > 120
     or p_payment_method is null
     or p_payment_method not in ('cash', 'card', 'bank_transfer', 'wallet')
     or (p_payment_method = 'cash' and p_cash_session_id is null)
     or (p_payment_method <> 'cash' and p_cash_session_id is not null) then
    raise exception 'invalid cloud expense payload' using errcode = '22023';
  end if;

  if not public.has_business_permission(p_business_id, 'expenses.create') then
    raise exception 'expense creation is not allowed' using errcode = '42501';
  end if;

  v_hash := encode(public.digest(jsonb_build_object(
    'branch_id', p_branch_id,
    'description', v_description,
    'category', v_category,
    'amount_minor', p_amount_minor,
    'payment_method', p_payment_method,
    'cash_session_id', p_cash_session_id
  )::text, 'sha256'), 'hex');

  perform pg_advisory_xact_lock(hashtextextended(
    p_business_id::text || ':expense:' || p_operation_id::text, 0
  ));

  select e.id, e.request_hash
  into v_existing_id, v_existing_hash
  from public.cloud_expenses e
  where e.business_id = p_business_id
    and e.operation_id = p_operation_id;

  if v_existing_id is not null then
    if v_existing_hash is distinct from v_hash then
      raise exception 'expense idempotency key reused with different payload'
        using errcode = '22023';
    end if;
    return v_existing_id;
  end if;

  select b.is_active into v_branch_active
  from public.cloud_branches b
  where b.id = p_branch_id and b.business_id = p_business_id
  for share;

  if not found or v_branch_active is distinct from true then
    raise exception 'expense branch is inactive or unavailable'
      using errcode = '23514';
  end if;

  if p_payment_method = 'cash' then
    select s.* into v_session
    from public.cloud_cash_sessions s
    where s.id = p_cash_session_id
      and s.business_id = p_business_id
      and s.branch_id = p_branch_id
      and s.status = 'open'
    for update;

    if not found then
      raise exception 'cash expense requires an open session in the selected branch'
        using errcode = '23514';
    end if;
  end if;

  insert into public.cloud_expenses (
    business_id, branch_id, description, category, amount_minor,
    payment_method, cash_session_id, operation_id, request_hash,
    created_by, created_at, updated_at
  ) values (
    p_business_id, p_branch_id, v_description, v_category, p_amount_minor,
    p_payment_method, p_cash_session_id, p_operation_id, v_hash,
    auth.uid(), v_stamp, v_stamp
  ) returning id into v_expense_id;

  if p_payment_method = 'cash' then
    v_note := v_category || ' — ' || v_description;
    v_cash_hash := encode(public.digest(jsonb_build_object(
      'cash_session_id', p_cash_session_id,
      'direction', 'out',
      'category', 'expense',
      'amount_minor', p_amount_minor,
      'source_type', 'expense',
      'source_id', v_expense_id,
      'note', v_note
    )::text, 'sha256'), 'hex');

    insert into public.cloud_cash_movements (
      business_id, branch_id, cash_session_id, direction, category,
      amount_minor, source_type, source_id, operation_id, request_hash,
      note, actor_user_id, created_at
    ) values (
      p_business_id, p_branch_id, p_cash_session_id, 'out', 'expense',
      p_amount_minor, 'expense', v_expense_id, p_operation_id, v_cash_hash,
      v_note, auth.uid(), v_stamp
    );
  end if;

  insert into public.audit_events (
    business_id, actor_user_id, action_key, entity_type, entity_id, metadata, created_at
  ) values (
    p_business_id, auth.uid(), 'expenses.create', 'cloud_expense',
    v_expense_id::text,
    jsonb_build_object(
      'branch_id', p_branch_id,
      'category', v_category,
      'amount_minor', p_amount_minor,
      'payment_method', p_payment_method,
      'cash_session_id', p_cash_session_id
    ),
    v_stamp
  );

  return v_expense_id;
end;
$function$;

revoke all on function public.create_cloud_expense(
  uuid, uuid, text, text, bigint, text, uuid, uuid
) from public, anon;
grant execute on function public.create_cloud_expense(
  uuid, uuid, text, text, bigint, text, uuid, uuid
) to authenticated;

comment on function public.create_cloud_expense(
  uuid, uuid, text, text, bigint, text, uuid, uuid
) is
  'Creates a branch-scoped expense idempotently; cash expenses atomically create an outflow in the same open branch cash session.';
