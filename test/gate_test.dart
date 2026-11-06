import 'dart:io';

import 'package:bill_tracker/models.dart';
import 'package:bill_tracker/store.dart';
import 'package:bill_tracker/sync/sync_service.dart';
import 'package:bill_tracker/ui/auth_pages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_remote.dart';

void main() {
  setUp(() {
    SyncService.I = SyncService(
      local: FakeLocal(AppData(), [Directory.systemTemp]),
      remote: () => FakeRemote(),
      accountId: () async => 'acc',
      wipe: () async {},
      signOut: () async {},
    );
  });

  Future<void> show(WidgetTester t, AppData d) async {
    AppStore.I.data = d;
    await t.pumpWidget(const MaterialApp(home: Gate()));
  }

  testWidgets('Gate shows SignInPage when not signed in', (t) async {
    await show(t, AppData());
    expect(find.byType(SignInPage), findsOneWidget);
    expect(find.text('Sign in with Google'), findsOneWidget);
  });

  testWidgets('Gate shows NamePage when name empty', (t) async {
    await show(t, AppData()
      ..session.accountId = 'acc'
      ..session.firstSyncDone = true);
    expect(find.byType(NamePage), findsOneWidget);
  });

  testWidgets('Gate shows FirstSyncPage before the first sync is done', (t) async {
    await show(t, AppData()..session.accountId = 'acc');
    expect(find.byType(FirstSyncPage), findsOneWidget);
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets('back button cannot leave the sign-in screen', (t) async {
    await show(t, AppData());
    final pop = t.widget<PopScope>(find.byType(PopScope).first);
    expect(pop.canPop, isFalse);
  });
}
