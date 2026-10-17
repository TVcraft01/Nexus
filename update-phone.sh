#!/bin/bash
echo "Resetting ADB..."
adb kill-server > /dev/null 2>&1
adb start-server > /dev/null 2>&1

echo "Searching for phone..."
TARGETS=$(adb mdns services | grep "_adb-tls-connect._tcp" | awk '{print $3}')
CONNECTED_TARGET=""

# Try to auto-connect to mDNS devices
for TARGET in $TARGETS; do
    adb connect "$TARGET" > /dev/null 2>&1
    if adb devices | grep -q "$TARGET.*device"; then
        CONNECTED_TARGET="$TARGET"
        break
    fi
done

# If auto-discovery failed, ask the user
if [ -z "$CONNECTED_TARGET" ]; then
    echo "❌ Could not auto-find phone."
    echo "👉 On your phone: Settings > Developer options > Wireless debugging."
    read -p "Enter the IP:PORT shown on the phone (e.g. 192.168.1.8:40000): " CONNECTED_TARGET
    adb connect "$CONNECTED_TARGET" > /dev/null 2>&1
fi

if adb devices | grep -q "$CONNECTED_TARGET.*device"; then
    echo "✅ Connected to $CONNECTED_TARGET"
    echo "Installing APK..."
    adb -s "$CONNECTED_TARGET" install -r build/app/outputs/flutter-apk/app-debug.apk
    if [ $? -eq 0 ]; then
        echo "🚀 Launching Nexus..."
        adb -s "$CONNECTED_TARGET" shell monkey -p dev.nexus.nexus -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1
    fi
else
    echo "❌ Failed to connect."
fi
