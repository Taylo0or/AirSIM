package com.airsim.phonecontrol;

import org.json.JSONArray;
import org.json.JSONObject;

import java.nio.charset.StandardCharsets;

/** Pure batching for {@link CloudSMSSync}: cursor, paging and per-message sealing. */
final class CloudSMSSyncBatch {
    static final int MAX_MESSAGES = 40;
    /** Relay command results travel in one 64 KiB WebSocket/HTTP body. */
    static final int MAX_BYTES = 40 * 1024;

    private CloudSMSSyncBatch() {}

    static JSONObject build(JSONArray records, String since, JSONObject identity,
                            E2ESMSCrypto.Keys keys, long nowMillis) throws Exception {
        int start = 0;
        if (since != null && !since.isEmpty()) {
            for (int index = 0; index < records.length(); index++) {
                if (since.equals(records.getJSONObject(index).optString("delivery_id"))) {
                    start = index + 1;
                    break;
                }
            }
        }
        JSONArray messages = new JSONArray();
        String cursor = since == null ? "" : since;
        boolean more = false;
        int bytes = 0;
        for (int index = start; index < records.length(); index++) {
            JSONObject source = records.getJSONObject(index);
            String timestamp = CloudSMSUploader.uploadTimestamp(source.optString("timestamp", ""), nowMillis);
            JSONObject message = CloudSMSEvent.body(new JSONObject(identity.toString()), source, timestamp, keys);
            message.remove("device_id"); // identity binds the seal; it is never echoed back
            int size = message.toString().getBytes(StandardCharsets.UTF_8).length;
            if (messages.length() >= MAX_MESSAGES || (messages.length() > 0 && bytes + size > MAX_BYTES)) {
                more = true;
                break;
            }
            messages.put(message);
            bytes += size;
            cursor = source.optString("delivery_id");
        }
        return new JSONObject().put("messages", messages).put("cursor", cursor).put("more", more)
                .put("encrypted", keys != null);
    }
}
