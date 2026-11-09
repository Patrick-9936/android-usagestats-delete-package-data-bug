# Suggested fix

`UsageStatsDatabase.deleteDataFor(String pkg)` reuses the *upgrade* prune with a singleton
map and a boot-relative clock, which inverts the operation.

## Before (AOSP main, line 1581)

```java
void deleteDataFor(String pkg) {
    // reuse the existing prune method to delete data for the specified package.
    // we'll use the current timestamp so that all events before now get pruned.
    prunePackagesDataOnUpgrade(
            new HashMap<>(Collections.singletonMap(pkg, SystemClock.elapsedRealtime())));
}
```

## After

```java
void deleteDataFor(String pkg) {
    // Build the full installed-package map so that pruneStats() does NOT treat every
    // other package as uninstalled, then override the target with a wall-clock
    // timestamp so that the target is the one that gets pruned.
    final HashMap<String, Long> installed = new HashMap<>();
    for (PackageInfo pi : mContext.getPackageManager().getInstalledPackages(0)) {
        installed.put(pi.packageName, pi.firstInstallTime);
    }
    installed.put(pkg, System.currentTimeMillis());   // wall clock, not elapsedRealtime
    prunePackagesDataOnUpgrade(installed);
}
```

Alternatively, implement a dedicated removal that filters `IntervalStats.packageStats`
(and `IntervalStats.events`) by package name, instead of reusing the upgrade prune.
