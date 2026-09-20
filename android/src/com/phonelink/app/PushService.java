package com.phonelink.app;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * Always-on relay. Holds a single low-importance foreground notification, drains the durable
 * outbox to the paired PC, and re-discovers the PC when its address changes.
 */
public class PushService extends Service {

    public static final String ACTION_WAKE = "com.phonelink.app.action.WAKE";
    public static final String ACTION_STOP = "com.phonelink.app.action.STOP";

    private static final String CH_ID = "phonelink_service";
    private static final int NOTI_ID = 0x504C;
    private static final long HEARTBEAT_MS = 5 * 60 * 1000L;
    private static final long MAX_AGE_MS = 7L * 24 * 3600 * 1000;

    private static volatile PushService sInstance;
    private static volatile boolean sRunning;

    private final Object wake = new Object();
    private volatile boolean alive;
    private Thread worker;
    private long lastBeat;
    private long lastDiscover;

    public static boolean isRunning() {
        return sRunning;
    }

    public static void start(Context c) {
        Intent i = new Intent(c, PushService.class);
        try {
            if (Build.VERSION.SDK_INT >= 26) c.startForegroundService(i);
            else c.startService(i);
        } catch (Throwable t) {
            Log.w(Net.TAG, "cannot start service: " + t);
        }
    }

    public static void stop(Context c) {
        try {
            c.stopService(new Intent(c, PushService.class));
        } catch (Throwable ignored) {
        }
    }

    /** Nudge the drain loop right after a new message lands. Safe from any thread. */
    public static void wake(Context c) {
        PushService s = sInstance;
        if (s != null) {
            synchronized (s.wake) {
                s.wake.notifyAll();
            }
        } else if (Config.load(c).enabled) {
            start(c);
        }
    }

    @Override
    public void onCreate() {
        super.onCreate();
        sInstance = this;
        sRunning = true;
        alive = true;
        foreground();
        worker = new Thread(new Runnable() {
            @Override
            public void run() {
                loop();
            }
        }, "phonelink-push");
        worker.setDaemon(true);
        worker.start();
        Log.i(Net.TAG, "service started");
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && ACTION_STOP.equals(intent.getAction())) {
            alive = false;
            stopSelf();
            return START_NOT_STICKY;
        }
        foreground();
        synchronized (wake) {
            wake.notifyAll();
        }
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        alive = false;
        sRunning = false;
        sInstance = null;
        synchronized (wake) {
            wake.notifyAll();
        }
        Log.i(Net.TAG, "service stopped");
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    // ---------------------------------------------------------------- foreground

    private void foreground() {
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= 26 && nm != null) {
            NotificationChannel ch = new NotificationChannel(CH_ID, "消息同步", NotificationManager.IMPORTANCE_MIN);
            ch.setDescription("常驻后台，把手机消息转发到电脑");
            ch.enableLights(false);
            ch.enableVibration(false);
            ch.setShowBadge(false);
            ch.setSound(null, null);
            nm.createNotificationChannel(ch);
        }
        Intent open = new Intent(this, MainActivity.class);
        int piFlags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= 23) piFlags |= PendingIntent.FLAG_IMMUTABLE;
        PendingIntent pi = PendingIntent.getActivity(this, 0, open, piFlags);

        Notification.Builder b = (Build.VERSION.SDK_INT >= 26)
                ? new Notification.Builder(this, CH_ID)
                : new Notification.Builder(this);
        b.setContentTitle("PhoneLink")
                .setContentText("消息同步运行中")
                .setSmallIcon(android.R.drawable.stat_notify_sync)
                .setContentIntent(pi)
                .setOngoing(true);
        // IMPORTANCE_MIN plus null sound/vibration already makes this fully silent.
        b.setSound(null);
        b.setVibrate(null);
        b.setDefaults(0);
        startForeground(NOTI_ID, b.build());
    }

    // ---------------------------------------------------------------- main loop

    private void loop() {
        while (alive) {
            Config.Cfg cfg = Config.load(this);
            int pending = 0;
            boolean ok = true;
            try {
                if (cfg.enabled) {
                    Db.get(this).prune(MAX_AGE_MS);
                    pending = Db.get(this).count();
                    if (pending > 0) {
                        ok = drain(cfg);
                    }
                }
            } catch (Throwable t) {
                Log.w(Net.TAG, "loop error: " + t);
                ok = false;
            }

            long now = System.currentTimeMillis();
            if (cfg.enabled && now - lastBeat > HEARTBEAT_MS) {
                lastBeat = now;
                try {
                    beat(cfg);
                } catch (Throwable ignored) {
                }
            }

            long waitMs;
            if (!cfg.enabled) waitMs = 30000L;
            else if (pending > 0) waitMs = ok ? 1500L : 15000L;
            else waitMs = 30000L;

            synchronized (wake) {
                if (!alive) break;
                try {
                    wake.wait(waitMs);
                } catch (InterruptedException e) {
                    break;
                }
            }
        }
    }

    private boolean drain(Config.Cfg cfg) {
        List<Db.Row> rows = Db.get(this).peek(50);
        if (rows.isEmpty()) return true;

        StringBuilder b = new StringBuilder(512 + rows.size() * 220);
        b.append("{\"device\":\"").append(Msg.esc(deviceName())).append("\",\"messages\":[");
        List<String> ids = new ArrayList<String>(rows.size());
        for (int i = 0; i < rows.size(); i++) {
            if (i > 0) b.append(',');
            b.append(rows.get(i).payload);
            ids.add(rows.get(i).id);
        }
        b.append("]}");

        int code;
        try {
            code = Net.post(cfg, "/api/messages", b.toString());
        } catch (IOException e) {
            Db.get(this).bumpTries(ids);
            note("电脑不可达：" + e.getMessage());
            if (cfg.autoDiscover) tryRediscover();
            return false;
        }

        if (code >= 200 && code < 300) {
            Db.get(this).ack(ids);
            Config.addSent(this, ids.size());
            note("已推送 " + ids.size() + " 条 → " + cfg.host);
            return true;
        }

        Db.get(this).bumpTries(ids);
        if (code == 401 || code == 403) {
            note("电脑拒绝：配对令牌不正确 (HTTP " + code + ")");
        } else {
            note("电脑返回 HTTP " + code);
        }
        return false;
    }

    private void beat(Config.Cfg cfg) {
        int level = -1;
        try {
            IntentFilter f = new IntentFilter(Intent.ACTION_BATTERY_CHANGED);
            Intent s = registerReceiver(null, f);
            if (s != null) {
                int raw = s.getIntExtra("level", -1);
                int scale = s.getIntExtra("scale", 100);
                if (raw >= 0 && scale > 0) level = raw * 100 / scale;
            }
        } catch (Throwable ignored) {
        }
        int queued = Db.get(this).count();
        String body = "{\"device\":\"" + Msg.esc(deviceName()) + "\","
                + "\"battery\":" + level + ","
                + "\"queued\":" + queued + ","
                + "\"sent\":" + Config.sentCount(this) + ","
                + "\"ts\":" + System.currentTimeMillis() + "}";
        try {
            int code = Net.post(cfg, "/api/heartbeat", body);
            if (code >= 200 && code < 300) {
                Log.i(Net.TAG, "heartbeat ok");
            }
        } catch (IOException e) {
            Log.i(Net.TAG, "heartbeat failed: " + e.getMessage());
        }
    }

    private void tryRediscover() {
        long now = System.currentTimeMillis();
        if (now - lastDiscover < 60000L) return;
        lastDiscover = now;
        String d = Net.discover();
        if (d == null) return;
        String[] parts = d.split("\\|");
        if (parts.length >= 2) {
            Config.setHost(this, parts[0]);
            try {
                Config.setPort(this, Integer.parseInt(parts[1]));
            } catch (NumberFormatException ignored) {
            }
            String name = parts.length >= 3 ? parts[2] : "";
            note("自动发现电脑 " + parts[0] + ":" + parts[1] + (name.length() > 0 ? " (" + name + ")" : ""));
        }
    }

    private void note(String s) {
        Log.i(Net.TAG, s);
        Config.setLastResult(this, String.format(Locale.US, "%1$tH:%1$tM:%1$tS  ", System.currentTimeMillis()) + s);
    }

    static String deviceName() {
        String brand = Build.BRAND == null ? "" : Build.BRAND;
        String model = Build.MODEL == null ? "" : Build.MODEL;
        String s = (brand + " " + model).trim();
        return s.length() == 0 ? "Android" : s;
    }
}
