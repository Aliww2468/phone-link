package com.phonelink.app;

import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.text.InputType;
import android.util.Log;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

/** Minimal one-time setup screen. After it is configured the user never needs to open it again. */
public class MainActivity extends Activity {

    private static final int REQ_SMS = 1001;

    private EditText eHost;
    private EditText ePort;
    private EditText eToken;
    private CheckBox cSms;
    private CheckBox cNotif;
    private CheckBox cOnlyText;
    private CheckBox cAuto;
    private TextView tvStatus;
    private TextView tvPerms;

    private final Handler ui = new Handler(Looper.getMainLooper());

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        setTitle("PhoneLink 设置");
        setContentView(buildUi());
        loadValues();
        refresh();
        // Setup may have been written straight into our prefs by install.ps1 (adb).
        // In that case bring the relay up immediately without any further interaction.
        autostartIfConfigured();
    }

    private void autostartIfConfigured() {
        try {
            Config.Cfg cfg = Config.load(this);
            if (cfg.enabled && cfg.host.length() > 0 && !PushService.isRunning()) {
                PushService.start(this);
                WatchdogJob.schedule(this);
                Thread t = new Thread(new Runnable() {
                    @Override
                    public void run() {
                        SmsBackfill.run(MainActivity.this);
                    }
                }, "phonelink-backfill");
                t.setDaemon(true);
                t.start();
            }
        } catch (Throwable t) {
            Log.w(Net.TAG, "autostart: " + t);
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        refresh();
    }

    // ------------------------------------------------------------------ UI

    private int dp(float v) {
        return (int) (v * getResources().getDisplayMetrics().density + 0.5f);
    }

    private TextView label(String s) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setPadding(0, dp(10), 0, dp(2));
        return t;
    }

    private Button button(String s, View.OnClickListener l) {
        Button b = new Button(this);
        b.setText(s);
        b.setAllCaps(false);
        b.setOnClickListener(l);
        return b;
    }

    private View buildUi() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(16), dp(8), dp(16), dp(24));

        tvStatus = new TextView(this);
        tvStatus.setTextSize(13);
        tvStatus.setPadding(dp(10), dp(10), dp(10), dp(10));
        root.addView(tvStatus);

        root.addView(label("电脑地址（IP）"));
        eHost = new EditText(this);
        eHost.setInputType(InputType.TYPE_CLASS_TEXT);
        eHost.setHint("例如 192.168.1.10");
        root.addView(eHost);

        root.addView(label("电脑端口"));
        ePort = new EditText(this);
        ePort.setInputType(InputType.TYPE_CLASS_NUMBER);
        ePort.setHint("8787");
        root.addView(ePort);

        root.addView(label("配对令牌（电脑屏幕上显示的那串，可留空）"));
        eToken = new EditText(this);
        eToken.setInputType(InputType.TYPE_CLASS_TEXT);
        root.addView(eToken);

        cSms = new CheckBox(this);
        cSms.setText("同步短信（完整内容）");
        cSms.setChecked(true);
        root.addView(cSms);

        cNotif = new CheckBox(this);
        cNotif.setText("同步所有 App 通知（微信 / QQ / 其他）");
        cNotif.setChecked(true);
        root.addView(cNotif);

        cOnlyText = new CheckBox(this);
        cOnlyText.setText("跳过没有文字的通知（如纯图标提示）");
        cOnlyText.setChecked(true);
        root.addView(cOnlyText);

        cAuto = new CheckBox(this);
        cAuto.setText("地址失效时自动搜索电脑");
        cAuto.setChecked(true);
        root.addView(cAuto);

        root.addView(button("① 自动搜索电脑", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                doDiscover();
            }
        }));
        root.addView(button("② 测试连接", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                doTest();
            }
        }));
        root.addView(button("③ 保存并开启同步", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                saveAndStart();
            }
        }));
        root.addView(button("停止同步", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                stopAll();
            }
        }));

        tvPerms = new TextView(this);
        tvPerms.setTextSize(13);
        tvPerms.setPadding(0, dp(14), 0, dp(4));
        root.addView(tvPerms);

        root.addView(button("打开「通知使用权」设置", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                openNotifAccess();
            }
        }));
        root.addView(button("申请短信权限", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                requestSms();
            }
        }));
        root.addView(button("加入电池优化白名单", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                requestBattery();
            }
        }));
        root.addView(button("打开荣耀「应用启动管理」", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                openStartupManager();
            }
        }));

        TextView tip = new TextView(this);
        tip.setTextSize(12);
        tip.setPadding(0, dp(16), 0, 0);
        tip.setText("荣耀手机请务必到「设置 → 应用 → 应用启动管理」把 PhoneLink 设为"
                + "「手动管理」并勾选全部三项（自启动 / 关联启动 / 后台活动），"
                + "否则系统会在锁屏后杀掉同步服务。");
        root.addView(tip);

        ScrollView sv = new ScrollView(this);
        sv.addView(root, new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        return sv;
    }

    private void toast(final String s) {
        ui.post(new Runnable() {
            @Override
            public void run() {
                Toast.makeText(MainActivity.this, s, Toast.LENGTH_SHORT).show();
                refresh();
            }
        });
    }

    // ------------------------------------------------------------------ state

    private void loadValues() {
        Config.Cfg cfg = Config.load(this);
        eHost.setText(cfg.host);
        ePort.setText(String.valueOf(cfg.port));
        eToken.setText(cfg.token);
        cSms.setChecked(cfg.sms);
        cNotif.setChecked(cfg.notif);
        cOnlyText.setChecked(cfg.onlyWithText);
        cAuto.setChecked(cfg.autoDiscover);
    }

    private void refresh() {
        Config.Cfg cfg = Config.load(this);
        int queued = Db.get(this).count();
        String s = "状态：" + (cfg.enabled ? "已开启" : "未开启")
                + "\n后台服务：" + (PushService.isRunning() ? "运行中" : "未运行")
                + "\n待发送：" + queued + " 条"
                + "\n累计已发送：" + Config.sentCount(this)
                + "\n最近结果：" + Config.lastResult(this);
        tvStatus.setText(s);

        String n = notifAccess() ? "已授权" : "未授权";
        String sm = hasSms() ? "已授权" : "未授权";
        tvPerms.setText("权限自检：通知使用权 " + n + "　短信 " + sm
                + "\n（用电脑上的 install.ps1 通过数据线安装时会自动授权，无需手动操作）");
    }

    private boolean notifAccess() {
        try {
            String flat = Settings.Secure.getString(getContentResolver(), "enabled_notification_listeners");
            return flat != null && flat.contains(getPackageName());
        } catch (Throwable t) {
            return false;
        }
    }

    private boolean hasSms() {
        return checkSelfPermission(android.Manifest.permission.RECEIVE_SMS) == PackageManager.PERMISSION_GRANTED;
    }

    // ------------------------------------------------------------------ actions

    private Config.Cfg readForm() {
        Config.Cfg cfg = Config.load(this);
        cfg.host = eHost.getText().toString().trim();
        try {
            cfg.port = Integer.parseInt(ePort.getText().toString().trim());
        } catch (Throwable t) {
            cfg.port = 8787;
        }
        cfg.token = eToken.getText().toString().trim();
        cfg.sms = cSms.isChecked();
        cfg.notif = cNotif.isChecked();
        cfg.onlyWithText = cOnlyText.isChecked();
        cfg.autoDiscover = cAuto.isChecked();
        return cfg;
    }

    private void persist(Config.Cfg cfg) {
        Config.setHost(this, cfg.host);
        Config.setPort(this, cfg.port);
        Config.setToken(this, cfg.token);
        Config.setSms(this, cfg.sms);
        Config.setNotif(this, cfg.notif);
        Config.setOnlyText(this, cfg.onlyWithText);
        Config.setAutoDiscover(this, cfg.autoDiscover);
    }

    private void doDiscover() {
        toast("正在搜索…");
        Thread t = new Thread(new Runnable() {
            @Override
            public void run() {
                final String r = Net.discover();
                ui.post(new Runnable() {
                    @Override
                    public void run() {
                        if (r == null) {
                            Toast.makeText(MainActivity.this,
                                    "没找到电脑。确认手机和电脑在同一个 WiFi，且电脑端已启动服务。",
                                    Toast.LENGTH_LONG).show();
                            return;
                        }
                        String[] p = r.split("\\|");
                        eHost.setText(p[0]);
                        if (p.length >= 2) ePort.setText(p[1]);
                        refresh();
                        Toast.makeText(MainActivity.this, "找到电脑 " + p[0], Toast.LENGTH_SHORT).show();
                    }
                });
            }
        }, "phonelink-discover");
        t.setDaemon(true);
        t.start();
    }

    private void doTest() {
        final Config.Cfg cfg = readForm();
        if (cfg.host.length() == 0) {
            toast("请先填写或搜索电脑 IP");
            return;
        }
        toast("正在测试…");
        Thread t = new Thread(new Runnable() {
            @Override
            public void run() {
                String msg;
                try {
                    String body = "{\"device\":\"" + Msg.esc(PushService.deviceName()) + "\","
                            + "\"test\":true,\"ts\":" + System.currentTimeMillis() + "}";
                    int code = Net.post(cfg, "/api/heartbeat", body);
                    if (code >= 200 && code < 300) {
                        msg = "连接成功（HTTP " + code + "）";
                    } else if (code == 401 || code == 403) {
                        msg = "连上了，但配对令牌不对（HTTP " + code + "）";
                    } else {
                        msg = "电脑返回 HTTP " + code;
                    }
                } catch (Throwable e) {
                    msg = "连不上：" + e.getMessage();
                }
                final String m = msg;
                ui.post(new Runnable() {
                    @Override
                    public void run() {
                        Toast.makeText(MainActivity.this, m, Toast.LENGTH_LONG).show();
                        refresh();
                    }
                });
            }
        }, "phonelink-test");
        t.setDaemon(true);
        t.start();
    }

    private void saveAndStart() {
        Config.Cfg cfg = readForm();
        if (cfg.host.length() == 0) {
            toast("请先填写或搜索电脑 IP");
            return;
        }
        persist(cfg);
        Config.setEnabled(this, true);
        PushService.start(this);
        WatchdogJob.schedule(this);
        Thread t = new Thread(new Runnable() {
            @Override
            public void run() {
                SmsBackfill.run(MainActivity.this);
            }
        }, "phonelink-backfill");
        t.setDaemon(true);
        t.start();
        toast("已开启同步，可以退出这个界面了");
    }

    private void stopAll() {
        Config.setEnabled(this, false);
        PushService.stop(this);
        WatchdogJob.cancel(this);
        toast("已停止同步");
    }

    private void openNotifAccess() {
        try {
            Intent i = new Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS);
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(i);
        } catch (Throwable t) {
            try {
                startActivity(new Intent("android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS"));
            } catch (Throwable t2) {
                toast("打不开设置页，请手动进入：设置 → 通知 → 通知使用权");
            }
        }
    }

    private void requestSms() {
        if (Build.VERSION.SDK_INT >= 23) {
            requestPermissions(new String[]{
                    android.Manifest.permission.RECEIVE_SMS,
                    android.Manifest.permission.READ_SMS}, REQ_SMS);
        }
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] perms, int[] res) {
        super.onRequestPermissionsResult(code, perms, res);
        refresh();
        if (code == REQ_SMS) {
            boolean ok = res.length > 0 && res[0] == PackageManager.PERMISSION_GRANTED;
            Toast.makeText(this, ok ? "短信权限已授予" : "短信权限被拒绝，只能同步通知了",
                    Toast.LENGTH_LONG).show();
            if (ok) {
                Thread t = new Thread(new Runnable() {
                    @Override
                    public void run() {
                        SmsBackfill.run(MainActivity.this);
                    }
                });
                t.setDaemon(true);
                t.start();
            }
        }
    }

    private void requestBattery() {
        try {
            Intent i = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS);
            i.setData(Uri.parse("package:" + getPackageName()));
            startActivity(i);
        } catch (Throwable t) {
            try {
                startActivity(new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS));
            } catch (Throwable t2) {
                toast("请在 设置 → 电池 中手动允许后台运行");
            }
        }
    }

    private void openStartupManager() {
        String[] candidates = new String[]{
                "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
                "com.huawei.systemmanager.mainscreen.MainScreenActivity",
                "com.huawei.systemmanager.appcontrol.activity.StartupAppControlActivity",
                "com.huawei.systemmanager.optimize.process.ProtectActivity"
        };
        for (String cn : candidates) {
            try {
                Intent i = new Intent();
                i.setClassName("com.huawei.systemmanager", cn);
                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                startActivity(i);
                return;
            } catch (Throwable ignored) {
            }
        }
        try {
            Intent i = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS);
            i.setData(Uri.parse("package:" + getPackageName()));
            startActivity(i);
            Toast.makeText(this, "请在本页把「自启动 / 后台活动」全部允许", Toast.LENGTH_LONG).show();
        } catch (Throwable t) {
            toast("请手动进入 设置 → 应用 → 应用启动管理");
        }
    }
}
