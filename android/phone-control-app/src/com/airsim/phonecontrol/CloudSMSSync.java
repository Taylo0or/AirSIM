package com.airsim.phonecontrol;

import android.content.Context;

import org.json.JSONObject;

/**
 * Answers the iPhone's "sms_sync" cloud command: the SMS this Agent still retains after a
 * cursor (a delivery ID), in the exact shape of an APNs SMS push so the iPhone reuses its
 * push parser. With an E2E key every message is sealed, so the Relay sees ciphertext only.
 * An unknown cursor (pruned after a local fetch) restarts from the oldest retained SMS;
 * the iPhone deduplicates by delivery ID.
 */
final class CloudSMSSync {
    private CloudSMSSync() {}

    static JSONObject batch(Context context, String since) throws Exception {
        JSONObject registration = new StandaloneAgentStore(context).registration();
        if (registration == null) throw new IllegalStateException("agent is not registered");
        byte[] key = E2EKeyStore.forRegistration(context, registration);
        JSONObject identity = new JSONObject().put("device_id", registration.getString("device_id"))
                .put("agent_id", registration.optString("android_agent_id", ""));
        return CloudSMSSyncBatch.build(new StandaloneSMSStore(context).syncMessages(), since, identity,
                key == null ? null : E2ESMSCrypto.keys(key), System.currentTimeMillis());
    }
}
