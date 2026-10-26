/// Username convention shared with the Supabase create-member function.
///
/// Supabase Auth is used internally, but users never need an email address and
/// no invitation or email is sent. The reserved .invalid domain is not deliverable.
const _internalAuthDomain = 'users.smart-merchant.invalid';

String normalizeUsername(String username) => username.trim().toLowerCase();

bool isValidUsername(String username) =>
    RegExp(r'^[a-z0-9][a-z0-9_.-]{2,31}$')
        .hasMatch(normalizeUsername(username));

String usernameToAuthEmail(String username) {
  final normalized = normalizeUsername(username);
  if (!isValidUsername(normalized)) {
    throw ArgumentError('اسم المستخدم يجب أن يتكون من 3 إلى 32 حرفًا أو رقمًا');
  }
  return '$normalized@$_internalAuthDomain';
}

/// Basic client-side validation only. The server enforces the same policy.
bool isValidNewPassword(String password) =>
    password.length >= 10 && password.length <= 128;
