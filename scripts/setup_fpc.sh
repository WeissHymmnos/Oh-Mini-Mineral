#!/usr/bin/env bash
# ==============================================================================
# scripts/setup_fpc.sh
# 
# Deploys Free Pascal Compiler (FPC 3.2.2) and Lazarus LCL (4.8) toolchain
# into the project sysroot at .sysroot/fpc without requiring root permissions.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYSROOT_DIR="${WORKSPACE_ROOT}/.sysroot"
TARGET_DIR="${SYSROOT_DIR}/fpc"
CACHE_DIR="${WORKSPACE_ROOT}/.cache/rpms"

echo "=== Oh-My-Mineral: Free Pascal & Lazarus Toolchain Setup ==="
echo "Workspace root: ${WORKSPACE_ROOT}"
echo "Target directory: ${TARGET_DIR}"

# 1. Quick check if toolchain is already operational
if [[ -x "${TARGET_DIR}/usr/bin/ppcx64" ]] && [[ -x "${TARGET_DIR}/usr/bin/lazbuild" ]]; then
    FPC_VER="$("${TARGET_DIR}/usr/bin/ppcx64" -iV 2>/dev/null || true)"
    LAZ_VER="$("${TARGET_DIR}/usr/bin/lazbuild" --version 2>/dev/null || true)"
    if [[ "${FPC_VER}" == "3.2.2" ]] && [[ "${LAZ_VER}" == "4.8" ]]; then
        echo "[OK] Free Pascal (${FPC_VER}) and Lazarus (${LAZ_VER}) are already installed and functional."
        echo "Toolchain path: ${TARGET_DIR}/usr/bin"
        exit 0
    fi
fi

# 2. Prepare directories
mkdir -p "${CACHE_DIR}"
mkdir -p "${TARGET_DIR}"

# 3. Locate or acquire RPM packages
REQUIRED_RPMS=(
    "fpc-3.2.2-5.8.x86_64.rpm"
    "lazarus-tools-4.8-1.2.x86_64.rpm"
    "lazarus-lcl-4.8-1.2.x86_64.rpm"
    "lazarus-lcl-gtk2-4.8-1.2.x86_64.rpm"
    "miniaudio-devel-0.11.25-1.2.noarch.rpm"
)

# Look in survey cache first
SURVEY_CACHE="${WORKSPACE_ROOT}/.agents/teamwork/teamwork_explorer_fpc_survey_1/cache"

echo "Checking package cache..."
MISSING_PACKAGES=()
for rpm in "${REQUIRED_RPMS[@]}"; do
    if [[ ! -f "${CACHE_DIR}/${rpm}" ]]; then
        # Check survey cache
        FOUND_RPM="$(find "${SURVEY_CACHE}" -name "${rpm}" 2>/dev/null | head -n 1 || true)"
        if [[ -n "${FOUND_RPM}" ]] && [[ -f "${FOUND_RPM}" ]]; then
            echo "Copying ${rpm} from survey cache..."
            cp "${FOUND_RPM}" "${CACHE_DIR}/${rpm}"
        else
            MISSING_PACKAGES+=("${rpm}")
        fi
    fi
done

# If any packages are missing, download them via zypper
if [[ ${#MISSING_PACKAGES[@]} -gt 0 ]]; then
    echo "Downloading missing RPM packages via zypper..."
    PACKAGE_NAMES=()
    for rpm in "${MISSING_PACKAGES[@]}"; do
        case "${rpm}" in
            fpc*) PACKAGE_NAMES+=("fpc") ;;
            lazarus-tools*) PACKAGE_NAMES+=("lazarus-tools") ;;
            lazarus-lcl-gtk2*) PACKAGE_NAMES+=("lazarus-lcl-gtk2") ;;
            lazarus-lcl*) PACKAGE_NAMES+=("lazarus-lcl") ;;
            miniaudio-devel*) PACKAGE_NAMES+=("miniaudio-devel") ;;
        esac
    done

    zypper --pkg-cache-dir "${CACHE_DIR}" download "${PACKAGE_NAMES[@]}"
    
    # Flatten any nested zypper download subdirectories into CACHE_DIR
    find "${CACHE_DIR}" -type f -name "*.rpm" -exec cp -u {} "${CACHE_DIR}/" \;
fi

# Verify all required RPMs exist
for rpm in "${REQUIRED_RPMS[@]}"; do
    if [[ ! -f "${CACHE_DIR}/${rpm}" ]]; then
        echo "ERROR: Required package ${rpm} could not be acquired." >&2
        exit 1
    fi
done

# 4. Extract RPMs into .sysroot/fpc
echo "Extracting RPM packages into ${TARGET_DIR}..."
cd "${TARGET_DIR}"
for rpm in "${REQUIRED_RPMS[@]}"; do
    echo "  Extracting ${rpm}..."
    rpm2cpio "${CACHE_DIR}/${rpm}" | cpio -idmv --quiet
done

# 5. Configure relocated fpc.cfg
echo "Configuring relocated fpc.cfg..."
FPC_CFG="${TARGET_DIR}/etc/fpc.cfg"
if [[ ! -f "${FPC_CFG}" ]]; then
    echo "ERROR: ${FPC_CFG} was not created during extraction." >&2
    exit 1
fi

# Backup original fpc.cfg
cp -f "${FPC_CFG}" "${FPC_CFG}.orig"

# Relocate standard FPC unit and binary paths
sed -i "s|/usr/lib64/fpc/3.2.2/units/|${TARGET_DIR}/usr/lib64/fpc/3.2.2/units/|g" "${FPC_CFG}"
sed -i "s|-FD/usr/lib64/fpc/3.2.2/bin/\$FPCTARGET|-FD${TARGET_DIR}/usr/bin\n-FD${TARGET_DIR}/usr/lib64/fpc/3.2.2/bin/\$FPCTARGET|g" "${FPC_CFG}"
sed -i "s|-Fl/usr/lib64/fpc/3.2.2/lib/\$FPCTARGET|-Fl${TARGET_DIR}/lib64\n-Fl${TARGET_DIR}/usr/lib64/fpc/3.2.2/lib/\$FPCTARGET\n-Fl/usr/lib64|g" "${FPC_CFG}"

# Append Lazarus LCL units and include paths if not already present
if ! grep -q "lazarus/lcl/units" "${FPC_CFG}"; then
    cat >> "${FPC_CFG}" <<EOF

# ----------------------------------------------------
# Lazarus LCL & LazUtils Relocated Unit Search Paths
# ----------------------------------------------------
-Fu${TARGET_DIR}/usr/lib64/lazarus/lcl/units/\$fpctarget
-Fu${TARGET_DIR}/usr/lib64/lazarus/lcl/units/\$fpctarget/gtk2
-Fu${TARGET_DIR}/usr/lib64/lazarus/components/lazutils/lib/\$fpctarget
-Fi${TARGET_DIR}/usr/lib64/lazarus/lcl/include
-Fi${TARGET_DIR}/usr/lib64/lazarus/lcl/units/\$fpctarget
-Fi${TARGET_DIR}/usr/lib64/lazarus/lcl/units/\$fpctarget/gtk2
EOF
fi

# 6. Create compiler auto-detection symlinks
echo "Setting up compiler auto-detection symlinks..."
mkdir -p "${TARGET_DIR}/usr/lib64/fpc/etc"
ln -sf "${TARGET_DIR}/etc/fpc.cfg" "${TARGET_DIR}/usr/lib64/fpc/etc/fpc.cfg"

mkdir -p "${TARGET_DIR}/usr/lib64/fpc/3.2.2/bin/x86_64-linux"
ln -sf "${TARGET_DIR}/usr/bin/fpcres" "${TARGET_DIR}/usr/lib64/fpc/3.2.2/bin/x86_64-linux/fpcres"

# 7. Create GTK2 library development symlinks
echo "Setting up GTK2 library symlinks..."
mkdir -p "${TARGET_DIR}/lib64"
ln -sf /usr/lib64/libgtk-x11-2.0.so.0 "${TARGET_DIR}/lib64/libgtk-x11-2.0.so"
ln -sf /usr/lib64/libgdk-x11-2.0.so.0 "${TARGET_DIR}/lib64/libgdk-x11-2.0.so"
ln -sf /usr/lib64/libgdk_pixbuf-2.0.so.0 "${TARGET_DIR}/lib64/libgdk_pixbuf-2.0.so"
ln -sf /usr/lib64/libpango-1.0.so.0 "${TARGET_DIR}/lib64/libpango-1.0.so"
ln -sf /usr/lib64/libatk-1.0.so.0 "${TARGET_DIR}/lib64/libatk-1.0.so"

# 8. Create Lazarus PCP directory for non-intrusive builds
mkdir -p "${TARGET_DIR}/pcp"

# 9. Verification
echo "Verifying toolchain installation..."
PPC_BIN="${TARGET_DIR}/usr/bin/ppcx64"
LAZ_BIN="${TARGET_DIR}/usr/bin/lazbuild"

FPC_VERSION="$("${PPC_BIN}" -iV)"
echo "  [OK] Free Pascal Compiler: ${FPC_VERSION}"
if [[ "${FPC_VERSION}" != "3.2.2" ]]; then
    echo "ERROR: Expected FPC version 3.2.2, got '${FPC_VERSION}'" >&2
    exit 1
fi

LAZ_VERSION="$("${LAZ_BIN}" --version)"
echo "  [OK] Lazarus LazBuild: ${LAZ_VERSION}"
if [[ "${LAZ_VERSION}" != "4.8" ]]; then
    echo "ERROR: Expected LazBuild version 4.8, got '${LAZ_VERSION}'" >&2
    exit 1
fi

# Smoke compile test
TEST_TMP="$(mktemp -d)"
cat > "${TEST_TMP}/smoke_test.pas" <<'EOF'
program SmokeTest;
begin
  writeln('Toolchain operational');
end.
EOF

"${PPC_BIN}" -XX -Xs -Os -o"${TEST_TMP}/smoke_test" "${TEST_TMP}/smoke_test.pas" >/dev/null
SMOKE_OUT="$("${TEST_TMP}/smoke_test")"
rm -rf "${TEST_TMP}"

if [[ "${SMOKE_OUT}" != "Toolchain operational" ]]; then
    echo "ERROR: Smoke compilation test failed." >&2
    exit 1
fi
echo "  [OK] Smoke compilation verified successfully."

echo "=== Free Pascal & Lazarus Toolchain Setup Complete ==="
echo "Add to PATH: export PATH=\"${TARGET_DIR}/usr/bin:\$PATH\""
