import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../cloud/cloud_auth_repository.dart';
import '../cloud/cloud_business.dart';
import 'cloud_members_page.dart';
import 'cloud_products_page.dart';
import 'cloud_locations_page.dart';

class CloudLoginPage extends StatefulWidget {
  const CloudLoginPage({super.key, required this.client});

  final SupabaseClient client;

  @override
  State<CloudLoginPage> createState() => _CloudLoginPageState();
}

class _CloudLoginPageState extends State<CloudLoginPage> {
  late final CloudAuthRepository _auth = CloudAuthRepository(widget.client);
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _businessName = TextEditingController();
  bool _registerMode = false;
  bool _busy = false;
  String? _message;
  String? _error;
  List<CloudBusiness> _businesses = const [];

  @override
  void initState() {
    super.initState();
    if (_auth.currentUser != null) _loadBusinesses();
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _businessName.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      if (_registerMode) {
        final ready = await _auth.signUpOwner(
          username: _username.text,
          password: _password.text,
          businessName: _businessName.text,
        );
        if (!ready) {
          setState(() {
            _message =
                'تم إنشاء طلب الحساب، لكن خادم Supabase لم يُنشئ جلسة دخول. '
                'يجب تعطيل تأكيد البريد الإلكتروني لهذا المشروع؛ اسم الدخول الداخلي '
                'ينتهي بنطاق .invalid ولا يستقبل رسائل.';
          });
          return;
        }
      } else {
        await _auth.signIn(
          username: _username.text,
          password: _password.text,
        );
      }
      await _loadBusinesses();
      if (mounted) {
        setState(() => _message = 'تم تسجيل الدخول إلى الحساب السحابي.');
      }
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadBusinesses() async {
    try {
      final rows = await _auth.businesses();
      if (mounted) setState(() => _businesses = rows);
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    }
  }

  Future<void> _createAnotherBusiness() async {
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      await _auth.createBusiness(
        name: _businessName.text,
        username: _username.text,
      );
      await _loadBusinesses();
      if (mounted) setState(() => _message = 'تم إنشاء النشاط والفرع والمخزن الرئيسيين.');
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    setState(() => _busy = true);
    try {
      await _auth.signOut();
      if (mounted) {
        setState(() {
          _businesses = const [];
          _message = 'تم تسجيل الخروج.';
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendlyError(Object error) {
    final message = error.toString();
    if (message.contains('Invalid login credentials')) {
      return 'اسم المستخدم أو كلمة المرور غير صحيحة.';
    }
    if (message.contains('already registered') || message.contains('User already registered')) {
      return 'اسم المستخدم مستخدم بالفعل.';
    }
    if (message.contains('duplicate key') || message.contains('23505')) {
      return 'اسم المستخدم مسجل بالفعل.';
    }
    return 'تعذر إتمام العملية. راجع إعدادات الاتصال والصلاحيات ثم أعد المحاولة.';
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = _auth.currentUser != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('الحساب السحابي'),
        actions: [
          if (signedIn)
            IconButton(
              tooltip: 'تسجيل الخروج',
              onPressed: _busy ? null : _signOut,
              icon: const Icon(Icons.logout),
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      signedIn ? 'الحساب متصل' : 'تسجيل الدخول',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'تسجيل الدخول باسم مستخدم وكلمة مرور، دون دعوات بريد إلكتروني.',
                    ),
                    if (!signedIn) ...[
                      const SizedBox(height: 16),
                      TextField(
                        controller: _username,
                        textDirection: TextDirection.ltr,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'اسم المستخدم',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _password,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'كلمة المرور',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      if (_registerMode) ...[
                        const SizedBox(height: 12),
                        TextField(
                          controller: _businessName,
                          decoration: const InputDecoration(
                            labelText: 'اسم المتجر / النشاط الأول',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _busy ? null : _submit,
                        child: Text(_busy
                            ? 'جارٍ التنفيذ...'
                            : _registerMode
                                ? 'إنشاء حساب المالك والنشاط'
                                : 'تسجيل الدخول'),
                      ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                  _registerMode = !_registerMode;
                                  _error = null;
                                  _message = null;
                                }),
                        child: Text(_registerMode
                            ? 'لدي حساب بالفعل'
                            : 'إنشاء حساب مالك جديد'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (signedIn) ...[
              const SizedBox(height: 16),
              Text('الأنشطة المتاحة', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              if (_businesses.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('لا توجد أنشطة مرتبطة بهذا الحساب حتى الآن.'),
                  ),
                )
              else
                ..._businesses.map((business) => Card(
                      child: ListTile(
                        leading: const Icon(Icons.store_outlined),
                        title: Text(business.name),
                        subtitle: Text(business.id),
                        trailing: Wrap(
                          spacing: 4,
                          children: [
                            IconButton(
                              tooltip: 'المنتجات والمخزون السحابي',
                              icon: const Icon(Icons.inventory_2_outlined),
                              onPressed: () {
                                Navigator.of(context).push(MaterialPageRoute<void>(
                                  builder: (_) => CloudProductsPage(
                                    client: widget.client,
                                    businessId: business.id,
                                    businessName: business.name,
                                  ),
                                ));
                              },
                            ),
                            IconButton(
                              tooltip: 'الفروع والمخازن',
                              icon: const Icon(Icons.warehouse_outlined),
                              onPressed: () {
                                Navigator.of(context).push(MaterialPageRoute<void>(
                                  builder: (_) => CloudLocationsPage(
                                    client: widget.client,
                                    businessId: business.id,
                                    businessName: business.name,
                                  ),
                                ));
                              },
                            ),
                          ],
                        ),
                        onTap: () {
                          Navigator.of(context).push(MaterialPageRoute<void>(
                            builder: (_) => CloudMembersPage(
                              client: widget.client,
                              businessId: business.id,
                              businessName: business.name,
                            ),
                          ));
                        },
                      ),
                    )),
              const SizedBox(height: 12),
              TextField(
                controller: _businessName,
                decoration: const InputDecoration(
                  labelText: 'اسم نشاط إضافي',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : _createAnotherBusiness,
                icon: const Icon(Icons.add_business_outlined),
                label: const Text('إضافة نشاط جديد'),
              ),
              const SizedBox(height: 12),
              const Text(
                'الاتصال وتسجيل الأنشطة يعملان. مزامنة بيانات SQLite بين الأجهزة '
                'لم تُفعّل بعد، لذلك تظل بيانات التشغيل الحالية محلية على هذا الجهاز.',
                style: TextStyle(color: Colors.black54),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            if (_message != null) ...[
              const SizedBox(height: 12),
              Text(_message!, style: const TextStyle(color: Colors.green)),
            ],
          ],
        ),
      ),
    );
  }
}
