package com.airsim.phonecontrol;

import java.lang.reflect.Constructor;
import java.lang.reflect.Field;

/**
 * Root / Shell helpers run as a bare {@code app_process} without a package identity.
 * After a privileged binder call such as {@code ISms.sendTextForSubscriber} has already
 * completed, the reply may carry noted app-ops. The client then reports a sampled stack
 * trace through {@code IAppOpsService.reportRuntimeAppOpAccessMessageAndGetConfig}, and
 * system_server throws a NullPointerException for the package-less caller (observed on
 * HyperOS / Android 13, Redmi K40). The exception surfaces from the finished send, so the
 * SMS result becomes "unknown" although the message was dispatched.
 *
 * Replacing the client-side sampling config with "no op sampled, never expires" makes
 * {@code isCollectingStackTraces()} false, so that report is skipped. Purely reflective:
 * no compile-time dependency on hidden classes; failure leaves behavior unchanged.
 */
final class AppOpsSamplingGuard {
    private static final int OP_NONE = -1;

    private AppOpsSamplingGuard() {}

    static boolean disable() {
        try {
            Class<?> appOps = Class.forName("android.app.AppOpsManager");
            Class<?> config = Class.forName("com.android.internal.app.MessageSamplingConfig");
            Constructor<?> constructor = config.getDeclaredConstructor(int.class, int.class, long.class);
            constructor.setAccessible(true);
            Field field = appOps.getDeclaredField("sConfig");
            field.setAccessible(true);
            field.set(null, constructor.newInstance(OP_NONE, 0, Long.MAX_VALUE));
            return true;
        } catch (ReflectiveOperationException | RuntimeException | LinkageError ignored) {
            return false;
        }
    }
}
