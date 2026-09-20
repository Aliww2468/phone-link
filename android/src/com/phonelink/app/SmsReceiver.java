package com.phonelink.app;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.provider.Telephony;
import android.telephony.SmsMessage;
import android.util.Log;

import java.util.UUID;

/** Captures inbound SMS directly from the radio broadcast (full text, no truncation). */
public class SmsReceiver extends BroadcastReceiver {

    @Override
    public void onReceive(Context c, Intent intent) {
        try {
            if (intent == null) return;
            if (!Telephony.Sms.Intents.SMS_RECEIVED_ACTION.equals(intent.getAction())) return;

            Config.Cfg cfg = Config.load(c);
            if (!cfg.enabled || !cfg.sms) return;

            SmsMessage[] parts = Telephony.Sms.Intents.getMessagesFromIntent(intent);
            if (parts == null || parts.length == 0) return;

            String sender = null;
            StringBuilder body = new StringBuilder();
            long ts = 0;
            for (SmsMessage p : parts) {
                if (p == null) continue;
                if (sender == null) sender = p.getDisplayOriginatingAddress();
                String b = p.getDisplayMessageBody();
                if (b != null) body.append(b);
                if (p.getTimestampMillis() > ts) ts = p.getTimestampMillis();
            }
            if (ts <= 0) ts = System.currentTimeMillis();

            int slot = intent.getIntExtra("slot", -1);
            if (slot < 0) slot = intent.getIntExtra("subscription", -1);

            Msg m = new Msg();
            m.id = UUID.randomUUID().toString();
            m.ts = ts;
            m.kind = "sms";
            m.pkg = "sms";
            m.app = "短信";
            m.sender = sender == null ? "" : sender;
            m.title = m.sender;
            m.text = body.toString();
            m.slot = slot;

            Db.get(c).enqueue(m);
            Config.setLastSmsTs(c, ts);
            PushService.wake(c);
            Log.i(Net.TAG, "sms from " + m.sender);
        } catch (Throwable t) {
            Log.w(Net.TAG, "SmsReceiver: " + t);
        }
    }
}
