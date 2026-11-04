-- Regression checks for the warehouse-stock SELECT policy.
-- The policy must permit product viewers while keeping writes unavailable.
do $$
declare
  v_policy text;
begin
  select pg_get_expr(polqual, polrelid)
    into v_policy
  from pg_policy
  where polname = 'cloud_stock_select_authorized'
    and polrelid = 'public.cloud_product_warehouse_stock'::regclass;

  if v_policy is null then
    raise exception 'cloud stock read policy is missing';
  end if;
  if position('products.view' in v_policy) = 0 then
    raise exception 'product viewers cannot read warehouse stock';
  end if;
  if position('business_id' in v_policy) = 0 then
    raise exception 'cloud stock policy lost tenant scoping';
  end if;
  if has_table_privilege('authenticated',
      'public.cloud_product_warehouse_stock', 'INSERT')
     or has_table_privilege('authenticated',
      'public.cloud_product_warehouse_stock', 'UPDATE')
     or has_table_privilege('authenticated',
      'public.cloud_product_warehouse_stock', 'DELETE') then
    raise exception 'authenticated users unexpectedly have cloud stock write privileges';
  end if;
end;
$$;
