package dev.zikwall.flutter_xray.v2ray;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

import org.junit.Test;

public final class BlockedApplicationFilterTest {
    @Test
    public void nullServerListRemainsUnset() {
        assertNull(BlockedApplicationFilter.installedOnly(
                null, packageName -> true, message -> {}));
    }

    @Test
    public void acceptsInstalledPackagesAndIgnoresLargeUnavailableList() {
        List<String> input = new ArrayList<>();
        for (int index = 0; index < 1_000; index += 1) {
            input.add("server.package." + index);
        }
        input.addAll(Arrays.asList(
                " com.example.one ", "com.example.two", "com.example.one", null, " "));
        Set<String> available = new HashSet<>(Arrays.asList(
                "com.example.one", "com.example.two"));
        List<String> warnings = new ArrayList<>();

        ArrayList<String> result = BlockedApplicationFilter.installedOnly(
                input, available::contains, warnings::add);

        assertEquals(Arrays.asList("com.example.one", "com.example.two"), result);
        assertEquals(2, warnings.size());
    }

    @Test
    public void unexpectedPackageLookupFailureIsNotSwallowed() {
        org.junit.Assert.assertThrows(
                IllegalStateException.class,
                () -> BlockedApplicationFilter.installedOnly(
                        Arrays.asList("some.package"),
                        packageName -> {
                            throw new IllegalStateException("package manager unavailable");
                        },
                        message -> {}));
    }
}
