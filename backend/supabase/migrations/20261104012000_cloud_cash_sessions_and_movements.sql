-- Tenant-scoped cloud cash sessions and append-only physical cash movements.
-- A session is scoped to a branch and register; only cash movements affect its balance.
create table if not exists public.cloud_cash_sessions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  branch_id uuid not null,
  register_key text not null check (length(btrim(register_key)) between 1 and 80),
  opening_balance_minor bigint not null check (opening_balance_minor >= 0),
  opening_note text,
  status text not null default 'open' check (status in ('open', 'closed')),
  opened_at timestamptz not null default now(),
  opened_by uuid references auth.users(id) on delete set null,
  open_operation_id uuid not null,
  open_request_hash text not null,
  closed_at timestamptz,
  expected_balance_minor bigint,
  counted_balance_minor bigint check (
    counted_balance_minor is null or counted_balance_minor >= 0
  ),
  difference_minor bigint,
  closing_note text,
  closed_by uuid references auth.users(id) on delete set null,
  close_operation_id uuid,
  close_request_hash text,
  created_at timestamptz not null default now(),
  unique (id, business_id, branch_id),
  unique (business_id, open_operation_id),
  unique (business_id, close_operation_id),
  foreign key (branch_id, business_id)
    references public.cloud_branches(id, business_id) on delete restrict,
  check (
    (status = 'open'
      and closed_at is null
      and expected_balance_minor is null
      and counted_balance_minor is null
      and difference_minor is null
      and closed_by is null
      and close_operation_id is null
      and close_request_hash is null)
    or
    (status = 'closed'
      and closed_at is not null
      and expected_balance_minor is not null
      and counted_balance_minor is not null
      and difference_minor is not null
      and close_operation_id is not null
      and close_request_hash is not null)
  )
);

create unique index if not exists cloud_cash_sessions_one_open_per_register
  on public.cloud_cash_sessions(business_id, branch_id, register_key)
  where status = 'open';

create table if not exists public.cloud_cash_movements (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  branch_id uuid not null,
  cash_session_id uuid not null,
  direction text not null check (direction in ('in', 'out')),
  category text not null check (length(btrim(category)) between 1 and 80),
  amount_minor bigint not null check (amount_minor > 0),
  source_type text not null check (length(btrim(source_type)) between 1 and 80),
  source_id uuid,
  operation_id uuid not null,
  request_hash text not null,
  note text,
  actor_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (id, business_id),
  unique (business_id, operation_id),
  foreign key (cash_session_id, business_id, branch_id)
    references public.cloud_cash_sessions(id, business_id, branch_id) on delete restrict
);

create index if not exists cloud_cash_sessions_statement_idx
  on public.cloud_cash_sessions(business_id, branch_id, opened_at desc, id);
create index if not exists cloud_cash_movements_session_idx
  on public.cloud_cash_movements(business_id, cash_session_id, created_at, id);

alter table public.cloud_cash_sessions enable row level security;
alter table public.cloud_cash_movements enable row level security;

drop policy if exists cloud_cash_sessions_select_authorized on public.cloud_cash_sessions;
create policy cloud_cash_sessions_select_authorized on public.cloud_cash_sessions
  for select to authenticated
  using (
    public.has_business_permission(business_id, 'cashbook.view')
    or public.has_business_permission(business_id, 'audit.view')
  );

drop policy if exists cloud_cash_movements_select_authorized on public.cloud_cash_movements;
create policy cloud_cash_movements_select_authorized on public.cloud_cash_movements
  for select to authenticated
  using (
    public.has_business_permission(business_id, 'cashbook.view')
    or public.has_business_permission(business_id, 'reports.view')
    or public.has_business_permission(business_id, 'audit.view')
  );

revoke all on public.cloud_cash_sessions, public.cloud_cash_movements from anon, authenticated;
grant select on public.cloud_cash_sessions, public.cloud_cash_movements to authenticated;

create or replace function public.open_cloud_cash_session(
  p_business_id uuid,
  p_branch_id uuid,
  p_register_key text,
  p_opening_balance_minor bigint,
  p_note text,
  p_operation_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_register_key text := btrim(coalesce(p_register_key, ''));
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_hash text;
  v_existing_id uuid;
  v_existing_hash text;
  v_session_id uuid;
  v_branch_active boolean;
  v_stamp timestamptz := now();
begin
  if auth.uid() is null or p_business_id is null or p_branch_id is null
     or p_operation_id is null or p_opening_balance_minor is null
     or p_opening_balance_minor < 0
     or length(v_register_key) < 1 or length(v_register_key) > 80
     or length(coalesce(v_note, '')) > 500 then
    raise exception 'invalid cash session opening details' using errcode = '22023';
  end if;
  if not public.has_business_permission(p_business_id, 'cashbook.session.open') then
    raise exception 'cash session opening is not allowed' using errcode = '42501';
  end if;

  v_hash := encode(public.digest(jsonb_build_object(
    'branch_id', p_branch_id,
    'register_key', v_register_key,
    'opening_balance_minor', p_opening_balance_minor,
    'note', v_note
  )::text, 'sha256'), 'hex');

  perform pg_advisory_xact_lock(hashtextextended(
    p_business_id::text || ':cash-open:' || p_operation_id::text, 0
  ));
  select s.id, s.open_request_hash
  into v_existing_id, v_existing_hash
  from public.cloud_cash_sessions s
  where s.business_id = p_business_id
    and s.open_operation_id = p_operation_id;
  if v_existing_id is not null then
    if v_existing_hash is distinct from v_hash then
      raise exception 'cash session open key reused with different payload'
        using errcode = '22023';
    end if;
    return v_existing_id;
  end if;

  select b.is_active into v_branch_active
  from public.cloud_branches b
  where b.id = p_branch_id and b.business_id = p_business_id
  for share;
  if not found or v_branch_active is distinct from true then
    raise exception 'cash session branch is inactive or unavailable' using errcode = '23514';
  end if;

  insert into public.cloud_cash_sessions (
    business_id, branch_id, register_key, opening_balance_minor,
    opening_note, opened_by, open_operation_id, open_request_hash, opened_at, created_at
  ) values (
    p_business_id, p_branch_id, v_register_key, p_opening_balance_minor,
    v_note, auth.uid(), p_operation_id, v_hash, v_stamp, v_stamp
  ) returning id into v_session_id;

  insert into public.audit_events (
    business_id, actor_user_id, action_key, entity_type, entity_id, metadata, created_at
  ) values (
    p_business_id, auth.uid(), 'cashbook.session.open', 'cloud_cash_session',
    v_session_id::text,
    jsonb_build_object(
      'branch_id', p_branch_id, 'register_key', v_register_key,
      'opening_balance_minor', p_opening_balance_minor
    ),
    v_stamp
  );

  return v_session_id;
end;
$function$;

create or replace function public.record_cloud_cash_movement(
  p_business_id uuid,
  p_cash_session_id uuid,
  p_direction text,
  p_category text,
  p_amount_minor bigint,
  p_note text,
  p_operation_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_category text := btrim(coalesce(p_category, ''));
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_hash text;
  v_existing_id uuid;
  v_existing_hash text;
  v_branch_id uuid;
  v_movement_id uuid;
  v_stamp timestamptz := now();
begin
  if auth.uid() is null or p_business_id is null or p_cash_session_id is null
     or p_operation_id is null or p_amount_minor is null or p_amount_minor <= 0
     or p_direction is null or p_direction not in ('in', 'out')
     or length(v_category) < 1 or length(v_category) > 80
     or length(coalesce(v_note, '')) > 500 then
    raise exception 'invalid cash movement details' using errcode = '22023';
  end if;
  if not public.has_business_permission(p_business_id, 'cashbook.adjust') then
    raise exception 'cash movement adjustment is not allowed' using errcode = '42501';
  end if;

  v_hash := encode(public.digest(jsonb_build_object(
    'cash_session_id', p_cash_session_id,
    'direction', p_direction,
    'category', v_category,
    'amount_minor', p_amount_minor,
    'note', v_note
  )::text, 'sha256'), 'hex');

  perform pg_advisory_xact_lock(hashtextextended(
    p_business_id::text || ':cash-movement:' || p_operation_id::text, 0
  ));
  select m.id, m.request_hash
  into v_existing_id, v_existing_hash
  from public.cloud_cash_movements m
  where m.business_id = p_business_id and m.operation_id = p_operation_id;
  if v_existing_id is not null then
    if v_existing_hash is distinct from v_hash then
      raise exception 'cash movement key reused with different payload'
        using errcode = '22023';
    end if;
    return v_existing_id;
  end if;

  select s.branch_id into v_branch_id
  from public.cloud_cash_sessions s
  where s.id = p_cash_session_id
    and s.business_id = p_business_id
    and s.status = 'open'
  for update;
  if not found then
    raise exception 'cash session is not open or unavailable' using errcode = '23514';
  end if;

  insert into public.cloud_cash_movements (
    business_id, branch_id, cash_session_id, direction, category,
    amount_minor, source_type, source_id, operation_id, request_hash,
    note, actor_user_id, created_at
  ) values (
    p_business_id, v_branch_id, p_cash_session_id, p_direction, v_category,
    p_amount_minor, 'manual_adjustment', p_operation_id, p_operation_id,
    v_hash, v_note, auth.uid(), v_stamp
  ) returning id into v_movement_id;

  insert into public.audit_events (
    business_id, actor_user_id, action_key, entity_type, entity_id, metadata, created_at
  ) values (
    p_business_id, auth.uid(), 'cashbook.adjust', 'cloud_cash_movement',
    v_movement_id::text,
    jsonb_build_object(
      'cash_session_id', p_cash_session_id, 'direction', p_direction,
      'category', v_category, 'amount_minor', p_amount_minor
    ),
    v_stamp
  );

  return v_movement_id;
end;
$function$;

create or replace function public.close_cloud_cash_session(
  p_business_id uuid,
  p_cash_session_id uuid,
  p_counted_balance_minor bigint,
  p_note text,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_hash text;
  v_session public.cloud_cash_sessions%rowtype;
  v_incoming bigint;
  v_outgoing bigint;
  v_expected bigint;
  v_difference bigint;
  v_stamp timestamptz := now();
begin
  if auth.uid() is null or p_business_id is null or p_cash_session_id is null
     or p_operation_id is null or p_counted_balance_minor is null
     or p_counted_balance_minor < 0
     or length(coalesce(v_note, '')) > 500 then
    raise exception 'invalid cash session closing details' using errcode = '22023';
  end if;
  if not public.has_business_permission(p_business_id, 'cashbook.session.close') then
    raise exception 'cash session closing is not allowed' using errcode = '42501';
  end if;

  v_hash := encode(public.digest(jsonb_build_object(
    'cash_session_id', p_cash_session_id,
    'counted_balance_minor', p_counted_balance_minor,
    'note', v_note
  )::text, 'sha256'), 'hex');

  perform pg_advisory_xact_lock(hashtextextended(
    p_business_id::text || ':cash-close:' || p_operation_id::text, 0
  ));
  select * into v_session
  from public.cloud_cash_sessions s
  where s.id = p_cash_session_id and s.business_id = p_business_id
  for update;
  if not found then
    raise exception 'cash session not found' using errcode = 'P0002';
  end if;

  if v_session.status = 'closed' then
    if v_session.close_operation_id = p_operation_id
       and v_session.close_request_hash = v_hash then
      select
        coalesce(sum(m.amount_minor) filter (where m.direction = 'in'), 0),
        coalesce(sum(m.amount_minor) filter (where m.direction = 'out'), 0)
      into v_incoming, v_outgoing
      from public.cloud_cash_movements m
      where m.business_id = p_business_id and m.cash_session_id = p_cash_session_id;
      return jsonb_build_object(
        'session_id', v_session.id,
        'opening_balance_minor', v_session.opening_balance_minor,
        'incoming_minor', v_incoming,
        'outgoing_minor', v_outgoing,
        'expected_balance_minor', v_session.expected_balance_minor,
        'counted_balance_minor', v_session.counted_balance_minor,
        'difference_minor', v_session.difference_minor,
        'closed_at', v_session.closed_at
      );
    end if;
    raise exception 'cash session is already closed' using errcode = '23514';
  end if;

  select
    coalesce(sum(m.amount_minor) filter (where m.direction = 'in'), 0),
    coalesce(sum(m.amount_minor) filter (where m.direction = 'out'), 0)
  into v_incoming, v_outgoing
  from public.cloud_cash_movements m
  where m.business_id = p_business_id and m.cash_session_id = p_cash_session_id;

  v_expected := v_session.opening_balance_minor + v_incoming - v_outgoing;
  v_difference := p_counted_balance_minor - v_expected;

  update public.cloud_cash_sessions
  set status = 'closed',
      closed_at = v_stamp,
      expected_balance_minor = v_expected,
      counted_balance_minor = p_counted_balance_minor,
      difference_minor = v_difference,
      closing_note = v_note,
      closed_by = auth.uid(),
      close_operation_id = p_operation_id,
      close_request_hash = v_hash
  where id = p_cash_session_id and business_id = p_business_id and status = 'open';

  insert into public.audit_events (
    business_id, actor_user_id, action_key, entity_type, entity_id, metadata, created_at
  ) values (
    p_business_id, auth.uid(), 'cashbook.session.close', 'cloud_cash_session',
    p_cash_session_id::text,
    jsonb_build_object(
      'opening_balance_minor', v_session.opening_balance_minor,
      'incoming_minor', v_incoming, 'outgoing_minor', v_outgoing,
      'expected_balance_minor', v_expected,
      'counted_balance_minor', p_counted_balance_minor,
      'difference_minor', v_difference
    ),
    v_stamp
  );

  return jsonb_build_object(
    'session_id', p_cash_session_id,
    'opening_balance_minor', v_session.opening_balance_minor,
    'incoming_minor', v_incoming,
    'outgoing_minor', v_outgoing,
    'expected_balance_minor', v_expected,
    'counted_balance_minor', p_counted_balance_minor,
    'difference_minor', v_difference,
    'closed_at', v_stamp
  );
end;
$function$;

create or replace function public.guard_cloud_branch_open_cash_session()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if old.is_active = true and new.is_active = false and exists (
    select 1 from public.cloud_cash_sessions s
    where s.business_id = old.business_id
      and s.branch_id = old.id
      and s.status = 'open'
  ) then
    raise exception 'branch with an open cash session cannot be deactivated'
      using errcode = '23514';
  end if;
  return new;
end;
$function$;

drop trigger if exists cloud_branch_open_cash_session_guard on public.cloud_branches;
create trigger cloud_branch_open_cash_session_guard
  before update of is_active on public.cloud_branches
  for each row
  execute function public.guard_cloud_branch_open_cash_session();

revoke all on function public.open_cloud_cash_session(uuid, uuid, text, bigint, text, uuid) from public, anon;
revoke all on function public.record_cloud_cash_movement(uuid, uuid, text, text, bigint, text, uuid) from public, anon;
revoke all on function public.close_cloud_cash_session(uuid, uuid, bigint, text, uuid) from public, anon;
grant execute on function public.open_cloud_cash_session(uuid, uuid, text, bigint, text, uuid) to authenticated;
grant execute on function public.record_cloud_cash_movement(uuid, uuid, text, text, bigint, text, uuid) to authenticated;
grant execute on function public.close_cloud_cash_session(uuid, uuid, bigint, text, uuid) to authenticated;
