import 'package:flutter/material.dart';

import '../application/ports/catalog_store.dart';
import '../core/app_error.dart';
import '../domain/product_category.dart';
import '../domain/product_unit.dart';

class CatalogManagementPage extends StatefulWidget {
  const CatalogManagementPage({super.key, required this.catalog});
  final CatalogStore catalog;

  @override
  State<CatalogManagementPage> createState() => _CatalogManagementPageState();
}

class _CatalogManagementPageState extends State<CatalogManagementPage> {
  List<ProductCategory> _categories = [];
  List<ProductUnit> _units = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final values = await Future.wait([
        widget.catalog.categories(includeInactive: true),
        widget.catalog.units(includeInactive: true),
      ]);
      if (!mounted) return;
      setState(() {
        _categories = values[0] as List<ProductCategory>;
        _units = values[1] as List<ProductUnit>;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = appErrorMessage(error, fallback: 'تعذر تحميل التصنيفات والوحدات.', operation: 'catalog.load');
      });
    }
  }

  Future<void> _categoryDialog([ProductCategory? category]) async {
    final controller = TextEditingController(text: category?.name ?? '');
    final key = GlobalKey<FormState>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(category == null ? 'إضافة تصنيف' : 'تعديل التصنيف'),
        content: Form(
          key: key,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'اسم التصنيف'),
            validator: (value) => value == null || value.trim().isEmpty ? 'اكتب اسم التصنيف' : null,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () { if (key.currentState!.validate()) Navigator.pop(ctx, true); },
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    if (saved == true) {
      try {
        if (category == null) {
          await widget.catalog.addCategory(controller.text);
        } else {
          await widget.catalog.updateCategory(id: category.id, name: controller.text);
        }
        await _load();
      } catch (error) {
        _showError(error, 'تعذر حفظ التصنيف.');
      }
    }
    controller.dispose();
  }

  Future<void> _unitDialog([ProductUnit? unit]) async {
    final name = TextEditingController(text: unit?.name ?? '');
    final abbreviation = TextEditingController(text: unit?.abbreviation ?? '');
    final key = GlobalKey<FormState>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
          title: Text(unit == null ? 'إضافة وحدة قياس' : 'تعديل وحدة القياس'),
          content: Form(
            key: key,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: name,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'اسم الوحدة'),
                  validator: (value) => value == null || value.trim().isEmpty ? 'اكتب اسم الوحدة' : null,
                ),
                TextFormField(
                  controller: abbreviation,
                  decoration: const InputDecoration(labelText: 'الاختصار (مثل كجم أو لتر)'),
                  validator: (value) => value == null || value.trim().isEmpty ? 'اكتب اختصار الوحدة' : null,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            FilledButton(
              onPressed: () { if (key.currentState!.validate()) Navigator.pop(ctx, true); },
              child: const Text('حفظ'),
            ),
          ],
      ),
    );
    if (saved == true) {
      try {
        if (unit == null) {
          await widget.catalog.addUnit(
            name: name.text,
            abbreviation: abbreviation.text,
            allowsFraction: false,
          );
        } else {
          await widget.catalog.updateUnit(
            id: unit.id,
            name: name.text,
            abbreviation: abbreviation.text,
            allowsFraction: false,
          );
        }
        await _load();
      } catch (error) {
        _showError(error, 'تعذر حفظ وحدة القياس.');
      }
    }
    name.dispose();
    abbreviation.dispose();
  }

  Future<void> _toggleCategory(ProductCategory category) async {
    try {
      await widget.catalog.setCategoryActive(id: category.id, isActive: !category.isActive);
      await _load();
    } catch (error) {
      _showError(error, 'تعذر تغيير حالة التصنيف.');
    }
  }

  Future<void> _toggleUnit(ProductUnit unit) async {
    try {
      await widget.catalog.setUnitActive(id: unit.id, isActive: !unit.isActive);
      await _load();
    } catch (error) {
      _showError(error, 'تعذر تغيير حالة وحدة القياس.');
    }
  }

  void _showError(Object error, String fallback) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(appErrorMessage(error, fallback: fallback, operation: 'catalog.save'))),
    );
  }

  Widget _categoryList() {
    if (_categories.isEmpty) return const Center(child: Text('لا توجد تصنيفات. أضف أول تصنيف.'));
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _categories.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final item = _categories[index];
        return Card(
          child: ListTile(
            title: Text(item.name),
            subtitle: Text(item.isActive ? 'نشط' : 'موقوف'),
            trailing: Wrap(
              spacing: 0,
              children: [
                IconButton(tooltip: 'تعديل التصنيف', onPressed: () => _categoryDialog(item), icon: const Icon(Icons.edit_outlined)),
                IconButton(
                  tooltip: item.isActive ? 'إيقاف التصنيف' : 'تفعيل التصنيف',
                  onPressed: () => _toggleCategory(item),
                  icon: Icon(item.isActive ? Icons.pause_circle_outline : Icons.play_circle_outline),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _unitList() {
    if (_units.isEmpty) return const Center(child: Text('لا توجد وحدات قياس.'));
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _units.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final item = _units[index];
        return Card(
          child: ListTile(
            title: Text(item.name),
            subtitle: Text('${item.abbreviation} • ${item.allowsFraction ? 'تقبل الكسور' : 'أعداد صحيحة فقط'} • ${item.isActive ? 'نشطة' : 'موقوفة'}'),
            trailing: Wrap(
              spacing: 0,
              children: [
                IconButton(tooltip: 'تعديل وحدة القياس', onPressed: () => _unitDialog(item), icon: const Icon(Icons.edit_outlined)),
                IconButton(
                  tooltip: item.isActive ? 'إيقاف الوحدة' : 'تفعيل الوحدة',
                  onPressed: () => _toggleUnit(item),
                  icon: Icon(item.isActive ? Icons.pause_circle_outline : Icons.play_circle_outline),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('التصنيفات ووحدات القياس'),
        bottom: const TabBar(tabs: [
          Tab(text: 'التصنيفات', icon: Icon(Icons.category_outlined)),
          Tab(text: 'وحدات القياس', icon: Icon(Icons.straighten)),
        ]),
      ),
      floatingActionButton: Builder(
        builder: (context) => FloatingActionButton.extended(
          onPressed: () {
            final index = DefaultTabController.of(context).index;
            if (index == 0) {
              _categoryDialog();
            } else {
              _unitDialog();
            }
          },
          icon: const Icon(Icons.add),
          label: const Text('إضافة'),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_error!, textAlign: TextAlign.center),
                  OutlinedButton(onPressed: _load, child: const Text('إعادة المحاولة')),
                ]))
              : TabBarView(children: [_categoryList(), _unitList()]),
    ),
  );
}
