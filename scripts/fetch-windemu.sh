#!/bin/sh
# Downloads the WindEmu WebAssembly build (emulator + bundled 5mx ROM) from
# wuffs.org into Psion5/Web, where the app serves it from. These files are
# not committed: the ROM is Psion's copyright, so each build fetches its own.
set -eu

BASE="https://wuffs.org/WindEmu"
DEST="$(cd "$(dirname "$0")/.." && pwd)/Psion5/Web"
FILES="WindEmu.js WindEmu.wasm WindEmu.data cover.svg"

mkdir -p "$DEST"
for f in $FILES; do
  if [ -s "$DEST/$f" ] && [ "${1:-}" != "--force" ]; then
    echo "have  $f"
    continue
  fi
  echo "fetch $f"
  curl -fsSL "$BASE/$f" -o "$DEST/$f.part"
  mv "$DEST/$f.part" "$DEST/$f"
done

# The build is from Dec 2019 and hasn't changed since; warn if that stops being true.
if ! grep -q 'REMOTE_PACKAGE_BASE="WindEmu.data"' "$DEST/WindEmu.js"; then
  echo "warning: WindEmu.js no longer looks like the 2019 build; the page may need updating" >&2
fi
