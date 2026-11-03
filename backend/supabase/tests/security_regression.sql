-- Security regression tests for tenant isolation and privileged operations.
-- Run after all migrations against a disposable PostgreSQL database.
begin;

insert into auth.users (id) values
  ('10000000-0000-0000-0000-000000000001'),
  ('10000000-0000-0000-0000-000000000002'),
  ('10000000-0000-0000-0000-000000000003')
on conflict (id) do nothing;

insert into public.businesses (id, name, owner_user_id) values
  ('20000000-0000-0000-0000-000000000001', 'Security Test Business A', '10000000-0000-0000-0000-000000000001'),
  ('20000000-0000-0000-0000-000000000002', 'Security Test Business B', '10000000-0000-0000-0000-000000000002')
on conflict (id) do nothing;

insert into public.cloud_products (
  id, business_id, name, sku, cost_minor, price_minor, stock_quantity, created_by
) values
  ('30000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000001',
   'Test product A', 'SEC-A', 50, 100, 10, '10000000-0000-0000-0000-000000000001'),
  ('30000000-0000-0000-0000-000000000002',
   '20000000-0000-0000-0000-000000000002',
   'Test product B', 'SEC-B', 70, 140, 20, '10000000-0000-0000-0000-000000000002')
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
grant select on public.businesses, public.cloud_products, public.cloud_inventory_movements,
  public.cloud_sales, public.cloud_sale_items, public.cloud_expenses to authenticated;

set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', true);

do $$
declare
  v_count integer;
  v_sale_one uuid;
  v_sale_two uuid;
  v_stock bigint;
  v_other_business_sale_rejected boolean := false;
begin
  select count(*) into v_count from public.cloud_products;
  if v_count <> 1 then
    raise exception 'tenant isolation failed: owner A can see % products, expected 1', v_count;
  end if;

  select count(*) into v_count from public.cloud_expenses;
  if v_count <> 1 then
    raise exception 'tenant isolation failed: owner A can see % expenses, expected 1', v_count;
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

  v_sale_one := public.create_cloud_sale(
    '20000000-0000-0000-0000-000000000001',
    jsonb_build_array(jsonb_build_object(
      'product_id', '30000000-0000-0000-0000-000000000001',
      'quantity', 2
    )),
    100,
    '50000000-0000-0000-0000-000000000001'
  );

  v_sale_two := public.create_cloud_sale(
    '20000000-0000-0000-0000-000000000001',
    jsonb_build_array(jsonb_build_object(
      'product_id', '30000000-0000-0000-0000-000000000001',
      'quantity', 2
    )),
    100,
    '50000000-0000-0000-0000-000000000001'
  );

  if v_sale_one is distinct from v_sale_two then
    raise exception 'idempotency failed: retry returned a different sale id';
  end if;

  select stock_quantity into v_stock
  from public.cloud_products
  where id = '30000000-0000-0000-0000-000000000001';

  if v_stock <> 8 then
    raise exception 'idempotency failed: expected stock 8 after one sale and retry, got %', v_stock;
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
    v_other_business_sale_rejected := true;
  end;

  if not v_other_business_sale_rejected then
    raise exception 'tenant isolation failed: owner A adjusted inventory in business B';
  end if;

  perform set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000003', true);
  select count(*) into v_count from public.cloud_products;
  if v_count <> 0 then
    raise exception 'tenant isolation failed: non-member can see % products', v_count;
  end if;
end;
$$;

rollback;
