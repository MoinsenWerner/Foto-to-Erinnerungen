#!/usr/bin/env bash
# Aktivierung: source ./scripts/ensure-java17.sh
# Prüft die tatsächlich vorhandenen JDK-Binaries statt des APT-Paketstatus.
# Verwendet vorhandenes JDK 17 oder installiert Eclipse Temurin 17 benutzerlokal.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo 'Bitte mit "source ./scripts/ensure-java17.sh" aufrufen, damit JAVA_HOME erhalten bleibt.' >&2
  exit 2
fi

_fte_is_jdk17() {
  local jdk_dir="$1"
  [[ -x "$jdk_dir/bin/java" && -x "$jdk_dir/bin/javac" ]] || return 1
  "$jdk_dir/bin/java" -version 2>&1 | grep -Eq 'version "17([.\"]|$)' || return 1
  "$jdk_dir/bin/javac" -version 2>&1 | grep -Eq '^javac 17([.]|$)' || return 1
}

_fte_enable_java17() {
  local candidate='' target='' tmp='' effective='' expected=''

  # JAVA_HOME hat Vorrang, falls es bereits auf ein vollständiges JDK 17 zeigt.
  if [[ -n "${JAVA_HOME:-}" ]] && _fte_is_jdk17 "$JAVA_HOME"; then
    candidate="$JAVA_HOME"
  fi

  # Auch manuell installierte Java-Binaries im PATH werden erkannt.
  if [[ -z "$candidate" ]] && command -v javac >/dev/null 2>&1; then
    candidate="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
    _fte_is_jdk17 "$candidate" || candidate=''
  fi

  target="${FTE_JDK17_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/foto-to-erinnerung/jdk-17}"
  if [[ -z "$candidate" ]] && _fte_is_jdk17 "$target"; then
    candidate="$target"
  fi

  if [[ -z "$candidate" ]]; then
    echo '[Foto to Erinnerung] Kein vollständiges JDK 17 gefunden. Installiere Eclipse Temurin 17 ...'
    [[ "$(uname -s)" == 'Linux' && "$(uname -m)" == 'x86_64' ]] || {
      echo 'Automatische JDK-Installation unterstützt Linux x86_64.' >&2; return 1;
    }
    # Nur für den Download notwendige Systemwerkzeuge nachinstallieren.
    # Es findet ausdrücklich KEINE Java-Paketprüfung per APT statt.
    local required=()
    command -v curl >/dev/null 2>&1 || required+=(curl)
    command -v tar >/dev/null 2>&1 || required+=(tar)
    command -v sha256sum >/dev/null 2>&1 || required+=(coreutils)
    if ((${#required[@]})); then
      command -v apt-get >/dev/null 2>&1 || {
        echo "Fehlende Download-Werkzeuge: ${required[*]} (apt-get nicht verfügbar)." >&2
        return 1
      }
      if [[ $EUID -eq 0 ]]; then
        apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates "${required[@]}" || return 1
      elif command -v sudo >/dev/null 2>&1; then
        sudo apt-get update && sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates "${required[@]}" || return 1
      else
        echo 'Zur Installation fehlender Download-Werkzeuge ist sudo/root erforderlich.' >&2
        return 1
      fi
    fi
    command -v mktemp >/dev/null 2>&1 || {
      echo 'mktemp fehlt.' >&2; return 1;
    }
    if [[ -e "$target" ]]; then
      echo "Der Zielpfad existiert, enthält aber kein gültiges JDK 17: $target" >&2
      return 1
    fi
    tmp="$(mktemp -d)" || return 1
    local api='https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse'
    # Adoptium leitet zur Release-Datei weiter. Die .sha256.txt liegt
    # NEBEN der Release-Datei, nicht neben der endgültigen CDN-URL.
    effective="$(curl -fsS --retry 3 --connect-timeout 20 -o /dev/null -w '%{redirect_url}' "$api")" || {
      rm -rf "$tmp"; return 1;
    }
    if [[ ! "$effective" == https://github.com/adoptium/temurin17-binaries/releases/download/* ]]; then
      echo "Unerwartete Adoptium-Weiterleitung: $effective" >&2
      rm -rf "$tmp"; return 1
    fi
    curl -fLsS --retry 3 --connect-timeout 20 "$effective" -o "$tmp/jdk.tar.gz" || {
      rm -rf "$tmp"; return 1;
    }
    curl -fLsS --retry 3 --connect-timeout 20 "${effective}.sha256.txt" -o "$tmp/jdk.sha256" || {
      echo 'SHA-256-Prüfsumme konnte nicht heruntergeladen werden.' >&2
      rm -rf "$tmp"; return 1;
    }
    expected="$(head -n 1 "$tmp/jdk.sha256" | awk '{print $1}')"
    if [[ ! "$expected" =~ ^[A-Fa-f0-9]{64}$ ]] || ! printf '%s  %s\n' "$expected" "$tmp/jdk.tar.gz" | sha256sum -c - >/dev/null; then
      echo 'SHA-256-Prüfung des JDK-Downloads fehlgeschlagen.' >&2
      rm -rf "$tmp"; return 1
    fi
    mkdir -p "$(dirname "$target")" || { rm -rf "$tmp"; return 1; }
    mkdir "$tmp/jdk" || { rm -rf "$tmp"; return 1; }
    tar -xzf "$tmp/jdk.tar.gz" -C "$tmp/jdk" --strip-components=1 || {
      rm -rf "$tmp"; return 1;
    }
    if ! _fte_is_jdk17 "$tmp/jdk"; then
      echo 'Das Archiv enthält kein gültiges JDK 17.' >&2
      rm -rf "$tmp"; return 1
    fi
    # Verzeichnis zuerst lokal komplett erstellen, dann atomar einhängen.
    mv "$tmp/jdk" "$target" || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    candidate="$target"
  fi

  export JAVA_HOME="$candidate"
  export PATH="$JAVA_HOME/bin:$PATH"
  echo "[Foto to Erinnerung] Verwendetes JDK: $JAVA_HOME"
  "$JAVA_HOME/bin/java" -version
}

_fte_enable_java17
_fte_status=$?
unset -f _fte_enable_java17 _fte_is_jdk17
return "$_fte_status"
