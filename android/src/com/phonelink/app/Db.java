package com.phonelink.app;

import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteOpenHelper;

import java.util.ArrayList;
import java.util.List;

/** Durable outbox: messages survive reboots and offline periods until the PC acks them. */
public final class Db extends SQLiteOpenHelper {

    private static final String NAME = "phonelink.db";
    private static final int VER = 1;
    private static volatile Db sInstance;

    public static synchronized Db get(Context c) {
        if (sInstance == null) sInstance = new Db(c.getApplicationContext());
        return sInstance;
    }

    private Db(Context c) {
        super(c, NAME, null, VER);
    }

    @Override
    public void onCreate(SQLiteDatabase d) {
        d.execSQL("CREATE TABLE outbox ("
                + "id TEXT PRIMARY KEY, "
                + "payload TEXT NOT NULL, "
                + "ts INTEGER NOT NULL, "
                + "tries INTEGER NOT NULL DEFAULT 0)");
        d.execSQL("CREATE INDEX idx_outbox_ts ON outbox(ts)");
    }

    @Override
    public void onUpgrade(SQLiteDatabase d, int oldV, int newV) {
        d.execSQL("DROP TABLE IF EXISTS outbox");
        onCreate(d);
    }

    public static final class Row {
        public String id;
        public String payload;
    }

    /** Insert a message. Silently ignores duplicates and DB errors. */
    public void enqueue(Msg m) {
        try {
            ContentValues v = new ContentValues();
            v.put("id", m.id);
            v.put("payload", m.json());
            v.put("ts", m.ts);
            v.put("tries", 0);
            getWritableDatabase().insertWithOnConflict("outbox", null, v, SQLiteDatabase.CONFLICT_IGNORE);
        } catch (Throwable t) {
            android.util.Log.w(Net.TAG, "enqueue failed: " + t);
        }
    }

    public int count() {
        Cursor c = null;
        try {
            c = getReadableDatabase().rawQuery("SELECT COUNT(*) FROM outbox", null);
            return c.moveToFirst() ? c.getInt(0) : 0;
        } catch (Throwable t) {
            return 0;
        } finally {
            if (c != null) c.close();
        }
    }

    public List<Row> peek(int limit) {
        List<Row> out = new ArrayList<Row>();
        Cursor c = null;
        try {
            c = getReadableDatabase().rawQuery(
                    "SELECT id, payload FROM outbox ORDER BY ts ASC LIMIT " + limit, null);
            while (c.moveToNext()) {
                Row r = new Row();
                r.id = c.getString(0);
                r.payload = c.getString(1);
                out.add(r);
            }
        } catch (Throwable t) {
            android.util.Log.w(Net.TAG, "peek failed: " + t);
        } finally {
            if (c != null) c.close();
        }
        return out;
    }

    public void ack(List<String> ids) {
        if (ids.isEmpty()) return;
        try {
            SQLiteDatabase d = getWritableDatabase();
            d.beginTransaction();
            try {
                for (String id : ids) {
                    d.delete("outbox", "id=?", new String[]{id});
                }
                d.setTransactionSuccessful();
            } finally {
                d.endTransaction();
            }
        } catch (Throwable t) {
            android.util.Log.w(Net.TAG, "ack failed: " + t);
        }
    }

    public void bumpTries(List<String> ids) {
        if (ids.isEmpty()) return;
        try {
            SQLiteDatabase d = getWritableDatabase();
            d.beginTransaction();
            try {
                for (String id : ids) {
                    d.execSQL("UPDATE outbox SET tries = tries + 1 WHERE id = ?", new Object[]{id});
                }
                d.setTransactionSuccessful();
            } finally {
                d.endTransaction();
            }
        } catch (Throwable t) {
            android.util.Log.w(Net.TAG, "bumpTries failed: " + t);
        }
    }

    /** Drop anything older than maxAgeMs so a broken link cannot grow the DB forever. */
    public void prune(long maxAgeMs) {
        try {
            long cutoff = System.currentTimeMillis() - maxAgeMs;
            getWritableDatabase().execSQL("DELETE FROM outbox WHERE ts > 0 AND ts < " + cutoff);
        } catch (Throwable ignored) {
        }
    }
}
