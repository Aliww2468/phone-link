package com.phonelink.app;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

/** Silent auto-start: brings the relay back up after reboot, update or first unlock. */
public class BootReceiver extends BroadcastReceiver {

    @Override
    public void onReceive(Context c, Intent intent) {
        try {
            String action = intent == null ? null : intent.getAction();
            Config.Cfg cfg = Config.load(c);
            Log.i(Net.TAG, "boot event " + action + " enabled=" + cfg.enabled);
            if (!cfg.enabled) return;

            PushService.start(c);
            WatchdogJob.schedule(c);

            final Context app = c.getApplicationContext();
            Thread t = new Thread(new Runnable() {
                @Override
                public void run() {
                    SmsBackfill.run(app);
                }
            }, "phonelink-backfill");
            t.setDaemon(true);
            t.start();
        } catch (Throwable t) {
            Log.w(Net.TAG, "BootReceiver: " + t);
        }
    }
}
