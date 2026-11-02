#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export PATH="${PROJECT_ROOT}/.sysroot/fpc/usr/bin:/home/wh/.cargo/bin:${PATH}"

echo "================================================================"
echo "    Oh-My-Mineral: Milestone 1 Seqlock & SHM Stress Suite       "
echo "================================================================"

cd "${PROJECT_ROOT}"

echo "[Step 1] Compiling test executables..."
fpc -Fu"src/common" tests/stress/stress_seqlock_wrap.pas -o"tests/stress/stress_seqlock_wrap"
fpc -gh -Fu"src/common" tests/stress/stress_shm_alloc.pas -o"tests/stress/stress_shm_alloc"
fpc -Fu"src/common" tests/stress/stress_seqlock_hang_minimal.pas -o"tests/stress/stress_seqlock_hang_minimal"
fpc -Fu"src/common" tests/stress/stress_shm_concurrent.pas -o"tests/stress/stress_shm_concurrent"
fpc -Fu"src/common" tests/stress/stress_shm_fixed.pas -o"tests/stress/stress_shm_fixed"
fpc -Fu"src/common" tests/stress/stress_shm_extreme.pas -o"tests/stress/stress_shm_extreme"

echo ""
echo "[Step 2] Executing 64-bit sequence counter wrap-around test..."
./tests/stress/stress_seqlock_wrap

echo ""
echo "[Step 3] Executing 50,000-iteration steady-state zero-heap allocation test..."
./tests/stress/stress_shm_alloc

echo ""
echo "[Step 4] Executing minimal pass-by-value hang demonstration..."
set +e
./tests/stress/stress_seqlock_hang_minimal
HANG_EXIT=$?
set -e
if [ "$HANG_EXIT" -eq 142 ]; then
    echo "  [CONFIRMED BUG] Unmodified SeqLockReadBegin deadlocks on odd sequence (killed by SIGALRM 142)!"
else
    echo "  [UNEXPECTED] Expected exit 142, got ${HANG_EXIT}"
fi

echo ""
echo "[Step 5] Executing unmodified omm_shm 4-reader concurrent stress test..."
set +e
./tests/stress/stress_shm_concurrent
CONC_EXIT=$?
set -e
if [ "$CONC_EXIT" -eq 142 ]; then
    echo "  [CONFIRMED BUG] Unmodified omm_shm deadlocks under 1 writer + 4 readers (killed by SIGALRM 142)!"
else
    echo "  [UNEXPECTED] Expected exit 142, got ${CONC_EXIT}"
fi

echo ""
echo "[Step 6] Executing pass-by-reference fixed 4-reader concurrent stress test (50,000 writes @ 1,000+ FPS, 4 readers @ 120 FPS)..."
./tests/stress/stress_shm_fixed

echo ""
echo "[Step 7] Executing extreme unthrottled contention test (2.6M FPS, ~70k reads, ~120k retries)..."
./tests/stress/stress_shm_extreme

echo ""
echo "================================================================"
echo "    ALL SEQLOCK & SHM EMPIRICAL STRESS TESTS COMPLETED!         "
echo "================================================================"
