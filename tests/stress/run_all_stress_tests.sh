#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FPC="${PROJECT_ROOT}/.sysroot/fpc/usr/bin/ppcx64"

echo "======================================================================"
echo "   Oh-My-Mineral: Empirical IPC Stress & Fuzzing Master Runner       "
echo "======================================================================"

cd "${PROJECT_ROOT}"

# Clean previous socket files if any
rm -f /tmp/omm_stress_*.sock /tmp/omm_sigpipe_test.sock /tmp/omm_timeout_test.sock

echo "[1/5] Compiling and running Free Pascal IPC Stress Test Suite..."
"${FPC}" -Fu"src/common" tests/stress/stress_ipc_fpc.pas -o"tests/stress/stress_ipc_fpc"
"${PROJECT_ROOT}/tests/stress/stress_ipc_fpc"

echo ""
echo "[2/5] Compiling and running C ABI Stress Test Suite (GCC)..."
gcc -Wall -Wextra -Isrc/common tests/stress/stress_ipc_c.c -o tests/stress/stress_ipc_c
"${PROJECT_ROOT}/tests/stress/stress_ipc_c"

echo ""
echo "[3/5] Compiling and running Cross-Language (C <-> FPC) IPC Suite..."
gcc -Wall -Wextra -Isrc/common tests/stress/stress_cross_c_client.c -o tests/stress/stress_cross_c_client
"${FPC}" -Fu"src/common" tests/stress/stress_cross_fpc_server.pas -o"tests/stress/stress_cross_fpc_server"
"${PROJECT_ROOT}/tests/stress/stress_cross_fpc_server"

echo ""
echo "[4/5] Running SIGPIPE Resilience & Broken Pipe Analysis..."
"${FPC}" -Fu"src/common" tests/stress/test_sigpipe.pas -o"tests/stress/test_sigpipe"
"${PROJECT_ROOT}/tests/stress/test_sigpipe"

echo ""
echo "[5/6] Running SO_RCVTIMEO Stall Guard Test..."
"${FPC}" -Fu"src/common" tests/stress/test_timeout.pas -o"tests/stress/test_timeout"
"${PROJECT_ROOT}/tests/stress/test_timeout"

echo ""
echo "[6/7] Running Plugin Lifecycle, Memory Leak & Deep Unload Stress Test (GCC)..."
gcc -Wall -Wextra -Werror -Isrc/common -rdynamic tests/stress/stress_plugin_lifecycle.c -ldl -lpthread -o tests/stress/stress_plugin_lifecycle
"${PROJECT_ROOT}/tests/stress/stress_plugin_lifecycle"

echo ""
echo ""
echo "[7/9] Running Milestone 3 Library Engine, 32-dim Int8 SIMD & Memory Stability Challenger (FPC)..."
"${FPC}" -Fu"src/common" -Fu"src/daemon" tests/stress/stress_m3_challenger.pas -o"tests/stress/stress_m3_challenger"
"${PROJECT_ROOT}/tests/stress/stress_m3_challenger"

echo ""
echo "[8/9] Running Milestone 3 Audio Pipeline Challenger (GCC)..."
gcc -Wall -Wextra -Isrc/common -Isrc/daemon tests/stress/challenge_m3_audio.c src/daemon/miniaudio_wrapper.o -lpthread -lm -ldl -o tests/stress/challenge_m3_audio
"${PROJECT_ROOT}/tests/stress/challenge_m3_audio"

echo ""
echo "[9/9] Running Milestone 3 Iteration 2 Continuous Playlist Challenger (GCC)..."
gcc -Wall -Wextra -Werror -Isrc/common -lpthread -lm -ldl -o tests/stress/challenge_m3_continuous_playlist tests/stress/challenge_m3_continuous_playlist.c
"${PROJECT_ROOT}/tests/stress/challenge_m3_continuous_playlist"

echo ""
echo "======================================================================"
echo "   ALL EMPIRICAL STRESS TESTS EXECUTED AND COMPLETED SUCCESSFULLY!    "
echo "======================================================================"


