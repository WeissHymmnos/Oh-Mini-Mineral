#!/usr/bin/env bash
# ==============================================================================
# scripts/build_all.sh
# 
# Unified build script for Oh-My-Mineral:
# - FPC Local Core Daemon (bin/omm_daemon) [< 800 KB]
# - Free Pascal Stateless Terminal Client (bin/omm_tui) [< 400 KB]
# - Lazarus LCL Desktop Client (bin/omm_gui) [< 2.8 MB]
# - Rust Streaming Plugin cdylib (bin/libomm_mineral.so)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYSROOT_FPC="${WORKSPACE_ROOT}/.sysroot/fpc"
BIN_DIR="${WORKSPACE_ROOT}/bin"

# Budget thresholds (in bytes)
MAX_DAEMON_BYTES=819200    # 800 KB
MAX_TUI_BYTES=409600       # 400 KB
MAX_GUI_BYTES=2936012      # 2.8 MB

TARGET="${1:-all}"

# Ensure toolchain is deployed
if [[ ! -x "${SYSROOT_FPC}/usr/bin/ppcx64" ]]; then
    echo "FPC toolchain not found at ${SYSROOT_FPC}. Running setup_fpc.sh..."
    "${SCRIPT_DIR}/setup_fpc.sh"
fi

export PATH="${SYSROOT_FPC}/usr/bin:${HOME}/.cargo/bin:${PATH}"
export LD_LIBRARY_PATH="${SYSROOT_FPC}/lib64:${LD_LIBRARY_PATH:-}"

mkdir -p "${BIN_DIR}"

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
    size="$(stat -c%s "${file}")"
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

# ------------------------------------------------------------------------------
# Target 0: Pure Pascal Lazy Codec Pool (bin/codecs/libcodec_*.so)
# ------------------------------------------------------------------------------
build_codecs() {
    echo "=== Building Target: Pure Pascal Lazy Codec Pool (bin/codecs/*.so) ==="
    local CODECS_SRC_DIR="${WORKSPACE_ROOT}/src/codecs"
    local COMMON_DIR="${WORKSPACE_ROOT}/src/common"
    local CODECS_BIN_DIR="${BIN_DIR}/codecs"
    local MAX_CODEC_BYTES=131072 # 128 KB budget per micro-plugin

    mkdir -p "${CODECS_BIN_DIR}"

    for lpr in "${CODECS_SRC_DIR}"/libcodec_*.lpr; do
        [[ -f "${lpr}" ]] || continue
        local base
        base="$(basename "${lpr}" .lpr)"
        local out_so="${CODECS_BIN_DIR}/${base}.so"

        echo "Compiling ${base}.so with ppcx64 (-XX -Xs -Os -k--gc-sections)..."
        ppcx64 @"${SYSROOT_FPC}/etc/fpc.cfg" \
            -FD"${SYSROOT_FPC}/usr/bin" \
            -Fu"${COMMON_DIR}" \
            -Fu"${CODECS_SRC_DIR}" \
            -Fl"${SYSROOT_FPC}/lib64" \
            -Fl/usr/lib64 \
            -Cg -XX -Xs -Os \
            -k--gc-sections \
            -o"${out_so}" \
            "${lpr}"

        strip --strip-unneeded "${out_so}" 2>/dev/null || true
        check_size "${out_so}" "${MAX_CODEC_BYTES}" "${base}.so"
    done
}

# ------------------------------------------------------------------------------
# Target 1: Daemon (omm_daemon)
# ------------------------------------------------------------------------------
build_daemon() {
    echo "=== Building Target: omm_daemon (100% Pure Free Pascal Microkernel) ==="
    local DAEMON_DIR="${WORKSPACE_ROOT}/src/daemon"
    local COMMON_DIR="${WORKSPACE_ROOT}/src/common"
    local DAEMON_LPR="${DAEMON_DIR}/omm_daemon.lpr"
    local DAEMON_BIN="${BIN_DIR}/omm_daemon"

    if [[ ! -f "${DAEMON_LPR}" ]]; then
        echo "Notice: ${DAEMON_LPR} not yet implemented."
        return 0
    fi

    echo "Compiling omm_daemon with ppcx64 (-XX -Xs -Os -k--gc-sections)..."
    ppcx64 @"${SYSROOT_FPC}/etc/fpc.cfg" \
        -FD"${SYSROOT_FPC}/usr/bin" \
        -Fu"${COMMON_DIR}" \
        -Fu"${DAEMON_DIR}" \
        -Fi"${DAEMON_DIR}" \
        -Fl"${SYSROOT_FPC}/lib64" \
        -Fl/usr/lib64 \
        -XX -Xs -Os \
        -k--gc-sections \
        -o"${DAEMON_BIN}" \
        "${DAEMON_LPR}"

    check_size "${DAEMON_BIN}" "${MAX_DAEMON_BYTES}" "omm_daemon"
}

# ------------------------------------------------------------------------------
# Target 2: TUI (omm_tui)
# ------------------------------------------------------------------------------
build_tui() {
    echo "=== Building Target: omm_tui ==="
    local TUI_DIR="${WORKSPACE_ROOT}/src/tui"
    local COMMON_DIR="${WORKSPACE_ROOT}/src/common"
    local TUI_PAS="${TUI_DIR}/omm_tui.pas"
    local TUI_BIN="${BIN_DIR}/omm_tui"

    if [[ ! -f "${TUI_PAS}" ]]; then
        echo "Notice: ${TUI_PAS} not yet implemented (pending Milestone 4)."
        return 0
    fi

    echo "Compiling omm_tui with ppcx64 (-XX -Xs -Os)..."
    ppcx64 @"${SYSROOT_FPC}/etc/fpc.cfg" \
        -FD"${SYSROOT_FPC}/usr/bin" \
        -Fu"${COMMON_DIR}" \
        -Fu"${TUI_DIR}" \
        -Fl/usr/lib64 \
        -XX -Xs -Os \
        -o"${TUI_BIN}" \
        "${TUI_PAS}"

    check_size "${TUI_BIN}" "${MAX_TUI_BYTES}" "omm_tui"
}

# ------------------------------------------------------------------------------
# Target 3: GUI (omm_gui)
# ------------------------------------------------------------------------------
build_gui() {
    echo "=== Building Target: omm_gui ==="
    local GUI_DIR="${WORKSPACE_ROOT}/src/gui"
    local COMMON_DIR="${WORKSPACE_ROOT}/src/common"
    local GUI_LPR="${GUI_DIR}/omm_gui.lpr"
    local GUI_LPI="${GUI_DIR}/omm_gui.lpi"
    local GUI_BIN="${BIN_DIR}/omm_gui"

    if [[ ! -f "${GUI_LPR}" ]]; then
        echo "Notice: ${GUI_LPR} not yet implemented (pending Milestone 4)."
        return 0
    fi

    if [[ -f "${GUI_LPI}" ]]; then
        echo "Compiling omm_gui with lazbuild (GTK2 widgetset, Release mode)..."
        lazbuild \
            --pcp="${SYSROOT_FPC}/pcp" \
            --lazarusdir="${SYSROOT_FPC}/usr/lib64/lazarus" \
            --compiler="${SYSROOT_FPC}/usr/bin/ppcx64" \
            --ws=gtk2 \
            --build-mode=Release \
            --opt="-XX -Xs -Os -Fl${SYSROOT_FPC}/lib64 -Fl/usr/lib64" \
            "${GUI_LPI}"
        # Ensure output is placed in bin/
        if [[ -f "${GUI_DIR}/omm_gui" ]] && [[ ! -f "${GUI_BIN}" ]]; then
            mv "${GUI_DIR}/omm_gui" "${GUI_BIN}"
        fi
    else
        echo "Compiling omm_gui directly with ppcx64 (-dLCL -dLCLgtk2 -XX -Xs -Os -k--gc-sections)..."
        ppcx64 @"${SYSROOT_FPC}/etc/fpc.cfg" \
            -FD"${SYSROOT_FPC}/usr/bin" \
            -Fu"${COMMON_DIR}" \
            -Fu"${GUI_DIR}" \
            -Fu"${WORKSPACE_ROOT}/src/daemon" \
            -Fu"${SYSROOT_FPC}/usr/lib64/lazarus/lcl/units/x86_64-linux" \
            -Fu"${SYSROOT_FPC}/usr/lib64/lazarus/lcl/units/x86_64-linux/gtk2" \
            -Fu"${SYSROOT_FPC}/usr/lib64/lazarus/components/lazutils/lib/x86_64-linux" \
            -Fi"${SYSROOT_FPC}/usr/lib64/lazarus/lcl/include" \
            -Fl"${SYSROOT_FPC}/lib64" \
            -Fl/usr/lib64 \
            -dLCL -dLCLgtk2 \
            -XX -Xs -Os \
            -k--gc-sections \
            -o"${GUI_BIN}" \
            "${GUI_LPR}"
    fi

    check_size "${GUI_BIN}" "${MAX_GUI_BYTES}" "omm_gui"
}

# ------------------------------------------------------------------------------
# Target 4: Rust Streaming Plugin (libomm_mineral.so)
# ------------------------------------------------------------------------------
build_plugin() {
    echo "=== Building Target: libomm_mineral.so ==="
    local PLUGIN_CRATE="${WORKSPACE_ROOT}/crates/omm-mineral"
    local PLUGIN_TOML="${PLUGIN_CRATE}/Cargo.toml"
    local TARGET_SO="${WORKSPACE_ROOT}/target/release/libomm_mineral.so"
    local DEST_SO="${BIN_DIR}/libomm_mineral.so"

    if [[ ! -f "${PLUGIN_TOML}" ]]; then
        echo "Notice: ${PLUGIN_TOML} not yet implemented (pending Milestone 2)."
        return 0
    fi

    echo "Compiling omm-mineral crate via cargo build --release..."
    cargo build --manifest-path "${PLUGIN_TOML}" --release

    if [[ -f "${TARGET_SO}" ]]; then
        cp -f "${TARGET_SO}" "${DEST_SO}"
        local size
        size="$(stat -c%s "${DEST_SO}")"
        echo "  [PASS] libomm_mineral.so size: $(format_size "${size}")"
        # Verify C-ABI VTable export
        if nm -D "${DEST_SO}" | grep -q "omm_plugin_get_vtable"; then
            echo "  [OK] Export symbol 'omm_plugin_get_vtable' verified."
        else
            echo "  [WARNING] 'omm_plugin_get_vtable' export not found in dynamic symbol table!" >&2
        fi
    fi
}

# ------------------------------------------------------------------------------
# Clean
# ------------------------------------------------------------------------------
clean_all() {
    echo "=== Cleaning build artifacts ==="
    rm -rf "${BIN_DIR}"
    rm -f "${WORKSPACE_ROOT}/src/daemon/miniaudio_wrapper.o"
    find "${WORKSPACE_ROOT}/src" -type f \( -name "*.o" -o -name "*.or" -o -name "*.ppu" -o -name "*.compiled" -o -name "*.a" \) -delete
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
