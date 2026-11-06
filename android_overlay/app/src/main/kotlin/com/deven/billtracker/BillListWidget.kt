package com.deven.billtracker

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Color
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

class BillListWidget : HomeWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray, widgetData: SharedPreferences) {
        val names = intArrayOf(R.id.r0_name, R.id.r1_name, R.id.r2_name)
        val dues = intArrayOf(R.id.r0_due, R.id.r1_due, R.id.r2_due)
        val rows = intArrayOf(R.id.r0, R.id.r1, R.id.r2)
        appWidgetIds.forEach { id ->
            val views = RemoteViews(context.packageName, R.layout.bill_list_widget).apply {
                setTextViewText(R.id.updated, widgetData.getString("w_updated", "") ?: "")
                for (i in 0..2) {
                    val name = widgetData.getString("r${i}_name", if (i == 0) "Open the app to load bills" else "") ?: ""
                    val due = widgetData.getString("r${i}_due", "") ?: ""
                    val late = widgetData.getBoolean("r${i}_late", false)
                    setViewVisibility(rows[i], if (name.isEmpty()) View.GONE else View.VISIBLE)
                    setTextViewText(names[i], name)
                    setTextViewText(dues[i], due)
                    setTextColor(dues[i], if (late) Color.parseColor("#B93A26") else Color.parseColor("#5B6863"))
                }
                setOnClickPendingIntent(R.id.root, HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java))
            }
            appWidgetManager.updateAppWidget(id, views)
        }
    }
}
