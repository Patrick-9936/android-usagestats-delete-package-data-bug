# Android bug: `cmd usagestats delete-package-data <pkg>` deletes the usage stats of **all other** packages

**TL;DR** — `adb shell cmd usagestats delete-package-data <pkg>` is supposed to delete the usage
statistics of `<pkg>`. Instead it deletes the usage statistics of **every package except** `<pkg>`,
and leaves `<pkg>` untouched. The command is inverted and destructive.

Verified on a real device (Android 15, MIUI/HyperOS, no root, via Shizuku shell uid 2000) and
confirmed in AOSP source (`frameworks/base`, branch `main`, still present as of 2026-11).

---

## 1. Root cause

`UsageStatsDatabase.deleteDataFor(String pkg)` reuses the "prune on upgrade" path and passes the
**current `SystemClock.elapsedRealtime()`** as if it were an install timestamp:

```java
// services/usage/java/com/android/server/usage/UsageStatsDatabase.java
void deleteDataFor(String pkg) {
    // reuse the existing prune method to delete data for the specified package.
    // we'll use the current timestamp so that all events before now get pruned.
    prunePackagesDataOnUpgrade(
            new HashMap<>(Collections.singletonMap(pkg, SystemClock.elapsedRealtime())));
}
```

`pruneStats()` then keeps a package only if its recorded timestamp is **strictly greater** than the
value in the map, and drops it when the value is `null`:

```java
private boolean pruneStats(HashMap<String, Long> installedPackages, IntervalStats stats) {
    boolean dataPruned = false;

    // prune old package usage stats
    for (int i = stats.packageStats.size() - 1; i >= 0; i--) {
        final UsageStats usageStats = stats.packageStats.valueAt(i);
        final Long timeInstalled = installedPackages.get(usageStats.mPackageName);
        if (timeInstalled == null || timeInstalled > usageStats.mEndTimeStamp) {
            stats.packageStats.removeAt(i);
            dataPruned = true;
        }
    }
    ...
    // prune old events
    for (int i = stats.events.size() - 1; i >= 0; i--) {
        final UsageEvents.Event event = stats.events.get(i);
        final Long timeInstalled = installedPackages.get(event.mPackage);
        if (timeInstalled == null || timeInstalled > event.mTimeStamp) {
            stats.events.remove(i);
            dataPruned = true;
        }
    }
    return dataPruned;
}
```

The two timestamps are on **different clocks**:

| value | meaning | magnitude |
|---|---|---|
| `installedPackages.get(pkg)` | `SystemClock.elapsedRealtime()` — ms since boot | ~`1.3e8` |
| `usageStats.mEndTimeStamp` / `event.mTimeStamp` | wall-clock epoch ms | ~`1.79e12` |

`elapsedRealtime()` is **never** greater than an epoch timestamp, so for the *target* package the
condition `timeInstalled > mEndTimeStamp` is always `false` and it is **kept**. Every *other* package
is not in the map (`timeInstalled == null`), so it is **removed**.

Result: the command deletes everything **except** the package you named.

---

## 2. Reproduction

```sh
# 1. Look at the on-disk usage stats (one entry per package)
adb shell dumpsys usagestats file 0 | grep -oE 'package=[a-zA-Z0-9_.]+' | sort -u | wc -l
#   -> e.g. 321

# 2. "Delete" the stats of one package
adb shell cmd usagestats delete-package-data org.telegram.messenger
#   -> rc=0, no output, no error

# 3. Look again
adb shell dumpsys usagestats file 0 | grep -oE 'package=[a-zA-Z0-9_.]+' | sort -u
#   -> exactly ONE package remains (whatever was written last), e.g. com.google.android.youtube
#      org.telegram.messenger is still there, everything else is gone
```

The in-memory stats are not affected until the next flush; the damage is on disk. A
`dumpsys usagestats flush` rewrites the files from memory and restores the full set.

---

## 3. Observed evidence (real device)

Before:

```
$ adb shell dumpsys usagestats file 0 | grep -oE 'package=[a-zA-Z0-9_.]+' | sort -u | wc -l
321
```

After running `delete-package-data org.telegram.messenger` and `delete-package-data com.openai.chatgpt`:

```
$ adb shell dumpsys usagestats file 0 | grep -oE 'package=[a-zA-Z0-9_.]+' | sort -u
package=com.google.android.youtube
```

Only one package left. After `dumpsys usagestats flush`:

```
$ adb shell dumpsys usagestats flush
Flushed stats to disk
$ adb shell dumpsys usagestats file 0 | grep -oE 'package=[a-zA-Z0-9_.]+' | sort -u | wc -l
321
```

`org.telegram.messenger`, `com.openai.chatgpt`, `com.anthropic.claude`, `ai.x.grok` — all present
again, because the in-memory store was never touched.

---

## 4. Impact

* Any user or script that runs `cmd usagestats delete-package-data <pkg>` to clear one app's history
  silently wipes the on-disk usage history of the whole device (all other packages).
* The command reports success (`rc=0`) and prints nothing, so the destruction is invisible.
* The named package keeps its data, so the intended operation does not even happen.

## 5. Affected versions

Present in AOSP `main` (checked 2026-11) and in the `android-34` sources. The same
`deleteDataFor` / `pruneStats` pair has been stable for many releases, so it is very likely present
across a wide range of Android versions. Not fixed as of this writing.

## 6. Workaround

There is no safe shell-level way to delete the usage stats of a single package without root.
Do **not** use `cmd usagestats delete-package-data`. To recover after an accidental run:

```sh
adb shell dumpsys usagestats flush
```

which rewrites the on-disk files from the in-memory store.

## 7. Suggested fix

`deleteDataFor()` should not reuse the install-time prune path. It should remove exactly the entries
whose package name equals `pkg`, e.g. filter `stats.packageStats` / `stats.events` by
`mPackageName.equals(pkg)` instead of comparing timestamps from two different clocks.

---

*Reported from a Termux/Android session; device evidence collected via Shizuku shell (uid 2000),
no root.*
