package com.phonelink.app;

import android.app.job.JobInfo;
import android.app.job.JobParameters;
import android.app.job.JobScheduler;
import android.app.job.JobService;
import android.content.ComponentName;
import android.content.Context;
import android.util.Log;

/**
 * Doze-safe watchdog. Chinese OEM ROMs kill background processes aggressively; this persisted
 * job re-arms the relay without any user-visible action.
 */
public class WatchdogJob extends JobService {

    private static final int JOB_ID = 0x504C;

    @Override
    public boolean onStartJob(JobParameters params) {
        try {
            Config.Cfg cfg = Config.load(this);
            if (cfg.enabled && !PushService.isRunning()) {
                Log.i(Net.TAG, "watchdog restarting relay");
                PushService.start(this);
            }
        } catch (Throwable t) {
            Log.w(Net.TAG, "watchdog: " + t);
        }
        jobFinished(params, false);
        return false;
    }

    @Override
    public boolean onStopJob(JobParameters params) {
        return true;
    }

    public static void schedule(Context c) {
        try {
            JobScheduler js = (JobScheduler) c.getSystemService(Context.JOB_SCHEDULER_SERVICE);
            if (js == null) return;
            JobInfo info = new JobInfo.Builder(JOB_ID, new ComponentName(c, WatchdogJob.class))
                    .setPersisted(true)
                    .setPeriodic(15 * 60 * 1000L)
                    .build();
            js.schedule(info);
        } catch (Throwable t) {
            Log.w(Net.TAG, "schedule watchdog: " + t);
        }
    }

    public static void cancel(Context c) {
        try {
            JobScheduler js = (JobScheduler) c.getSystemService(Context.JOB_SCHEDULER_SERVICE);
            if (js != null) js.cancel(JOB_ID);
        } catch (Throwable ignored) {
        }
    }
}
