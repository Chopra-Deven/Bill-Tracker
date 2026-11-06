import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';

import 'logic.dart';
import 'models.dart';

/// Pushes the next bills to the two Android home-screen widgets.
class WidgetSync {
  static Future<void> update(AppData d) async {
    try {
      final today = dateOnly(DateTime.now());
      final list = d.bills.where((b) => !(paidNow(b, today) && active(b, today).st == DueState.upcoming)).toList()
        ..sort((x, y) => active(x, today).due.compareTo(active(y, today).due));
      for (var i = 0; i < 3; i++) {
        if (i < list.length) {
          final b = list[i];
          final a = active(b, today);
          await HomeWidget.saveWidgetData<String>('r${i}_name', b.name);
          await HomeWidget.saveWidgetData<String>(
              'r${i}_due', a.days < 0 ? 'Overdue · ${niceDate(a.due)}' : 'Due ${niceDate(a.due)}');
          await HomeWidget.saveWidgetData<bool>('r${i}_late', a.days < 0);
        } else {
          await HomeWidget.saveWidgetData<String>('r${i}_name', i == 0 ? 'All bills paid' : '');
          await HomeWidget.saveWidgetData<String>('r${i}_due', '');
          await HomeWidget.saveWidgetData<bool>('r${i}_late', false);
        }
      }
      final week = countDueWithin(d.bills, today, 7);
      final over = d.bills.where((b) => active(b, today).st == DueState.overdue).length;
      await HomeWidget.saveWidgetData<String>('w_week', '$week');
      await HomeWidget.saveWidgetData<String>('w_over', over > 0 ? '$over overdue' : 'none overdue');
      await HomeWidget.saveWidgetData<String>('w_updated', 'as of ${niceDate(today)}');
      await HomeWidget.updateWidget(androidName: 'BillListWidget', qualifiedAndroidName: 'com.deven.billtracker.BillListWidget');
      await HomeWidget.updateWidget(androidName: 'BillCountWidget', qualifiedAndroidName: 'com.deven.billtracker.BillCountWidget');
    } catch (e) {
      debugPrint('widget update failed: $e');
    }
  }
}
