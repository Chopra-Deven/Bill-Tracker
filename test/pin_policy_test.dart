import 'package:bill_tracker/pin_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('hash round trip', () {
    final s = hashPin('1234', 'abcd');
    expect(verifyStored(s, '1234'), isTrue);
    expect(verifyStored(s, '1235'), isFalse);
    expect(s.contains('1234'), isFalse);
  });

  test('legacy plain pin verifies and needs upgrade', () {
    expect(verifyStored('4321', '4321'), isTrue);
    expect(needsUpgrade('4321'), isTrue);
    expect(needsUpgrade(hashPin('4321', 'x')), isFalse);
  });

  test('lockout schedule', () {
    expect(lockoutFor(4), Duration.zero);
    expect(lockoutFor(5), const Duration(seconds: 30));
    expect(lockoutFor(6), const Duration(seconds: 60));
    expect(lockoutFor(20), const Duration(minutes: 5));
  });
}
