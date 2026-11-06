import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

/// Stored form of a PIN: `v1:<salt>:<sha256(salt + pin) hex>`.
String hashPin(String pin, String salt) => 'v1:$salt:${sha256.convert(utf8.encode(salt + pin))}';

/// Checks [pin] against a stored value, which is either `v1:` hashed or a
/// plain PIN saved by an older version of the app.
bool verifyStored(String stored, String pin) {
  if (!stored.startsWith('v1:')) return stored == pin;
  final parts = stored.split(':');
  if (parts.length != 3) return false;
  return hashPin(pin, parts[1]) == stored;
}

bool needsUpgrade(String stored) => !stored.startsWith('v1:');

/// Wait time after [failures] wrong PINs in a row: none for the first 4,
/// then 30 s doubling each time, at most 5 minutes.
Duration lockoutFor(int failures) {
  if (failures < 5) return Duration.zero;
  final secs = 30 * math.pow(2, math.min(failures - 5, 10));
  return Duration(seconds: math.min(secs.toInt(), 300));
}
