package dev.zikwall.flutter_xray.v2ray;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import dev.zikwall.flutter_xray.v2ray.utils.AppConfigs;

import org.junit.Test;

public final class ConnectionLifecycleGuardTest {
    @Test
    public void onePendingStartOwnsTheApplicationProcessReservation() {
        ConnectionLifecycleGuard guard = new ConnectionLifecycleGuard();

        assertTrue(guard.reserveStart());
        assertEquals(AppConfigs.V2RAY_STATES.V2RAY_CONNECTING, guard.state());
        assertFalse(guard.reserveStart());

        guard.update(AppConfigs.V2RAY_STATES.V2RAY_CONNECTED);
        assertFalse(guard.reserveStart());

        guard.update(AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED);
        assertTrue(guard.reserveStart());
        guard.cancelStart();
        assertEquals(AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED, guard.state());
    }
}
