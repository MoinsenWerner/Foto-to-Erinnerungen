#!/usr/bin/env bash
# Apply the R8 ML Kit fix to this existing Flutter project and optionally rebuild.
# Rerunning is safe; Java is not checked or installed.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
mkdir -p android_overrides/app android/app
cat > android_overrides/app/proguard-rules.pro <<'FOTO_PROGUARD'
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
FOTO_PROGUARD
cp android_overrides/app/proguard-rules.pro android/app/proguard-rules.pro

python3 - "$ROOT" <<'PYTHON'
from pathlib import Path
import sys
root=Path(sys.argv[1])
compile=root/'compile.sh'
s=compile.read_text(encoding='utf-8')
anchor='cat > "$ROOT/android/local.properties" <<PROPERTIES'
if 'FOTO_R8_MLKIT_START' not in s:
    if s.count(anchor)!=1:
        raise SystemExit('compile.sh has an unexpected format. No build attempted.')
    block = '# FOTO_R8_MLKIT_START\n# Suppress missing optional ML Kit OCR languages for Latin-only recognition.\nmkdir -p "$ROOT/android/app"\ncat > "$ROOT/android/app/proguard-rules.pro" <<\'FOTO_PROGUARD\'\n-dontwarn com.google.mlkit.vision.text.chinese.**\n-dontwarn com.google.mlkit.vision.text.devanagari.**\n-dontwarn com.google.mlkit.vision.text.japanese.**\n-dontwarn com.google.mlkit.vision.text.korean.**\nFOTO_PROGUARD\nif [[ -f "$gradle_kts" ]]; then\n  if ! grep -Fq \'FOTO_MLKIT_R8_RULES\' "$gradle_kts"; then\n    cat >> "$gradle_kts" <<\'FOTO_KTS\'\n\n// FOTO_MLKIT_R8_RULES\nandroid {\n    buildTypes {\n        getByName("release") {\n            proguardFiles("proguard-rules.pro")\n        }\n    }\n}\nFOTO_KTS\n  fi\nelif [[ -f "$gradle_groovy" ]]; then\n  if ! grep -Fq \'FOTO_MLKIT_R8_RULES\' "$gradle_groovy"; then\n    cat >> "$gradle_groovy" <<\'FOTO_GROOVY\'\n\n// FOTO_MLKIT_R8_RULES\nandroid {\n    buildTypes {\n        release {\n            proguardFiles \'proguard-rules.pro\'\n        }\n    }\n}\nFOTO_GROOVY\n  fi\nfi\n# FOTO_R8_MLKIT_END\n'
    compile.write_text(s.replace(anchor, block + '\n' + anchor, 1), encoding='utf-8')

for filename, groovy in [('build.gradle.kts', False), ('build.gradle', True)]:
    gradle=root/'android/app'/filename
    if not gradle.exists():
        continue
    original=gradle.read_text(encoding='utf-8')
    if 'FOTO_MLKIT_R8_RULES' not in original:
        if groovy:
            addition="\n// FOTO_MLKIT_R8_RULES\nandroid { buildTypes { release { proguardFiles 'proguard-rules.pro' } } }\n"
        else:
            addition='\n// FOTO_MLKIT_R8_RULES\nandroid { buildTypes { getByName("release") { proguardFiles("proguard-rules.pro") } } }\n'
        gradle.write_text(original + addition, encoding='utf-8')
print('R8 fix applied to Gradle configuration and compile.sh.')
PYTHON

if [[ "${1:-}" != "--no-build" ]]; then
  exec "$ROOT/compile.sh"
fi
