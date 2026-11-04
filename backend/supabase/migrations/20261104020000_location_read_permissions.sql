-- Allow dedicated location-view permissions to read branch and warehouse selectors.
-- Keep operational permissions as backwards-compatible read access.
drop policy if exists cloud_branches_select_authorized on public.cloud_branches;
create policy cloud_branches_select_authorized on public.cloud_branches
  for select to authenticated using (
    public.has_business_permission(business_id, 'branches.view')
    or public.has_business_permission(business_id, 'warehouses.view')
    or public.has_business_permission(business_id, 'inventory.view')
    or public.has_business_permission(business_id, 'sales.create')
    or public.has_business_permission(business_id, 'products.view')
    or public.has_business_permission(business_id, 'purchases.view')
    or public.has_business_permission(business_id, 'purchases.create')
  );

drop policy if exists cloud_warehouses_select_authorized on public.cloud_warehouses;
create policy cloud_warehouses_select_authorized on public.cloud_warehouses
  for select to authenticated using (
    public.has_business_permission(business_id, 'warehouses.view')
    or public.has_business_permission(business_id, 'branches.view')
    or public.has_business_permission(business_id, 'inventory.view')
    or public.has_business_permission(business_id, 'sales.create')
    or public.has_business_permission(business_id, 'products.view')
    or public.has_business_permission(business_id, 'purchases.view')
    or public.has_business_permission(business_id, 'purchases.create')
  );
