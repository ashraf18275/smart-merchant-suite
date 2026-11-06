-- Disposable PostgreSQL regression checks for branch-scoped cloud expenses.
begin;

insert into auth.users (id) values
  ('71000000-0000-0000-0000-000000000001'),
  ('71000000-0000-0000-0000-000000000002')
on conflict (id) do nothing;

insert into public.businesses (id, name, owner_user_id) values
  ('72000000-0000-0000-0000-000000000001', 'Expense Test Business A', '71000000-0000-0000-0000-000000000001'),
  ('72000000-0000-0000-0000-000000000002', 'Expense Test Business B', '71000000-0000-0000-0000-000000000002')
on conflict (id) do nothing;

insert into public.cloud_branches (id, business_id, name, is_active) values
  ('73000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000001', 'Expense Branch A', true),
  ('73000000-0000-0000-0000-000000000002', '72000000-0000-0000-0000-000000000001', 'Expense Branch B', true),
  ('73000000-0000-0000-0000-000000000003', '72000000-0000-0000-0000-000000000002', 'Other Business Branch', true)
on conflict (id) do nothing;

-- Legacy rows are intentionally retained without inferred branch or operation metadata.
insert into public.cloud_expenses (
  id, business_id, description, category, amount_minor, created_by,
  branch_id, payment_method, cash_session_id, operation_id, request_hash
) values (
  '74000000-0000-0000-0000-000000000001',
  '72000000-0000-0000-0000-000000000001',
  'Legacy unassigned expense', 'legacy', 17,
  '71000000-0000-0000-0000-000000000001',
  null, null, null, null, null
)
on conflict (id) do nothing;

grant usage on schema public to authenticated;
grant select on public.cloud_expenses, public.cloud_cash_sessions,
  public.cloud_cash_movements, public.cloud_branches to authenticated;

set local role authenticated;
select set_config('request.jwt.claim.sub', '71000000-0000-0000-0000-000000000001', true);

do $$
declare
  v_session_id uuid;
  v_expense_id uuid;
  v_retry_id uuid;
  v_non_cash_id uuid;
  v_mismatch_rejected boolean := false;
  v_wrong_branch_session_rejected boolean := false;
  v_cross_tenant_rejected boolean := false;
  v_direct_insert_rejected boolean := false;
  v_legacy_unassigned boolean;
  v_cash_movement_count integer;
begin
  v_session_id := public.open_cloud_cash_session(
    '72000000-0000-0000-0000-000000000001',
    '73000000-0000-0000-0000-000000000001',
    'expense-test-device-a',
    10000,
    'test opening',
    '75000000-0000-0000-0000-000000000001'
  );

  v_expense_id := public.create_cloud_expense(
    '72000000-0000-0000-0000-000000000001',
    '73000000-0000-0000-0000-000000000001',
    'Electricity bill',
    'Utilities',
    1250,
    'cash',
    v_session_id,
    '75000000-0000-0000-0000-000000000002'
  );

  v_retry_id := public.create_cloud_expense(
    '72000000-0000-0000-0000-000000000001',
    '73000000-0000-0000-0000-000000000001',
    'Electricity bill',
    'Utilities',
    1250,
    'cash',
    v_session_id,
    '75000000-0000-0000-0000-000000000002'
  );

  if v_expense_id is distinct from v_retry_id then
    raise exception 'expense idempotency failed: retry returned a different id';
  end if;

  select count(*) into v_cash_movement_count
  from public.cloud_cash_movements
  where business_id = '72000000-0000-0000-0000-000000000001'
    and operation_id = '75000000-0000-0000-0000-000000000002'
    and source_type = 'expense'
    and source_id = v_expense_id
    and cash_session_id = v_session_id
    and branch_id = '73000000-0000-0000-0000-000000000001'
    and direction = 'out'
    and amount_minor = 1250;

  if v_cash_movement_count <> 1 then
    raise exception 'cash expense must create exactly one matching branch/session outflow';
  end if;

  begin
    perform public.create_cloud_expense(
      '72000000-0000-0000-0000-000000000001',
      '73000000-0000-0000-0000-000000000001',
      'Electricity bill',
      'Utilities',
      1251,
      'cash',
      v_session_id,
      '75000000-0000-0000-0000-000000000002'
    );
    raise exception 'expense idempotency accepted a different payload for the same key';
  exception when invalid_parameter_value then
    v_mismatch_rejected := true;
  end;

  if not v_mismatch_rejected then
    raise exception 'expense idempotency failed to reject a changed payload';
  end if;

  v_non_cash_id := public.create_cloud_expense(
    '72000000-0000-0000-0000-000000000001',
    '73000000-0000-0000-0000-000000000002',
    'Online subscription',
    'Services',
    500,
    'wallet',
    null,
    '75000000-0000-0000-0000-000000000003'
  );

  if not exists (
    select 1 from public.cloud_expenses
    where id = v_non_cash_id
      and branch_id = '73000000-0000-0000-0000-000000000002'
      and payment_method = 'wallet'
      and cash_session_id is null
  ) then
    raise exception 'non-cash expense did not retain its branch/payment context';
  end if;

  select count(*) into v_cash_movement_count
  from public.cloud_cash_movements
  where business_id = '72000000-0000-0000-0000-000000000001'
    and operation_id = '75000000-0000-0000-0000-000000000003';

  if v_cash_movement_count <> 0 then
    raise exception 'non-cash expense unexpectedly changed the cash drawer';
  end if;

  begin
    perform public.create_cloud_expense(
      '72000000-0000-0000-0000-000000000001',
      '73000000-0000-0000-0000-000000000002',
      'Wrong branch cash expense',
      'Utilities',
      100,
      'cash',
      v_session_id,
      '75000000-0000-0000-0000-000000000004'
    );
    raise exception 'cash expense accepted a session belonging to another branch';
  exception when check_violation then
    v_wrong_branch_session_rejected := true;
  end;

  if not v_wrong_branch_session_rejected then
    raise exception 'cash expense branch/session mismatch was not rejected';
  end if;

  begin
    perform public.create_cloud_expense(
      '72000000-0000-0000-0000-000000000002',
      '73000000-0000-0000-0000-000000000003',
      'Cross-tenant expense',
      'Other',
      100,
      'wallet',
      null,
      '75000000-0000-0000-0000-000000000005'
    );
    raise exception 'expense RPC accepted a different business';
  exception when insufficient_privilege then
    v_cross_tenant_rejected := true;
  end;

  if not v_cross_tenant_rejected then
    raise exception 'expense RPC did not reject cross-tenant writes';
  end if;

  begin
    insert into public.cloud_expenses (
      business_id, branch_id, description, category, amount_minor,
      payment_method, operation_id, request_hash, created_by
    ) values (
      '72000000-0000-0000-0000-000000000001',
      '73000000-0000-0000-0000-000000000001',
      'Direct write attempt', 'Other', 100,
      'wallet', '75000000-0000-0000-0000-000000000006',
      repeat('a', 64), auth.uid()
    );
    raise exception 'authenticated direct expense insert unexpectedly succeeded';
  exception when insufficient_privilege then
    v_direct_insert_rejected := true;
  end;

  if not v_direct_insert_rejected then
    raise exception 'authenticated direct expense insert was not revoked';
  end if;

  select (branch_id is null and payment_method is null and operation_id is null and request_hash is null)
    into v_legacy_unassigned
  from public.cloud_expenses
  where id = '74000000-0000-0000-0000-000000000001';

  if v_legacy_unassigned is distinct from true then
    raise exception 'legacy expense was unexpectedly assigned inferred branch metadata';
  end if;
end;
$$;

rollback;
