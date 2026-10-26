import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/security/username_login.dart';

void main() {
  group('username login', () {
    test('normalizes username and maps it to internal auth identity', () {
      expect(usernameToAuthEmail('  Shop.User  '),
          'shop.user@users.smart-merchant.invalid');
    });

    test('rejects short or malformed usernames', () {
      expect(isValidUsername('ab'), isFalse);
      expect(isValidUsername('name with spaces'), isFalse);
      expect(isValidUsername('name@domain.com'), isFalse);
      expect(isValidUsername('_starts-with-symbol'), isFalse);
      expect(isValidUsername('valid_user-3'), isTrue);
    });

    test('throws for invalid login username', () {
      expect(() => usernameToAuthEmail('a b'), throwsArgumentError);
    });

    test('validates password length before sending request', () {
      expect(isValidNewPassword('short'), isFalse);
      expect(isValidNewPassword('1234567890'), isTrue);
      expect(isValidNewPassword(List.filled(129, 'x').join()), isFalse);
    });
  });
}
