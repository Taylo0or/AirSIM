package com.airsim.phonecontrol;

final class RemoteCallScreenGuard {
    private static final RemoteCallScreenGuard INSTANCE = new RemoteCallScreenGuard();
    static RemoteCallScreenGuard get(android.content.Context context) { return INSTANCE; }
    void added(String id, boolean incoming) {}
    void ownership(String id, boolean owned) {}
    void removed(String id) {}
}
