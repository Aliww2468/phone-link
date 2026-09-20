package com.phonelink.app;

import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.URL;
import java.util.Locale;

/** Tiny HTTP client + UDP LAN discovery. No third-party dependencies. */
public final class Net {

    public static final String TAG = "PhoneLink";
    public static final int DISCOVERY_PORT = 8788;
    private static final String PROBE = "PHONELINK_DISCOVER_V1";
    private static final String REPLY_PREFIX = "PHONELINK|";

    private Net() {}

    private static String drain(InputStream is) throws IOException {
        if (is == null) return "";
        ByteArrayOutputStream bo = new ByteArrayOutputStream();
        byte[] buf = new byte[4096];
        int n;
        while ((n = is.read(buf)) > 0) bo.write(buf, 0, n);
        is.close();
        return new String(bo.toByteArray(), "UTF-8");
    }

    /** POST a JSON body. Returns the HTTP status, or throws IOException on transport failure. */
    public static int post(Config.Cfg cfg, String path, String body) throws IOException {
        URL u = new URL("http://" + cfg.host + ":" + cfg.port + path);
        HttpURLConnection c = (HttpURLConnection) u.openConnection();
        try {
            c.setRequestMethod("POST");
            c.setConnectTimeout(8000);
            c.setReadTimeout(20000);
            c.setDoOutput(true);
            c.setUseCaches(false);
            c.setRequestProperty("Content-Type", "application/json; charset=utf-8");
            c.setRequestProperty("User-Agent", "PhoneLink/1.0 (Android)");
            if (cfg.token != null && cfg.token.length() > 0) {
                c.setRequestProperty("X-Token", cfg.token);
            }
            byte[] data = body.getBytes("UTF-8");
            c.setFixedLengthStreamingMode(data.length);
            OutputStream os = c.getOutputStream();
            os.write(data);
            os.flush();
            os.close();
            int code = c.getResponseCode();
            try {
                drain(code >= 200 && code < 300 ? c.getInputStream() : c.getErrorStream());
            } catch (IOException ignored) {
            }
            return code;
        } finally {
            c.disconnect();
        }
    }

    /** Broadcast on the LAN and return "<ip>|<port>|<name>" of the first PC that answers, or null. */
    public static String discover() {
        DatagramSocket s = null;
        try {
            s = new DatagramSocket();
            s.setBroadcast(true);
            s.setSoTimeout(1500);
            byte[] probe = PROBE.getBytes("UTF-8");
            DatagramPacket p = new DatagramPacket(probe, probe.length,
                    InetAddress.getByName("255.255.255.255"), DISCOVERY_PORT);
            for (int i = 0; i < 3; i++) {
                s.send(p);
                try {
                    byte[] buf = new byte[512];
                    DatagramPacket r = new DatagramPacket(buf, buf.length);
                    s.receive(r);
                    String resp = new String(r.getData(), 0, r.getLength(), "UTF-8").trim();
                    if (resp.startsWith(REPLY_PREFIX)) {
                        String tail = resp.substring(REPLY_PREFIX.length());
                        String ip = r.getAddress().getHostAddress();
                        Log.i(TAG, "discover ok: " + ip + " " + tail);
                        return ip + "|" + tail;
                    }
                } catch (IOException timeout) {
                    // keep probing
                }
            }
        } catch (Throwable t) {
            Log.w(TAG, "discover failed: " + t);
        } finally {
            if (s != null) s.close();
        }
        return null;
    }

    public static String nowIso() {
        return String.format(Locale.US, "%d", System.currentTimeMillis());
    }
}
