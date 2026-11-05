import 'package:path/path.dart' as p;

/// Resolves a tenant-isolated SQLite filename without ever treating an
/// untrusted tenant identifier as a filesystem path.
abstract final class LocalDatabasePath {
  static final RegExp _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  static String resolve(String supportDirectory, {String? businessId}) {
    if (businessId == null) {
      // Preserve the existing offline-only database in place. Never copy it
      // into a cloud business database automatically.
      return p.join(supportDirectory, 'smart_merchant_suite.db');
    }

    final normalized = businessId.trim().toLowerCase();
    if (!_uuid.hasMatch(normalized)) {
      throw ArgumentError.value(
        businessId,
        'businessId',
        'A canonical cloud business UUID is required.',
      );
    }

    return p.join(
      supportDirectory,
      'businesses',
      'business_$normalized.db',
    );
  }
}
