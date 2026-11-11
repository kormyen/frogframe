#!/bin/sh
set -eu
cd "$(dirname "$0")/../android"
if [ -z "${JAVA_HOME:-}" ] && [ -d /opt/homebrew/opt/openjdk@17 ]; then
  export JAVA_HOME=/opt/homebrew/opt/openjdk@17
fi
if [ -z "${ANDROID_HOME:-}" ] && [ -d /opt/homebrew/share/android-commandlinetools ]; then
  export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
fi
exec ./gradlew assembleDebug lintDebug "$@"
