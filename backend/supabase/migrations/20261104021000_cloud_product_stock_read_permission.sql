-- Product viewers need to read the selected warehouse balance alongside the
-- catalogue. Keep the same tenant boundary and grant no write capability.
drop policy if exists cloud_stock_select_authorized
  on public.cloud_product_warehouse_stock;

create policy cloud_stock_select_authorized
  on public.cloud_product_warehouse_stock
  for select to authenticated
  using (
    public.has_business_permission(business_id, 'inventory.view')
    or public.has_business_permission(business_id, 'sales.create')
    or public.has_business_permission(business_id, 'products.view')
    or public.has_business_permission(business_id, 'reports.view')
  );
