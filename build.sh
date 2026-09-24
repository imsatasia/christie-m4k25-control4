#!/usr/bin/env bash
# Package the driver into christie_m4k25.c4z.
#
# A .c4z is just a ZIP with a different extension, so this does not need
# Control4's DriverPackager -- that is only required for squishing multiple
# Lua files into one or for encrypting the source, neither of which applies
# here. The file layout inside the archive must match driver.c4zproj.
set -euo pipefail

cd "$(dirname "$0")"
OUT="christie_m4k25.c4z"

# Validate before packaging: a malformed driver.xml is silently rejected by
# Composer, and a Lua syntax error only shows up once the driver is loaded.
python3 -c "import xml.etree.ElementTree as ET; ET.parse('driver.xml')"
echo "driver.xml parses"

if command -v luac5.1 >/dev/null 2>&1; then
    luac5.1 -p driver.lua && echo "driver.lua compiles"
elif command -v docker >/dev/null 2>&1 && docker image inspect christie-lua >/dev/null 2>&1; then
    docker run --rm -v "$PWD":/d -w /d christie-lua luac5.1 -p driver.lua \
        && echo "driver.lua compiles"
else
    echo "warning: no Lua available, skipping syntax check" >&2
fi

rm -f "$OUT"
python3 - "$OUT" <<'PY'
import sys, zipfile
from pathlib import Path

# Paths inside the archive must match driver.c4zproj.
members = ["driver.xml", "driver.lua", "www/documentation.html"]
out = sys.argv[1]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as archive:
    for name in members:
        archive.write(name, name)
print(f"built {out}")
for info in zipfile.ZipFile(out).infolist():
    print(f"  {info.file_size:7d}  {info.filename}")
PY
