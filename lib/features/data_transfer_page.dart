import 'dart:convert';
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

const _tables = <_ExportTable>[
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
const _legacyV6Tables = _tables;

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
      if (schemaVersion != 3 && schemaVersion != 4 && schemaVersion != 5 && schemaVersion != 6 && schemaVersion != 7) {
        throw AppException(
          'إصدار قاعدة البيانات غير مدعوم (الإصدار المكتشف: $schemaVersion، المدعوم: 3 أو 4 أو 5 أو 6).',
        );
      }

      final data = <String, List<Map<String, Object?>>>{};
      final restoreTables = schemaVersion == 7
          ? _tables
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
        final branchRows = await widget.database.rawQuery(
          "SELECT b.id, b.name, b.address, b.phone, b.is_active, b.created_at, w.id AS warehouse_id, w.name AS warehouse_name, w.is_active AS warehouse_active, w.created_at AS warehouse_created_at FROM branches b JOIN warehouses w ON w.branch_id = b.id WHERE b.name = 'الفرع الرئيسي' AND w.name = 'المخزن الرئيسي' LIMIT 1",
        );
        final defaultUnitRows = await widget.database.query(
          'product_units', columns: ['id'], where: 'name = ?', whereArgs: ['قطعة'], limit: 1,
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

      await widget.database.transaction((txn) async {
        for (final table in [
          'inventory_movements',
          'sale_items',
          'sales',
          'expenses',
          'product_warehouse_stock',
          'products',
          'product_categories',
          'product_units',
          'warehouses',
          'branches',
        ]) {
          await txn.delete(table);
        }
        for (final table in [
          'branches',
          'warehouses',
          'product_categories',
          'product_units',
          'products',
          'product_warehouse_stock',
          'sales',
          'sale_items',
          'expenses',
          'inventory_movements',
        ]) {
          for (final row in data[table]!) {
            await txn.insert(table, row, conflictAlgorithm: ConflictAlgorithm.abort);
          }
        }
      });
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
      if (schemaVersion != 7) {
        throw AppException('إصدار قاعدة البيانات الحالية غير متوقع: $schemaVersion.');
      }

      // Require SQLite to finish checkpointing before copying the database file.
      final checkpoint = await widget.database.rawQuery('PRAGMA wal_checkpoint(FULL)');
      if (checkpoint.isEmpty) {
        throw AppException('تعذر التأكد من اكتمال تجهيز قاعدة البيانات للنسخ الاحتياطي.');
      }
      final checkpointRow = checkpoint.first;
      final busy = (checkpointRow['busy'] as num?)?.toInt() ?? 0;
      final walFrames = (checkpointRow['log'] as num?)?.toInt() ?? -1;
      final checkpointedFrames =
          (checkpointRow['checkpointed'] as num?)?.toInt() ?? -1;
      if (busy != 0 ||
          (walFrames >= 0 &&
              checkpointedFrames >= 0 &&
              checkpointedFrames < walFrames)) {
        throw AppException('تعذر إكمال تجهيز قاعدة البيانات للنسخ؛ أغلق العمليات الجارية ثم أعد المحاولة.');
      }

      final sourceFile = File(widget.database.path);
      if (!await sourceFile.exists()) {
        throw AppException('لم يتم العثور على ملف قاعدة البيانات.');
      }
      final directory = await getTemporaryDirectory();
      backup = File(p.join(directory.path, 'smart_merchant_backup_${_timestamp()}.db'));
      await sourceFile.copy(backup.path);

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
      if (backupVersion != 7) {
        throw AppException('ملف النسخة الاحتياطية لا يحتوي على إصدار المخطط المطلوب.');
      }
      for (final spec in _tables) {
        final originalRows = await widget.database.query(
          spec.table,
          columns: spec.columns,
          orderBy: 'id ASC',
        );
        final backupRows = await opened.query(
          spec.table,
          columns: spec.columns,
          orderBy: 'id ASC',
        );
        // Compare actual row contents as well as counts; equal counts alone
        // cannot detect a stale or mismatched copy.
        if (jsonEncode(originalRows) != jsonEncode(backupRows)) {
          throw AppException('لم تتطابق بيانات جدول ${spec.label} في النسخة الاحتياطية.');
        }
      }
      final originalMigrations = await widget.database.query(
        'schema_migrations',
        columns: ['version', 'applied_at'],
        orderBy: 'version ASC',
      );
      final backupMigrations = await opened.query(
        'schema_migrations',
        columns: ['version', 'applied_at'],
        orderBy: 'version ASC',
      );
      if (jsonEncode(originalMigrations) != jsonEncode(backupMigrations)) {
        throw AppException('لم تتطابق بيانات إصدارات المخطط في النسخة الاحتياطية.');
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
