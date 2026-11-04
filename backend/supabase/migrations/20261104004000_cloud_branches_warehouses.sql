-- Tenant-scoped branch and warehouse foundations.
-- Existing aggregate stock is assigned to one default warehouse per business.
create table if not exists public.cloud_branches (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  address text,
  phone text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (id, business_id),
  unique (business_id, name)
);

create table if not exists public.cloud_warehouses (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  branch_id uuid not null,
  name text not null check (length(trim(name)) > 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (id, business_id, branch_id),
  unique (business_id, branch_id, name),
  foreign key (branch_id, business_id)
    references public.cloud_branches(id, business_id) on delete restrict
);

insert into public.cloud_branches (business_id, name)
select b.id, 'الفرع الرئيسي'
from public.businesses b
where not exists (
  select 1 from public.cloud_branches x where x.business_id = b.id
);

insert into public.cloud_warehouses (business_id, branch_id, name)
select b.business_id, b.id, 'المخزن الرئيسي'
from public.cloud_branches b
where not exists (
  select 1 from public.cloud_warehouses w
  where w.business_id = b.business_id and w.branch_id = b.id
);

alter table public.cloud_products
  add column if not exists default_branch_id uuid,
  add column if not exists default_warehouse_id uuid;

update public.cloud_products p
set default_branch_id = b.id, default_warehouse_id = w.id
from public.cloud_branches b
join public.cloud_warehouses w
  on w.business_id = b.business_id and w.branch_id = b.id
where p.business_id = b.business_id
  and (p.default_branch_id is null or p.default_warehouse_id is null);

alter table public.cloud_inventory_movements
  add column if not exists branch_id uuid,
  add column if not exists warehouse_id uuid;

alter table public.cloud_sales
  add column if not exists branch_id uuid,
  add column if not exists warehouse_id uuid;

update public.cloud_inventory_movements m
set branch_id = p.default_branch_id, warehouse_id = p.default_warehouse_id
from public.cloud_products p
where m.product_id = p.id and m.business_id = p.business_id
  and (m.branch_id is null or m.warehouse_id is null);

update public.cloud_sales s
set branch_id = b.id, warehouse_id = w.id
from public.cloud_branches b
join public.cloud_warehouses w
  on w.business_id = b.business_id and w.branch_id = b.id
where s.business_id = b.business_id
  and (s.branch_id is null or s.warehouse_id is null);

alter table public.cloud_inventory_movements
  alter column branch_id set not null,
  alter column warehouse_id set not null;
alter table public.cloud_sales
  alter column branch_id set not null,
  alter column warehouse_id set not null;

alter table public.cloud_inventory_movements
  add constraint cloud_inventory_branch_fk
    foreign key (branch_id, business_id)
    references public.cloud_branches(id, business_id) on delete restrict,
  add constraint cloud_inventory_warehouse_fk
    foreign key (warehouse_id, business_id, branch_id)
    references public.cloud_warehouses(id, business_id, branch_id) on delete restrict;

alter table public.cloud_sales
  add constraint cloud_sales_branch_fk
    foreign key (branch_id, business_id)
    references public.cloud_branches(id, business_id) on delete restrict,
  add constraint cloud_sales_warehouse_fk
    foreign key (warehouse_id, business_id, branch_id)
    references public.cloud_warehouses(id, business_id, branch_id) on delete restrict;

create table if not exists public.cloud_product_warehouse_stock (
  business_id uuid not null,
  branch_id uuid not null,
  warehouse_id uuid not null,
  product_id uuid not null,
  quantity bigint not null default 0 check (quantity >= 0),
  updated_at timestamptz not null default now(),
  primary key (business_id, warehouse_id, product_id),
  foreign key (branch_id, business_id)
    references public.cloud_branches(id, business_id) on delete restrict,
  foreign key (warehouse_id, business_id, branch_id)
    references public.cloud_warehouses(id, business_id, branch_id) on delete restrict,
  foreign key (product_id, business_id)
    references public.cloud_products(id, business_id) on delete restrict
);

insert into public.cloud_product_warehouse_stock (
  business_id, branch_id, warehouse_id, product_id, quantity
)
select p.business_id, p.default_branch_id, p.default_warehouse_id, p.id, p.stock_quantity
from public.cloud_products p
on conflict (business_id, warehouse_id, product_id) do nothing;

create index if not exists cloud_branches_business_idx
  on public.cloud_branches(business_id, is_active);
create index if not exists cloud_warehouses_business_branch_idx
  on public.cloud_warehouses(business_id, branch_id, is_active);
create index if not exists cloud_stock_product_idx
  on public.cloud_product_warehouse_stock(business_id, product_id);

alter table public.cloud_branches enable row level security;
alter table public.cloud_warehouses enable row level security;
alter table public.cloud_product_warehouse_stock enable row level security;

create policy cloud_branches_select_authorized on public.cloud_branches
  for select to authenticated using (
    public.has_business_permission(business_id, 'inventory.view')
    or public.has_business_permission(business_id, 'sales.create')
    or public.has_business_permission(business_id, 'products.view')
  );

create policy cloud_warehouses_select_authorized on public.cloud_warehouses
  for select to authenticated using (
    public.has_business_permission(business_id, 'inventory.view')
    or public.has_business_permission(business_id, 'sales.create')
    or public.has_business_permission(business_id, 'products.view')
  );

create policy cloud_stock_select_authorized on public.cloud_product_warehouse_stock
  for select to authenticated using (
    public.has_business_permission(business_id, 'inventory.view')
    or public.has_business_permission(business_id, 'sales.create')
    or public.has_business_permission(business_id, 'reports.view')
  );

revoke insert, update, delete on public.cloud_branches,
  public.cloud_warehouses, public.cloud_product_warehouse_stock from anon, authenticated;
grant select on public.cloud_branches, public.cloud_warehouses,
  public.cloud_product_warehouse_stock to authenticated;
