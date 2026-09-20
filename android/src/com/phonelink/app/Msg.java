package com.phonelink.app;

import java.util.Locale;

/** A single captured message, plus a dependency-free JSON encoder. */
public final class Msg {

    public String id;
    public long ts;
    /** "sms" or "notif" */
    public String kind = "notif";
    public String pkg = "";
    public String app = "";
    public String title = "";
    public String text = "";
    public String sender = "";
    public int slot = -1;

    public static String esc(String s) {
        if (s == null) return "";
        int n = s.length();
        StringBuilder b = new StringBuilder(n + 16);
        for (int i = 0; i < n; i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"':  b.append("\\\""); break;
                case '\\': b.append("\\\\"); break;
                case '\n': b.append("\\n");  break;
                case '\r': b.append("\\r");  break;
                case '\t': b.append("\\t");  break;
                case '\b': b.append("\\b");  break;
                case '\f': b.append("\\f");  break;
                default:
                    if (c < 0x20) {
                        b.append(String.format(Locale.US, "\\u%04x", (int) c));
                    } else {
                        b.append(c);
                    }
            }
        }
        return b.toString();
    }

    private static void kv(StringBuilder b, String k, String v, boolean comma) {
        b.append('"').append(k).append("\":\"").append(esc(v)).append('"');
        if (comma) b.append(',');
    }

    /** Serialize to a flat JSON object (one line, no whitespace). */
    public String json() {
        StringBuilder b = new StringBuilder(320);
        b.append('{');
        kv(b, "id", id == null ? "" : id, true);
        b.append("\"ts\":").append(ts).append(',');
        kv(b, "kind", kind, true);
        kv(b, "pkg", pkg, true);
        kv(b, "app", app, true);
        kv(b, "title", title, true);
        kv(b, "text", text, true);
        kv(b, "sender", sender, true);
        b.append("\"slot\":").append(slot);
        b.append('}');
        return b.toString();
    }
}
