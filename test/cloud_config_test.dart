import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/cloud/cloud_config.dart';

void main() {
  group('CloudConfig', () {
    test('requires both a valid endpoint and public client key', () {
      expect(
        const CloudConfig(url: '', anonKey: '').isConfigured,
        isFalse,
      );
      expect(
        const CloudConfig(
          url: 'https://example.supabase.co',
          anonKey: '',
        ).isConfigured,
        isFalse,
      );
      expect(
        const CloudConfig(
          url: 'not-a-url',
          anonKey: 'public-key',
        ).isConfigured,
        isFalse,
      );
    });

    test('accepts HTTPS cloud endpoints', () {
      expect(
        const CloudConfig(
          url: 'https://example.supabase.co',
          anonKey: 'public-anon-key',
        ).isConfigured,
        isTrue,
      );
    });

    test('allows HTTP only for local development hosts', () {
      expect(
        const CloudConfig(
          url: 'http://localhost:54321',
          anonKey: 'public-anon-key',
        ).isConfigured,
        isTrue,
      );
      expect(
        const CloudConfig(
          url: 'http://192.168.1.20:54321',
          anonKey: 'public-anon-key',
        ).isConfigured,
        isFalse,
      );
    });
  });
}
