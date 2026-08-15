package dev.zikwall.flutter_xray.v2ray;

import dev.zikwall.flutter_xray.v2ray.utils.AppConfigs;

/**
 * Owns connection requests in the Flutter application process.
 *
 * <p>The VPN service runs in a separate Android process, so its static core
 * state cannot be used to serialize method-channel requests.</p>
 */
final class ConnectionLifecycleGuard {
    private AppConfigs.V2RAY_STATES state = AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED;

    synchronized boolean reserveStart() {
        if (state != AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED) {
            return false;
        }
        state = AppConfigs.V2RAY_STATES.V2RAY_CONNECTING;
        return true;
    }

    synchronized void cancelStart() {
        if (state == AppConfigs.V2RAY_STATES.V2RAY_CONNECTING) {
            state = AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED;
        }
    }

    synchronized void update(AppConfigs.V2RAY_STATES nextState) {
        if (nextState != null) {
            state = nextState;
        }
    }

    synchronized AppConfigs.V2RAY_STATES state() {
        return state;
    }
}
