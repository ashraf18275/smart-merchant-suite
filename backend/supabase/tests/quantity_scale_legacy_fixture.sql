-- Seed pre-thousandths cloud data after migrations through 20261104005000.
-- This file runs only in a disposable legacy migration test database.
insert into auth.users (id)
values ('90000000-0000-0000-0000-000000000001')
on conflict (id) do nothing;

insert into public.businesses (id, name, owner_user_id)
values (
  '91000000-0000-0000-0000-000000000001',
  'Legacy quantity migration fixture',
  '90000000-0000-0000-0000-000000000001'
);

insert into public.cloud_products (
  id, business_id, name, sku, cost_minor, price_minor,
  stock_quantity, created_by
) values (
  '92000000-0000-0000-0000-000000000001',
  '91000000-0000-0000-0000-000000000001',
  'Legacy stock fixture', 'LEGACY-SCALE-01', 50, 100,
  8, '90000000-0000-0000-0000-000000000001'
);

insert into public.cloud_sales (
  id, business_id, branch_id, warehouse_id,
  total_minor, paid_minor, operation_id, created_by, request_hash
)
select
  '93000000-0000-0000-0000-000000000001',
  p.business_id, p.default_branch_id, p.default_warehouse_id,
  200, 200, '94000000-0000-0000-0000-000000000001',
  '90000000-0000-0000-0000-000000000001', repeat('a', 64)
from public.cloud_products p
where p.id = '92000000-0000-0000-0000-000000000001';

insert into public.cloud_sale_items (
  business_id, sale_id, product_id, quantity,
  unit_price_minor, unit_cost_minor, line_total_minor
) values (
  '91000000-0000-0000-0000-000000000001',
  '93000000-0000-0000-0000-000000000001',
  '92000000-0000-0000-0000-000000000001',
  2, 100, 50, 200
);

insert into public.cloud_inventory_movements (
  business_id, branch_id, warehouse_id, product_id,
  quantity_delta, reason, operation_id, actor_user_id, request_hash
)
select
  p.business_id, p.default_branch_id, p.default_warehouse_id, p.id,
  -2, 'legacy migration sale',
  '94000000-0000-0000-0000-000000000001',
  '90000000-0000-0000-0000-000000000001', repeat('b', 64)
from public.cloud_products p
where p.id = '92000000-0000-0000-0000-000000000001';
