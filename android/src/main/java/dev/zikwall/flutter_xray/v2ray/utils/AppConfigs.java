package dev.zikwall.flutter_xray.v2ray.utils;

public class AppConfigs {

    public static final String EXTRA_APPLICATION_NAME = "APPLICATION_NAME";
    public static final String EXTRA_APPLICATION_ICON = "APPLICATION_ICON";
    public static final String EXTRA_DELAY_URL = "URL";

    public static V2RAY_CONNECTION_MODES V2RAY_CONNECTION_MODE = V2RAY_CONNECTION_MODES.VPN_TUN;
    public static String APPLICATION_NAME;
    public static int APPLICATION_ICON;
    public static V2rayConfig V2RAY_CONFIG = null;
    public static boolean ENABLE_TRAFFIC_AND_SPEED_STATICS = true;
    public static String NOTIFICATION_DISCONNECT_BUTTON_NAME;

    public enum V2RAY_SERVICE_COMMANDS {
        START_SERVICE,
        STOP_SERVICE,
        MEASURE_DELAY
    }

    public enum V2RAY_STATES {
        V2RAY_CONNECTED,
        V2RAY_DISCONNECTED,
        V2RAY_CONNECTING
    }

    public enum V2RAY_CONNECTION_MODES {
        VPN_TUN,
        PROXY_ONLY
    }
}
