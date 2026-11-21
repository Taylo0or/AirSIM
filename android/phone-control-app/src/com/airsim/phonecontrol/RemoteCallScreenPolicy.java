package com.airsim.phonecontrol;

import java.util.regex.Pattern;

/** Only a fresh application wake belonging to a screen-off remote call is eligible. */
final class RemoteCallScreenPolicy {
    /** PowerManager.WAKE_REASON_APPLICATION, e.g. a full-screen intent or turn-screen-on activity. */
    static final int WAKE_REASON_APPLICATION = 2;

    record Wake(boolean interactive, long time, int reason) {}

    private static final Pattern TIME = Pattern.compile("(?m)^\\s*mLastWakeTime=(\\d+)");
    private static final Pattern REASON = Pattern.compile("(?m)^\\s*mLastWakeReason=(\\d+)");
    private static final Pattern AWAKE = Pattern.compile("(?m)^\\s*mWakefulness=(Awake|1)\\s*$");

    private RemoteCallScreenPolicy() {}

    /**
     * Parses {@code dumpsys power}. Android 13 builds (e.g. MIUI on the K40) do not
     * print mLastWakeReason; without it a power-button wake cannot be told apart, so
     * parsing fails closed and the screen is left alone.
     */
    static Wake parse(String dump) {
        String text = dump == null ? "" : dump;
        var t = TIME.matcher(text);
        var r = REASON.matcher(text);
        if (!t.find() || !r.find()) throw new IllegalArgumentException("wake evidence unavailable");
        return new Wake(AWAKE.matcher(text).find(), Long.parseLong(t.group(1)), Integer.parseInt(r.group(1)));
    }

    static boolean suppress(Wake wake, long since, long now) {
        // POWER_BUTTON=1, WAKE_KEY=6 and BIOMETRIC=17 must remain user-controlled.
        return wake.interactive && wake.reason == WAKE_REASON_APPLICATION && since >= 0 && since <= now
                && wake.time >= Math.max(0, since - 1500) && wake.time <= now
                && now - wake.time <= 1500;
    }

    static boolean eligible(boolean remoteSilentPaired, boolean initiallyOff, boolean recentlyAwakened) {
        return remoteSilentPaired && (initiallyOff || recentlyAwakened);
    }

    static boolean scopeAllows(boolean eligible, boolean owned, int liveCalls, boolean terminalGrace) {
        return eligible && owned && (terminalGrace ? liveCalls == 0 : liveCalls == 1);
    }
}
