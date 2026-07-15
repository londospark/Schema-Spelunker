#!/bin/sh
set -e

: "${CC:=}"
: "${CXX:=}"
: "${AR:=ar}"

detect_cc() {
    if [ -n "$CC" ]; then
        return 0
    fi
    for c in gcc clang cc; do
        if command -v "$c" >/dev/null 2>&1; then
            CC="$c"
            return 0
        fi
    done
    echo "Error: C compiler not found."
    echo "Install GCC or Clang from your package manager."
    echo "  Debian/Ubuntu: sudo apt install gcc g++"
    echo "  Fedora: sudo dnf install gcc gcc-c++"
    echo "  Arch: sudo pacman -S gcc"
    exit 1
}

detect_cxx() {
    if [ -n "$CXX" ]; then
        return 0
    fi
    for c in g++ clang++ c++; do
        if command -v "$c" >/dev/null 2>&1; then
            CXX="$c"
            return 0
        fi
    done
    echo "Error: C++ compiler not found."
    exit 1
}

ensure_sqlite() {
    if [ -f vendor/sqlite3/sqlite3.a ]; then
        return 0
    fi

    detect_cc

    echo "Compiling SQLite from source..."
    $CC -c -O2 \
        -Wno-discarded-qualifiers \
        -DSQLITE_THREADSAFE=0 \
        -DSQLITE_OMIT_LOAD_EXTENSION \
        -DSQLITE_DEFAULT_MEMSTATUS=0 \
        vendor/sqlite3/sqlite3.c \
        -o vendor/sqlite3/sqlite3.o
    $AR rcs vendor/sqlite3/sqlite3.a vendor/sqlite3/sqlite3.o
    rm vendor/sqlite3/sqlite3.o
}

ensure_imgui() {
    if [ -f vendor/imgui/imgui.a ]; then
        return 0
    fi

    detect_cxx

    echo "Compiling ImGui + ImNodes + backends from source..."

    mkdir -p build/imgui

    IMGUI=vendor/imgui
    SDL3INC=vendor/sdl3_headers

    CFLAGS="-std=c++17 -O2 -DIMGUI_ENABLE_DOCKING -DIMGUI_IMPL_API="
    INC="-I$IMGUI -I$IMGUI/backends -I$SDL3INC"

    $CXX -c $CFLAGS $INC \
        "$IMGUI/dcimgui.cpp" \
        "$IMGUI/imgui.cpp" \
        "$IMGUI/imgui_demo.cpp" \
        "$IMGUI/imgui_draw.cpp" \
        "$IMGUI/imgui_tables.cpp" \
        "$IMGUI/imgui_widgets.cpp" \
        "$IMGUI/dcimnodes.cpp" \
        "$IMGUI/imnodes.cpp" \
        "$IMGUI/backends/imgui_impl_sdl3.cpp" \
        "$IMGUI/backends/imgui_impl_opengl3.cpp"

    $AR rcs "$IMGUI/imgui.a" *.o
    mv *.o build/imgui/
    rm -rf build/imgui
}

ensure_sqlite
ensure_imgui
