import 'package:bill_tracker/paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const base = '/storage/emulated/0/BillTracker';
  test('safeJoin accepts normal nested entry',
      () => expect(safeJoin(base, 'Receipts/HDFC_Regalia/2026-11_x.jpg'), '$base/Receipts/HDFC_Regalia/2026-11_x.jpg'));
  test('safeJoin rejects parent traversal', () => expect(safeJoin(base, '../../data/evil.so'), isNull));
  test('safeJoin rejects hidden traversal', () => expect(safeJoin(base, 'Receipts/../../x'), isNull));
  test('safeJoin rejects absolute entry', () => expect(safeJoin(base, '/etc/passwd'), isNull));
  test('safeJoin rejects base itself', () => expect(safeJoin(base, '.'), isNull));
}
