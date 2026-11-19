package com.airsim.phonecontrol;

import android.app.Notification;
import android.content.ComponentName;
import android.content.Context;
import android.os.Bundle;
import android.provider.Settings;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;

import org.json.JSONObject;

import java.time.Instant;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

/**
 * MIUI does not reliably deliver SMS to a non-default app. With user-granted
 * notification access, forward only MIUI Messages notifications to the same
 * SMS event pipeline so replies appear on the iPhone. No other app is read.
 */
public final class SmsNotificationListenerService extends NotificationListenerService {
    private static final String MIUI_MESSAGES = "com.android.mms";
    private static final long DEDUPE_MS = 5L * 60L * 1_000L;
    private static final Map<String, Long> RECENT = new ConcurrentHashMap<>();
    /** The SMS broadcast and inbox scan normally land within a second of the notification. */
    private static final long BROADCAST_GRACE_MS = 6_000L;
    private static final ScheduledExecutorService FORWARDER = Executors.newSingleThreadScheduledExecutor();

    static boolean isEnabled(Context context) {
        String enabled = Settings.Secure.getString(context.getContentResolver(),
                "enabled_notification_listeners");
        if (enabled == null) return false;
        ComponentName component = new ComponentName(context, SmsNotificationListenerService.class);
        return enabled.contains(component.flattenToString())
                || enabled.contains(component.flattenToShortString());
    }

    @Override public void onNotificationPosted(StatusBarNotification sbn) {
        if (sbn == null || sbn.isOngoing() || !MIUI_MESSAGES.equals(sbn.getPackageName())) return;
        Notification notification = sbn.getNotification();
        if (notification == null || notification.extras == null) return;
        Bundle extras = notification.extras;
        String sender = text(extras.getCharSequence(Notification.EXTRA_TITLE));
        String body = text(extras.getCharSequence(Notification.EXTRA_TEXT));
        if (sender.isEmpty() || body.isEmpty()) return;
        if (!isActualMessageNotification(notification, sender, body)) return;
        String key = sender + "\u0000" + body;
        long now = System.currentTimeMillis();
        RECENT.entrySet().removeIf(entry -> entry.getValue() < now - DEDUPE_MS);
        Long previous = RECENT.putIfAbsent(key, now);
        if (previous != null) return;
        long timestamp = sbn.getPostTime() > 0 ? sbn.getPostTime() : now;
        Context context = getApplicationContext();
        // Fallback only: when the SMS broadcast / inbox scan works they store the same SMS
        // under a different delivery ID (carrier time vs. post time, decorated text), which
        // showed every SMS twice on the iPhone. Let them land first, then skip their copy.
        FORWARDER.schedule(() -> forward(context, sender, body, timestamp),
                BROADCAST_GRACE_MS, TimeUnit.MILLISECONDS);
    }

    private static void forward(Context context, String sender, String body, long timestamp) {
        try {
            if (new StandaloneSMSStore(context).hasBroadcastCopy(sender, body, timestamp)) {
                BridgeLog.info("sms_notification_skipped_broadcast_copy");
                return;
            }
            String deliveryID = SMSDeliveryIdentity.id(StandaloneAgentStore.currentE2EKey(context), sender, body, timestamp);
            JSONObject event = new JSONObject(WireJson.smsEvent(UUID.randomUUID().toString(),
                    deliveryID, sender, body, Instant.ofEpochMilli(timestamp).toString()));
            StandaloneAgentGateway.get(context).sendSMSEvent(event.toString());
            BridgeLog.info("sms_notification_received");
        } catch (Exception error) {
            BridgeLog.error("sms_notification_failed", error);
        }
    }

    @Override public void onNotificationRemoved(StatusBarNotification sbn) {}

    private static boolean isActualMessageNotification(
            Notification notification, String sender, String body) {
        if (sender.contains("正在运行") || body.contains("点按即可了解详情或停止应用")) {
            return false;
        }
        String channel = notification.getChannelId();
        if (channel != null && channel.startsWith("Channel_Msg")) return true;
        return Notification.CATEGORY_MESSAGE.equals(notification.category);
    }

    private static String text(CharSequence value) {
        return value == null ? "" : value.toString().trim();
    }
}

