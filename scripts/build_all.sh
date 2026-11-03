#!/usr/bin/env bash
# ==============================================================================
# scripts/build_all.sh
#
# Unified cross-platform build script for Oh-Mini-Mineral (Linux / macOS / Windows):
# - Pure Pascal Lazy Codec Pool (bin/codecs/libcodec_*.{so,dylib,dll})
# - FPC Local Core Daemon (bin/omm_daemon[.exe])
# - Free Pascal Stateless Terminal Client (bin/omm_tui[.exe])
# - Lazarus LCL Desktop Client (bin/omm_gui[.exe])
# - Rust Streaming Plugin cdylib (bin/libomm_mineral.{so,dylib,dll})
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYSROOT_FPC="${WORKSPACE_ROOT}/.sysroot/fpc"
BIN_DIR="${WORKSPACE_ROOT}/bin"
UNITS_ROOT="${WORKSPACE_ROOT}/target/fpc-units"

OS_UNAME="$(uname -s)"
case "${OS_UNAME}" in
    Linux*)
        PLATFORM="linux"
        LIB_EXT=".so"
        EXE_EXT=""
        WIDGETSET="gtk2"
        GC_FLAGS=("-k--gc-sections")
        MAX_DAEMON_BYTES=819200    # 800 KB
        MAX_TUI_BYTES=409600       # 400 KB
        MAX_GUI_BYTES=2936012      # 2.8 MB
        MAX_CODEC_BYTES=131072     # 128 KB
        ;;
    Darwin*)
        PLATFORM="macos"
        LIB_EXT=".dylib"
        EXE_EXT=""
        WIDGETSET="cocoa"
        GC_FLAGS=("-k-dead_strip")
        MAX_DAEMON_BYTES=3145728   # Universal binary (x86_64 + arm64)
        MAX_TUI_BYTES=2097152
        MAX_GUI_BYTES=12582912
        MAX_CODEC_BYTES=1048576
        ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT*)
        PLATFORM="windows"
        LIB_EXT=".dll"
        EXE_EXT=".exe"
        WIDGETSET="win32"
        GC_FLAGS=()
        MAX_DAEMON_BYTES=1572864
        MAX_TUI_BYTES=1048576
        MAX_GUI_BYTES=8388608
        MAX_CODEC_BYTES=524288
        ;;
    *)
        PLATFORM="linux"
        LIB_EXT=".so"
        EXE_EXT=""
        WIDGETSET="gtk2"
        GC_FLAGS=()
        MAX_DAEMON_BYTES=1572864
        MAX_TUI_BYTES=1048576
        MAX_GUI_BYTES=8388608
        MAX_CODEC_BYTES=524288
        ;;
esac

TARGET="${1:-all}"

export PATH="${HOME}/.cargo/bin:${PATH}"

USE_SYSROOT=0
if [[ "${PLATFORM}" == "linux" ]]; then
    if [[ -x "${SYSROOT_FPC}/usr/bin/ppcx64" ]]; then
        USE_SYSROOT=1
    elif ! command -v fpc >/dev/null 2>&1; then
        echo "FPC toolchain not found in PATH or ${SYSROOT_FPC}. Running setup_fpc.sh..."
        "${SCRIPT_DIR}/setup_fpc.sh"
        USE_SYSROOT=1
    fi
fi

if [[ "${USE_SYSROOT}" -eq 1 ]]; then
    export PATH="${SYSROOT_FPC}/usr/bin:${PATH}"
    export LD_LIBRARY_PATH="${SYSROOT_FPC}/lib64:${LD_LIBRARY_PATH:-}"
    FPC_CMD=("ppcx64" "@${SYSROOT_FPC}/etc/fpc.cfg" "-FD${SYSROOT_FPC}/usr/bin" "-Fl${SYSROOT_FPC}/lib64" "-Fl/usr/lib64")
else
    FPC_CMD=("fpc")
fi

mkdir -p "${BIN_DIR}" "${UNITS_ROOT}"

file_size() {
    local file="$1"
    if stat -c%s "${file}" >/dev/null 2>&1; then
        stat -c%s "${file}"
    elif stat -f%z "${file}" >/dev/null 2>&1; then
        stat -f%z "${file}"
    else
        wc -c < "${file}" | tr -d '[:space:]'
    fi
}

format_size() {
    local bytes="$1"
    if (( bytes < 1024 )); then
        echo "${bytes} B"
    elif (( bytes < 1048576 )); then
        awk -v b="$bytes" 'BEGIN { printf "%.1f KB", b / 1024 }'
    else
        awk -v b="$bytes" 'BEGIN { printf "%.2f MB", b / 1048576 }'
    fi
}

check_size() {
    local file="$1"
    local max="$2"
    local name="$3"
    local size
    size="$(file_size "${file}")"
    local size_fmt
    size_fmt="$(format_size "${size}")"
    local max_fmt
    max_fmt="$(format_size "${max}")"

    if (( size > max )); then
        echo "  [FAIL] ${name} size ${size_fmt} exceeds budget of ${max_fmt}!" >&2
        return 1
    else
        echo "  [PASS] ${name} size: ${size_fmt} (budget: ${max_fmt})"
        return 0
    fi
}

strip_binary() {
    local file="$1"
    if [[ "${PLATFORM}" == "linux" ]]; then
        strip --strip-unneeded "${file}" 2>/dev/null || true
    elif [[ "${PLATFORM}" == "macos" ]]; then
        strip -x "${file}" 2>/dev/null || true
    elif [[ "${PLATFORM}" == "windows" ]]; then
        strip --strip-unneeded "${file}" 2>/dev/null || true
    fi
}

# Compile helper that produces Universal (x86_64 + aarch64) binaries on macOS when both compilers exist
compile_fpc_target() {
    local out_file="$1"
    local unit_subdir="$2"
    shift 2
    local extra_args=("$@")

    if [[ "${PLATFORM}" == "macos" ]] && command -v ppcx64 >/dev/null 2>&1 && command -v ppca64 >/dev/null 2>&1 && command -v lipo >/dev/null 2>&1; then
        local u_x64="${UNITS_ROOT}/${unit_subdir}_x86_64"
        local u_arm="${UNITS_ROOT}/${unit_subdir}_aarch64"
        mkdir -p "${u_x64}" "${u_arm}"
        fpc -Px86_64 -FU"${u_x64}" "${extra_args[@]}" -o"${out_file}.x86_64"
        fpc -Paarch64 -FU"${u_arm}" "${extra_args[@]}" -o"${out_file}.arm64"
        strip -x "${out_file}.x86_64" 2>/dev/null || true
        strip -x "${out_file}.arm64" 2>/dev/null || true
        lipo -create -output "${out_file}" "${out_file}.x86_64" "${out_file}.arm64"
        rm -f "${out_file}.x86_64" "${out_file}.arm64"
    else
        local u_dir="${UNITS_ROOT}/${unit_subdir}"
        mkdir -p "${u_dir}"
        "${FPC_CMD[@]}" -FU"${u_dir}" "${extra_args[@]}" -o"${out_file}"
        strip_binary "${out_file}"
    fi
}

# ------------------------------------------------------------------------------
# Target 0: Pure Pascal Lazy Codec Pool (bin/codecs/libcodec_*.{so,dylib,dll})
# ------------------------------------------------------------------------------
build_codecs() {
    echo "=== Building Target: Pure Pascal Lazy Codec Pool (bin/codecs/*${LIB_EXT}) ==="
    local CODECS_SRC_DIR="${WORKSPACE_ROOT}/src/codecs"
    local COMMON_DIR="${WORKSPACE_ROOT}/src/common"
    local CODECS_BIN_DIR="${BIN_DIR}/codecs"

    mkdir -p "${CODECS_BIN_DIR}"

    for lpr in "${CODECS_SRC_DIR}"/libcodec_*.lpr; do
        [[ -f "${lpr}" ]] || continue
        local base
        base="$(basename "${lpr}" .lpr)"
        local out_lib="${CODECS_BIN_DIR}/${base}${LIB_EXT}"

        echo "Compiling ${base}${LIB_EXT}..."
        compile_fpc_target "${out_lib}" "codecs_${base}" \
            -Fu"${COMMON_DIR}" \
            -Fu"${CODECS_SRC_DIR}" \
            -Cg -XX -Xs -Os \
            "${GC_FLAGS[@]}" \
            "${lpr}"

        check_size "${out_lib}" "${MAX_CODEC_BYTES}" "${base}${LIB_EXT}"
    done
}

# ------------------------------------------------------------------------------
# Target 1: Daemon (omm_daemon)
# ------------------------------------------------------------------------------
build_daemon() {
    echo "=== Building Target: omm_daemon${EXE_EXT} (100% Pure Free Pascal Microkernel) ==="
    local DAEMON_DIR="${WORKSPACE_ROOT}/src/daemon"
    local COMMON_DIR="${WORKSPACE_ROOT}/src/common"
    local DAEMON_LPR="${DAEMON_DIR}/omm_daemon.lpr"
    local DAEMON_BIN="${BIN_DIR}/omm_daemon${EXE_EXT}"

    if [[ ! -f "${DAEMON_LPR}" ]]; then
        echo "Notice: ${DAEMON_LPR} not yet implemented."
        return 0
    fi

    echo "Compiling omm_daemon${EXE_EXT}..."
    compile_fpc_target "${DAEMON_BIN}" "daemon" \
        -Fu"${COMMON_DIR}" \
        -Fu"${DAEMON_DIR}" \
        -Fi"${DAEMON_DIR}" \
        -XX -Xs -Os \
        "${GC_FLAGS[@]}" \
        "${DAEMON_LPR}"

    check_size "${DAEMON_BIN}" "${MAX_DAEMON_BYTES}" "omm_daemon${EXE_EXT}"
}

# ------------------------------------------------------------------------------
# Target 2: TUI (omm_tui)
# ------------------------------------------------------------------------------
build_tui() {
    echo "=== Building Target: omm_tui${EXE_EXT} ==="
    local TUI_DIR="${WORKSPACE_ROOT}/src/tui"
    local COMMON_DIR="${WORKSPACE_ROOT}/src/common"
    local TUI_PAS="${TUI_DIR}/omm_tui.pas"
    local TUI_BIN="${BIN_DIR}/omm_tui${EXE_EXT}"

    if [[ ! -f "${TUI_PAS}" ]]; then
        echo "Notice: ${TUI_PAS} not yet implemented."
        return 0
    fi

    echo "Compiling omm_tui${EXE_EXT}..."
    compile_fpc_target "${TUI_BIN}" "tui" \
        -Fu"${COMMON_DIR}" \
        -Fu"${TUI_DIR}" \
        -Fu"${WORKSPACE_ROOT}/src/daemon" \
        -XX -Xs -Os \
        "${TUI_PAS}"

    check_size "${TUI_BIN}" "${MAX_TUI_BYTES}" "omm_tui${EXE_EXT}"
}

# ------------------------------------------------------------------------------
# Target 3: GUI (omm_gui)
# ------------------------------------------------------------------------------
build_gui() {
    echo "=== Building Target: omm_gui${EXE_EXT} (${WIDGETSET}) ==="
    local GUI_DIR="${WORKSPACE_ROOT}/src/gui"
    local COMMON_DIR="${WORKSPACE_ROOT}/src/common"
    local GUI_LPR="${GUI_DIR}/omm_gui.lpr"
    local GUI_LPI="${GUI_DIR}/omm_gui.lpi"
    local GUI_BIN="${BIN_DIR}/omm_gui${EXE_EXT}"

    if [[ ! -f "${GUI_LPR}" ]]; then
        echo "Notice: ${GUI_LPR} not yet implemented."
        return 0
    fi

    if [[ "${USE_SYSROOT}" -eq 1 ]]; then
        echo "Compiling omm_gui directly with sysroot ppcx64 (-dLCL -dLCLgtk2 -XX -Xs -Os -k--gc-sections)..."
        mkdir -p "${UNITS_ROOT}/gui"
        "${FPC_CMD[@]}" \
            -FU"${UNITS_ROOT}/gui" \
            -Fu"${COMMON_DIR}" \
            -Fu"${GUI_DIR}" \
            -Fu"${WORKSPACE_ROOT}/src/daemon" \
            -Fu"${SYSROOT_FPC}/usr/lib64/lazarus/lcl/units/x86_64-linux" \
            -Fu"${SYSROOT_FPC}/usr/lib64/lazarus/lcl/units/x86_64-linux/gtk2" \
            -Fu"${SYSROOT_FPC}/usr/lib64/lazarus/components/lazutils/lib/x86_64-linux" \
            -Fi"${SYSROOT_FPC}/usr/lib64/lazarus/lcl/include" \
            -dLCL -dLCLgtk2 \
            -XX -Xs -Os \
            "${GC_FLAGS[@]}" \
            -o"${GUI_BIN}" \
            "${GUI_LPR}"
    else
        echo "Compiling omm_gui${EXE_EXT} with lazbuild (--ws=${WIDGETSET})..."
        lazbuild \
            --ws="${WIDGETSET}" \
            --build-mode=Release \
            "${GUI_LPI}"
        if [[ -f "${GUI_DIR}/omm_gui${EXE_EXT}" ]] && [[ ! -f "${GUI_BIN}" ]]; then
            mv "${GUI_DIR}/omm_gui${EXE_EXT}" "${GUI_BIN}"
        fi
        strip_binary "${GUI_BIN}"
    fi

    check_size "${GUI_BIN}" "${MAX_GUI_BYTES}" "omm_gui${EXE_EXT}"
}

# ------------------------------------------------------------------------------
# Target 4: Rust Streaming Plugin (libomm_mineral.{so,dylib,dll})
# ------------------------------------------------------------------------------
build_plugin() {
    echo "=== Building Target: libomm_mineral${LIB_EXT} ==="
    local PLUGIN_CRATE="${WORKSPACE_ROOT}/crates/omm-mineral"
    local PLUGIN_TOML="${PLUGIN_CRATE}/Cargo.toml"
    local DEST_LIB="${BIN_DIR}/libomm_mineral${LIB_EXT}"

    if [[ ! -f "${PLUGIN_TOML}" ]]; then
        echo "Notice: ${PLUGIN_TOML} not yet implemented."
        return 0
    fi

    if [[ "${PLATFORM}" == "macos" ]] && command -v rustup >/dev/null 2>&1 && command -v lipo >/dev/null 2>&1; then
        echo "Compiling Universal (x86_64 + aarch64) libomm_mineral.dylib on macOS..."
        rustup target add x86_64-apple-darwin aarch64-apple-darwin >/dev/null 2>&1 || true
        if cargo build --manifest-path "${PLUGIN_TOML}" --target-dir "${WORKSPACE_ROOT}/target" --target x86_64-apple-darwin --release && \
           cargo build --manifest-path "${PLUGIN_TOML}" --target-dir "${WORKSPACE_ROOT}/target" --target aarch64-apple-darwin --release; then
            lipo -create -output "${DEST_LIB}" \
                "${WORKSPACE_ROOT}/target/x86_64-apple-darwin/release/libomm_mineral.dylib" \
                "${WORKSPACE_ROOT}/target/aarch64-apple-darwin/release/libomm_mineral.dylib"
            local size
            size="$(file_size "${DEST_LIB}")"
            echo "  [PASS] Universal libomm_mineral.dylib size: $(format_size "${size}")"
            return 0
        fi
    fi

    echo "Compiling omm-mineral crate via cargo build --release..."
    cargo build --manifest-path "${PLUGIN_TOML}" --target-dir "${WORKSPACE_ROOT}/target" --release

    local TARGET_LIB=""
    if [[ -f "${WORKSPACE_ROOT}/target/release/libomm_mineral${LIB_EXT}" ]]; then
        TARGET_LIB="${WORKSPACE_ROOT}/target/release/libomm_mineral${LIB_EXT}"
    elif [[ -f "${WORKSPACE_ROOT}/target/release/omm_mineral${LIB_EXT}" ]]; then
        TARGET_LIB="${WORKSPACE_ROOT}/target/release/omm_mineral${LIB_EXT}"
    fi

    if [[ -n "${TARGET_LIB}" && -f "${TARGET_LIB}" ]]; then
        cp -f "${TARGET_LIB}" "${DEST_LIB}"
        if [[ "${PLATFORM}" == "windows" ]]; then
            cp -f "${TARGET_LIB}" "${BIN_DIR}/omm_mineral.dll"
        fi
        local size
        size="$(file_size "${DEST_LIB}")"
        echo "  [PASS] libomm_mineral${LIB_EXT} size: $(format_size "${size}")"
        if [[ "${PLATFORM}" == "linux" ]] && command -v nm >/dev/null 2>&1; then
            if nm -D "${DEST_LIB}" | grep -q "omm_plugin_get_vtable"; then
                echo "  [OK] Export symbol 'omm_plugin_get_vtable' verified."
            fi
        elif [[ "${PLATFORM}" == "macos" ]] && command -v nm >/dev/null 2>&1; then
            if nm -gU "${DEST_LIB}" | grep -q "omm_plugin_get_vtable"; then
                echo "  [OK] Export symbol 'omm_plugin_get_vtable' verified."
            fi
        fi
    else
        echo "  [FAIL] Built plugin library not found in ${WORKSPACE_ROOT}/target/release/" >&2
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Clean
# ------------------------------------------------------------------------------
clean_all() {
    echo "=== Cleaning build artifacts ==="
    rm -rf "${BIN_DIR}"
    rm -rf "${UNITS_ROOT}"
    rm -rf "${WORKSPACE_ROOT}/src/gui/lib"
    rm -f "${WORKSPACE_ROOT}/src/daemon/miniaudio_wrapper.o"
    find "${WORKSPACE_ROOT}/src" -type f \( -name "*.o" -o -name "*.or" -o -name "*.ppu" -o -name "*.compiled" -o -name "*.a" -o -name "*.res" \) -delete
    echo "Done."
}

# ------------------------------------------------------------------------------
# Main Dispatch
# ------------------------------------------------------------------------------
case "${TARGET}" in
    codecs)
        build_codecs
        ;;
    daemon)
        build_codecs
        build_daemon
        ;;
    tui)
        build_tui
        ;;
    gui)
        build_gui
        ;;
    plugin)
        build_plugin
        ;;
    clean)
        clean_all
        ;;
    all)
        build_codecs
        build_daemon
        build_tui
        build_gui
        build_plugin
        echo ""
        echo "=== Build All Summary ==="
        ls -lh "${BIN_DIR}" "${BIN_DIR}/codecs" 2>/dev/null || true
        ;;
    *)
        echo "Usage: $0 [all|codecs|daemon|tui|gui|plugin|clean]"
        exit 1
        ;;
esac
