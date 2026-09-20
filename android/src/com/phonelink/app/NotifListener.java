package com.phonelink.app;

import android.app.Notification;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;
import android.text.TextUtils;
import android.util.Log;

import java.util.HashMap;
import java.util.UUID;

/**
 * Universal capture channel: every app that posts a notification (WeChat, QQ, SMS app, ...)
 * is relayed. This is the path that needs no SMS permission at all.
 */
public class NotifListener extends NotificationListenerService {

    private static final long DEDUP_WINDOW_MS = 90 * 1000L;
    private static final int DEDUP_MAX = 300;

    private final HashMap<String, Long> seen = new HashMap<String, Long>();

    @Override
    public void onListenerConnected() {
        super.onListenerConnected();
        Log.i(Net.TAG, "notification listener connected");
    }

    @Override
    public void onNotificationPosted(StatusBarNotification sbn) {
        try {
            handle(sbn);
        } catch (Throwable t) {
            Log.w(Net.TAG, "onNotificationPosted: " + t);
        }
    }

    private void handle(StatusBarNotification sbn) {
        if (sbn == null) return;

        Config.Cfg cfg = Config.load(this);
        if (!cfg.enabled || !cfg.notif) return;

        String pkg = sbn.getPackageName();
        if (pkg == null || pkg.equals(getPackageName())) return;

        Notification n = sbn.getNotification();
        if (n == null) return;
        if ((n.flags & Notification.FLAG_GROUP_SUMMARY) != 0) return; // group roll-ups duplicate content

        Bundle ex = n.extras;
        if (ex == null) return;

        String title = str(ex.getCharSequence(Notification.EXTRA_TITLE));
        String text = str(ex.getCharSequence(Notification.EXTRA_TEXT));
        if (TextUtils.isEmpty(text)) {
            text = str(ex.getCharSequence(Notification.EXTRA_BIG_TEXT));
        }
        if (TextUtils.isEmpty(text)) {
            text = str(ex.getCharSequence(Notification.EXTRA_SUMMARY_TEXT));
        }
        if (TextUtils.isEmpty(text)) {
            CharSequence[] lines = ex.getCharSequenceArray(Notification.EXTRA_TEXT_LINES);
            if (lines != null && lines.length > 0) {
                StringBuilder b = new StringBuilder();
                for (CharSequence cs : lines) {
                    if (cs == null) continue;
                    if (b.length() > 0) b.append('\n');
                    b.append(cs);
                }
                text = b.toString();
            }
        }

        if (cfg.onlyWithText && TextUtils.isEmpty(text)) return;
        if (TextUtils.isEmpty(title) && TextUtils.isEmpty(text)) return;

        String key = pkg + "|" + title + "|" + text;
        if (isDuplicate(key)) return;

        Msg m = new Msg();
        m.id = UUID.randomUUID().toString();
        m.ts = sbn.getPostTime() > 0 ? sbn.getPostTime() : System.currentTimeMillis();
        m.kind = "notif";
        m.pkg = pkg;
        m.app = appLabel(this, pkg);
        m.title = title;
        m.text = text;

        Db.get(this).enqueue(m);
        PushService.wake(this);
    }

    private boolean isDuplicate(String key) {
        long now = System.currentTimeMillis();
        synchronized (seen) {
            Long prev = seen.get(key);
            if (prev != null && now - prev < DEDUP_WINDOW_MS) {
                seen.put(key, now);
                return true;
            }
            seen.put(key, now);
            if (seen.size() > DEDUP_MAX) {
                // drop the oldest half
                java.util.Iterator<java.util.Map.Entry<String, Long>> it = seen.entrySet().iterator();
                int drop = seen.size() / 2;
                while (it.hasNext() && drop-- > 0) {
                    it.next();
                    it.remove();
                }
            }
            return false;
        }
    }

    private static String str(CharSequence cs) {
        return cs == null ? "" : cs.toString().trim();
    }

    static String appLabel(Context c, String pkg) {
        try {
            PackageManager pm = c.getPackageManager();
            return String.valueOf(pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)));
        } catch (Throwable t) {
            return pkg;
        }
    }
}
