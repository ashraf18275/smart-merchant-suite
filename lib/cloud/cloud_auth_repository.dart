import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/app_error.dart';
import '../security/username_login.dart';
import 'cloud_business.dart';

/// Auth and owner-onboarding operations. Authorization remains server-side:
/// this repository never carries a service-role key or writes privileged rows.
class CloudAuthRepository {
  CloudAuthRepository(this._client);

  final SupabaseClient _client;

  User? get currentUser => _client.auth.currentUser;

  Stream<AuthState> get authChanges => _client.auth.onAuthStateChange;

  Future<void> signIn({
    required String username,
    required String password,
  }) async {
    final normalized = normalizeUsername(username);
    if (!isValidUsername(normalized)) {
      throw AppException('اسم المستخدم غير صالح');
    }
    if (password.isEmpty || password.length > 128) {
      throw AppException('أدخل كلمة المرور الصحيحة');
    }
    await _client.auth.signInWithPassword(
      email: usernameToAuthEmail(normalized),
      password: password,
    );
  }

  /// Returns false when Supabase has email confirmation enabled. The
  /// application's reserved .invalid login address cannot receive a message.
  Future<bool> signUpOwner({
    required String username,
    required String password,
    required String businessName,
  }) async {
    final normalized = normalizeUsername(username);
    final cleanBusinessName = businessName.trim();
    if (!isValidUsername(normalized)) {
      throw AppException('اسم المستخدم يجب أن يكون من 3 إلى 32 حرفًا');
    }
    if (!isValidNewPassword(password)) {
      throw AppException('كلمة المرور يجب أن تكون من 10 إلى 128 حرفًا');
    }
    if (cleanBusinessName.isEmpty || cleanBusinessName.length > 160) {
      throw AppException('اسم النشاط مطلوب وبحد أقصى 160 حرفًا');
    }

    final response = await _client.auth.signUp(
      email: usernameToAuthEmail(normalized),
      password: password,
      data: {'username': normalized},
    );
    if (response.user == null) {
      throw AppException('تعذر إنشاء الحساب');
    }
    if (response.session == null) return false;

    await createBusiness(
      name: cleanBusinessName,
      username: normalized,
    );
    return true;
  }

  /// Completes owner setup after sign-up, or creates another shop for an
  /// already authenticated owner. Database triggers create the owner member,
  /// default branch and default warehouse atomically with the business row.
  Future<CloudBusiness> createBusiness({
    required String name,
    required String username,
  }) async {
    final user = _client.auth.currentUser;
    if (user == null) throw AppException('سجّل الدخول أولاً');
    final cleanName = name.trim();
    final normalized = normalizeUsername(username);
    if (cleanName.isEmpty || cleanName.length > 160) {
      throw AppException('اسم النشاط مطلوب وبحد أقصى 160 حرفًا');
    }
    if (!isValidUsername(normalized)) {
      throw AppException('اسم المستخدم غير صالح');
    }

    final row = await _client
        .from('businesses')
        .insert({'name': cleanName, 'owner_user_id': user.id})
        .select('id,name,created_at')
        .single();
    final business = CloudBusiness.fromMap(row);

    final metadataUsername = user.userMetadata['username'];
    if (metadataUsername is String &&
        normalizeUsername(metadataUsername) != normalized) {
      throw AppException('اسم المستخدم لا يطابق الحساب المسجل');
    }

    final member = await _client
        .from('business_members')
        .select('id')
        .eq('business_id', business.id)
        .eq('user_id', user.id)
        .single();
    // A single Auth identity may own multiple businesses. Its globally unique
    // username is attached once to the first owner membership, not duplicated
    // for every additional business.
    final existingLogin = await _client
        .from('member_login_names')
        .select('id')
        .eq('username', normalized)
        .maybeSingle();
    if (existingLogin == null) {
      await _client.from('member_login_names').insert({
        'business_id': business.id,
        'member_id': member['id'],
        'username': normalized,
      });
    }
    return business;
  }

  Future<List<CloudBusiness>> businesses() async {
    final rows = await _client
        .from('businesses')
        .select('id,name,created_at')
        .order('created_at');
    return rows
        .map((row) => CloudBusiness.fromMap(row))
        .toList(growable: false);
  }

  Future<void> signOut() => _client.auth.signOut();
}
