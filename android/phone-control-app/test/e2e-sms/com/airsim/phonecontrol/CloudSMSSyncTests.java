package com.airsim.phonecontrol;

import org.json.JSONArray;
import org.json.JSONObject;

public final class CloudSMSSyncTests {
    private static int cases;
    private static final byte[] KEY = new byte[32];
    private static final long NOW = 1_800_000_000_000L;

    public static void main(String[] args) throws Exception {
        plaintextBatchCarriesNoIdentitySecrets();
        cursorResumesAfterLastDelivery();
        unknownCursorRestartsFromOldest();
        pagesByCountAndBytes();
        sealedBatchHasNoPlaintext();
        System.out.println("Cloud SMS sync tests passed: " + cases + " cases");
    }

    private static JSONArray records(int count, int contentLength) throws Exception {
        JSONArray records = new JSONArray();
        for (int index = 1; index <= count; index++) {
            records.put(new JSONObject().put("delivery_id", "d" + index).put("sender", "10086")
                    .put("content", "短".repeat(contentLength)).put("sim_slot", "SIM 1")
                    .put("timestamp", "2026-11-19T20:00:0" + (index % 10) + "Z"));
        }
        return records;
    }

    private static JSONObject identity() throws Exception {
        return new JSONObject().put("device_id", "device-1").put("agent_id", "android-A");
    }

    private static void plaintextBatchCarriesNoIdentitySecrets() throws Exception {
        JSONObject batch = CloudSMSSyncBatch.build(records(3, 4), "", identity(), null, NOW);
        JSONArray messages = batch.getJSONArray("messages");
        check(messages.length() == 3 && "d3".equals(batch.getString("cursor")) && !batch.getBoolean("more"),
                "plaintext batch returns every retained SMS");
        check(!batch.getBoolean("encrypted"), "batch without key is marked plaintext");
        JSONObject first = messages.getJSONObject(0);
        check("incoming_sms".equals(first.getString("event")) && "android-A".equals(first.getString("agent_id"))
                && "d1".equals(first.getString("delivery_id")) && "10086".equals(first.getString("sender")),
                "each item has the APNs SMS push shape");
        check(!first.has("device_id") && !first.has("device_secret"), "no pairing identity is echoed");
    }

    private static void cursorResumesAfterLastDelivery() throws Exception {
        JSONObject batch = CloudSMSSyncBatch.build(records(3, 4), "d1", identity(), null, NOW);
        JSONArray messages = batch.getJSONArray("messages");
        check(messages.length() == 2 && "d2".equals(messages.getJSONObject(0).getString("delivery_id")),
                "cursor resumes after its delivery ID");
        JSONObject done = CloudSMSSyncBatch.build(records(3, 4), "d3", identity(), null, NOW);
        check(done.getJSONArray("messages").length() == 0 && "d3".equals(done.getString("cursor"))
                && !done.getBoolean("more"), "an up-to-date cursor returns nothing and keeps its place");
    }

    private static void unknownCursorRestartsFromOldest() throws Exception {
        JSONObject batch = CloudSMSSyncBatch.build(records(3, 4), "pruned-id", identity(), null, NOW);
        check(batch.getJSONArray("messages").length() == 3, "a pruned cursor restarts from the oldest SMS");
    }

    private static void pagesByCountAndBytes() throws Exception {
        JSONObject first = CloudSMSSyncBatch.build(records(45, 4), "", identity(), null, NOW);
        check(first.getJSONArray("messages").length() == CloudSMSSyncBatch.MAX_MESSAGES && first.getBoolean("more")
                && "d40".equals(first.getString("cursor")), "count limit pages the batch");
        JSONObject second = CloudSMSSyncBatch.build(records(45, 4), first.getString("cursor"), identity(), null, NOW);
        check(second.getJSONArray("messages").length() == 5 && !second.getBoolean("more"), "next page finishes");
        JSONObject large = CloudSMSSyncBatch.build(records(30, 1_000), "", identity(), null, NOW);
        int bytes = large.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8).length;
        check(large.getBoolean("more") && large.getJSONArray("messages").length() < 30 && bytes < 60 * 1024,
                "byte budget keeps one result under the Relay's 64 KiB body limit");
    }

    private static void sealedBatchHasNoPlaintext() throws Exception {
        JSONObject batch = CloudSMSSyncBatch.build(records(2, 4), "", identity(), E2ESMSCrypto.keys(KEY), NOW);
        check(batch.getBoolean("encrypted"), "keyed batch is marked encrypted");
        JSONObject first = batch.getJSONArray("messages").getJSONObject(0);
        check(first.has("e2e") && !first.has("content") && !first.has("sender") && !first.has("sim_slot"),
                "sealed items carry only the envelope");
        check(!batch.toString().contains("10086") && !batch.toString().contains("短"), "no plaintext anywhere");
    }

    private static void check(boolean condition, String message) {
        cases++;
        if (!condition) throw new AssertionError(message);
    }
}
