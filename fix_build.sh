#!/usr/bin/env bash
# Repariert die drei Dart-API-Fehler der ursprünglichen Projektversion
# und startet anschließend den regulären Build.
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
python3 - <<'PY'
from pathlib import Path
p = Path('lib/main.dart')
s = p.read_text(encoding='utf-8')

old = """    final file = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['mp3']);
    final picked = file?.files.single;
    if (picked?.path == null) return null;
    final folder = Directory('${(await getApplicationSupportDirectory()).path}/sounds');
    await folder.create(recursive: true);
    final target = File('${folder.path}/${DateTime.now().microsecondsSinceEpoch}.mp3');
    await File(picked!.path!).copy(target.path);
    return AlarmSound('mp3', target.path, picked.name);"""
new = """    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['mp3'],
    );
    if (picked == null) return null;
    final folder = Directory('${(await getApplicationSupportDirectory()).path}/sounds');
    await folder.create(recursive: true);
    final target = File('${folder.path}/${DateTime.now().microsecondsSinceEpoch}.mp3');
    await target.writeAsBytes(await picked.readAsBytes(), flush: true);
    return AlarmSound('mp3', target.path, picked.name);"""
if old in s:
    s = s.replace(old, new, 1)
elif new not in s:
    raise SystemExit('Unerwartete FilePicker-Codeversion in lib/main.dart; keine Änderung vorgenommen.')

for old_button, new_button in [
    ("FilledButton.icon(onPressed: save, icon: const Icon(Icons.save), child: const Text('Speichern'))", "FilledButton.icon(onPressed: save, icon: const Icon(Icons.save), label: const Text('Speichern'))"),
    ("}, icon: const Icon(Icons.save), child: const Text('Tag speichern'))", "}, icon: const Icon(Icons.save), label: const Text('Tag speichern'))"),
]:
    if old_button in s:
        s = s.replace(old_button, new_button, 1)
    elif new_button not in s:
        raise SystemExit('Unerwartete FilledButton-Codeversion; keine Änderung vorgenommen.')

p.write_text(s, encoding='utf-8')
print('lib/main.dart: API-Korrekturen angewendet.')
PY
exec ./compile.sh
