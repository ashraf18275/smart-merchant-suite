import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../core/app_error.dart';
import '../core/quantity.dart';

import '../data/backup_schema.dart';
import '../data/backup_snapshot.dart';
import '../data/backup_restore_writer.dart';
import '../data/csv_encoder.dart';

class _ExportTable {
  const _ExportTable(this.label, this.table, this.columns);
  final String label;
  final String table;
  final List<String> columns;
}

const _legacyV3Tables = <_ExportTable>[
  _ExportTable('المنتجات', 'products', [
    'id', 'name', 'sku', 'cost_minor', 'price_minor', 'stock_quantity',
    'is_active', 'created_at',
  ]),
  _ExportTable('الفواتير', 'sales', ['id', 'total_minor', 'paid_minor', 'created_at']),
  _ExportTable('بنود الفواتير', 'sale_items', [
    'id', 'sale_id', 'product_id', 'quantity', 'unit_price_minor',
    'unit_cost_minor', 'line_total_minor',
  ]),
  _ExportTable('المصروفات', 'expenses', ['id', 'description', 'category', 'amount_minor', 'created_at']),
  _ExportTable('حركات المخزون', 'inventory_movements', [
    'id', 'product_id', 'quantity_delta', 'reason', 'created_at',
  ]),
];

const _legacyV4Tables = <_ExportTable>[
  _ExportTable('التصنيفات', 'product_categories', ['id', 'name', 'is_active', 'created_at']),
  _ExportTable('وحدات القياس', 'product_units', [
    'id', 'name', 'abbreviation', 'allows_fraction', 'is_active', 'created_at',
  ]),
  _ExportTable('المنتجات', 'products', [
    'id', 'name', 'sku', 'cost_minor', 'price_minor', 'stock_quantity',
    'category_id', 'unit_id', 'is_active', 'created_at',
  ]),
  _ExportTable('الفواتير', 'sales', ['id', 'total_minor', 'paid_minor', 'created_at']),
  _ExportTable('بنود الفواتير', 'sale_items', [
    'id', 'sale_id', 'product_id', 'quantity', 'unit_price_minor',
    'unit_cost_minor', 'line_total_minor',
  ]),
  _ExportTable('المصروفات', 'expenses', ['id', 'description', 'category', 'amount_minor', 'created_at']),
  _ExportTable('حركات المخزون', 'inventory_movements', [
    'id', 'product_id', 'quantity_delta', 'reason', 'created_at',
  ]),
];

const _legacyV7Tables = <_ExportTable>[
  _ExportTable('الفروع', 'branches', ['id', 'name', 'address', 'phone', 'is_active', 'created_at']),
  _ExportTable('المخازن', 'warehouses', ['id', 'branch_id', 'name', 'is_active', 'created_at']),
  _ExportTable('التصنيفات', 'product_categories', ['id', 'name', 'is_active', 'created_at']),
  _ExportTable('وحدات القياس', 'product_units', [
    'id', 'name', 'abbreviation', 'allows_fraction', 'is_active', 'created_at',
  ]),
  _ExportTable('المنتجات', 'products', [
    'id', 'name', 'sku', 'cost_minor', 'price_minor', 'stock_quantity',
    'category_id', 'unit_id', 'is_active', 'created_at',
  ]),
  _ExportTable('أرصدة المخازن', 'product_warehouse_stock', [
    'id', 'product_id', 'warehouse_id', 'quantity', 'updated_at',
  ]),
  _ExportTable('الفواتير', 'sales', ['id', 'total_minor', 'paid_minor', 'warehouse_id', 'created_at']),
  _ExportTable('بنود الفواتير', 'sale_items', [
    'id', 'sale_id', 'product_id', 'quantity', 'unit_price_minor',
    'unit_cost_minor', 'line_total_minor',
  ]),
  _ExportTable('المصروفات', 'expenses', ['id', 'description', 'category', 'amount_minor', 'created_at']),
  _ExportTable('حركات المخزون', 'inventory_movements', [
    'id', 'product_id', 'warehouse_id', 'quantity_delta', 'reason', 'created_at',
  ]),
];

// Version 8 adds supplier and purchase documents to the version 7 layout.
const _legacyV8Tables = <_ExportTable>[
  ..._legacyV7Tables,
  _ExportTable('الموردون', 'suppliers', [
    'id', 'name', 'phone', 'address', 'is_active', 'created_at',
  ]),
  _ExportTable('فواتير المشتريات', 'purchases', [
    'id', 'supplier_id', 'warehouse_id', 'total_minor', 'paid_minor', 'created_at',
  ]),
  _ExportTable('بنود المشتريات', 'purchase_items', [
    'id', 'purchase_id', 'product_id', 'quantity', 'unit_cost_minor', 'line_total_minor',
  ]),
];

// Version 9 adds customer accounts and both append-only account ledgers.
const _legacyV9Tables = <_ExportTable>[
  _ExportTable('الفروع', 'branches', ['id', 'name', 'address', 'phone', 'is_active', 'created_at']),
  _ExportTable('المخازن', 'warehouses', ['id', 'branch_id', 'name', 'is_active', 'created_at']),
  _ExportTable('التصنيفات', 'product_categories', ['id', 'name', 'is_active', 'created_at']),
  _ExportTable('وحدات القياس', 'product_units', [
    'id', 'name', 'abbreviation', 'allows_fraction', 'is_active', 'created_at',
  ]),
  _ExportTable('المنتجات', 'products', [
    'id', 'name', 'sku', 'cost_minor', 'price_minor', 'stock_quantity',
    'category_id', 'unit_id', 'is_active', 'created_at',
  ]),
  _ExportTable('أرصدة المخازن', 'product_warehouse_stock', [
    'id', 'product_id', 'warehouse_id', 'quantity', 'updated_at',
  ]),
  _ExportTable('العملاء', 'customers', [
    'id', 'name', 'phone', 'address', 'is_active', 'created_at',
  ]),
  _ExportTable('الفواتير', 'sales', [
    'id', 'total_minor', 'paid_minor', 'warehouse_id', 'customer_id', 'created_at',
  ]),
  _ExportTable('بنود الفواتير', 'sale_items', [
    'id', 'sale_id', 'product_id', 'quantity', 'unit_price_minor',
    'unit_cost_minor', 'line_total_minor',
  ]),
  _ExportTable('المصروفات', 'expenses', ['id', 'description', 'category', 'amount_minor', 'created_at']),
  _ExportTable('حركات المخزون', 'inventory_movements', [
    'id', 'product_id', 'warehouse_id', 'quantity_delta', 'reason', 'created_at',
  ]),
  _ExportTable('الموردون', 'suppliers', [
    'id', 'name', 'phone', 'address', 'is_active', 'created_at',
  ]),
  _ExportTable('فواتير المشتريات', 'purchases', [
    'id', 'supplier_id', 'warehouse_id', 'total_minor', 'paid_minor', 'created_at',
  ]),
  _ExportTable('بنود المشتريات', 'purchase_items', [
    'id', 'purchase_id', 'product_id', 'quantity', 'unit_cost_minor', 'line_total_minor',
  ]),
  _ExportTable('حسابات الموردين', 'supplier_account_entries', [
    'id', 'supplier_id', 'amount_minor', 'entry_type', 'reference_id', 'note', 'created_at',
  ]),
  _ExportTable('حسابات العملاء', 'customer_account_entries', [
    'id', 'customer_id', 'amount_minor', 'entry_type', 'reference_id', 'note', 'created_at',
  ]),
];


// Version 10 adds supplier return documents and returned purchase quantities.
final _legacyV10Tables = <_ExportTable>[
  ..._legacyV9Tables.where((spec) => spec.table != 'purchase_items'),
  const _ExportTable('بنود المشتريات', 'purchase_items', [
    'id', 'purchase_id', 'product_id', 'quantity', 'returned_quantity',
    'unit_cost_minor', 'line_total_minor',
  ]),
  const _ExportTable('مرتجعات الموردين', 'supplier_returns', [
    'id', 'purchase_id', 'supplier_id', 'warehouse_id', 'total_minor',
    'reason', 'created_at',
  ]),
  const _ExportTable('بنود مرتجعات الموردين', 'supplier_return_items', [
    'id', 'supplier_return_id', 'purchase_item_id', 'product_id',
    'quantity', 'unit_cost_minor', 'line_total_minor',
  ]),
];

// Version 11 adds customer returns and returned sale quantities/value tracking.
final _legacyV11Tables = <_ExportTable>[
  ..._legacyV10Tables.where((spec) => spec.table != 'sale_items'),
  const _ExportTable('بنود الفواتير', 'sale_items', [
    'id', 'sale_id', 'product_id', 'quantity', 'returned_quantity',
    'returned_minor', 'returned_cost_minor', 'unit_price_minor', 'unit_cost_minor', 'line_total_minor',
  ]),
  const _ExportTable('مرتجعات العملاء', 'customer_returns', [
    'id', 'sale_id', 'customer_id', 'warehouse_id', 'total_minor',
    'refunded_minor', 'reason', 'created_at',
  ]),
  const _ExportTable('بنود مرتجعات العملاء', 'customer_return_items', [
    'id', 'customer_return_id', 'sale_item_id', 'product_id',
    'quantity', 'unit_price_minor', 'unit_cost_minor', 'line_total_minor', 'line_cost_minor',
  ]),
];

 
// Version 12 adds sale cancellation documents and cancellation status.
final _legacyV12Tables = <_ExportTable>[
  ..._legacyV11Tables.where((spec) => spec.table != 'sales'),
  const _ExportTable('فواتير البيع', 'sales', [
    'id', 'total_minor', 'paid_minor', 'warehouse_id', 'customer_id',
    'created_at', 'cancelled_at', 'cancellation_reason',
  ]),
  const _ExportTable('إلغاءات فواتير البيع', 'sales_cancellations', [
    'id', 'sale_id', 'customer_id', 'warehouse_id', 'total_minor',
    'paid_minor', 'refunded_minor', 'reason', 'created_at',
  ]),
];

// Version 13 adds the audit trail and cash journal.
final _legacyV13Tables = <_ExportTable>[
  ..._legacyV12Tables,
  const _ExportTable('سجل النشاط', 'audit_events', [
    'id', 'action', 'entity_type', 'entity_id', 'amount_minor',
    'details', 'actor_label', 'created_at',
  ]),
  const _ExportTable('حركة الصندوق', 'cash_transactions', [
    'id', 'direction', 'category', 'amount_minor', 'source_type',
    'source_id', 'note', 'created_at',
  ]),
];

// Version 14 adds unified settlement records (cash, card, transfer, wallet).
final _legacyV14Tables = <_ExportTable>[
  ..._legacyV13Tables,
  const _ExportTable('المدفوعات', 'payment_records', [
    'id', 'direction', 'payment_method', 'amount_minor',
    'source_type', 'source_id', 'note', 'created_at',
  ]),
];

// Version 15 adds cash sessions and associates new cash movements with a shift.
final _tables = <_ExportTable>[
  ..._legacyV13Tables.where((spec) => spec.table != 'cash_transactions'),
  const _ExportTable('ورديات الصندوق', 'cash_sessions', [
    'id', 'opened_at', 'opening_balance_minor', 'opening_note',
    'closed_at', 'expected_balance_minor', 'counted_balance_minor',
    'difference_minor', 'closing_note', 'status',
  ]),
  const _ExportTable('حركة الصندوق', 'cash_transactions', [
    'id', 'direction', 'category', 'amount_minor', 'source_type',
    'source_id', 'cash_session_id', 'note', 'created_at',
  ]),
  const _ExportTable('المدفوعات', 'payment_records', [
    'id', 'direction', 'payment_method', 'amount_minor',
    'source_type', 'source_id', 'note', 'created_at',
  ]),
];

const _legacyV5Tables = <_ExportTable>[
  _ExportTable('الفروع', 'branches', ['id', 'name', 'address', 'phone', 'is_active', 'created_at']),
  _ExportTable('المخازن', 'warehouses', ['id', 'branch_id', 'name', 'is_active', 'created_at']),
  _ExportTable('التصنيفات', 'product_categories', ['id', 'name', 'is_active', 'created_at']),
  _ExportTable('وحدات القياس', 'product_units', [
    'id', 'name', 'abbreviation', 'allows_fraction', 'is_active', 'created_at',
  ]),
  _ExportTable('المنتجات', 'products', [
    'id', 'name', 'sku', 'cost_minor', 'price_minor', 'stock_quantity',
    'category_id', 'unit_id', 'is_active', 'created_at',
  ]),
  _ExportTable('أرصدة المخازن', 'product_warehouse_stock', [
    'id', 'product_id', 'warehouse_id', 'quantity', 'updated_at',
  ]),
  _ExportTable('الفواتير', 'sales', ['id', 'total_minor', 'paid_minor', 'created_at']),
  _ExportTable('بنود الفواتير', 'sale_items', [
    'id', 'sale_id', 'product_id', 'quantity', 'unit_price_minor',
    'unit_cost_minor', 'line_total_minor',
  ]),
  _ExportTable('المصروفات', 'expenses', ['id', 'description', 'category', 'amount_minor', 'created_at']),
  _ExportTable('حركات المخزون', 'inventory_movements', [
    'id', 'product_id', 'warehouse_id', 'quantity_delta', 'reason', 'created_at',
  ]),
];

// Version 6 uses the same table layout as v7, but its quantities are whole units.
const _legacyV6Tables = _legacyV7Tables;

class DataTransferPage extends StatefulWidget {
  const DataTransferPage({super.key, required this.database});
  final Database database;

  @override
  State<DataTransferPage> createState() => _DataTransferPageState();
}

class _DataTransferPageState extends State<DataTransferPage> {
  int _selectedTable = 0;
  bool _working = false;

  String _timestamp() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  Object? _csvValue(String table, String column, Object? value) {
    const quantityFields = <String, Set<String>>{
      'products': {'stock_quantity'},
      'product_warehouse_stock': {'quantity'},
      'sale_items': {'quantity'},
      'supplier_return_items': {'quantity'},
      'customer_return_items': {'quantity'},
      'inventory_movements': {'quantity_delta'},
    };
    if (quantityFields[table]?.contains(column) == true && value is num) {
      return Quantity.format(value.toInt());
    }
    return value;
  }

  Future<void> _shareCsv() async {
    if (_working) return;
    setState(() => _working = true);
    try {
      final spec = _tables[_selectedTable];
      final rows = await widget.database.query(
        spec.table,
        columns: spec.columns,
        orderBy: 'id ASC',
      );
      final csvRows = <List<Object?>>[
        spec.columns,
        ...rows.map((row) => spec.columns.map((column) => _csvValue(spec.table, column, row[column])).toList()),
      ];
      final directory = await getTemporaryDirectory();
      final file = File(p.join(directory.path, '${spec.table}_${_timestamp()}.csv'));
      await file.writeAsString(encodeCsv(csvRows), flush: true);
      if (!mounted) return;
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'text/csv')],
        text: 'تصدير ${spec.label} من عدة التاجر الذكي',
      );
    } catch (error) {
      _showError(appErrorMessage(error, fallback: 'تعذر تصدير ملف CSV.', operation: 'data.export_csv'));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }


  Future<void> _restoreBackup() async {
    if (_working) return;
    setState(() => _working = true);
    Database? source;
    File? restoreCandidate;
    try {
      final selection = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['db', 'sqlite'],
        withData: true,
        allowMultiple: false,
      );
      if (selection == null || selection.files.isEmpty) return;
      final bytes = selection.files.single.bytes;
      if (bytes == null || bytes.isEmpty) {
        throw AppException('تعذر قراءة الملف المختار.');
      }

      final directory = await getTemporaryDirectory();
      final candidate = File(p.join(directory.path, 'restore_candidate_' + _timestamp() + '.db'));
      restoreCandidate = candidate;
      await candidate.writeAsBytes(bytes, flush: true);
      final isMobile = !kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS);
      final opened = isMobile
          ? await sqflite.openDatabase(candidate.path, readOnly: true)
          : await databaseFactoryFfi.openDatabase(
              candidate.path,
              options: OpenDatabaseOptions(readOnly: true),
            );
      source = opened;

      final integrity = await opened.rawQuery('PRAGMA integrity_check');
      if (integrity.isEmpty || integrity.first.values.first != 'ok') {
        throw AppException('الملف لا يجتاز فحص سلامة SQLite.');
      }
      final versionRows = await opened.rawQuery('PRAGMA user_version');
      final schemaVersion = versionRows.isEmpty
          ? 0
          : (versionRows.first['user_version'] as num?)?.toInt() ?? 0;
      if (!BackupSchema.supports(schemaVersion)) {
        throw AppException(
          'إصدار قاعدة البيانات غير مدعوم (الإصدار المكتشف: $schemaVersion، المدعوم: 3 إلى 17).',
        );
      }

      final data = <String, List<Map<String, Object?>>>{};
      final restoreTables = schemaVersion >= 15
          ? _tables
          : schemaVersion >= 14
              ? _legacyV14Tables
              : schemaVersion >= 13
                  ? _legacyV13Tables
              : schemaVersion == 12
              ? _legacyV12Tables
              : schemaVersion == 11
              ? _legacyV11Tables
              : schemaVersion == 10
              ? _legacyV10Tables
              : schemaVersion == 9
                  ? _legacyV9Tables
                  : schemaVersion == 8
              ? _legacyV8Tables
              : schemaVersion == 7
                  ? _legacyV7Tables
                  : schemaVersion == 6
                      ? _legacyV6Tables
                      : schemaVersion == 5
                          ? _legacyV5Tables
                          : schemaVersion == 4
                              ? _legacyV4Tables
                              : _legacyV3Tables;
      for (final spec in restoreTables) {
        final tableInfo = await opened.rawQuery('PRAGMA table_info(' + spec.table + ')');
        final available = tableInfo.map((column) => column['name'] as String).toSet();
        if (!spec.columns.every(available.contains)) {
          throw AppException('النسخة لا تحتوي على بنية جدول ' + spec.label + ' المتوقعة.');
        }
        data[spec.table] = await opened.query(spec.table, orderBy: 'id ASC');
      }
      if (schemaVersion < 6) {
        data['sales'] = data['sales']!.map((row) => {...row, 'warehouse_id': null}).toList(growable: false);
      }
      if (schemaVersion < 5) {
        // Legacy v3/v4 backups have no branch or warehouse identifiers.
        // Reuse a valid destination pair by ID, without assuming the owner has
        // kept the default branch/warehouse names unchanged.
        final branchRows = await widget.database.rawQuery(
          'SELECT b.id, b.created_at, w.id AS warehouse_id, '
          'w.created_at AS warehouse_created_at '
          'FROM branches b JOIN warehouses w ON w.branch_id = b.id '
          'ORDER BY b.id ASC, w.id ASC LIMIT 1',
        );
        // The current schema guarantees at least one unit. Its display name
        // may have been customized, so resolve a stable existing ID instead.
        final defaultUnitRows = await widget.database.query(
          'product_units',
          columns: ['id'],
          orderBy: 'id ASC',
          limit: 1,
        );
        if (branchRows.isEmpty || defaultUnitRows.isEmpty) {
          throw AppException('تعذر تجهيز الفرع والمخزن الافتراضيين لاستعادة النسخة القديمة.');
        }
        final base = branchRows.single;
        final stamp = DateTime.now().toUtc().toIso8601String();
        final defaultUnitId = defaultUnitRows.single['id'];
        data['branches'] = [{
          'id': base['id'], 'name': 'الفرع الرئيسي', 'address': null,
          'phone': null, 'is_active': 1, 'created_at': base['created_at'] ?? stamp,
        }];
        data['warehouses'] = [{
          'id': base['warehouse_id'], 'branch_id': base['id'],
          'name': 'المخزن الرئيسي', 'is_active': 1,
          'created_at': base['warehouse_created_at'] ?? stamp,
        }];
        if (schemaVersion == 3) {
          data['product_categories'] = [];
          data['product_units'] = [{
            'id': defaultUnitId, 'name': 'قطعة', 'abbreviation': 'قطعة',
            'allows_fraction': 0, 'is_active': 1, 'created_at': stamp,
          }];
          data['products'] = data['products']!.map((row) => {
            ...row, 'category_id': null, 'unit_id': defaultUnitId,
          }).toList(growable: false);
        }
        final warehouseId = base['warehouse_id'];
        data['product_warehouse_stock'] = data['products']!.map((row) => {
          'product_id': row['id'], 'warehouse_id': warehouseId,
          'quantity': row['stock_quantity'], 'updated_at': row['created_at'] ?? stamp,
        }).toList(growable: false);
        data['inventory_movements'] = data['inventory_movements']!.map((row) => {
          ...row, 'warehouse_id': warehouseId,
        }).toList(growable: false);
      }
      if (schemaVersion < 13) {
        data['audit_events'] = [];
        data['cash_transactions'] = [];
      }
      if (schemaVersion < 14) {
        data['payment_records'] = [];
      }
      if (schemaVersion < 15) {
        data['cash_sessions'] = [];
        data['cash_transactions'] = data['cash_transactions']!.map((row) => {
          ...row, 'cash_session_id': null,
        }).toList(growable: false);
      }
      if (schemaVersion < 12) {
        data['sales'] = data['sales']!.map((row) => {
          ...row, 'cancelled_at': null, 'cancellation_reason': null,
        }).toList(growable: false);
        data['sales_cancellations'] = [];
      }
      if (schemaVersion < 11) {
        data['sale_items'] = data['sale_items']!.map((row) => {
          ...row, 'returned_quantity': 0, 'returned_minor': 0, 'returned_cost_minor': 0,
        }).toList(growable: false);
      }
      if (!BackupSchema.hasPurchaseData(schemaVersion)) {
        data['suppliers'] = [];
        data['purchases'] = [];
        data['purchase_items'] = [];
      }
      if (!BackupSchema.hasSupplierReturnData(schemaVersion)) {
        data['supplier_returns'] = [];
        data['supplier_return_items'] = [];
        data['purchase_items'] = data['purchase_items']!.map((row) => {
          ...row, 'returned_quantity': 0,
        }).toList(growable: false);
      }
      if (!BackupSchema.hasCustomerReturnData(schemaVersion)) {
        data['customer_returns'] = [];
        data['customer_return_items'] = [];
      }
      if (!BackupSchema.hasAccountData(schemaVersion)) {
        data['customers'] = [];
        data['supplier_account_entries'] = [];
        data['customer_account_entries'] = [];
      }
      if (schemaVersion < 7) {
        const quantityColumns = <String, List<String>>{
          'products': ['stock_quantity'],
          'product_warehouse_stock': ['quantity'],
          'sale_items': ['quantity'],
          'inventory_movements': ['quantity_delta'],
        };
        for (final entry in quantityColumns.entries) {
          data[entry.key] = data[entry.key]!.map((row) {
            final converted = Map<String, Object?>.from(row);
            for (final column in entry.value) {
              final value = (converted[column] as num?)?.toInt() ?? 0;
              if (value > 9223372036854775 || value < -9223372036854775) {
                throw AppException('توجد كمية أكبر من الحد الآمن للتحويل في جدول ${entry.key}.');
              }
              converted[column] = value * 1000;
            }
            return converted;
          }).toList(growable: false);
        }
      }
      final foreignKeyErrors = await opened.rawQuery('PRAGMA foreign_key_check');
      if (foreignKeyErrors.isNotEmpty) {
        throw AppException('النسخة تحتوي على روابط غير سليمة بين السجلات.');
      }
      await opened.close();
      source = null;

      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('تأكيد استعادة البيانات'),
          content: Text(
            'سيتم استبدال بيانات التطبيق الحالية بالبيانات الموجودة في النسخة المختارة. '
            'عدد المنتجات: ' + data['products']!.length.toString() + '، '
            'الفواتير: ' + data['sales']!.length.toString() + '، '
            'المصروفات: ' + data['expenses']!.length.toString() + '. '
            'أنشئ نسخة احتياطية من البيانات الحالية قبل المتابعة.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('استبدال البيانات'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;

      await widget.database.transaction(
        (txn) => replaceBackupBusinessData(txn, data),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تمت استعادة البيانات بنجاح.')),
      );
    } catch (error) {
      _showError(appErrorMessage(error, fallback: 'تعذرت استعادة النسخة الاحتياطية.', operation: 'data.restore'));
    } finally {
      try {
        if (source != null) {
          await source.close();
          source = null;
        }
      } finally {
        try {
          if (restoreCandidate != null && await restoreCandidate.exists()) {
            await restoreCandidate.delete();
          }
        } finally {
          if (mounted) setState(() => _working = false);
        }
      }
    }
  }

  Future<void> _createBackup() async {
    if (_working) return;
    setState(() => _working = true);
    File? backup;
    Database? verificationDb;
    try {
      final integrity = await widget.database.rawQuery('PRAGMA integrity_check');
      if (integrity.isEmpty || integrity.first.values.first != 'ok') {
        throw AppException('فشل فحص سلامة قاعدة البيانات؛ لم يتم إنشاء النسخة.');
      }

      final versionRows = await widget.database.rawQuery('PRAGMA user_version');
      final schemaVersion = versionRows.isEmpty
          ? 0
          : (versionRows.first['user_version'] as num?)?.toInt() ?? 0;
      if (schemaVersion != BackupSchema.currentVersion) {
        throw AppException('إصدار قاعدة البيانات الحالية غير متوقع: $schemaVersion.');
      }
      final exportedTableNames = _tables.map((spec) => spec.table).toSet();
      if (!exportedTableNames.containsAll(BackupSchema.currentTableNames)) {
        throw AppException('تعريف النسخة الاحتياطية لا يشمل كل جداول بيانات النشاط.');
      }

      final sourceFile = File(widget.database.path);
      if (!await sourceFile.exists()) {
        throw AppException('لم يتم العثور على ملف قاعدة البيانات.');
      }
      final directory = await getTemporaryDirectory();
      backup = File(p.join(
        directory.path,
        'smart_merchant_backup_${DateTime.now().microsecondsSinceEpoch}.db',
      ));
      if (await backup.exists()) {
        throw AppException('يوجد ملف بنفس اسم النسخة الاحتياطية؛ أعد المحاولة.');
      }
      // VACUUM INTO creates a consistent SQLite snapshot, including committed
      // WAL data, instead of copying the live database file after a checkpoint.
      await createSqliteBackupSnapshot(widget.database, backup.path);

      // Validate the actual copied file, not just the live database.
      final isMobile = !kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS);
      final opened = isMobile
          ? await sqflite.openDatabase(backup.path, readOnly: true)
          : await databaseFactoryFfi.openDatabase(
              backup.path,
              options: OpenDatabaseOptions(readOnly: true),
            );
      verificationDb = opened;
      final backupIntegrity = await opened.rawQuery('PRAGMA integrity_check');
      if (backupIntegrity.isEmpty || backupIntegrity.first.values.first != 'ok') {
        throw AppException('فشل فحص سلامة ملف النسخة الاحتياطية بعد إنشائه.');
      }
      final backupVersionRows = await opened.rawQuery('PRAGMA user_version');
      final backupVersion = backupVersionRows.isEmpty
          ? 0
          : (backupVersionRows.first['user_version'] as num?)?.toInt() ?? 0;
      if (backupVersion != BackupSchema.currentVersion) {
        throw AppException('ملف النسخة الاحتياطية لا يحتوي على إصدار المخطط المطلوب.');
      }
      // Validate the snapshot's complete schema. Do not compare its rows with
      // the live database here: writes may legitimately commit after VACUUM
      // INTO has captured its consistent point-in-time snapshot.
      for (final spec in _tables) {
        final tableInfo = await opened.rawQuery(
          'PRAGMA table_info(${spec.table})',
        );
        final availableColumns = tableInfo
            .map((column) => column['name'] as String)
            .toSet();
        if (tableInfo.isEmpty || !spec.columns.every(availableColumns.contains)) {
          throw AppException('ملف النسخة الاحتياطية لا يحتوي على بنية جدول ${spec.label} المتوقعة.');
        }
      }
      final migrationInfo = await opened.rawQuery(
        'PRAGMA table_info(schema_migrations)',
      );
      final migrationColumns = migrationInfo
          .map((column) => column['name'] as String)
          .toSet();
      if (!migrationColumns.containsAll({'version', 'applied_at'})) {
        throw AppException('ملف النسخة الاحتياطية لا يحتوي على سجل إصدارات المخطط المتوقع.');
      }

      final foreignKeyErrors = await opened.rawQuery('PRAGMA foreign_key_check');
      if (foreignKeyErrors.isNotEmpty) {
        throw AppException('ملف النسخة الاحتياطية يحتوي على روابط غير سليمة.');
      }
      await opened.close();
      verificationDb = null;

      if (!mounted) return;
      await Share.shareXFiles(
        [XFile(backup.path, mimeType: 'application/octet-stream')],
        text: 'نسخة احتياطية من عدة التاجر الذكي. احتفظ بها في مكان آمن.',
      );
    } catch (error) {
      // Close the validation handle before deleting the temporary database file.
      if (verificationDb != null) {
        try {
          await verificationDb.close();
        } catch (_) {
          // Preserve the original backup error and continue best-effort cleanup.
        } finally {
          verificationDb = null;
        }
      }
      if (backup != null && await backup.exists()) {
        await backup.delete();
      }
      _showError(appErrorMessage(error, fallback: 'تعذر إنشاء نسخة احتياطية موثوقة.', operation: 'data.backup'));
    } finally {
      try {
        if (verificationDb != null) await verificationDb.close();
      } finally {
        if (mounted) setState(() => _working = false);
      }
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('تصدير البيانات والنسخ الاحتياطي')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.table_view_outlined, size: 32),
                const SizedBox(height: 8),
                Text('تصدير CSV', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                const Text('اختر جدولًا لتصديره كملف CSV بترميز UTF-8 مناسب لعرض العربية في برامج الجداول. المبالغ محفوظة بوحدات العملة الصغرى.'),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: _selectedTable,
                  decoration: const InputDecoration(labelText: 'البيانات المطلوب تصديرها'),
                  items: [
                    for (var i = 0; i < _tables.length; i++)
                      DropdownMenuItem(value: i, child: Text(_tables[i].label)),
                  ],
                  onChanged: _working ? null : (value) {
                    if (value != null) setState(() => _selectedTable = value);
                  },
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _working ? null : _shareCsv,
                    icon: const Icon(Icons.ios_share),
                    label: const Text('تصدير ومشاركة الملف'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.backup_outlined, size: 32),
                const SizedBox(height: 8),
                Text('نسخة احتياطية كاملة', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                const Text('ينشئ ملف قاعدة بيانات SQLite بعد فحص سلامتها، ثم يفتح قائمة المشاركة لحفظه في مكان آمن. لا ترسل النسخة إلى أشخاص غير موثوقين لأنها تحتوي على بيانات نشاطك.'),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _working ? null : _createBackup,
                    icon: const Icon(Icons.save_alt),
                    label: const Text('إنشاء ومشاركة نسخة احتياطية'),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_working) const Padding(
          padding: EdgeInsets.all(20),
          child: Center(child: CircularProgressIndicator()),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.settings_backup_restore_outlined, size: 32),
                const SizedBox(height: 8),
                Text('استعادة نسخة احتياطية', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                const Text('اختر ملف نسخة احتياطية صادرًا من هذا التطبيق. يفحص التطبيق سلامة الملف وتوافق المخطط قبل عرض تأكيد الاستبدال. ستتم عملية الاستعادة داخل معاملة واحدة.'),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonalIcon(
                    onPressed: _working ? null : _restoreBackup,
                    icon: const Icon(Icons.restore),
                    label: const Text('اختيار نسخة واستعادتها'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const Text('تنبيه: الاستعادة تستبدل البيانات الحالية. احتفظ بنسخة احتياطية منفصلة قبل التأكيد.'),
      ],
    ),
  );
}
