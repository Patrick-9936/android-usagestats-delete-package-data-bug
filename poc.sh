#!/bin/sh
# PoC: `cmd usagestats delete-package-data <PKG>` keeps <PKG> and wipes all others.
#
# Run on the device (adb shell) or via a shell that can execute `cmd`.
# WARNING: destructive to on-disk usage stats. Use `dumpsys usagestats flush` to restore
# from memory afterwards (while the system is still running).
#
# Usage: sh poc.sh <PACKAGE_TO_DELETE>

PKG="${1:-com.google.android.youtube}"

echo "[*] packages on disk BEFORE:"
cmd usagestats 2>/dev/null >/dev/null   # touch the service
dumpsys usagestats file 0 | grep -oE 'package=[A-Za-z0-9_.]+' | sort -u | wc -l

echo "[*] running: cmd usagestats delete-package-data $PKG"
cmd usagestats delete-package-data "$PKG"

echo "[*] packages on disk AFTER:"
dumpsys usagestats file 0 | grep -oE 'package=[A-Za-z0-9_.]+' | sort -u

echo
echo "[!] If only '$PKG' is listed above, the bug is confirmed."
echo "[!] Restore with: dumpsys usagestats flush"
