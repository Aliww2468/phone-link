package com.phonelink.app;

import android.content.Context;
import android.content.SharedPreferences;

/** SharedPreferences-backed settings. */
public final class Config {

    private static final String FILE = "phonelink";

    private Config() {}

    public static SharedPreferences sp(Context c) {
        return c.getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }

    public static final class Cfg {
        public String host;
        public int port;
        public String token;
        public boolean sms;
        public boolean notif;
        public boolean onlyWithText;
        public boolean autoDiscover;
        public boolean enabled;
    }

    public static Cfg load(Context c) {
        SharedPreferences p = sp(c);
        Cfg f = new Cfg();
        f.host = p.getString("host", "");
        f.port = p.getInt("port", 8787);
        f.token = p.getString("token", "");
        f.sms = p.getBoolean("sms", true);
        f.notif = p.getBoolean("notif", true);
        f.onlyWithText = p.getBoolean("onlyText", true);
        f.autoDiscover = p.getBoolean("autoDiscover", true);
        f.enabled = p.getBoolean("enabled", false);
        return f;
    }

    public static void setHost(Context c, String v) { sp(c).edit().putString("host", v == null ? "" : v.trim()).apply(); }
    public static void setPort(Context c, int v) { sp(c).edit().putInt("port", v).apply(); }
    public static void setToken(Context c, String v) { sp(c).edit().putString("token", v == null ? "" : v.trim()).apply(); }
    public static void setSms(Context c, boolean v) { sp(c).edit().putBoolean("sms", v).apply(); }
    public static void setNotif(Context c, boolean v) { sp(c).edit().putBoolean("notif", v).apply(); }
    public static void setOnlyText(Context c, boolean v) { sp(c).edit().putBoolean("onlyText", v).apply(); }
    public static void setAutoDiscover(Context c, boolean v) { sp(c).edit().putBoolean("autoDiscover", v).apply(); }
    public static void setEnabled(Context c, boolean v) { sp(c).edit().putBoolean("enabled", v).apply(); }

    public static long lastSmsTs(Context c) { return sp(c).getLong("lastSmsTs", 0L); }
    public static void setLastSmsTs(Context c, long v) { sp(c).edit().putLong("lastSmsTs", v).apply(); }

    public static String lastResult(Context c) { return sp(c).getString("lastResult", "尚未推送"); }
    public static void setLastResult(Context c, String v) { sp(c).edit().putString("lastResult", v).apply(); }

    public static long sentCount(Context c) { return sp(c).getLong("sentCount", 0L); }
    public static void addSent(Context c, long n) { sp(c).edit().putLong("sentCount", sentCount(c) + n).apply(); }
}
