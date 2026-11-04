-- Security regression tests for tenant isolation and privileged operations.
-- Run after all migrations against a disposable PostgreSQL database.
begin;

insert into auth.users (id) values
  ('10000000-0000-0000-0000-000000000001'),
  ('10000000-0000-0000-0000-000000000002'),
  ('10000000-0000-0000-0000-000000000003'),
  ('10000000-0000-0000-0000-000000000004'),
  ('10000000-0000-0000-0000-000000000005'),
  ('10000000-0000-0000-0000-000000000006')
on conflict (id) do nothing;

insert into public.businesses (id, name, owner_user_id) values
  ('20000000-0000-0000-0000-000000000001', 'Security Test Business A', '10000000-0000-0000-0000-000000000001'),
  ('20000000-0000-0000-0000-000000000002', 'Security Test Business B', '10000000-0000-0000-0000-000000000002')
on conflict (id) do nothing;

insert into public.cloud_branches (id, business_id, name)
values (
  '22000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000001',
  'Second test branch'
)
on conflict (id) do nothing;

insert into public.cloud_warehouses (id, business_id, branch_id, name)
values (
  '23000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000001',
  '22000000-0000-0000-0000-000000000001',
  'Second test warehouse'
)
on conflict (id) do nothing;

-- One least-privilege active member and one inactive member in business A.
insert into public.business_members (
  id, business_id, user_id, display_name, is_owner, is_active
) values
  ('21000000-0000-0000-0000-000000000003',
   '20000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-000000000003',
   'Read-only member', false, true),
  ('21000000-0000-0000-0000-000000000004',
   '20000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-000000000004',
   'Inactive member', false, false),
  ('21000000-0000-0000-0000-000000000006',
   '20000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-000000000006',
   'Delegated administrator', false, true),
  ('21000000-0000-0000-0000-000000000007',
   '20000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-000000000005',
   'Location viewer', false, true)
on conflict (id) do nothing;

insert into public.member_permissions (
  business_id, member_id, permission_key, allowed
) values
  ('20000000-0000-0000-0000-000000000001',
   '21000000-0000-0000-0000-000000000003',
   'products.view', true),
  ('20000000-0000-0000-0000-000000000001',
   '21000000-0000-0000-0000-000000000004',
   'products.view', true),
  ('20000000-0000-0000-0000-000000000001',
   '21000000-0000-0000-0000-000000000006',
   'products.view', true),
  ('20000000-0000-0000-0000-000000000001',
   '21000000-0000-0000-0000-000000000006',
   'customers.view', true),
  ('20000000-0000-0000-0000-000000000001',
   '21000000-0000-0000-0000-000000000006',
   'accounts.view', true),
  ('20000000-0000-0000-0000-000000000001',
   '21000000-0000-0000-0000-000000000006',
   'users.view', true),
  ('20000000-0000-0000-0000-000000000001',
   '21000000-0000-0000-0000-000000000006',
   'users.create', true),
  ('20000000-0000-0000-0000-000000000001',
   '21000000-0000-0000-0000-000000000006',
   'users.edit', true),
  ('20000000-0000-0000-0000-000000000001',
   '21000000-0000-0000-0000-000000000006',
   'branches.manage', true),
  ('20000000-0000-0000-0000-000000000001',
   '21000000-0000-0000-0000-000000000007',
   'branches.view', true),
  ('20000000-0000-0000-0000-000000000001',
   '21000000-0000-0000-0000-000000000007',
   'warehouses.view', true)
on conflict (member_id, permission_key) do nothing;

insert into public.cloud_products (
  id, business_id, name, sku, cost_minor, price_minor, stock_quantity, created_by
) values
  ('30000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000001',
   'Test product A', 'SEC-A', 50, 100, 10000, '10000000-0000-0000-0000-000000000001'),
  ('30000000-0000-0000-0000-000000000002',
   '20000000-0000-0000-0000-000000000002',
   'Test product B', 'SEC-B', 70, 140, 20000, '10000000-0000-0000-0000-000000000002')
on conflict (id) do nothing;

insert into public.cloud_expenses (
  id, business_id, description, category, amount_minor, created_by
) values
  ('40000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000001',
   'Test expense A', 'test', 25, '10000000-0000-0000-0000-000000000001'),
  ('40000000-0000-0000-0000-000000000002',
   '20000000-0000-0000-0000-000000000002',
   'Test expense B', 'test', 35, '10000000-0000-0000-0000-000000000002')
on conflict (id) do nothing;

-- The minimal PostgreSQL CI database emulates Supabase's public-schema read grants.
grant usage on schema public to authenticated;
grant select on public.businesses, public.business_members, public.cloud_products, public.cloud_inventory_movements,
  public.cloud_sales, public.cloud_sale_items, public.cloud_expenses, public.audit_events,
  public.cloud_branches, public.cloud_warehouses, public.cloud_product_warehouse_stock,
  public.cloud_customers, public.cloud_suppliers,
  public.cloud_customer_account_entries, public.cloud_supplier_account_entries,
  public.cloud_customer_payments, public.cloud_supplier_payments to authenticated;

set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', true);

do $$
declare
  v_count integer;
  v_sale_one uuid;
  v_sale_two uuid;
  v_fractional_sale_one uuid;
  v_fractional_sale_two uuid;
  v_line_total bigint;
  v_movement_one uuid;
  v_movement_two uuid;
  v_stock bigint;
  v_mismatched_sale_rejected boolean := false;
  v_mismatched_adjustment_rejected boolean := false;
  v_owner_member_id uuid;
  v_count_audit integer;
  v_delegated_escalation_rejected boolean := false;
  v_owner_change_rejected boolean := false;
  v_owner_login_insert_rejected boolean := false;
  v_member_active boolean;
  v_member_deactivation_rejected boolean := false;
  v_permission_visibility_count integer;
  v_other_business_adjustment_rejected boolean := false;
  v_created_branch uuid;
  v_created_default_warehouse uuid;
  v_created_second_warehouse uuid;
  v_delegated_branch uuid;
  v_location_operation uuid;
  v_location_rejected boolean := false;
  v_customer_id uuid;
  v_supplier_id uuid;
  v_customer_id_retry uuid;
  v_customer_payment_id uuid;
  v_customer_payment_retry uuid;
  v_supplier_payment_id uuid;
  v_account_cash_session_id uuid;
  v_customer_cash_payment_id uuid;
  v_customer_cash_payment_retry uuid;
  v_supplier_cash_payment_id uuid;
  v_account_cash_close jsonb;
  v_customer_balance bigint;
  v_supplier_balance bigint;
  v_receipt_payload_rejected boolean := false;
  v_customer_overpayment_rejected boolean := false;
  v_supplier_overpayment_rejected boolean := false;
  v_unauthorized_receipt_rejected boolean := false;
  v_unauthorized_supplier_payment_rejected boolean := false;
  v_customer_b_id uuid;
  v_credit_without_customer_rejected boolean := false;
  v_default_branch_id uuid;
  v_default_warehouse_id uuid;
  v_sale_cash_session_id uuid;
  v_sale_cash_close jsonb;
  v_cash_session_id uuid;
  v_cash_session_retry uuid;
  v_cash_movement_id uuid;
  v_cash_movement_retry uuid;
  v_cash_close_summary jsonb;
  v_cash_close_retry jsonb;
  v_cash_open_rejected boolean := false;
  v_cash_branch_deactivation_rejected boolean := false;
  v_cash_closed_movement_rejected boolean := false;
  v_cash_movement_payload_rejected boolean := false;
  v_unauthorized_cash_open_rejected boolean := false;
  v_purchase_id uuid;
  v_purchase_retry uuid;
  v_purchase_payload_rejected boolean := false;
  v_purchase_stock bigint;
  v_sale_item_id uuid;
  v_purchase_item_id uuid;
  v_sale_return_id uuid;
  v_sale_return_retry uuid;
  v_purchase_return_id uuid;
  v_purchase_return_retry uuid;
  v_sale_return_payload_rejected boolean := false;
  v_purchase_return_payload_rejected boolean := false;
  v_return_stock bigint;
  v_return_cash_session_id uuid;
  v_return_cash_close jsonb;
  v_sale_cash_refund_id uuid;
  v_purchase_cash_refund_id uuid;
  v_sale_overreturn_rejected boolean := false;
  v_purchase_overreturn_rejected boolean := false;
begin
  -- Business ownership is immutable to clients; business names remain editable.
  if has_column_privilege(current_user, 'public.businesses', 'owner_user_id', 'UPDATE') then
    raise exception 'security regression: authenticated can transfer business ownership';
  end if;
  if not has_column_privilege(current_user, 'public.businesses', 'name', 'UPDATE') then
    raise exception 'security regression: authenticated owner cannot rename a business';
  end if;
  if has_table_privilege(current_user, 'public.businesses', 'DELETE') then
    raise exception 'security regression: authenticated can delete a business and cascade its data';
  end if;

  begin
    update public.businesses
    set owner_user_id = '10000000-0000-0000-0000-000000000002'
    where id = '20000000-0000-0000-0000-000000000001';
    raise exception 'security regression: business ownership transfer unexpectedly succeeded';
  exception when insufficient_privilege then
    null;
  end;

  update public.businesses
  set name = 'Security Test Business A - renamed'
  where id = '20000000-0000-0000-0000-000000000001';

  if not exists (
    select 1 from public.businesses
    where id = '20000000-0000-0000-0000-000000000001'
      and owner_user_id = '10000000-0000-0000-0000-000000000001'
      and name = 'Security Test Business A - renamed'
  ) then
    raise exception 'security regression: owner rename failed or ownership changed';
  end if;

  select count(*) into v_count from public.cloud_products;
  if v_count <> 1 then
    raise exception 'tenant isolation failed: owner A can see % products, expected 1', v_count;
  end if;

  select count(*) into v_count from public.cloud_expenses;
  if v_count <> 1 then
    raise exception 'tenant isolation failed: owner A can see % expenses, expected 1', v_count;
  end if;

  select count(*) into v_count from public.cloud_branches;
  if v_count <> 2 then
    raise exception 'branch isolation failed: owner A can see % branches, expected 2', v_count;
  end if;

  select count(*) into v_count from public.cloud_warehouses;
  if v_count <> 2 then
    raise exception 'warehouse isolation failed: owner A can see % warehouses, expected 2', v_count;
  end if;

  select count(*) into v_count from public.cloud_product_warehouse_stock;
  if v_count <> 1 then
    raise exception 'warehouse stock isolation failed: owner A can see % stock rows, expected 1 before second-warehouse initialization', v_count;
  end if;

  -- Location changes must be performed through audited, tenant-scoped RPCs.
  v_created_branch := public.create_cloud_branch(
    '20000000-0000-0000-0000-000000000001',
    'Managed branch',
    'Test address',
    '01000000000'
  );
  select w.id into v_created_default_warehouse
  from public.cloud_warehouses w
  where w.business_id = '20000000-0000-0000-0000-000000000001'
    and w.branch_id = v_created_branch
    and w.name = 'المخزن الرئيسي';

  if v_created_default_warehouse is null then
    raise exception 'location management failed: new branch did not receive its default warehouse';
  end if;

  v_created_second_warehouse := public.create_cloud_warehouse(
    '20000000-0000-0000-0000-000000000001',
    v_created_branch,
    'Second managed warehouse'
  );

  if (select count(*) from public.cloud_warehouses
      where business_id = '20000000-0000-0000-0000-000000000001'
        and branch_id = v_created_branch and is_active = true) <> 2 then
    raise exception 'location management failed: expected two active warehouses';
  end if;

  -- A warehouse with stock cannot be deactivated.
  v_location_operation := public.adjust_cloud_inventory(
    '20000000-0000-0000-0000-000000000001',
    v_created_branch,
    v_created_second_warehouse,
    '30000000-0000-0000-0000-000000000001',
    1000,
    'location deactivation guard',
    '50000000-0000-0000-0000-000000000011'
  );
  begin
    perform public.set_cloud_warehouse_active(
      '20000000-0000-0000-0000-000000000001',
      v_created_second_warehouse,
      false
    );
    raise exception 'location security regression: warehouse with stock was deactivated';
  exception when check_violation then
    v_location_rejected := true;
  end;
  if not v_location_rejected then
    raise exception 'location security regression: stock warehouse deactivation was not rejected';
  end if;

  perform public.adjust_cloud_inventory(
    '20000000-0000-0000-0000-000000000001',
    v_created_branch,
    v_created_second_warehouse,
    '30000000-0000-0000-0000-000000000001',
    -1000,
    'reverse location deactivation guard',
    '50000000-0000-0000-0000-000000000012'
  );

  -- A live branch cannot be left with zero active warehouses.
  perform public.set_cloud_warehouse_active(
    '20000000-0000-0000-0000-000000000001',
    v_created_default_warehouse,
    false
  );
  v_location_rejected := false;
  begin
    perform public.set_cloud_warehouse_active(
      '20000000-0000-0000-0000-000000000001',
      v_created_second_warehouse,
      false
    );
    raise exception 'location security regression: last active warehouse was deactivated';
  exception when check_violation then
    v_location_rejected := true;
  end;
  if not v_location_rejected then
    raise exception 'location security regression: last active warehouse deactivation was not rejected';
  end if;
  perform public.set_cloud_warehouse_active(
    '20000000-0000-0000-0000-000000000001',
    v_created_default_warehouse,
    true
  );

  -- Branch deactivation is atomic: all empty warehouses are disabled together.
  v_location_rejected := false;
  perform public.adjust_cloud_inventory(
    '20000000-0000-0000-0000-000000000001',
    v_created_branch,
    v_created_second_warehouse,
    '30000000-0000-0000-0000-000000000001',
    1000,
    'branch stock deactivation guard',
    '50000000-0000-0000-0000-000000000013'
  );
  begin
    perform public.set_cloud_branch_active(
      '20000000-0000-0000-0000-000000000001',
      v_created_branch,
      false
    );
    raise exception 'location security regression: branch with stock was deactivated';
  exception when check_violation then
    v_location_rejected := true;
  end;
  if not v_location_rejected then
    raise exception 'location security regression: branch stock deactivation was not rejected';
  end if;
  perform public.adjust_cloud_inventory(
    '20000000-0000-0000-0000-000000000001',
    v_created_branch,
    v_created_second_warehouse,
    '30000000-0000-0000-0000-000000000001',
    -1000,
    'clear branch stock before deactivation',
    '50000000-0000-0000-0000-000000000014'
  );
  perform public.set_cloud_branch_active(
    '20000000-0000-0000-0000-000000000001',
    v_created_branch,
    false
  );
  if exists (
    select 1 from public.cloud_warehouses
    where business_id = '20000000-0000-0000-0000-000000000001'
      and branch_id = v_created_branch and is_active = true
  ) or exists (
    select 1 from public.cloud_branches
    where id = v_created_branch and is_active = true
  ) then
    raise exception 'location management failed: branch deactivation was not atomic';
  end if;
  -- Neither inventory nor warehouse activation is allowed while the branch is inactive.
  v_location_rejected := false;
  begin
    perform public.adjust_cloud_inventory(
      '20000000-0000-0000-0000-000000000001',
      v_created_branch,
      v_created_second_warehouse,
      '30000000-0000-0000-0000-000000000001',
      1000,
      'reject stock in inactive branch',
      '50000000-0000-0000-0000-000000000015'
    );
    raise exception 'location security regression: stock was added to an inactive branch';
  exception when check_violation then
    v_location_rejected := true;
  end;
  if not v_location_rejected then
    raise exception 'location security regression: stock write to inactive branch was not rejected';
  end if;

  v_location_rejected := false;
  begin
    perform public.set_cloud_warehouse_active(
      '20000000-0000-0000-0000-000000000001',
      v_created_second_warehouse,
      true
    );
    raise exception 'location security regression: warehouse activated under inactive branch';
  exception when check_violation then
    v_location_rejected := true;
  end;
  if not v_location_rejected then
    raise exception 'location security regression: warehouse activation under inactive branch was not rejected';
  end if;

  perform public.set_cloud_branch_active(
    '20000000-0000-0000-0000-000000000001',
    v_created_branch,
    true
  );
  if not exists (
    select 1 from public.cloud_warehouses
    where business_id = '20000000-0000-0000-0000-000000000001'
      and branch_id = v_created_branch and is_active = true
  ) then
    raise exception 'location management failed: branch reactivation did not restore an active warehouse';
  end if;

  -- Members without settings.edit cannot create or change locations.
  perform set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000003', true);
  v_location_rejected := false;
  begin
    perform public.create_cloud_branch(
      '20000000-0000-0000-0000-000000000001',
      'Unauthorized branch',
      null,
      null
    );
    raise exception 'location security regression: read-only member created a branch';
  exception when insufficient_privilege then
    v_location_rejected := true;
  end;
  if not v_location_rejected then
    raise exception 'location security regression: branch creation without settings.edit was not rejected';
  end if;

  -- Dedicated read permissions must be sufficient for location selectors.
  perform set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000005', true);
  select count(*) into v_count from public.cloud_branches
  where business_id = '20000000-0000-0000-0000-000000000001';
  if v_count < 2 then
    raise exception 'location read regression: branches.view cannot read branches';
  end if;
  select count(*) into v_count from public.cloud_warehouses
  where business_id = '20000000-0000-0000-0000-000000000001';
  if v_count < 2 then
    raise exception 'location read regression: warehouses.view cannot read warehouses';
  end if;

  perform set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', true);

  -- Delegated branch managers may create branches but not warehouses without the separate grant.
  perform set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000006', true);
  v_delegated_branch := public.create_cloud_branch(
    '20000000-0000-0000-0000-000000000001',
    'Delegated managed branch',
    null,
    null
  );
  v_location_rejected := false;
  begin
    perform public.create_cloud_warehouse(
      '20000000-0000-0000-0000-000000000001',
      v_delegated_branch,
      'Unauthorized extra warehouse'
    );
    raise exception 'location security regression: branch manager created warehouse without warehouses.manage';
  exception when insufficient_privilege then
    v_location_rejected := true;
  end;
  if not v_location_rejected then
    raise exception 'location security regression: warehouse creation without warehouses.manage was not rejected';
  end if;
  perform set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', true);

  -- A caller cannot create locations in another business by supplying its UUID.
  v_location_rejected := false;
  begin
    perform public.create_cloud_branch(
      '20000000-0000-0000-0000-000000000002',
      'Cross-tenant branch',
      null,
      null
    );
    raise exception 'location security regression: cross-tenant branch creation succeeded';
  exception when insufficient_privilege then
    v_location_rejected := true;
  end;
  if not v_location_rejected then
    raise exception 'location security regression: cross-tenant branch creation was not rejected';
  end if;

  if has_table_privilege(current_user, 'public.cloud_product_warehouse_stock', 'UPDATE')
     or has_table_privilege(current_user, 'public.cloud_product_warehouse_stock', 'INSERT')
     or has_table_privilege(current_user, 'public.cloud_product_warehouse_stock', 'DELETE') then
    raise exception 'security regression: authenticated can directly mutate warehouse stock';
  end if;

  if has_table_privilege(current_user, 'public.cloud_expenses', 'DELETE') then
    raise exception 'security regression: authenticated can permanently delete expenses';
  end if;

  if has_column_privilege(current_user, 'public.cloud_products', 'stock_quantity', 'UPDATE') then
    raise exception 'security regression: authenticated can directly change stock_quantity';
  end if;

  if has_table_privilege(current_user, 'public.cloud_sales', 'INSERT') then
    raise exception 'security regression: authenticated can directly insert sales';
  end if;

  if has_table_privilege(current_user, 'public.business_members', 'INSERT')
     or has_table_privilege(current_user, 'public.business_members', 'UPDATE')
     or has_table_privilege(current_user, 'public.business_members', 'DELETE') then
    raise exception 'security regression: client can mutate business memberships outside audited workflows';
  end if;

  if has_table_privilege(current_user, 'public.member_permissions', 'INSERT')
     or has_table_privilege(current_user, 'public.member_permissions', 'UPDATE')
     or has_table_privilege(current_user, 'public.member_permissions', 'DELETE') then
    raise exception 'security regression: client can mutate permissions outside audited workflows';
  end if;

  if has_table_privilege(current_user, 'public.audit_events', 'INSERT')
     or has_table_privilege(current_user, 'public.audit_events', 'UPDATE')
     or has_table_privilege(current_user, 'public.audit_events', 'DELETE') then
    raise exception 'security regression: client can mutate audit events';
  end if;

  v_customer_id := public.create_cloud_customer(
    '20000000-0000-0000-0000-000000000001',
    'عميل فاتورة سحابية', null, null, 0,
    '50000000-0000-0000-0000-000000000040'
  );

  select b.id, w.id into v_default_branch_id, v_default_warehouse_id
  from public.cloud_branches b
  join public.cloud_warehouses w
    on w.business_id = b.business_id and w.branch_id = b.id
  where b.business_id = '20000000-0000-0000-0000-000000000001'
    and b.is_active and w.is_active
  order by b.created_at, w.created_at
  limit 1;

  v_sale_cash_session_id := public.open_cloud_cash_session(
    '20000000-0000-0000-0000-000000000001',
    v_default_branch_id,
    'sales-register',
    1000,
    'رصيد افتتاحي لاختبار تحصيل البيع',
    '550e8400-e29b-41d4-a716-446655440050'
  );

  v_sale_one := public.create_cloud_sale_with_account(
    '20000000-0000-0000-0000-000000000001',
    v_default_branch_id,
    v_default_warehouse_id,
    jsonb_build_array(jsonb_build_object(
      'product_id', '30000000-0000-0000-0000-000000000001',
      'quantity_scaled', 2000
    )),
    100,
    v_customer_id,
    'cash',
    v_sale_cash_session_id,
    '50000000-0000-0000-0000-000000000001'
  );

  v_sale_two := public.create_cloud_sale_with_account(
    '20000000-0000-0000-0000-000000000001',
    v_default_branch_id,
    v_default_warehouse_id,
    jsonb_build_array(jsonb_build_object(
      'product_id', '30000000-0000-0000-0000-000000000001',
      'quantity_scaled', 2000
    )),
    100,
    v_customer_id,
    'cash',
    v_sale_cash_session_id,
    '50000000-0000-0000-0000-000000000001'
  );

  if v_sale_one is distinct from v_sale_two then
    raise exception 'idempotency failed: retry returned a different sale id';
  end if;

  if not exists (
    select 1 from public.cloud_sales
    where id = v_sale_one and customer_id = v_customer_id
      and total_minor = 200 and paid_minor = 100
  ) then
    raise exception 'sale customer linkage failed';
  end if;
  select coalesce(sum(amount_minor), 0) into v_customer_balance
  from public.cloud_customer_account_entries
  where business_id = '20000000-0000-0000-0000-000000000001'
    and customer_id = v_customer_id
    and reference_type = 'sale' and reference_id = v_sale_one;
  if v_customer_balance <> 100 then
    raise exception 'sale receivable failed: expected 100, got %', v_customer_balance;
  end if;
  if not exists (
    select 1 from public.cloud_sale_payments
    where business_id = '20000000-0000-0000-0000-000000000001'
      and sale_id = v_sale_one and amount_minor = 100 and payment_method = 'cash'
      and cash_session_id = v_sale_cash_session_id
  ) then
    raise exception 'sale payment record failed';
  end if;
  if not exists (
    select 1 from public.cloud_cash_movements
    where business_id = '20000000-0000-0000-0000-000000000001'
      and cash_session_id = v_sale_cash_session_id
      and direction = 'in' and category = 'sale_receipt'
      and amount_minor = 100 and source_type = 'sale_payment'
      and source_id = (select id from public.cloud_sale_payments where sale_id = v_sale_one)
  ) then
    raise exception 'cash sale integration failed: no incoming movement was posted';
  end if;
  v_sale_cash_close := public.close_cloud_cash_session(
    '20000000-0000-0000-0000-000000000001',
    v_sale_cash_session_id,
    1100,
    'إقفال وردية تحصيل البيع',
    '550e8400-e29b-41d4-a716-446655440051'
  );
  if (v_sale_cash_close->>'expected_balance_minor')::bigint <> 1100
     or (v_sale_cash_close->>'difference_minor')::bigint <> 0 then
    raise exception 'cash sale integration failed: expected 1100, got %', v_sale_cash_close;
  end if;

  begin
    perform public.create_cloud_sale_with_account(
      '20000000-0000-0000-0000-000000000001',
      v_default_branch_id,
      v_default_warehouse_id,
      jsonb_build_array(jsonb_build_object(
        'product_id', '30000000-0000-0000-0000-000000000001',
        'quantity_scaled', 1000
      )),
      0,
      null,
      'cash',
      null,
      '550e8400-e29b-41d4-a716-446655440039'
    );
    raise exception 'credit sale regression: unpaid sale without customer was accepted';
  exception when check_violation then
    v_credit_without_customer_rejected := true;
  end;
  if not v_credit_without_customer_rejected then
    raise exception 'credit sale regression: unpaid sale without customer was not rejected';
  end if;

  select stock_quantity into v_stock
  from public.cloud_products
  where id = '30000000-0000-0000-0000-000000000001';

  if v_stock <> 8000 then
    raise exception 'idempotency failed: expected stock 8000 scaled units after one sale and retry, got %', v_stock;
  end if;

  begin
    perform public.create_cloud_sale_with_account(
      '20000000-0000-0000-0000-000000000001',
      v_default_branch_id,
      v_default_warehouse_id,
      jsonb_build_array(jsonb_build_object(
        'product_id', '30000000-0000-0000-0000-000000000001',
        'quantity_scaled', 1000
      )),
      100,
      v_customer_id,
      'cash',
      v_sale_cash_session_id,
      '50000000-0000-0000-0000-000000000001'
    );
    raise exception 'idempotency failed: reused sale key accepted a different payload';
  exception when invalid_parameter_value then
    v_mismatched_sale_rejected := true;
  end;

  if not v_mismatched_sale_rejected then
    raise exception 'idempotency failed: mismatched sale payload was not rejected';
  end if;

  v_movement_one := public.adjust_cloud_inventory(
    '20000000-0000-0000-0000-000000000001',
    '30000000-0000-0000-0000-000000000001',
    3,
    'test inventory count',
    '50000000-0000-0000-0000-000000000010'
  );

  v_movement_two := public.adjust_cloud_inventory(
    '20000000-0000-0000-0000-000000000001',
    '30000000-0000-0000-0000-000000000001',
    3,
    'test inventory count',
    '50000000-0000-0000-0000-000000000010'
  );

  if v_movement_one is distinct from v_movement_two then
    raise exception 'idempotency failed: inventory retry returned a different movement id';
  end if;

  begin
    perform public.adjust_cloud_inventory(
      '20000000-0000-0000-0000-000000000001',
      '30000000-0000-0000-0000-000000000001',
      4,
      'test inventory count',
      '50000000-0000-0000-0000-000000000010'
    );
    raise exception 'idempotency failed: reused inventory key accepted a different payload';
  exception when invalid_parameter_value then
    v_mismatched_adjustment_rejected := true;
  end;

  if not v_mismatched_adjustment_rejected then
    raise exception 'idempotency failed: mismatched inventory payload was not rejected';
  end if;

  select stock_quantity into v_stock
  from public.cloud_products
  where id = '30000000-0000-0000-0000-000000000001';

  if v_stock <> 11000 then
    raise exception 'idempotency failed: expected stock 11000 scaled units after one adjustment and retry, got %', v_stock;
  end if;

  -- A second warehouse has an independent balance; sales there must not
  -- consume the default warehouse's stock.
  perform public.adjust_cloud_inventory(
    '20000000-0000-0000-0000-000000000001',
    '22000000-0000-0000-0000-000000000001',
    '23000000-0000-0000-0000-000000000001',
    '30000000-0000-0000-0000-000000000001',
    5000,
    'opening balance second warehouse',
    '50000000-0000-0000-0000-000000000020'
  );

  perform public.create_cloud_sale_with_account(
    '20000000-0000-0000-0000-000000000001',
    '22000000-0000-0000-0000-000000000001',
    '23000000-0000-0000-0000-000000000001',
    jsonb_build_array(jsonb_build_object(
      'product_id', '30000000-0000-0000-0000-000000000001',
      'quantity_scaled', 2000
    )),
    200,
    null,
    'card',
    null,
    '50000000-0000-0000-0000-000000000021'
  );

  select quantity_scaled into v_stock
  from public.cloud_product_warehouse_stock
  where business_id = '20000000-0000-0000-0000-000000000001'
    and warehouse_id = '23000000-0000-0000-0000-000000000001'
    and product_id = '30000000-0000-0000-0000-000000000001';

  if v_stock <> 3000 then
    raise exception 'warehouse stock failed: expected 3000 scaled units in second warehouse, got %', v_stock;
  end if;

  perform public.adjust_cloud_inventory(
    '20000000-0000-0000-0000-000000000001',
    '22000000-0000-0000-0000-000000000001',
    '23000000-0000-0000-0000-000000000001',
    '30000000-0000-0000-0000-000000000001',
    250,
    'quarter-unit receipt',
    '50000000-0000-0000-0000-000000000022'
  );

  v_fractional_sale_one := public.create_cloud_sale_with_account(
    '20000000-0000-0000-0000-000000000001',
    '22000000-0000-0000-0000-000000000001',
    '23000000-0000-0000-0000-000000000001',
    jsonb_build_array(jsonb_build_object(
      'product_id', '30000000-0000-0000-0000-000000000001',
      'quantity_scaled', 1250
    )),
    125,
    null,
    'card',
    null,
    '50000000-0000-0000-0000-000000000023'
  );

  v_fractional_sale_two := public.create_cloud_sale_with_account(
    '20000000-0000-0000-0000-000000000001',
    '22000000-0000-0000-0000-000000000001',
    '23000000-0000-0000-0000-000000000001',
    jsonb_build_array(jsonb_build_object(
      'product_id', '30000000-0000-0000-0000-000000000001',
      'quantity_scaled', 1250
    )),
    125,
    null,
    'card',
    null,
    '50000000-0000-0000-0000-000000000023'
  );

  if v_fractional_sale_one is distinct from v_fractional_sale_two then
    raise exception 'fractional sale retry returned a different sale id';
  end if;

  select quantity_scaled, line_total_minor
  into v_stock, v_line_total
  from public.cloud_sale_items
  where sale_id = v_fractional_sale_one;

  if v_stock <> 1250 or v_line_total <> 125 then
    raise exception 'fractional sale rounding failed: quantity %, line total %', v_stock, v_line_total;
  end if;

  select stock_quantity into v_stock
  from public.cloud_products
  where id = '30000000-0000-0000-0000-000000000001';

  if v_stock <> 13000 then
    raise exception 'aggregate stock failed: expected 13000 scaled units after fractional warehouse operations, got %', v_stock;
  end if;

  select count(*) into v_count from public.cloud_sales
  where operation_id = '50000000-0000-0000-0000-000000000001';
  if v_count <> 1 then
    raise exception 'idempotency failed: expected one sale row, got %', v_count;
  end if;

  begin
    perform public.adjust_cloud_inventory(
      '20000000-0000-0000-0000-000000000002',
      '30000000-0000-0000-0000-000000000002',
      1,
      'unauthorized cross-tenant adjustment',
      '50000000-0000-0000-0000-000000000002'
    );
  exception when insufficient_privilege then
    v_other_business_adjustment_rejected := true;
  end;

  if not v_other_business_adjustment_rejected then
    raise exception 'tenant isolation failed: owner A adjusted inventory in business B';
  end if;

  -- An active member with products.view can read products, but cannot sell.
  perform set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000003', true);
  select count(*) into v_count from public.cloud_products;
  if v_count <> 1 then
    raise exception 'least privilege failed: products.view member sees % products, expected 1', v_count;
  end if;

  begin
    perform public.create_cloud_sale(
      '20000000-0000-0000-0000-000000000001',
      jsonb_build_array(jsonb_build_object(
        'product_id', '30000000-0000-0000-0000-000000000001',
        'quantity', 1
      )),
      0,
      '50000000-0000-0000-0000-000000000003'
    );
    raise exception 'least privilege failed: products.view member created a sale';
  exception when insufficient_privilege then
    null;
  end;

  -- An inactive member receives no access even when a permission row remains.
  perform set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000004', true);
  select count(*) into v_count from public.cloud_products;
  if v_count <> 0 then
    raise exception 'inactive membership failed: inactive member sees % products', v_count;
  end if;

  -- The owner can change a member's permissions and the RPC writes an audit event atomically.
  perform set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', true);
  perform public.replace_member_permissions(
    '20000000-0000-0000-0000-000000000001',
    '21000000-0000-0000-0000-000000000003',
    array['products.view', 'customers.view', 'accounts.view']
  );

  perform set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000003', true);
  if not public.has_business_permission(
    '20000000-0000-0000-0000-000000000001', 'customers.view'
  ) or not public.has_business_permission(
    '20000000-0000-0000-0000-000000000001', 'accounts.view'
  ) then
    raise exception 'permission catalogue regression: expanded customer/account permissions were not persisted';
  end if;
  perform set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', true);

  select count(*) into v_count_audit
  from public.audit_events
  where business_id = '20000000-0000-0000-0000-000000000001'
    and action_key = 'users.permissions.update'
    and entity_id = '21000000-0000-0000-0000-000000000003';

  if v_count_audit <> 1 then
    raise exception 'audit regression: expected one permission-change event, got %', v_count_audit;
  end if;

  -- Delegated admin may preserve or grant only capabilities it already holds.
  perform set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000006', true);
  perform public.replace_member_permissions(
    '20000000-0000-0000-0000-000000000001',
    '21000000-0000-0000-0000-000000000003',
    array['products.view', 'customers.view', 'accounts.view']
  );

  begin
    perform public.replace_member_permissions(
      '20000000-0000-0000-0000-000000000001',
      '21000000-0000-0000-0000-000000000003',
      array['sales.create']
    );
    raise exception 'delegation regression: admin granted a permission it does not hold';
  exception when insufficient_privilege then
    v_delegated_escalation_rejected := true;
  end;

  if not v_delegated_escalation_rejected then
    raise exception 'delegation regression: privilege escalation was not rejected';
  end if;

  -- Customer/supplier cloud ledgers are append-only and their payment RPCs are idempotent.
  perform set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', true);

  v_customer_id := public.create_cloud_customer(
    '20000000-0000-0000-0000-000000000001',
    'عميل سحابي اختبار', '01000000000', null, 2500,
    '50000000-0000-0000-0000-000000000030'
  );
  v_customer_id_retry := public.create_cloud_customer(
    '20000000-0000-0000-0000-000000000001',
    'عميل سحابي اختبار', '01000000000', null, 2500,
    '50000000-0000-0000-0000-000000000030'
  );
  if v_customer_id is distinct from v_customer_id_retry then
    raise exception 'customer idempotency failed: retry returned a different customer id';
  end if;

  begin
    perform public.create_cloud_customer(
      '20000000-0000-0000-0000-000000000001',
      'اسم مختلف', '01000000000', null, 2500,
      '50000000-0000-0000-0000-000000000030'
    );
    raise exception 'customer idempotency failed: reused key accepted a different payload';
  exception when invalid_parameter_value then
    null;
  end;

  v_supplier_id := public.create_cloud_supplier(
    '20000000-0000-0000-0000-000000000001',
    'مورد سحابي اختبار', null, null, 4000,
    '50000000-0000-0000-0000-000000000031'
  );

  -- A viewer may read account data but cannot post receipts or supplier payments.
  perform set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000003', true);
  begin
    perform public.record_cloud_customer_receipt(
      '20000000-0000-0000-0000-000000000001', v_customer_id, 500,
      'cash', 'تحصيل غير مصرح', '50000000-0000-0000-0000-000000000032'
    );
    raise exception 'account permission regression: viewer recorded a customer receipt';
  exception when insufficient_privilege then
    v_unauthorized_receipt_rejected := true;
  end;
  begin
    perform public.record_cloud_supplier_payment(
      '20000000-0000-0000-0000-000000000001', v_supplier_id, 500,
      'cash', 'سداد غير مصرح', '50000000-0000-0000-0000-000000000033'
    );
    raise exception 'account permission regression: viewer recorded a supplier payment';
  exception when insufficient_privilege then
    v_unauthorized_supplier_payment_rejected := true;
  end;
  if not v_unauthorized_receipt_rejected or not v_unauthorized_supplier_payment_rejected then
    raise exception 'account permission regression: account viewer received a write capability';
  end if;

  perform set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', true);
  v_customer_payment_id := public.record_cloud_customer_receipt(
    '20000000-0000-0000-0000-000000000001', v_customer_id, 1000,
    'card', 'تحصيل بطاقة', '50000000-0000-0000-0000-000000000034'
  );
  v_customer_payment_retry := public.record_cloud_customer_receipt(
    '20000000-0000-0000-0000-000000000001', v_customer_id, 1000,
    'card', 'تحصيل بطاقة', '50000000-0000-0000-0000-000000000034'
  );
  if v_customer_payment_id is distinct from v_customer_payment_retry then
    raise exception 'customer receipt idempotency failed';
  end if;
  select coalesce(sum(amount_minor), 0) into v_customer_balance
  from public.cloud_customer_account_entries
  where business_id = '20000000-0000-0000-0000-000000000001'
    and customer_id = v_customer_id;
  if v_customer_balance <> 1500 then
    raise exception 'customer ledger balance failed: expected 1500, got %', v_customer_balance;
  end if;
  select count(*) into v_count
  from public.cloud_customer_payments
  where business_id = '20000000-0000-0000-0000-000000000001'
    and operation_id = '50000000-0000-0000-0000-000000000034';
  if v_count <> 1 then
    raise exception 'customer receipt idempotency failed: expected one payment row, got %', v_count;
  end if;
  begin
    perform public.record_cloud_customer_receipt(
      '20000000-0000-0000-0000-000000000001', v_customer_id, 1200,
      'card', 'تحصيل مختلف', '50000000-0000-0000-0000-000000000034'
    );
    raise exception 'customer receipt idempotency failed: mismatched payload accepted';
  exception when invalid_parameter_value then
    v_receipt_payload_rejected := true;
  end;
  if not v_receipt_payload_rejected then
    raise exception 'customer receipt idempotency failed: mismatched payload not rejected';
  end if;

  v_account_cash_session_id := public.open_cloud_cash_session(
    '20000000-0000-0000-0000-000000000001',
    v_default_branch_id,
    'account-register',
    500,
    'رصيد افتتاحي لاختبار تحصيل وسداد الحسابات',
    '550e8400-e29b-41d4-a716-446655440053'
  );
  v_customer_cash_payment_id := public.record_cloud_customer_receipt(
    '20000000-0000-0000-0000-000000000001', v_customer_id, 200,
    'cash', 'تحصيل نقدي من العميل', '550e8400-e29b-41d4-a716-446655440054',
    v_account_cash_session_id
  );
  v_customer_cash_payment_retry := public.record_cloud_customer_receipt(
    '20000000-0000-0000-0000-000000000001', v_customer_id, 200,
    'cash', 'تحصيل نقدي من العميل', '550e8400-e29b-41d4-a716-446655440054',
    v_account_cash_session_id
  );
  if v_customer_cash_payment_id is distinct from v_customer_cash_payment_retry then
    raise exception 'cash customer receipt idempotency failed';
  end if;
  if not exists (
    select 1 from public.cloud_cash_movements
    where cash_session_id = v_account_cash_session_id
      and direction = 'in' and category = 'customer_receipt'
      and amount_minor = 200 and source_id = v_customer_cash_payment_id
  ) then
    raise exception 'cash customer receipt was not posted to the register';
  end if;

  begin
    perform public.record_cloud_customer_receipt(
      '20000000-0000-0000-0000-000000000001', v_customer_id, 1600,
      'card', 'تحصيل أكبر من الرصيد', '550e8400-e29b-41d4-a716-446655440035'
    );
    raise exception 'customer balance regression: overpayment was accepted';
  exception when check_violation then
    v_customer_overpayment_rejected := true;
  end;
  if not v_customer_overpayment_rejected then
    raise exception 'customer balance regression: overpayment was not rejected';
  end if;

  v_supplier_payment_id := public.record_cloud_supplier_payment(
    '20000000-0000-0000-0000-000000000001', v_supplier_id, 1500,
    'bank_transfer', 'سداد تحويل', '550e8400-e29b-41d4-a716-446655440036'
  );
  select coalesce(sum(amount_minor), 0) into v_supplier_balance
  from public.cloud_supplier_account_entries
  where business_id = '20000000-0000-0000-0000-000000000001'
    and supplier_id = v_supplier_id;
  if v_supplier_balance <> 2500 then
    raise exception 'supplier ledger balance failed: expected 2500, got %', v_supplier_balance;
  end if;
  select count(*) into v_count
  from public.cloud_supplier_payments
  where id = v_supplier_payment_id
    and payment_method = 'bank_transfer'
    and amount_minor = 1500;
  if v_count <> 1 then
    raise exception 'supplier payment record failed';
  end if;
  v_supplier_cash_payment_id := public.record_cloud_supplier_payment(
    '20000000-0000-0000-0000-000000000001', v_supplier_id, 500,
    'cash', 'سداد نقدي للمورد', '550e8400-e29b-41d4-a716-446655440055',
    v_account_cash_session_id
  );
  if not exists (
    select 1 from public.cloud_cash_movements
    where cash_session_id = v_account_cash_session_id
      and direction = 'out' and category = 'supplier_payment'
      and amount_minor = 500 and source_id = v_supplier_cash_payment_id
  ) then
    raise exception 'cash supplier payment was not posted to the register';
  end if;
  -- Purchase invoice, stock receipt, supplier liability and cash payment are atomic/idempotent.
  v_purchase_id := public.create_cloud_purchase_with_account(
    '20000000-0000-0000-0000-000000000001',
    v_default_branch_id,
    v_default_warehouse_id,
    v_supplier_id,
    jsonb_build_array(jsonb_build_object(
      'product_id', '30000000-0000-0000-0000-000000000001',
      'quantity_scaled', 1000,
      'unit_cost_minor', 1000
    )),
    100,
    'cash',
    v_account_cash_session_id,
    '550e8400-e29b-41d4-a716-446655440057'
  );
  v_purchase_retry := public.create_cloud_purchase_with_account(
    '20000000-0000-0000-0000-000000000001',
    v_default_branch_id,
    v_default_warehouse_id,
    v_supplier_id,
    jsonb_build_array(jsonb_build_object(
      'product_id', '30000000-0000-0000-0000-000000000001',
      'quantity_scaled', 1000,
      'unit_cost_minor', 1000
    )),
    100,
    'cash',
    v_account_cash_session_id,
    '550e8400-e29b-41d4-a716-446655440057'
  );
  if v_purchase_id is distinct from v_purchase_retry then
    raise exception 'purchase idempotency failed: retry returned a different purchase';
  end if;
  if not exists (
    select 1 from public.cloud_purchases
    where id = v_purchase_id and business_id = '20000000-0000-0000-0000-000000000001'
      and total_minor = 1000 and paid_minor = 100 and due_minor = 900
  ) then
    raise exception 'purchase totals failed: expected total 1000, paid 100, due 900';
  end if;
  if not exists (
    select 1 from public.cloud_purchase_items
    where purchase_id = v_purchase_id and product_id = '30000000-0000-0000-0000-000000000001'
      and quantity_scaled = 1000 and unit_cost_minor = 1000 and line_total_minor = 1000
  ) then
    raise exception 'purchase item was not stored with scaled quantity and cost';
  end if;
  if not exists (
    select 1 from public.cloud_inventory_movements
    where source_type = 'purchase' and source_id = v_purchase_id
      and quantity_delta = 1000
  ) then
    raise exception 'purchase stock movement was not recorded';
  end if;
  select quantity_scaled into v_purchase_stock
  from public.cloud_product_warehouse_stock
  where business_id = '20000000-0000-0000-0000-000000000001'
    and warehouse_id = v_default_warehouse_id
    and product_id = '30000000-0000-0000-0000-000000000001';
  if v_purchase_stock is null or v_purchase_stock < 1000 then
    raise exception 'purchase stock was not received into the selected warehouse';
  end if;
  if not exists (
    select 1 from public.cloud_purchase_payments
    where purchase_id = v_purchase_id and amount_minor = 100
      and payment_method = 'cash' and cash_session_id = v_account_cash_session_id
  ) then
    raise exception 'cash purchase payment was not recorded against the register';
  end if;
  if not exists (
    select 1 from public.cloud_cash_movements
    where cash_session_id = v_account_cash_session_id
      and direction = 'out' and category = 'purchase_payment'
      and amount_minor = 100
      and source_type = 'purchase_payment'
      and source_id = (select id from public.cloud_purchase_payments where purchase_id = v_purchase_id)
  ) then
    raise exception 'cash purchase payment was not posted to the register';
  end if;
  select coalesce(sum(amount_minor), 0) into v_supplier_balance
  from public.cloud_supplier_account_entries
  where business_id = '20000000-0000-0000-0000-000000000001'
    and supplier_id = v_supplier_id;
  if v_supplier_balance <> 2900 then
    raise exception 'purchase supplier liability failed: expected 2900, got %', v_supplier_balance;
  end if;
  begin
    perform public.create_cloud_purchase_with_account(
      '20000000-0000-0000-0000-000000000001',
      v_default_branch_id,
      v_default_warehouse_id,
      v_supplier_id,
      jsonb_build_array(jsonb_build_object(
        'product_id', '30000000-0000-0000-0000-000000000001',
        'quantity_scaled', 2000,
        'unit_cost_minor', 1000
      )),
      100,
      'cash',
      v_account_cash_session_id,
      '550e8400-e29b-41d4-a716-446655440057'
    );
    raise exception 'purchase idempotency failed: reused key accepted a different payload';
  exception when invalid_parameter_value then
    v_purchase_payload_rejected := true;
  end;
  if not v_purchase_payload_rejected then
    raise exception 'purchase idempotency failed: mismatched payload was not rejected';
  end if;

  -- Sales return restores stock, credits the customer account and records the actual refund.
  select id into v_sale_item_id from public.cloud_sale_items
  where sale_id = v_sale_one and product_id = '30000000-0000-0000-0000-000000000001';
  v_sale_return_id := public.create_cloud_sale_return(
    '20000000-0000-0000-0000-000000000001',
    v_sale_one,
    jsonb_build_array(jsonb_build_object(
      'sale_item_id', v_sale_item_id, 'quantity_scaled', 1000
    )),
    50,
    'card',
    null,
    '550e8400-e29b-41d4-a716-446655440060'
  );
  v_sale_return_retry := public.create_cloud_sale_return(
    '20000000-0000-0000-0000-000000000001',
    v_sale_one,
    jsonb_build_array(jsonb_build_object(
      'sale_item_id', v_sale_item_id, 'quantity_scaled', 1000
    )),
    50,
    'card',
    null,
    '550e8400-e29b-41d4-a716-446655440060'
  );
  if v_sale_return_id is distinct from v_sale_return_retry then
    raise exception 'sales return idempotency failed';
  end if;
  if not exists (
    select 1 from public.cloud_sale_returns
    where id = v_sale_return_id and total_minor = 100 and refunded_minor = 50
  ) then
    raise exception 'sales return valuation/refund amount failed';
  end if;
  if not exists (
    select 1 from public.cloud_customer_account_entries
    where reference_type = 'sale_return' and reference_id = v_sale_return_id
      and amount_minor = -50
  ) then
    raise exception 'sales return customer account net credit failed';
  end if;
  if not exists (
    select 1 from public.cloud_sale_return_refunds
    where return_id = v_sale_return_id and amount_minor = 50
      and payment_method = 'card' and cash_session_id is null
  ) then
    raise exception 'electronic sales refund was not recorded';
  end if;
  select quantity_scaled into v_return_stock
  from public.cloud_product_warehouse_stock
  where business_id = '20000000-0000-0000-0000-000000000001'
    and warehouse_id = v_default_warehouse_id
    and product_id = '30000000-0000-0000-0000-000000000001';
  if v_return_stock < 1000 then
    raise exception 'sales return did not restore inventory';
  end if;
  begin
    perform public.create_cloud_sale_return(
      '20000000-0000-0000-0000-000000000001',
      v_sale_one,
      jsonb_build_array(jsonb_build_object(
        'sale_item_id', v_sale_item_id, 'quantity_scaled', 1000
      )),
      49,
      'card',
      null,
      '550e8400-e29b-41d4-a716-446655440060'
    );
    raise exception 'sales return idempotency accepted a different payload';
  exception when invalid_parameter_value then
    v_sale_return_payload_rejected := true;
  end;
  if not v_sale_return_payload_rejected then
    raise exception 'sales return mismatched payload was not rejected';
  end if;

  -- Purchase return reverses stock and supplier liability, and records supplier refund.
  select id into v_purchase_item_id from public.cloud_purchase_items
  where purchase_id = v_purchase_id and product_id = '30000000-0000-0000-0000-000000000001';
  v_purchase_return_id := public.create_cloud_purchase_return(
    '20000000-0000-0000-0000-000000000001',
    v_purchase_id,
    jsonb_build_array(jsonb_build_object(
      'purchase_item_id', v_purchase_item_id, 'quantity_scaled', 250
    )),
    50,
    'bank_transfer',
    null,
    '550e8400-e29b-41d4-a716-446655440061'
  );
  v_purchase_return_retry := public.create_cloud_purchase_return(
    '20000000-0000-0000-0000-000000000001',
    v_purchase_id,
    jsonb_build_array(jsonb_build_object(
      'purchase_item_id', v_purchase_item_id, 'quantity_scaled', 250
    )),
    50,
    'bank_transfer',
    null,
    '550e8400-e29b-41d4-a716-446655440061'
  );
  if v_purchase_return_id is distinct from v_purchase_return_retry then
    raise exception 'purchase return idempotency failed';
  end if;
  if not exists (
    select 1 from public.cloud_purchase_returns
    where id = v_purchase_return_id and total_minor = 250 and refunded_minor = 50
  ) then
    raise exception 'purchase return valuation/refund amount failed';
  end if;
  if not exists (
    select 1 from public.cloud_supplier_account_entries
    where reference_type = 'purchase_return' and reference_id = v_purchase_return_id
      and amount_minor = -200
  ) then
    raise exception 'purchase return supplier account net adjustment failed';
  end if;
  if not exists (
    select 1 from public.cloud_purchase_return_refunds
    where return_id = v_purchase_return_id and amount_minor = 50
      and payment_method = 'bank_transfer' and cash_session_id is null
  ) then
    raise exception 'electronic purchase return refund was not recorded';
  end if;
  select quantity_scaled into v_return_stock
  from public.cloud_product_warehouse_stock
  where business_id = '20000000-0000-0000-0000-000000000001'
    and warehouse_id = v_default_warehouse_id
    and product_id = '30000000-0000-0000-0000-000000000001';
  if v_return_stock is null then
    raise exception 'purchase return stock row missing';
  end if;
  if not exists (
    select 1 from public.cloud_inventory_movements
    where source_type = 'purchase_return' and source_id = v_purchase_return_id
      and quantity_delta = -250
  ) then
    raise exception 'purchase return inventory reversal was not recorded';
  end if;
  begin
    perform public.create_cloud_purchase_return(
      '20000000-0000-0000-0000-000000000001',
      v_purchase_id,
      jsonb_build_array(jsonb_build_object(
        'purchase_item_id', v_purchase_item_id, 'quantity_scaled', 250
      )),
      49,
      'bank_transfer',
      null,
      '550e8400-e29b-41d4-a716-446655440061'
    );
    raise exception 'purchase return idempotency accepted a different payload';
  exception when invalid_parameter_value then
    v_purchase_return_payload_rejected := true;
  end;
  if not v_purchase_return_payload_rejected then
    raise exception 'purchase return mismatched payload was not rejected';
  end if;

  -- Remaining quantities are capped across all returns, including concurrent retry paths.
  begin
    perform public.create_cloud_sale_return(
      '20000000-0000-0000-0000-000000000001',
      v_sale_one,
      jsonb_build_array(jsonb_build_object(
        'sale_item_id', v_sale_item_id, 'quantity_scaled', 1500
      )),
      50,
      'card',
      null,
      '550e8400-e29b-41d4-a716-446655440062'
    );
    raise exception 'sales return accepted more than the unreturned quantity';
  exception when check_violation then
    v_sale_overreturn_rejected := true;
  end;
  if not v_sale_overreturn_rejected then
    raise exception 'sales return remaining quantity guard failed';
  end if;
  begin
    perform public.create_cloud_purchase_return(
      '20000000-0000-0000-0000-000000000001',
      v_purchase_id,
      jsonb_build_array(jsonb_build_object(
        'purchase_item_id', v_purchase_item_id, 'quantity_scaled', 800
      )),
      50,
      'bank_transfer',
      null,
      '550e8400-e29b-41d4-a716-446655440065'
    );
    raise exception 'purchase return accepted more than the unreturned quantity';
  exception when check_violation then
    v_purchase_overreturn_rejected := true;
  end;
  if not v_purchase_overreturn_rejected then
    raise exception 'purchase return remaining quantity guard failed';
  end if;

  -- Cash refunds are posted to the correct branch register and included in its closing balance.
  v_return_cash_session_id := public.open_cloud_cash_session(
    '20000000-0000-0000-0000-000000000001',
    v_default_branch_id,
    'returns-register',
    500,
    'رصيد افتتاحي لاختبار ردود المرتجعات',
    '550e8400-e29b-41d4-a716-446655440066'
  );
  v_sale_cash_refund_id := public.create_cloud_sale_return(
    '20000000-0000-0000-0000-000000000001',
    v_sale_one,
    jsonb_build_array(jsonb_build_object(
      'sale_item_id', v_sale_item_id, 'quantity_scaled', 1000
    )),
    50,
    'cash',
    v_return_cash_session_id,
    '550e8400-e29b-41d4-a716-446655440063'
  );
  if not exists (
    select 1 from public.cloud_cash_movements
    where cash_session_id = v_return_cash_session_id
      and direction = 'out' and category = 'sale_return_refund'
      and amount_minor = 50 and source_type = 'sale_return_refund'
  ) then
    raise exception 'cash sales return refund was not posted as an outgoing movement';
  end if;
  v_purchase_cash_refund_id := public.create_cloud_purchase_return(
    '20000000-0000-0000-0000-000000000001',
    v_purchase_id,
    jsonb_build_array(jsonb_build_object(
      'purchase_item_id', v_purchase_item_id, 'quantity_scaled', 750
    )),
    50,
    'cash',
    v_return_cash_session_id,
    '550e8400-e29b-41d4-a716-446655440064'
  );
  if not exists (
    select 1 from public.cloud_cash_movements
    where cash_session_id = v_return_cash_session_id
      and direction = 'in' and category = 'purchase_return_refund'
      and amount_minor = 50 and source_type = 'purchase_return_refund'
  ) then
    raise exception 'cash purchase return refund was not posted as an incoming movement';
  end if;
  v_return_cash_close := public.close_cloud_cash_session(
    '20000000-0000-0000-0000-000000000001',
    v_return_cash_session_id,
    500,
    'إقفال وردية ردود المرتجعات',
    '550e8400-e29b-41d4-a716-446655440067'
  );
  if (v_return_cash_close->>'expected_balance_minor')::bigint <> 500
     or (v_return_cash_close->>'difference_minor')::bigint <> 0 then
    raise exception 'return cash refund reconciliation failed: %', v_return_cash_close;
  end if;

  if has_table_privilege(current_user, 'public.cloud_sale_returns', 'INSERT')
     or has_table_privilege(current_user, 'public.cloud_purchase_return_items', 'DELETE')
     or has_table_privilege(current_user, 'public.cloud_purchase_return_refunds', 'UPDATE') then
    raise exception 'security regression: authenticated can directly mutate return records';
  end if;

  select coalesce(sum(amount_minor), 0) into v_customer_balance
  from public.cloud_customer_account_entries
  where business_id = '20000000-0000-0000-0000-000000000001'
    and customer_id = v_customer_id;
  if v_customer_balance <> 1300 then
    raise exception 'customer cash receipt balance failed: expected 1300, got %', v_customer_balance;
  end if;
  v_account_cash_close := public.close_cloud_cash_session(
    '20000000-0000-0000-0000-000000000001',
    v_account_cash_session_id,
    100,
    'إقفال وردية تحصيل وسداد الحسابات',
    '550e8400-e29b-41d4-a716-446655440056'
  );
  if (v_account_cash_close->>'expected_balance_minor')::bigint <> 100
     or (v_account_cash_close->>'counted_balance_minor')::bigint <> 100
     or (v_account_cash_close->>'difference_minor')::bigint <> 0 then
    raise exception 'account cash session calculation failed: expected and counted balance should both be 100, got %', v_account_cash_close;
  end if;
  begin
    perform public.record_cloud_supplier_payment(
      '20000000-0000-0000-0000-000000000001', v_supplier_id, 3000,
      'bank_transfer', 'سداد أكبر من الرصيد', '550e8400-e29b-41d4-a716-446655440037'
    );
    raise exception 'supplier balance regression: overpayment was accepted';
  exception when check_violation then
    v_supplier_overpayment_rejected := true;
  end;
  if not v_supplier_overpayment_rejected then
    raise exception 'supplier balance regression: overpayment was not rejected';
  end if;

  -- Cash sessions are branch/register scoped, append-only and idempotent.
  v_cash_session_id := public.open_cloud_cash_session(
    '20000000-0000-0000-0000-000000000001',
    v_created_branch,
    'register-01',
    1000,
    'رصيد افتتاحي للصندوق',
    '550e8400-e29b-41d4-a716-446655440040'
  );
  v_cash_session_retry := public.open_cloud_cash_session(
    '20000000-0000-0000-0000-000000000001',
    v_created_branch,
    'register-01',
    1000,
    'رصيد افتتاحي للصندوق',
    '550e8400-e29b-41d4-a716-446655440040'
  );
  if v_cash_session_id is distinct from v_cash_session_retry then
    raise exception 'cash session idempotency failed: retry returned a different session';
  end if;

  begin
    perform public.open_cloud_cash_session(
      '20000000-0000-0000-0000-000000000001',
      v_created_branch,
      'register-01',
      1000,
      'محاولة وردية ثانية',
      '550e8400-e29b-41d4-a716-446655440041'
    );
    raise exception 'cash session regression: two open sessions exist for one register';
  exception when unique_violation then
    v_cash_open_rejected := true;
  end;
  if not v_cash_open_rejected then
    raise exception 'cash session regression: duplicate open register session was not rejected';
  end if;

  v_cash_movement_id := public.record_cloud_cash_movement(
    '20000000-0000-0000-0000-000000000001',
    v_cash_session_id,
    'in',
    'other_income',
    500,
    'إيراد نقدي إضافي',
    '550e8400-e29b-41d4-a716-446655440042'
  );
  v_cash_movement_retry := public.record_cloud_cash_movement(
    '20000000-0000-0000-0000-000000000001',
    v_cash_session_id,
    'in',
    'other_income',
    500,
    'إيراد نقدي إضافي',
    '550e8400-e29b-41d4-a716-446655440042'
  );
  if v_cash_movement_id is distinct from v_cash_movement_retry then
    raise exception 'cash movement idempotency failed';
  end if;

  perform public.record_cloud_cash_movement(
    '20000000-0000-0000-0000-000000000001',
    v_cash_session_id,
    'out',
    'cash_expense',
    200,
    'مصروف نقدي',
    '550e8400-e29b-41d4-a716-446655440043'
  );

  begin
    perform public.record_cloud_cash_movement(
      '20000000-0000-0000-0000-000000000001',
      v_cash_session_id,
      'in',
      'other_income',
      501,
      'حمولة مختلفة',
      '550e8400-e29b-41d4-a716-446655440042'
    );
    raise exception 'cash movement idempotency failed: mismatched payload accepted';
  exception when invalid_parameter_value then
    v_cash_movement_payload_rejected := true;
  end;
  if not v_cash_movement_payload_rejected then
    raise exception 'cash movement idempotency failed: mismatched payload was not rejected';
  end if;

  -- An open cash session prevents branch deactivation, even when stock is zero.
  begin
    perform public.set_cloud_branch_active(
      '20000000-0000-0000-0000-000000000001',
      v_created_branch,
      false
    );
    raise exception 'cash session regression: branch with an open session was deactivated';
  exception when check_violation then
    v_cash_branch_deactivation_rejected := true;
  end;
  if not v_cash_branch_deactivation_rejected then
    raise exception 'cash session regression: open-session branch deactivation was not rejected';
  end if;

  v_cash_close_summary := public.close_cloud_cash_session(
    '20000000-0000-0000-0000-000000000001',
    v_cash_session_id,
    1200,
    'عد فعلي أقل من المتوقع بمائة',
    '550e8400-e29b-41d4-a716-446655440044'
  );
  if (v_cash_close_summary->>'expected_balance_minor')::bigint <> 1300
     or (v_cash_close_summary->>'difference_minor')::bigint <> -100 then
    raise exception 'cash session calculation failed: expected 1300 and difference -100, got %',
      v_cash_close_summary;
  end if;
  v_cash_close_retry := public.close_cloud_cash_session(
    '20000000-0000-0000-0000-000000000001',
    v_cash_session_id,
    1200,
    'عد فعلي أقل من المتوقع بمائة',
    '550e8400-e29b-41d4-a716-446655440044'
  );
  if v_cash_close_summary is distinct from v_cash_close_retry then
    raise exception 'cash session close idempotency failed';
  end if;

  begin
    perform public.record_cloud_cash_movement(
      '20000000-0000-0000-0000-000000000001',
      v_cash_session_id,
      'in',
      'other_income',
      100,
      'حركة بعد الإغلاق',
      '550e8400-e29b-41d4-a716-446655440045'
    );
    raise exception 'cash session regression: movement was recorded after close';
  exception when check_violation then
    v_cash_closed_movement_rejected := true;
  end;
  if not v_cash_closed_movement_rejected then
    raise exception 'cash session regression: movement after close was not rejected';
  end if;

  -- After the session is closed, the now-empty branch can be deactivated safely.
  perform public.set_cloud_branch_active(
    '20000000-0000-0000-0000-000000000001',
    v_created_branch,
    false
  );
  perform public.set_cloud_branch_active(
    '20000000-0000-0000-0000-000000000001',
    v_created_branch,
    true
  );

  -- Cash session creation is a separate capability from viewing customer accounts.
  perform set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000003', true);
  begin
    perform public.open_cloud_cash_session(
      '20000000-0000-0000-0000-000000000001',
      v_created_branch,
      'unauthorized-register',
      0,
      null,
      '550e8400-e29b-41d4-a716-446655440046'
    );
    raise exception 'cash session permission regression: account viewer opened a cash session';
  exception when insufficient_privilege then
    v_unauthorized_cash_open_rejected := true;
  end;
  if not v_unauthorized_cash_open_rejected then
    raise exception 'cash session permission regression: unauthorized open was not rejected';
  end if;
  perform set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', true);

  if has_table_privilege(current_user, 'public.cloud_cash_sessions', 'INSERT')
     or has_table_privilege(current_user, 'public.cloud_cash_sessions', 'UPDATE')
     or has_table_privilege(current_user, 'public.cloud_cash_movements', 'INSERT')
     or has_table_privilege(current_user, 'public.cloud_cash_movements', 'DELETE') then
    raise exception 'security regression: authenticated can directly mutate cloud cashbook records';
  end if;

  -- Customer records are tenant-isolated even when another business has its own customer.
  perform set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000002', true);
  v_customer_b_id := public.create_cloud_customer(
    '20000000-0000-0000-0000-000000000002',
    'عميل النشاط الثاني', null, null, 0,
    '550e8400-e29b-41d4-a716-446655440038'
  );
  perform set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000003', true);
  select count(*) into v_count
  from public.cloud_customers
  where business_id = '20000000-0000-0000-0000-000000000001';
  if v_count <> 2 then
    raise exception 'customer tenant isolation failed: member sees % own-business customers, expected 2', v_count;
  end if;
  select count(*) into v_count
  from public.cloud_customers
  where business_id = '20000000-0000-0000-0000-000000000002';
  if v_count <> 0 then
    raise exception 'customer tenant isolation failed: member sees % customers from another business', v_count;
  end if;
  if has_table_privilege(current_user, 'public.cloud_customer_account_entries', 'INSERT')
     or has_table_privilege(current_user, 'public.cloud_supplier_account_entries', 'UPDATE')
     or has_table_privilege(current_user, 'public.cloud_customer_payments', 'DELETE') then
    raise exception 'security regression: authenticated can directly mutate account ledgers or payments';
  end if;

  perform set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', true);
  select id into v_owner_member_id
  from public.business_members
  where business_id = '20000000-0000-0000-0000-000000000001'
    and user_id = '10000000-0000-0000-0000-000000000001'
    and is_owner = true;

  insert into public.member_login_names (business_id, member_id, username)
  values (
    '20000000-0000-0000-0000-000000000001',
    v_owner_member_id,
    'owner-regression-test'
  );
  if not exists (
    select 1 from public.member_login_names
    where business_id = '20000000-0000-0000-0000-000000000001'
      and member_id = v_owner_member_id
      and username = 'owner-regression-test'
  ) then
    raise exception 'owner username onboarding failed';
  end if;

  perform set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000003', true);
  begin
    insert into public.member_login_names (business_id, member_id, username)
    values (
      '20000000-0000-0000-0000-000000000001',
      v_owner_member_id,
      'owner-spoof-regression'
    );
    raise exception 'username onboarding security regression: non-owner assigned the owner login';
  exception when insufficient_privilege then
    v_owner_login_insert_rejected := true;
  end;
  if not v_owner_login_insert_rejected then
    raise exception 'username onboarding security regression: non-owner insert was not rejected';
  end if;
  -- User managers may inspect all permission assignments; ordinary members see only their own.
  perform set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000006', true);
  select count(*) into v_permission_visibility_count
  from public.member_permissions
  where business_id = '20000000-0000-0000-0000-000000000001';
  if v_permission_visibility_count < 6 then
    raise exception 'user manager cannot inspect member permissions: saw % rows', v_permission_visibility_count;
  end if;

  perform set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000003', true);
  select count(*) into v_permission_visibility_count
  from public.member_permissions
  where business_id = '20000000-0000-0000-0000-000000000001';
  if v_permission_visibility_count <> 3 then
    raise exception 'least-privilege member sees % permission rows, expected only its own 3', v_permission_visibility_count;
  end if;

  -- Delegated managers cannot deactivate users without the dedicated capability.
  perform set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000006', true);
  begin
    perform public.set_business_member_active(
      '20000000-0000-0000-0000-000000000001',
      '21000000-0000-0000-0000-000000000004',
      false
    );
    raise exception 'member management regression: delegated manager deactivated a user without users.deactivate';
  exception when insufficient_privilege then
    v_member_deactivation_rejected := true;
  end;
  if not v_member_deactivation_rejected then
    raise exception 'member management regression: unauthorized deactivation was not rejected';
  end if;

  -- Owner can reactivate then deactivate an ordinary account, with an audit event.
  perform set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', true);
  perform public.set_business_member_active(
    '20000000-0000-0000-0000-000000000001',
    '21000000-0000-0000-0000-000000000004',
    true
  );
  select is_active into v_member_active
  from public.business_members where id = '21000000-0000-0000-0000-000000000004';
  if not v_member_active then
    raise exception 'member management regression: owner activation failed';
  end if;
  perform public.set_business_member_active(
    '20000000-0000-0000-0000-000000000001',
    '21000000-0000-0000-0000-000000000004',
    false
  );
  select is_active into v_member_active
  from public.business_members where id = '21000000-0000-0000-0000-000000000004';
  if v_member_active then
    raise exception 'member management regression: owner deactivation failed';
  end if;
  if not exists (
    select 1 from public.audit_events
    where business_id = '20000000-0000-0000-0000-000000000001'
      and action_key = 'users.deactivate'
      and entity_id = '21000000-0000-0000-0000-000000000004'
  ) then
    raise exception 'member management regression: deactivation audit event missing';
  end if;

  begin
    perform public.replace_member_permissions(
      '20000000-0000-0000-0000-000000000001',
      v_owner_member_id,
      array['products.view']
    );
    raise exception 'owner protection regression: owner permissions were changed';
  exception when insufficient_privilege then
    v_owner_change_rejected := true;
  end;

  if not v_owner_change_rejected then
    raise exception 'owner protection regression: owner permission change was not rejected';
  end if;

  -- A user with no membership in either business receives no tenant data.
  perform set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000005', true);
  select count(*) into v_count from public.cloud_products;
  if v_count <> 0 then
    raise exception 'tenant isolation failed: non-member can see % products', v_count;
  end if;
end;
$$;

rollback;
