/// Runtime configuration for the optional shared-cloud layer.
///
/// Values are injected at build time. No service-role credential is ever
/// embedded in the client; the public publishable key is protected by RLS.
class CloudConfig {
  const CloudConfig({required this.url, required this.publishableKey});

  factory CloudConfig.fromEnvironment() => const CloudConfig(
        url: String.fromEnvironment('SUPABASE_URL'),
        publishableKey: String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY'),
      );

  final String url;
  final String publishableKey;

  bool get isConfigured {
    final parsed = Uri.tryParse(url.trim());
    final validScheme = parsed?.scheme == 'https' ||
        (parsed?.scheme == 'http' &&
            (parsed?.host == 'localhost' || parsed?.host == '127.0.0.1'));
    return validScheme && parsed?.hasAuthority == true && publishableKey.trim().isNotEmpty;
  }
}
