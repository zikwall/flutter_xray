package dev.zikwall.flutter_xray.tunnel;

import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.os.Bundle;

public final class TunnelBackendSelector {
    public static final String MANIFEST_KEY = "dev.zikwall.flutter_xray.TUNNEL_BACKEND";

    private TunnelBackendSelector() {
    }

    public static TunnelBackendKind fromManifest(Context context) {
        try {
            ApplicationInfo applicationInfo = context.getPackageManager().getApplicationInfo(
                    context.getPackageName(), PackageManager.GET_META_DATA);
            Bundle metadata = applicationInfo.metaData;
            String configuredValue = metadata == null ? null : metadata.getString(MANIFEST_KEY);
            return TunnelBackendKind.fromConfigValue(configuredValue);
        } catch (PackageManager.NameNotFoundException error) {
            throw new IllegalStateException("Application metadata is unavailable", error);
        }
    }
}
