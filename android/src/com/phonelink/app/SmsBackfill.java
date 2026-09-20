package com.phonelink.app;

import android.content.ContentResolver;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.util.Log;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;
import java.util.UUID;

/**
 * Re-reads the SMS inbox for anything that arrived while the relay was down (reboot, kill,
 * permission granted late) so nothing is silently lost.
 */
public final class SmsBackfill {

    private SmsBackfill() {}

    private static final class Item {
        String address;
        String body;
        long date;
    }

    public static void run(Context c) {
        try {
            Config.Cfg cfg = Config.load(c);
            if (!cfg.enabled || !cfg.sms) return;

            long since = Config.lastSmsTs(c);
            if (since <= 0) {
                since = System.currentTimeMillis() - 10 * 60 * 1000L;
            }
            long newest = since;

            ContentResolver cr = c.getContentResolver();
            Cursor cur = null;
            List<Item> items = new ArrayList<Item>();
            try {
                cur = cr.query(Uri.parse("content://sms/inbox"),
                        new String[]{"_id", "address", "body", "date"},
                        null, null, "date DESC LIMIT 40");
                if (cur != null) {
                    while (cur.moveToNext()) {
                        long d = cur.getLong(3);
                        if (d <= since) continue;
                        Item it = new Item();
                        it.address = cur.getString(1);
                        it.body = cur.getString(2);
                        it.date = d;
                        items.add(it);
                        if (d > newest) newest = d;
                    }
                }
            } catch (Throwable t) {
                Log.i(Net.TAG, "sms backfill skipped: " + t);
                return;
            } finally {
                if (cur != null) cur.close();
            }

            if (items.isEmpty()) return;
            Collections.sort(items, new Comparator<Item>() {
                @Override
                public int compare(Item a, Item b) {
                    return a.date < b.date ? -1 : (a.date == b.date ? 0 : 1);
                }
            });

            int n = 0;
            for (Item it : items) {
                Msg m = new Msg();
                m.id = UUID.randomUUID().toString();
                m.ts = it.date;
                m.kind = "sms";
                m.pkg = "sms";
                m.app = "短信";
                m.sender = it.address == null ? "" : it.address;
                m.title = m.sender;
                m.text = it.body == null ? "" : it.body;
                m.slot = -1;
                Db.get(c).enqueue(m);
                n++;
            }
            Config.setLastSmsTs(c, newest);
            if (n > 0) {
                Log.i(Net.TAG, "backfilled " + n + " sms");
                PushService.wake(c);
            }
        } catch (Throwable t) {
            Log.w(Net.TAG, "SmsBackfill: " + t);
        }
    }
}
