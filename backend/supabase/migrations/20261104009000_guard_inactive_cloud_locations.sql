-- Serialize stock writes against branch/warehouse deactivation.
-- The row locks make a concurrent stock write either finish before deactivation
-- (so the deactivation sees the stock and fails) or observe the inactive location.
create or replace function public.guard_cloud_product_warehouse_stock_location()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_branch_active boolean;
  v_warehouse_active boolean;
begin
  select b.is_active
  into v_branch_active
  from public.cloud_branches b
  where b.id = new.branch_id
    and b.business_id = new.business_id
  for share;

  if not found or v_branch_active is distinct from true then
    raise exception 'branch is inactive or unavailable' using errcode = '23514';
  end if;

  select w.is_active
  into v_warehouse_active
  from public.cloud_warehouses w
  where w.id = new.warehouse_id
    and w.business_id = new.business_id
    and w.branch_id = new.branch_id
  for share;

  if not found or v_warehouse_active is distinct from true then
    raise exception 'warehouse is inactive or unavailable' using errcode = '23514';
  end if;

  return new;
end;
$function$;

drop trigger if exists cloud_stock_active_location_guard
  on public.cloud_product_warehouse_stock;
create trigger cloud_stock_active_location_guard
  before insert or update of branch_id, warehouse_id, quantity_scaled
  on public.cloud_product_warehouse_stock
  for each row
  execute function public.guard_cloud_product_warehouse_stock_location();

revoke all on function public.guard_cloud_product_warehouse_stock_location()
  from public, anon, authenticated;
