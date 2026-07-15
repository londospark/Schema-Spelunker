#!/bin/sh
set -e

VENDOR="$(cd "$(dirname "$0")" && pwd)/"
DEPS="${VENDOR}../../build/deps"
DEAR_BINDINGS_TAG="DearBindings_v0.21_ImGui_v1.92.8-docking"

if ! python3 --version >/dev/null 2>&1 && ! python --version >/dev/null 2>&1; then
    echo "Error: Python 3 not found. Install from https://www.python.org/"
    exit 1
fi

if command -v python3 >/dev/null 2>&1; then
    PY=python3
else
    PY=python
fi

if [ ! -d "$DEPS/dear_bindings" ]; then
    echo "Cloning dear_bindings..."
    mkdir -p "$DEPS"
    git clone --depth 1 --branch "$DEAR_BINDINGS_TAG" \
        https://github.com/dearimgui/dear_bindings.git "$DEPS/dear_bindings"
fi

echo "Generating dcimgui from imgui.h..."
$PY "$DEPS/dear_bindings/dear_bindings.py" \
    --nogeneratedefaultargfunctions \
    -o "${VENDOR}dcimgui" \
    "${VENDOR}imgui.h"

echo "Fixing Odin binding link-prefixes for underscore-namespaced functions..."
$PY "${VENDOR}fix_foreign_prefixes.py" "${VENDOR}imgui.odin"

echo "Done. Generated files:"
ls -1 "${VENDOR}dcimgui"*
