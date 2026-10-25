#!/usr/bin/env bash
# Debian/Ubuntu, x86_64. Builds an Android release APK and increases the output version
# ONLY after a successful build. Java is deliberately neither checked nor installed.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="${FOTO_TOOLS_DIR:-/opt/foto-to-erinnerung-tools}"
ANDROID_HOME="${ANDROID_HOME:-$TOOLS_DIR/android-sdk}"
ANDROID_SDK_ROOT="$ANDROID_HOME"
FLUTTER_HOME="${FLUTTER_HOME:-$TOOLS_DIR/flutter}"
DEST_DIR="/root/apk"
CMDTOOLS_VERSION="15859902"
CMDTOOLS_SHA256="4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583"

log() { printf '\n\033[1;36m[Foto to Erinnerung]\033[0m %s\n' "$*"; }
fail() { printf '\nFEHLER: %s\n' "$*" >&2; exit 1; }
command -v apt-get >/dev/null || fail 'Automatische Installation benötigt Debian/Ubuntu mit apt-get.'
[[ "$(uname -m)" == "x86_64" ]] || fail 'Dieses Build-Skript ist für Linux x86_64 ausgelegt.'

# Install only missing system packages, never try to install/probe Java.
needed=(git curl unzip xz-utils zip ca-certificates libglu1-mesa python3 util-linux)
missing=()
for pkg in "${needed[@]}"; do
  if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -qx 'install ok installed'; then
    missing+=("$pkg")
  fi
done
if ((${#missing[@]})); then
  [[ "$EUID" -eq 0 ]] || fail "Für fehlende Pakete bitte als root starten: ${missing[*]}"
  log "Installiere fehlende Systempakete: ${missing[*]}"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
fi

mkdir -p "$TOOLS_DIR" "$ANDROID_HOME" "$DEST_DIR"
export ANDROID_HOME ANDROID_SDK_ROOT
export PATH="$FLUTTER_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"

if ! command -v flutter >/dev/null 2>&1; then
  log 'Lade Flutter SDK 3.47.5 (stable) herunter ...'
  git clone --depth 1 --single-branch --branch 3.47.5 \
    https://github.com/flutter/flutter.git "$FLUTTER_HOME"
fi
log "Flutter: $(command -v flutter)"
flutter --version

if [[ ! -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]]; then
  log 'Lade Android SDK Command-line Tools ...'
  download="$(mktemp -d)"
  trap 'rm -rf "$download"' EXIT
  url="https://dl.google.com/android/repository/commandlinetools-linux-${CMDTOOLS_VERSION}_latest.zip"
  curl -fL --retry 3 --connect-timeout 20 "$url" -o "$download/cmdtools.zip"
  echo "$CMDTOOLS_SHA256  $download/cmdtools.zip" | sha256sum -c -
  unzip -q "$download/cmdtools.zip" -d "$download"
  mkdir -p "$ANDROID_HOME/cmdline-tools"
  mv "$download/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
  rm -rf "$download"
  trap - EXIT
fi

sdkmanager="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
# SDK components are installed only when absent.
components=()
[[ -d "$ANDROID_HOME/platforms/android-36" ]] || components+=("platforms;android-36")
[[ -d "$ANDROID_HOME/build-tools/36.0.0" ]] || components+=("build-tools;36.0.0")
[[ -d "$ANDROID_HOME/platform-tools" ]] || components+=("platform-tools")
[[ -d "$ANDROID_HOME/ndk/28.2.13676358" ]] || components+=("ndk;28.2.13676358")

if ((${#components[@]})); then
  log 'Akzeptiere die notwendigen Android-SDK-Lizenzen und installiere fehlende Komponenten.'
  set +o pipefail
  yes | "$sdkmanager" --sdk_root="$ANDROID_HOME" --licenses >/dev/null
  license_status="${PIPESTATUS[1]}"
  set -o pipefail
  [[ "$license_status" -eq 0 ]] || fail 'Android SDK-Lizenzen konnten nicht akzeptiert werden.'
  "$sdkmanager" --sdk_root="$ANDROID_HOME" "${components[@]}"
fi
flutter config --android-sdk "$ANDROID_HOME" >/dev/null

# Generate the official Gradle Android skeleton if necessary, without overwriting lib/.
if [[ ! -f "$ROOT/android/settings.gradle.kts" && ! -f "$ROOT/android/settings.gradle" ]]; then
  log 'Erzeuge Android/Gradle-Projektdateien ...'
  tmp="$(mktemp -d)"
  flutter create --platforms=android --org de.felix --project-name foto_to_erinnerung --no-pub "$tmp/foto_to_erinnerung"
  cp -a "$tmp/foto_to_erinnerung/android" "$ROOT/android"
  rm -rf "$tmp"
fi

# Always apply app-specific Android code/permissions before building.
cp -a "$ROOT/android_overrides/." "$ROOT/android/"
gradle_kts="$ROOT/android/app/build.gradle.kts"
gradle_groovy="$ROOT/android/app/build.gradle"
if [[ -f "$gradle_kts" ]]; then
  sed -i -E \
    -e 's/^(\s*)compileSdk\s*=.*/\1compileSdk = 36/' \
    -e 's/^(\s*)minSdk\s*=.*/\1minSdk = 26/' \
    -e 's/^(\s*)targetSdk\s*=.*/\1targetSdk = 35/' \
    -e 's/^(\s*)ndkVersion\s*=.*/\1ndkVersion = "28.2.13676358"/' \
    "$gradle_kts"
elif [[ -f "$gradle_groovy" ]]; then
  sed -i -E \
    -e 's/compileSdkVersion.*/compileSdkVersion 36/' \
    -e 's/minSdkVersion.*/minSdkVersion 26/' \
    -e 's/targetSdkVersion.*/targetSdkVersion 35/' \
    "$gradle_groovy"
else
  fail 'Android-Gradle-Datei nicht vorhanden.'
fi
# Native notification code uses AndroidX NotificationCompat explicitly.
if [[ -f "$gradle_kts" ]] && ! grep -q 'androidx.core:core:' "$gradle_kts"; then
  cat >> "$gradle_kts" <<'GRADLE'

dependencies {
    implementation("androidx.core:core:1.16.0")
}
GRADLE
fi

cat > "$ROOT/android/local.properties" <<PROPERTIES
sdk.dir=$ANDROID_HOME
flutter.sdk=$(dirname "$(dirname "$(readlink -f "$(command -v flutter)")")")
PROPERTIES

# Prevent concurrent builds from using the same release number.
exec 9> "$DEST_DIR/.foto-to-erinnerung-build.lock"
flock -x 9
last=0
version_marker="$DEST_DIR/.foto-to-erinnerung-version"
if [[ -r "$version_marker" ]]; then
  saved="$(cat "$version_marker")"
  if [[ "$saved" =~ ^[0-9]+$ ]]; then last=$((10#$saved)); fi
fi
shopt -s nullglob
for output in "$DEST_DIR"/foto-to-erinnerung_v*.apk; do
  base="${output##*/}"
  if [[ "$base" =~ ^foto-to-erinnerung_v([0-9]+)\.apk$ ]]; then
    version="${BASH_REMATCH[1]}"
    if ((10#$version > last)); then last=$((10#$version)); fi
  fi
done
shopt -u nullglob
next=$((last + 1))
log "Baue APK-Version $next ..."
cd "$ROOT"
flutter pub get
flutter build apk --release --build-name="1.0.$next" --build-number="$next"

apk="$ROOT/build/app/outputs/flutter-apk/app-release.apk"
[[ -s "$apk" ]] || fail 'Build meldete Erfolg, aber die APK ist nicht vorhanden.'
file="$DEST_DIR/foto-to-erinnerung_v${next}.apk"
cp "$apk" "${file}.tmp.$$"
mv "${file}.tmp.$$" "$file"
printf '%s\n' "$next" > "${version_marker}.tmp.$$"
mv "${version_marker}.tmp.$$" "$version_marker"
log "ERFOLG: $file"
ls -lh "$file"
