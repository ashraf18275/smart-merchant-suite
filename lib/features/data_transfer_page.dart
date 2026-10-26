import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../data/csv_encoder.dart';

class _ExportTable {
  const _ExportTable(this.label, this.table, this.columns);
  final String label;
  final String table;
  final List<String> columns;
}

const _tables = <_ExportTable>[
  _ExportTable('المنتجات', 'products', [
    'id', 'name', 'sku', 'cost_minor', 'price_minor', 'stock_quantity',
    'is_active', 'created_at',
  ]),
  _ExportTable('الفواتير', 'sales', [
    'id', 'total_minor', 'paid_minor', 'created_at',
  ]),
  _ExportTable('بنود الفواتير', 'sale_items', [
    'id', 'sale_id', 'product_id', 'quantity', 'unit_price_minor',
    'unit_cost_minor', 'line_total_minor',
  ]),
  _ExportTable('المصروفات', 'expenses', [
    'id', 'description', 'category', 'amount_minor', 'created_at',
  ]),
  _ExportTable('حركات المخزون', 'inventory_movements', [
    'id', 'product_id', 'quantity_delta', 'reason', 'created_at',
  ]),
];

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
        ...rows.map((row) => spec.columns.map((column) => row[column]).toList()),
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
      _showError('تعذر تصدير CSV: $error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }


  Future<void> _restoreBackup() async {
    if (_working) return;
    setState(() => _working = true);
    Database? source;
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
        throw StateError('تعذر قراءة الملف المختار.');
      }

      final directory = await getTemporaryDirectory();
      final candidate = File(p.join(directory.path, 'restore_candidate_' + _timestamp() + '.db'));
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
        throw StateError('الملف لا يجتاز فحص سلامة SQLite.');
      }
      final migrations = await opened.query(
        'schema_migrations',
        columns: ['version'],
        where: 'version = ?',
        whereArgs: [3],
        limit: 1,
      );
      if (migrations.isEmpty) {
        throw StateError('النسخة غير متوافقة: يلزم مخطط قاعدة البيانات الإصدار 3.');
      }

      final data = <String, List<Map<String, Object?>>>{};
      for (final spec in _tables) {
        final tableInfo = await opened.rawQuery('PRAGMA table_info(' + spec.table + ')');
        final available = tableInfo.map((column) => column['name'] as String).toSet();
        if (!spec.columns.every(available.contains)) {
          throw StateError('النسخة لا تحتوي على بنية جدول ' + spec.label + ' المتوقعة.');
        }
        data[spec.table] = await opened.query(spec.table, orderBy: 'id ASC');
      }
      final foreignKeyErrors = await opened.rawQuery('PRAGMA foreign_key_check');
      if (foreignKeyErrors.isNotEmpty) {
        throw StateError('النسخة تحتوي على روابط غير سليمة بين السجلات.');
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
          'products',
        ]) {
          await txn.delete(table);
        }
        for (final table in [
          'products',
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
      _showError('تعذرت استعادة النسخة الاحتياطية: ' + error.toString());
    } finally {
      if (source != null) await source.close();
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _createBackup() async {
    if (_working) return;
    setState(() => _working = true);
    try {
      final integrity = await widget.database.rawQuery('PRAGMA integrity_check');
      if (integrity.isEmpty || integrity.first.values.first != 'ok') {
        throw StateError('فشل فحص سلامة قاعدة البيانات؛ لم يتم إنشاء النسخة.');
      }
      // Flush SQLite's write-ahead log before copying the database file.
      await widget.database.rawQuery('PRAGMA wal_checkpoint(FULL)');
      final source = File(widget.database.path);
      if (!await source.exists()) {
        throw StateError('لم يتم العثور على ملف قاعدة البيانات.');
      }
      final directory = await getTemporaryDirectory();
      final backup = File(p.join(directory.path, 'smart_merchant_backup_${_timestamp()}.db'));
      await source.copy(backup.path);
      if (!await backup.exists() || await backup.length() == 0) {
        throw StateError('لم يتم إنشاء ملف النسخة الاحتياطية بصورة سليمة.');
      }
      if (!mounted) return;
      await Share.shareXFiles(
        [XFile(backup.path, mimeType: 'application/octet-stream')],
        text: 'نسخة احتياطية من عدة التاجر الذكي. احتفظ بها في مكان آمن.',
      );
    } catch (error) {
      _showError('تعذر إنشاء النسخة الاحتياطية: $error');
    } finally {
      if (mounted) setState(() => _working = false);
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
