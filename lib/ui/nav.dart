import 'package:flutter/material.dart';

import '../models.dart';
import 'bill_detail_page.dart';
import 'bill_form_page.dart';
import 'pay_page.dart';
import 'profile_page.dart';
import 'settings_page.dart';
import 'share_pick_page.dart';

final navKey = GlobalKey<NavigatorState>();

Future<T?> push<T>(Widget page) =>
    navKey.currentState!.push<T>(MaterialPageRoute(builder: (_) => page));

void openDetail(String id) => push(BillDetailPage(billId: id));
void openForm([Bill? b]) => push(BillFormPage(bill: b));
void openSettings() => push(const SettingsPage());
void openProfile() => push(const ProfilePage());
Future<bool?> openPay(Bill b, String key, {String? presetPath, String? presetName}) =>
    push<bool>(PayPage(bill: b, keyMonth: key, presetPath: presetPath, presetName: presetName));
void openSharePick(String path, String name) => push(SharePickPage(path: path, name: name));
