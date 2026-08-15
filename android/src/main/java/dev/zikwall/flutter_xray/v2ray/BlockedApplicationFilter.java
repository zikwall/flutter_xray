package dev.zikwall.flutter_xray.v2ray;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/** Keeps only installed package ids from a best-effort server-provided bypass list. */
final class BlockedApplicationFilter {
    interface PackageLookup {
        boolean isInstalled(String packageName);
    }

    interface WarningSink {
        void warn(String message);
    }

    private BlockedApplicationFilter() {}

    static ArrayList<String> installedOnly(
            List<String> packageNames,
            PackageLookup packageLookup,
            WarningSink warningSink) {
        if (packageNames == null) {
            return null;
        }
        Set<String> installed = new LinkedHashSet<>();
        Set<String> inspected = new LinkedHashSet<>();
        int emptyCount = 0;
        int unavailableCount = 0;
        for (String packageName : packageNames) {
            String candidate = packageName == null ? "" : packageName.trim();
            if (candidate.isEmpty()) {
                emptyCount += 1;
                continue;
            }
            if (!inspected.add(candidate)) {
                continue;
            }
            if (packageLookup.isInstalled(candidate)) {
                installed.add(candidate);
            } else {
                unavailableCount += 1;
            }
        }
        if (unavailableCount > 0) {
            warningSink.warn("Ignored " + unavailableCount
                    + " unavailable blockedApps package id(s)");
        }
        if (emptyCount > 0) {
            warningSink.warn("Ignored " + emptyCount + " empty blockedApps package id(s)");
        }
        return new ArrayList<>(installed);
    }
}
