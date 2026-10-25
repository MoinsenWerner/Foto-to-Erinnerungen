#!/usr/bin/env bash
# Repair ML Kit release OCR initialization without changing Flutter code or user data.
# Changes ProGuard rules and makes compile.sh apply them at every build.
# Java is never checked or installed.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
python3 - "$ROOT" <<'PYTHON'
from pathlib import Path
import sys, re, shutil

root = Path(sys.argv[1])
start = "# FOTO_OCR_R8_RUNTIME_START"
end = "# FOTO_OCR_R8_RUNTIME_END"
fix = """# FOTO_OCR_R8_RUNTIME_START
# ML Kit uses runtime reflection/component discovery; keep its registrars and implementations.
-keep class * implements com.google.firebase.components.ComponentRegistrar { public <init>(); }
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }
# Latin OCR is sufficient. These four other language modules are optional.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
# FOTO_OCR_R8_RUNTIME_END
"""

# Amend the canonical rules and preserve any unrelated project-specific rules.
source = root / "android_overrides/app/proguard-rules.pro"
target = root / "android/app/proguard-rules.pro"
source.parent.mkdir(parents=True, exist_ok=True)
target.parent.mkdir(parents=True, exist_ok=True)
original = source.read_text(encoding="utf-8") if source.exists() else ""
if start in original:
    original = re.sub(r"(?ms)^# FOTO_OCR_R8_RUNTIME_START\n.*?^# FOTO_OCR_R8_RUNTIME_END\n?", "", original)
original = "\n".join(line for line in original.splitlines() if not (
    line.strip().startswith("-dontwarn com.google.mlkit.vision.text.") and
    any(f".{lang}." in line for lang in ("chinese", "devanagari", "japanese", "korean"))
))
source.write_text(original.rstrip("\n") + "\n\n" + fix if original.strip() else fix, encoding="utf-8")
shutil.copyfile(source, target)

# The old compile.sh wrote -dontwarn-only rules on each build. Replace the
# heredoc with copying the permanent rules from android_overrides.
script = root / "compile.sh"
if not script.exists():
    raise SystemExit("compile.sh fehlt")
s = script.read_text(encoding="utf-8")
pattern = r'''^cat > "\$ROOT/android/app/proguard-rules\.pro" <<'FOTO_PROGUARD'\n.*?^FOTO_PROGUARD$'''
s, num = re.subn(pattern,
    'cp "$ROOT/android_overrides/app/proguard-rules.pro" "$ROOT/android/app/proguard-rules.pro"',
    s, flags=re.M | re.S)
if "FOTO_R8_MLKIT_START" in s and not (num or
    'cp "$ROOT/android_overrides/app/proguard-rules.pro" "$ROOT/android/app/proguard-rules.pro"' in s):
    raise SystemExit("compile.sh enthaelt einen unbekannten ProGuard-Block. Automatische Aenderung abgebrochen.")

# Older project layouts need to have proguard-rules.pro registered with Gradle.
if "FOTO_MLKIT_R8_RULES" not in s:
    anchor = 'cat > "$ROOT/android/local.properties" <<PROPERTIES'
    if s.count(anchor) != 1:
        raise SystemExit("compile.sh hat ein unbekanntes Format; Gradle-Einbindung nicht moeglich.")
    block = '''# FOTO_OCR_GRADLE_RULES
if [[ -f "$gradle_kts" ]] && ! grep -q 'FOTO_MLKIT_R8_RULES' "$gradle_kts"; then
  cat >> "$gradle_kts" <<'KTS'
// FOTO_MLKIT_R8_RULES
android { buildTypes { getByName("release") { proguardFiles("proguard-rules.pro") } } }
KTS
elif [[ -f "$gradle_groovy" ]] && ! grep -q 'FOTO_MLKIT_R8_RULES' "$gradle_groovy"; then
  cat >> "$gradle_groovy" <<'GROOVY'
// FOTO_MLKIT_R8_RULES
android { buildTypes { release { proguardFiles 'proguard-rules.pro' } } } }
GROOVY
fi
'''
    s = s.replace(anchor, block + "\n" + anchor, 1)
script.write_text(s, encoding="utf-8")

for file_name in ("build.gradle.kts", "build.gradle"):
    gradle = root / "android/app" / file_name
    if not gradle.is_file():
        continue
    t = gradle.read_text(encoding="utf-8")
    if "FOTO_MLKIT_R8_RULES" in t:
        continue
    kts = file_name.endswith(".kts")
    block = ('''
// FOTO_MLKIT_R8_RULES
android { buildTypes { getByName("release") { proguardFiles("proguard-rules.pro") } } }
''' if kts else '''
// FOTO_MLKIT_R8_RULES
android { buildTypes { release { proguardFiles 'proguard-rules.pro' } } }
''')
    gradle.write_text(t + block, encoding="utf-8")

print("ML Kit OCR-Runtime-Regeln aktualisiert.")
print("compile.sh wendet die Regeln nun bei jedem Build erneut an.")
print("Gespeicherte Erinnerungen, Tags und APK-Versionen bleiben unveraendert.")
PYTHON
if [[ "${1:-}" != "--no-build" ]]; then
  exec "$ROOT/compile.sh"
fi
