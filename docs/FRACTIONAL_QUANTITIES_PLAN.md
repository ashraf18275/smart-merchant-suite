# Fractional Quantities — Implementation Contract

Status: design checkpoint only. Fractional quantity entry is **not enabled** until the schema, repositories, application ports, UI, backup/restore, and tests are migrated together.

## Why this is a cross-cutting change

The current application stores whole-number quantities as SQLite integers and exposes them as Dart `int` values. This affects product balances, warehouse balances, stock movements, transfers, sale-item quantities, sale validation, invoice totals, and CSV/backup workflows. The existing `product_units.allows_fraction` flag is not sufficient by itself: enabling it before these paths are migrated would either reject decimal input or silently lose precision.

## Canonical representation

- Use a fixed scale of 1,000 (three decimal places).
- Persist quantity values as integer thousandths in SQLite. Examples: 1.000 = 1000, 1.500 = 1500, 0.750 = 750.
- Keep monetary values in minor currency units (piastres) as integers.
- Parse quantity text using decimal-string arithmetic, not binary floating-point conversion.
- Format quantities using the product unit abbreviation and trim insignificant trailing zeros.
- Reject more than three fractional digits; do not silently round user-entered quantities.
- For units with `allows_fraction = 0`, accept whole quantities only. For units with `allows_fraction = 1`, accept up to three decimal places.
- A quantity delta may be negative for stock movements; balances and sale quantities must remain non-negative / positive as appropriate.

## Schema migration

Bump the local database schema from version 6 to version 7 on both Android and desktop. In a single transaction, multiply existing whole-number quantities by 1,000 in:
- `products.stock_quantity`
- `product_warehouse_stock.quantity`
- `inventory_movements.quantity_delta`
- `sale_items.quantity`

Do not change monetary columns. Preserve all IDs, timestamps, foreign keys, and historical invoice totals. Add schema migration record 7 only after all conversions succeed. Migration must be idempotent through the normal SQLite version mechanism and covered by a version-6 fixture test containing positive, negative movement, and historical sale quantities.

## Invoice arithmetic

For a line item, calculate the amount in minor currency units from integer operands and the scale, with one documented rounding rule (nearest piastre, half-up). Never use `double` for monetary calculations. Test edge cases around half-piastre rounding, zero-priced items, large quantities, and multiple invoice lines. Keep historical `line_total_minor`, `total_minor`, and `paid_minor` unchanged during migration.

## Application layers that must move together

- Domain product and warehouse-stock quantity representation.
- Product and branch/warehouse ports and application services.
- Product, warehouse, and sales repositories.
- Sales service quantity map and stock validation.
- Product creation/edit forms, stock adjustment, warehouse transfer, and sales forms.
- Quantity display in product lists, warehouse stock, and invoices.
- Unit management UI so `allows_fraction` can actually be configured.
- CSV exports and backup creation/restore.

Use one shared quantity parser/formatter/conversion utility so the screens cannot drift in decimal precision or validation rules.

## Backup and restore compatibility

- Export schema version 7 quantities in scaled integer form.
- Continue accepting backup schema versions 3, 4, 5, and 6.
- Treat versions 3–6 as whole-unit quantities and multiply their quantity fields by 1,000 during restore.
- Add a dedicated legacy-v6 table specification; never read a v6 backup using the v7 table contract.
- Keep the existing historical-sale warehouse behavior: do not infer a warehouse for old invoices.
- Verify backup integrity, foreign keys, row counts, and converted quantities before asking the user to confirm replacement.

## Required acceptance tests

1. Upgrade a v6 database and verify every existing quantity is multiplied exactly once.
2. Preserve historical invoice money totals and all row identifiers.
3. Parse and format values such as 1, 1.5, 0.75, and 0.001 without precision loss.
4. Reject malformed values, excess decimal places, negative balances, and fractional quantities for whole-only units.
5. Add stock, adjust stock, transfer stock, and sell fractional quantities while maintaining warehouse isolation and movement audit records.
6. Calculate invoice line totals with deterministic piastre rounding.
7. Restore v3/v4/v5/v6 backups and verify whole-unit quantities become scaled values.
8. Create and restore a v7 backup without rescaling its quantities.
9. Run Flutter analyze, the complete test suite, Android debug APK build, and Windows release build.

## Safety boundary

Implement and validate on `feature/multi-user-cloud` only. Do not merge to `main`, publish a release, or modify any real user database.