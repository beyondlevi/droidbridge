#!/usr/bin/env bash
# Builds droidbridge-server.jar (a dex in a jar) without Gradle, like scrcpy's
# build_without_gradle.sh. Needs ANDROID_HOME with platforms/android-36 and build-tools/36.0.0.
set -euo pipefail

VERSION=${DROIDBRIDGE_VERSION:-0.2.0}
PLATFORM=${ANDROID_PLATFORM:-36}
BUILD_TOOLS=${ANDROID_BUILD_TOOLS:-36.0.0}
: "${ANDROID_HOME:?set ANDROID_HOME}"

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${BUILD_DIR:-$HERE/build}
ANDROID_JAR="$ANDROID_HOME/platforms/android-$PLATFORM/android.jar"
ANDROID_AIDL="$ANDROID_HOME/platforms/android-$PLATFORM/framework.aidl"
TOOLS="$ANDROID_HOME/build-tools/$BUILD_TOOLS"

rm -rf "$OUT" && mkdir -p "$OUT/classes" "$OUT/gen/com/genymobile/scrcpy" "$OUT/gen/dev/droidbridge"

cat > "$OUT/gen/com/genymobile/scrcpy/BuildConfig.java" <<JAVA
package com.genymobile.scrcpy;
public final class BuildConfig {
  public static final boolean DEBUG = false;
  public static final String VERSION_NAME = "4.1";
}
JAVA
cat > "$OUT/gen/dev/droidbridge/BuildInfo.java" <<JAVA
package dev.droidbridge;
final class BuildInfo {
  static final String VERSION = "$VERSION";
}
JAVA

(cd "$HERE/third_party/scrcpy-aidl" &&
  "$TOOLS/aidl" -o"$OUT/gen" -I. android/content/IOnPrimaryClipChangedListener.aidl &&
  "$TOOLS/aidl" -o"$OUT/gen" -I. -p "$ANDROID_AIDL" android/view/IDisplayWindowListener.aidl)

find "$HERE/third_party/scrcpy-java" "$HERE/src" "$OUT/gen" -name '*.java' > "$OUT/sources.txt"
javac -encoding UTF-8 -nowarn -bootclasspath "$ANDROID_JAR" -cp "$TOOLS/core-lambda-stubs.jar" \
  -d "$OUT/classes" -source 1.8 -target 1.8 @"$OUT/sources.txt" 2>&1 | grep -v "^warning\|^Note:\|^1 warning\|^[0-9]* warnings" || true
test -f "$OUT/classes/dev/droidbridge/Main.class"

# Like scrcpy, the generated/stub android.* classes go into the dex too.
(cd "$OUT/classes" && "$TOOLS/d8" --classpath "$ANDROID_JAR" --output "$OUT/droidbridge-server.jar" --min-api 26 \
  $(find . -name '*.class'))
echo "$OUT/droidbridge-server.jar"
