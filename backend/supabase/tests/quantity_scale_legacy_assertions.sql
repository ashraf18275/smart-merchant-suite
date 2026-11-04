-- Assert that pre-migration whole-unit records were scaled exactly once and
-- that legacy whole-unit RPC retries still resolve to the original receipts.
select set_config(
  'request.jwt.claim.sub',
  '90000000-0000-0000-0000-000000000001',
  false
);

do $$
declare
  v_sale_id uuid;
  v_movement_id uuid;
  v_stock bigint;
  v_warehouse_stock bigint;
  v_sale_quantity bigint;
  v_movement_delta bigint;
  v_total bigint;
  v_paid bigint;
begin
  v_sale_id := public.create_cloud_sale(
    '91000000-0000-0000-0000-000000000001',
    jsonb_build_array(jsonb_build_object(
      'product_id', '92000000-0000-0000-0000-000000000001',
      'quantity', 2
    )),
    200,
    '94000000-0000-0000-0000-000000000001'
  );

  if v_sale_id <> '93000000-0000-0000-0000-000000000001' then
    raise exception 'legacy sale retry did not return the original sale id';
  end if;

  v_movement_id := public.adjust_cloud_inventory(
    '91000000-0000-0000-0000-000000000001',
    '92000000-0000-0000-0000-000000000001',
    -2,
    'legacy migration sale',
    '94000000-0000-0000-0000-000000000001'
  );

  select id into v_sale_id
  from public.cloud_inventory_movements
  where business_id = '91000000-0000-0000-0000-000000000001'
    and operation_id = '94000000-0000-0000-0000-000000000001'
    and product_id = '92000000-0000-0000-0000-000000000001';

  if v_movement_id is distinct from v_sale_id then
    raise exception 'legacy inventory retry did not return the original movement id';
  end if;

  select stock_quantity into v_stock
  from public.cloud_products
  where id = '92000000-0000-0000-0000-000000000001';

  select quantity_scaled into v_warehouse_stock
  from public.cloud_product_warehouse_stock
  where product_id = '92000000-0000-0000-0000-000000000001';

  select quantity_scaled into v_sale_quantity
  from public.cloud_sale_items
  where sale_id = '93000000-0000-0000-0000-000000000001';

  select quantity_delta into v_movement_delta
  from public.cloud_inventory_movements
  where id = v_movement_id;

  select total_minor, paid_minor into v_total, v_paid
  from public.cloud_sales
  where id = '93000000-0000-0000-0000-000000000001';

  if v_stock <> 8000 or v_warehouse_stock <> 8000
     or v_sale_quantity <> 2000 or v_movement_delta <> -2000 then
    raise exception 'legacy quantity conversion mismatch: aggregate %, warehouse %, sale %, movement %',
      v_stock, v_warehouse_stock, v_sale_quantity, v_movement_delta;
  end if;

  if v_total <> 200 or v_paid <> 200 then
    raise exception 'quantity migration changed monetary values: total %, paid %', v_total, v_paid;
  end if;
end;
$$;
