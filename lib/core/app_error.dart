import 'dart:developer' as developer;

/// A safe, localized error that is appropriate to show to the user.
class AppException implements Exception {
  const AppException(
    this.userMessage, {
    this.code = 'operation_failed',
  });

  final String userMessage;
  final String code;

  /// Avoid leaking internal details if an exception is accidentally stringified.
  @override
  String toString() => 'AppException($code)';
}

/// Returns a localized message for known application errors and a generic
/// fallback for unexpected infrastructure errors. Only stable error codes and
/// operation names are written to the local diagnostic log; raw exception
/// messages, SQL, file paths, and user data are never logged here.
String appErrorMessage(
  Object error, {
  required String fallback,
  required String operation,
}) {
  if (error is AppException) {
    developer.log(
      'operation_failed code=${error.code}',
      name: 'smart_merchant.$operation',
      level: 800,
    );
    return error.userMessage;
  }

  developer.log(
    'operation_failed code=unexpected_error',
    name: 'smart_merchant.$operation',
    level: 1000,
  );
  return fallback;
}
