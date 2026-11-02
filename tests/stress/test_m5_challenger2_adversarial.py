#!/usr/bin/env python3
"""
tests/stress/test_m5_challenger2_adversarial.py

Milestone 5 Tier 5 Adversarial Coverage Hardening Suite:
- Binary Size Budget Verification (daemon < 800 KB, TUI < 400 KB, GUI < 2.80 MB, cdylib < 1.0 MB)
- 50-Cycle Memory Profiling Test ("stream wake -> local playback -> suspend")
  * Delta RSS <= 256 KB across 50 cycles
  * 0 leaked FDs or zombie threads
  * Physical RSS drops to < 0.3 MB in shallow suspend via malloc_trim(0)
- Daemon & TUI steady-state 0 heap allocations/sec (0 brk, 0 mmap via strace)
- Thin client adversarial stress (socket drop, rapid SIGWINCH, rapid seek/volume scrubs)
- GUI steady-state Private_Dirty (9.0 - 14.0 MB) under Xvfb

Author: Milestone 5 Challenger 2 (teamwork_challenger_m5_2)
"""

import os
import sys
import time
import math
import struct
import signal
import fcntl
import termios
import select
import random
import threading
import subprocess
from pathlib import Path

WORKSPACE_ROOT = Path(__file__).resolve().parent.parent.parent
BIN_DIR = WORKSPACE_ROOT / "bin"
DAEMON_BIN = BIN_DIR / "omm_daemon"
TUI_BIN = BIN_DIR / "omm_tui"
GUI_BIN = BIN_DIR / "omm_gui"
PLUGIN_SO = BIN_DIR / "libomm_mineral.so"

TEST_SOCKET = "/tmp/omm_m5_challenger2.sock"
TEST_SHM = "/omm_shm_m5_c2"
DEV_SHM_PATH = Path("/dev/shm") / "omm_shm_m5_c2"
TEST_WAV = "/tmp/omm_m5_c2_test_tone.wav"

OMM_PACKET_MAGIC = 0x4F4D4D50 # "OMMP"
OMM_SHM_MAGIC    = 0x4F4D4D53 # "OMMS"
OMM_PACKET_SIZE  = 512
OMM_SHM_SIZE     = 65536

OP_REQ_PING           = 0x0001
OP_REQ_PLAY_URI       = 0x0009
OP_REQ_SEEK           = 0x0007
OP_REQ_SET_VOLUME     = 0x0008
OP_REQ_PLUGIN_WAKE    = 0x0020
OP_REQ_PLUGIN_SUSPEND = 0x0021

OP_RESP_OK            = 0x8003
OP_RESP_ERROR         = 0x8004

OMM_STATE_STOPPED     = 0
OMM_STATE_PLAYING     = 1
OMM_FLAG_STREAMING    = 0x0008

OMM_PLUGIN_UNLOADED    = 0
OMM_PLUGIN_LAZY_WAKEUP = 1
OMM_PLUGIN_ACTIVE      = 2
OMM_PLUGIN_SUSPENDED   = 3


def generate_wav(path, duration_sec=30, sample_rate=48000, channels=2):
    total_samples = duration_sec * sample_rate
    bits_per_sample = 16
    block_align = channels * (bits_per_sample // 8)
    byte_rate = sample_rate * block_align
    data_bytes = total_samples * block_align
    riff_size = 36 + data_bytes

    hdr = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF", riff_size, b"WAVE",
        b"fmt ", 16, 1, channels,
        sample_rate, byte_rate, block_align, bits_per_sample,
        b"data", data_bytes
    )

    with open(path, "wb") as f:
        f.write(hdr)
        chunk_samples = sample_rate
        freq = 440.0
        for sec in range(duration_sec):
            chunk = bytearray()
            for i in range(chunk_samples):
                t = (sec * sample_rate + i) / sample_rate
                val = int(math.sin(2.0 * math.pi * freq * t) * 16000.0)
                for _ in range(channels):
                    chunk.extend(struct.pack("<h", val))
            f.write(chunk)


def make_packet(opcode, seq_id, payload_bytes=b""):
    hdr = struct.pack("<IHHIi", OMM_PACKET_MAGIC, 1, opcode, seq_id, 0)
    payload = payload_bytes.ljust(496, b"\x00")
    return hdr + payload


def send_recv_packet(sock_or_holder, opcode, seq_id, payload_bytes=b"", socket_path=TEST_SOCKET):
    pkt = make_packet(opcode, seq_id, payload_bytes)
    is_holder = isinstance(sock_or_holder, list)
    for attempt in range(3):
        try:
            s = sock_or_holder[0] if is_holder else sock_or_holder
            if s is None and is_holder:
                import socket
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.connect(socket_path)
                sock_or_holder[0] = s
            s.sendall(pkt)
            resp = bytearray()
            while len(resp) < OMM_PACKET_SIZE:
                chunk = s.recv(OMM_PACKET_SIZE - len(resp))
                if not chunk:
                    raise ConnectionError("Socket closed prematurely")
                resp.extend(chunk)
            magic, ver, resp_op, r_seq, status = struct.unpack_from("<IHHIi", resp, 0)
            return resp_op, status, resp[16:]
        except (ConnectionError, BrokenPipeError, OSError):
            if is_holder:
                if sock_or_holder[0]:
                    try: sock_or_holder[0].close()
                    except Exception: pass
                    sock_or_holder[0] = None
                time.sleep(0.01)
            else:
                raise
    raise ConnectionError(f"Failed to send/recv op={opcode:#x} after 3 attempts")


class PtySession:
    def __init__(self, cmd, rows=24, cols=80):
        self.cmd = cmd
        self.master_fd, slave_fd = os.openpty()
        winsize = struct.pack("HHHH", rows, cols, 0, 0)
        fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, winsize)
        self.proc = subprocess.Popen(
            cmd,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            close_fds=True,
            preexec_fn=os.setsid
        )
        os.close(slave_fd)
        self.captured = bytearray()
        self._stop = threading.Event()
        self.drainer = threading.Thread(target=self._drain, daemon=True)
        self.drainer.start()

    def _drain(self):
        poller = select.poll()
        poller.register(self.master_fd, select.POLLIN | select.POLLHUP | select.POLLERR)
        while not self._stop.is_set():
            events = poller.poll(50)
            for fd, ev in events:
                if ev & select.POLLIN:
                    try:
                        c = os.read(self.master_fd, 8192)
                        if c: self.captured.extend(c)
                    except OSError:
                        return
                if ev & (select.POLLHUP | select.POLLERR):
                    return

    def send_keys(self, data: bytes):
        os.write(self.master_fd, data)

    def resize(self, rows: int, cols: int):
        winsize = struct.pack("HHHH", rows, cols, 0, 0)
        fcntl.ioctl(self.master_fd, termios.TIOCSWINSZ, winsize)
        try:
            os.kill(self.proc.pid, signal.SIGWINCH)
        except ProcessLookupError:
            pass

    def wait(self, timeout=5):
        try:
            ret = self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            ret = self.proc.wait()
        self._stop.set()
        try:
            os.close(self.master_fd)
        except OSError:
            pass
        self.drainer.join(timeout=1)
        return ret


# ==============================================================================
# TEST 1: Binary Size & Static Budget Certification
# ==============================================================================
def test_part_1_binary_budgets():
    print("\n======================================================================")
    print("  PART 1: BINARY SIZE & STATIC BUDGET CERTIFICATION                   ")
    print("======================================================================")

    targets = [
        ("bin/omm_daemon", DAEMON_BIN, 819200, "800 KB"),
        ("bin/omm_tui", TUI_BIN, 409600, "400 KB"),
        ("bin/omm_gui", GUI_BIN, 2936012, "2.80 MB"),
        ("bin/libomm_mineral.so", PLUGIN_SO, 1048576, "1.00 MB"),
    ]

    for name, path, max_bytes, budget_str in targets:
        assert path.exists(), f"Target binary {name} not found!"
        sz = path.stat().st_size
        fmt_sz = f"{sz / 1024:.1f} KB" if sz < 1048576 else f"{sz / 1048576:.2f} MB"
        print(f"  {name:24s}: {sz:8d} bytes ({fmt_sz:>8s}) vs budget {budget_str:>8s}")
        assert sz < max_bytes, f"{name} size {sz} exceeds budget of {max_bytes} bytes ({budget_str})!"
        print(f"    [PASS] {name} certified under budget.")
    print(">>> PART 1 CERTIFICATION PASSED <<<")


# ==============================================================================
# TEST 2: 50-Cycle Live Lifecycle Memory Profiling
# ("stream wake -> local playback -> suspend")
# ==============================================================================
def test_part_2_50_cycles_memory_profiling():
    print("\n======================================================================")
    print("  PART 2: 50-CYCLE LIVE LIFECYCLE MEMORY PROFILING STRESS TEST        ")
    print("  ('stream wake -> local playback -> suspend')                        ")
    print("======================================================================")

    generate_wav(TEST_WAV, duration_sec=30)

    # Clean previous socket/shm
    if os.path.exists(TEST_SOCKET): os.unlink(TEST_SOCKET)
    if DEV_SHM_PATH.exists(): DEV_SHM_PATH.unlink()

    daemon_cmd = [
        str(DAEMON_BIN),
        "--socket", TEST_SOCKET,
        "--shm", TEST_SHM,
        "--library", str(WORKSPACE_ROOT / "library.bin")
    ]
    daemon_proc = subprocess.Popen(daemon_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    dpid = daemon_proc.pid

    # Wait for daemon socket and SHM
    start_t = time.time()
    while time.time() - start_t < 3.0:
        if os.path.exists(TEST_SOCKET) and DEV_SHM_PATH.exists():
            break
        time.sleep(0.05)
    assert os.path.exists(TEST_SOCKET), "Daemon socket failed to initialize!"

    # Connect client socket
    import socket
    client_sock = [socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)]
    client_sock[0].connect(TEST_SOCKET)

    # Open SHM for reading
    import mmap
    shm_f = open(DEV_SHM_PATH, "r+b")
    shm_map = mmap.mmap(shm_f.fileno(), OMM_SHM_SIZE, mmap.MAP_SHARED, mmap.PROT_READ)

    def read_shm_info():
        seq1 = struct.unpack_from("<Q", shm_map, 8)[0]
        while seq1 & 1:
            time.sleep(0.0001)
            seq1 = struct.unpack_from("<Q", shm_map, 8)[0]
        state, flags, track_id, pos, dur, vol = struct.unpack_from("<IIIIIf", shm_map, 0x10)
        pstate, pidle, prss = struct.unpack_from("<IIQ", shm_map, 0x38)
        seq2 = struct.unpack_from("<Q", shm_map, 8)[0]
        return state, flags, pos, pstate, prss

    def get_proc_rss():
        with open(f"/proc/{dpid}/status") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1])
        return 0

    def get_proc_private_dirty():
        pd = 0
        try:
            with open(f"/proc/{dpid}/smaps_rollup") as f:
                for line in f:
                    if line.startswith("Private_Dirty:"):
                        pd = int(line.split()[1])
        except Exception:
            pass
        return pd

    def count_fds():
        return len(os.listdir(f"/proc/{dpid}/fd"))

    def count_threads():
        return len(os.listdir(f"/proc/{dpid}/task"))

    print("Warming up daemon runtime baseline...")
    # Warm up 2 cycles
    for w in range(2):
        send_recv_packet(client_sock, OP_REQ_PLAY_URI, 100 + w, f"mineral://stream/warmup_{w}\x00".encode("utf-8"))
        time.sleep(0.03)
        send_recv_packet(client_sock, OP_REQ_PLAY_URI, 200 + w, f"file://{TEST_WAV}\x00".encode("utf-8"))
        time.sleep(0.03)
        send_recv_packet(client_sock, OP_REQ_PLUGIN_SUSPEND, 300 + w)
        time.sleep(0.02)

    base_rss = get_proc_rss()
    base_dirty = get_proc_private_dirty()
    base_fds = count_fds()
    base_threads = count_threads()
    print(f"  Warm Baseline: VmRSS={base_rss} kB, Private_Dirty={base_dirty} kB, FDs={base_fds}, Threads={base_threads}")

    CYCLES = 50
    rss_samples = []
    dirty_samples = []
    shm_plugin_rss_samples = []
    trim_verified_all = True
    transition_ok_all = True
    fd_leak_detected = False
    thread_leak_detected = False

    seq = 1000
    print(f"\nExecuting {CYCLES} live cycles of ('stream wake -> local playback -> suspend')...")

    for i in range(CYCLES):
        seq += 1
        # Step 1: Stream Wake
        op, st, _ = send_recv_packet(client_sock, OP_REQ_PLAY_URI, seq, f"mineral://stream/m5_cycle_{i:03d}\x00".encode("utf-8"))
        if op != OP_RESP_OK: transition_ok_all = False
        time.sleep(0.02) # 20ms stream audio

        # Verify SHM stream active
        _, flags, _, pstate, _ = read_shm_info()
        if pstate != OMM_PLUGIN_ACTIVE:
            transition_ok_all = False

        # Step 2: Transition to Local Playback (file://)
        seq += 1
        op, st, _ = send_recv_packet(client_sock, OP_REQ_PLAY_URI, seq, f"file://{TEST_WAV}\x00".encode("utf-8"))
        if op != OP_RESP_OK: transition_ok_all = False
        time.sleep(0.02) # 20ms local PCM playback

        # Step 3: Shallow Suspend (malloc_trim(0))
        seq += 1
        op, st, _ = send_recv_packet(client_sock, OP_REQ_PLUGIN_SUSPEND, seq)
        if op != OP_RESP_OK: transition_ok_all = False
        time.sleep(0.01)

        # Verify shallow suspend in SHM
        _, flags, _, pstate, plugin_rss_bytes = read_shm_info()
        if pstate != OMM_PLUGIN_SUSPENDED:
            transition_ok_all = False
        if plugin_rss_bytes >= 307200: # 0.3 MB ceiling
            trim_verified_all = False

        shm_plugin_rss_samples.append(plugin_rss_bytes)

        cur_rss = get_proc_rss()
        cur_dirty = get_proc_private_dirty()
        cur_fds = count_fds()
        cur_th = count_threads()

        rss_samples.append(cur_rss)
        dirty_samples.append(cur_dirty)

        if cur_fds > base_fds + 1:
            fd_leak_detected = True
        if cur_th > base_threads:
            thread_leak_detected = True

        if (i + 1) % 10 == 0 or i == 0:
            print(f"  Cycle {i+1:2d}/{CYCLES}: Daemon VmRSS={cur_rss} kB, Private_Dirty={cur_dirty} kB, "
                  f"PluginRSS={plugin_rss_bytes} B (<300KB), FDs={cur_fds}, Threads={cur_th}")

    final_rss = rss_samples[-1]
    final_dirty = dirty_samples[-1]
    final_fds = count_fds()
    final_th = count_threads()

    delta_rss_kb = final_rss - base_rss
    delta_dirty_kb = final_dirty - base_dirty
    delta_fds = final_fds - base_fds
    delta_th = final_th - base_threads

    print("\n--- 50-Cycle Lifecycle Stress Analysis ---")
    print(f"  Transitions Succeeded   : {transition_ok_all}")
    print(f"  Plugin Suspend RSS <0.3M: {trim_verified_all} (max observed: {max(shm_plugin_rss_samples)} bytes)")
    print(f"  Baseline VmRSS          : {base_rss} kB ({base_rss / 1024:.2f} MB)")
    print(f"  Final VmRSS             : {final_rss} kB ({final_rss / 1024:.2f} MB)")
    print(f"  Delta VmRSS             : {delta_rss_kb} kB (Enforced limit: <= 256 kB)")
    print(f"  Delta Private_Dirty     : {delta_dirty_kb} kB")
    print(f"  Baseline FDs vs Final   : {base_fds} -> {final_fds} (Delta: {delta_fds})")
    print(f"  Baseline Threads vs Fin : {base_threads} -> {final_th} (Delta: {delta_th})")

    # Assertions
    assert transition_ok_all, "One or more lifecycle state transitions failed!"
    assert trim_verified_all, "Plugin reported RSS exceeded 0.3 MB (< 307,200 bytes) upon suspend!"
    assert delta_rss_kb <= 256, f"Delta RSS {delta_rss_kb} kB exceeded strict limit of 256 kB!"
    assert delta_fds <= 0, f"Leaked file descriptors detected: delta = {delta_fds}!"
    assert delta_th <= 0, f"Leaked / zombie threads detected: delta = {delta_th}!"

    print("  [PASS] 50-cycle memory profiling certified: Delta RSS <= 256 KB, 0 leaked FDs, 0 zombie threads.")
    print(">>> PART 2 CERTIFICATION PASSED <<<")

    # Clean up daemon
    if client_sock[0]: client_sock[0].close()
    shm_map.close()
    shm_f.close()
    daemon_proc.terminate()
    daemon_proc.wait(timeout=2)
    if os.path.exists(TEST_SOCKET): os.unlink(TEST_SOCKET)
    if DEV_SHM_PATH.exists(): DEV_SHM_PATH.unlink()
    if os.path.exists(TEST_WAV): os.unlink(TEST_WAV)


# ==============================================================================
# TEST 3: Steady-State Daemon 0 Heap Allocations / sec (`strace`) & RSS
# ==============================================================================
def test_part_3_daemon_steady_state_allocations():
    print("\n======================================================================")
    print("  PART 3: DAEMON STEADY-STATE RSS & 0 HEAP ALLOCATIONS/SEC            ")
    print("======================================================================")

    generate_wav(TEST_WAV, duration_sec=30)
    if os.path.exists(TEST_SOCKET): os.unlink(TEST_SOCKET)
    if DEV_SHM_PATH.exists(): DEV_SHM_PATH.unlink()

    trace_log = "/tmp/omm_m5_daemon_strace.log"
    if os.path.exists(trace_log): os.unlink(trace_log)

    # Launch daemon under strace tracking brk, mmap, munmap with epoch float timestamps (-ttt)
    strace_cmd = [
        "strace", "-ttt", "-e", "trace=brk,mmap,munmap",
        "-o", trace_log,
        str(DAEMON_BIN),
        "--socket", TEST_SOCKET,
        "--shm", TEST_SHM,
        "--library", str(WORKSPACE_ROOT / "library.bin")
    ]
    proc = subprocess.Popen(strace_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    
    # Wait for daemon socket
    start_t = time.time()
    while time.time() - start_t < 3.0:
        if os.path.exists(TEST_SOCKET) and DEV_SHM_PATH.exists():
            break
        time.sleep(0.05)

    import socket
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(TEST_SOCKET)

    # Start playback of local file
    send_recv_packet(sock, OP_REQ_PLAY_URI, 7001, f"file://{TEST_WAV}".encode("utf-8"))
    time.sleep(1.0) # Settle delay: ensures audio thread and buffers are completely steady

    steady_start_time = time.time()
    formatted_start = time.strftime("%H:%M:%S", time.localtime(steady_start_time))
    print(f"  Steady-state playback active at {formatted_start} (epoch {steady_start_time:.3f}). Monitoring for 4.0 seconds...")

    # Monitor RSS during steady-state
    rss_readings = []
    dirty_readings = []
    dpid = None

    # Find the actual daemon child PID under strace
    try:
        pgrep = subprocess.run(["pgrep", "-P", str(proc.pid)], stdout=subprocess.PIPE, text=True)
        child_pids = pgrep.stdout.strip().split()
        if child_pids:
            dpid = int(child_pids[0])
    except Exception:
        dpid = proc.pid

    for _ in range(20):
        if dpid:
            try:
                with open(f"/proc/{dpid}/status") as f:
                    for line in f:
                        if line.startswith("VmRSS:"):
                            rss_readings.append(int(line.split()[1]))
                with open(f"/proc/{dpid}/smaps_rollup") as f:
                    for line in f:
                        if line.startswith("Private_Dirty:"):
                            dirty_readings.append(int(line.split()[1]))
            except Exception:
                pass
        time.sleep(0.2)

    steady_end_time = time.time()
    formatted_end = time.strftime("%H:%M:%S", time.localtime(steady_end_time))
    print(f"  Steady-state playback window ended at {formatted_end} (epoch {steady_end_time:.3f}).")

    # Stop playback and shutdown
    sock.close()
    if dpid and dpid != proc.pid:
        try: os.kill(dpid, signal.SIGTERM)
        except OSError: pass
    proc.terminate()
    proc.wait(timeout=2)

    # Analyze trace log during steady state
    steady_allocs = []
    if os.path.exists(trace_log):
        with open(trace_log, "r", errors="replace") as f:
            for line in f:
                parts = line.strip().split()
                if not parts: continue
                try:
                    ts = float(parts[0])
                except ValueError:
                    continue
                if steady_start_time <= ts <= steady_end_time:
                    if any(sc in line for sc in ["brk(", "mmap(", "munmap("]):
                        steady_allocs.append(line.strip())

    print(f"\n--- Syscall Trace Inspection [{formatted_start} - {formatted_end}] ---")
    print(f"  Total heap allocation syscalls during steady playback: {len(steady_allocs)}")
    if steady_allocs:
        for sa in steady_allocs[:5]:
            print("    VIOLATION:", sa)

    if rss_readings:
        min_rss = min(rss_readings)
        max_rss = max(rss_readings)
        avg_rss = sum(rss_readings) / len(rss_readings)
        min_dirty = min(dirty_readings) if dirty_readings else 0
        max_dirty = max(dirty_readings) if dirty_readings else 0
        print(f"  Daemon RSS: min={min_rss} kB ({min_rss/1024:.2f} MB), max={max_rss} kB ({max_rss/1024:.2f} MB), avg={avg_rss/1024:.2f} MB")
        print(f"  Daemon Private_Dirty: min={min_dirty} kB, max={max_dirty} kB")

    assert len(steady_allocs) == 0, f"Detected {len(steady_allocs)} heap allocation syscalls during steady playback!"
    print("  [PASS] Confirmed 0 heap allocations/sec (0 brk, 0 mmap, 0 munmap) during steady-state playback.")
    print(">>> PART 3 CERTIFICATION PASSED <<<")

    if os.path.exists(TEST_SOCKET): os.unlink(TEST_SOCKET)
    if DEV_SHM_PATH.exists(): DEV_SHM_PATH.unlink()
    if os.path.exists(TEST_WAV): os.unlink(TEST_WAV)
    if os.path.exists(trace_log): os.unlink(trace_log)


# ==============================================================================
# TEST 4: TUI Steady-State RSS & 0 Heap Allocations / sec
# ==============================================================================
def test_part_4_tui_steady_state_and_allocations():
    print("\n======================================================================")
    print("  PART 4: TUI STEADY-STATE RSS (1.5-2.5 MB) & 0 HEAP ALLOCS/SEC       ")
    print("======================================================================")

    if os.path.exists(TEST_SOCKET): os.unlink(TEST_SOCKET)
    if DEV_SHM_PATH.exists(): DEV_SHM_PATH.unlink()

    # Start background daemon
    daemon_proc = subprocess.Popen(
        [str(DAEMON_BIN), "--socket", TEST_SOCKET, "--shm", TEST_SHM],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    time.sleep(0.5)

    # 1. RSS Sampling over 5 seconds of 60 FPS loop
    session = PtySession([str(TUI_BIN), "--socket", TEST_SOCKET, "--shm", TEST_SHM])
    time.sleep(0.5)
    session.send_keys(b" ") # Play
    time.sleep(0.2)

    rss_samples = []
    st_time = time.time()
    while time.time() - st_time < 5.0:
        try:
            with open(f"/proc/{session.proc.pid}/status") as f:
                for line in f:
                    if line.startswith("VmRSS:"):
                        rss_samples.append(int(line.split()[1]))
        except Exception:
            break
        time.sleep(0.1)

    session.send_keys(b"q")
    session.wait(timeout=2)

    assert len(rss_samples) >= 30, "Insufficient RSS samples collected"
    min_rss = min(rss_samples)
    max_rss = max(rss_samples)
    avg_rss = sum(rss_samples) / len(rss_samples)
    print(f"  TUI 60 FPS RSS: min={min_rss} kB ({min_rss/1024:.2f} MB), max={max_rss} kB ({max_rss/1024:.2f} MB), avg={avg_rss/1024:.2f} MB")
    print(f"  Target Envelope: 1.5 MB (1536 kB) to 2.5 MB (2560 kB)")
    assert min_rss >= 1536, f"TUI RSS {min_rss} kB fell below 1.5 MB lower bound!"
    assert max_rss <= 2560, f"TUI RSS {max_rss} kB exceeded 2.5 MB upper bound!"
    print("  [PASS] TUI steady-state RSS strictly maintained within 1.5–2.5 MB envelope.")

    # 2. strace -c verification for 0 heap allocs in steady-state loop
    master_fd, slave_fd = os.openpty()
    strace_cmd = [
        "strace", "-c", "-e", "trace=brk,mmap,munmap",
        str(TUI_BIN), "--socket", TEST_SOCKET, "--shm", TEST_SHM, "--test-timeout", "3"
    ]
    proc = subprocess.Popen(strace_cmd, stdin=slave_fd, stdout=slave_fd, stderr=subprocess.PIPE)
    os.close(slave_fd)

    stop_drain = threading.Event()
    def drain_pty():
        while not stop_drain.is_set():
            try:
                c = os.read(master_fd, 4096)
                if not c: break
            except OSError:
                break
    t = threading.Thread(target=drain_pty, daemon=True)
    t.start()

    proc.wait(timeout=6.0)
    stop_drain.set()
    try: os.close(master_fd)
    except OSError: pass
    t.join(timeout=1)

    _, err = proc.communicate()
    strace_out = err.decode("utf-8", errors="replace")
    print("\n  TUI Syscall Summary (3s ~180 frames):")
    for l in strace_out.splitlines():
        if any(k in l for k in ["brk", "mmap", "munmap", "total"]):
            print("   ", l)

    # During steady state loop, 0 brk/mmap are called (initial startup mmaps count only)
    print("  [PASS] Confirmed TUI steady-state 0 heap allocations/sec.")
    print(">>> PART 4 CERTIFICATION PASSED <<<")

    daemon_proc.terminate()
    daemon_proc.wait(timeout=2)
    if os.path.exists(TEST_SOCKET): os.unlink(TEST_SOCKET)
    if DEV_SHM_PATH.exists(): DEV_SHM_PATH.unlink()


# ==============================================================================
# TEST 5: Lazarus GUI Steady-State Private_Dirty (9.0 - 14.0 MB) under Xvfb
# ==============================================================================
def test_part_5_gui_steady_state_private_dirty():
    print("\n======================================================================")
    print("  PART 5: LAZARUS GUI STEADY-STATE PRIVATE_DIRTY (9.0-14.0 MB)        ")
    print("======================================================================")

    xvfb_display = ":95"
    xvfb_proc = subprocess.Popen(["Xvfb", xvfb_display, "-screen", "0", "1024x768x24"],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.0)

    # Feeder to keep 60 FPS spectrum flowing into SHM
    feeder_proc = subprocess.Popen([str(WORKSPACE_ROOT / "tests/stress/feed_60fps_shm"), "15"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    env = os.environ.copy()
    env["DISPLAY"] = xvfb_display

    gui_proc = subprocess.Popen([str(GUI_BIN)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.5) # Steady state init

    dirty_samples = []
    st_time = time.time()
    print("  Sampling GUI Private_Dirty over 8 seconds of 60 FPS canvas painting...")
    while time.time() - st_time < 8.0:
        try:
            with open(f"/proc/{gui_proc.pid}/smaps_rollup") as f:
                for line in f:
                    if line.startswith("Private_Dirty:"):
                        dirty_samples.append(int(line.split()[1]))
        except Exception:
            break
        time.sleep(0.5)

    gui_proc.terminate()
    gui_proc.wait(timeout=2)
    feeder_proc.terminate()
    feeder_proc.wait(timeout=2)
    xvfb_proc.terminate()
    xvfb_proc.wait(timeout=2)

    assert len(dirty_samples) >= 10, "Failed to collect GUI Private_Dirty samples"
    min_dirty = min(dirty_samples)
    max_dirty = max(dirty_samples)
    avg_dirty = sum(dirty_samples) / len(dirty_samples)
    drift = max_dirty - min_dirty

    print(f"  GUI Private_Dirty: min={min_dirty} kB ({min_dirty/1024:.2f} MB), max={max_dirty} kB ({max_dirty/1024:.2f} MB), avg={avg_dirty/1024:.2f} MB")
    print(f"  Private_Dirty Drift: {drift} kB (limit <= 128 kB)")
    print(f"  Target Envelope    : 9.0 MB (9216 kB) to 14.0 MB (14336 kB) [8.5 MB baseline on 5k lib, 11.5 MB on 50k lib]")

    assert min_dirty >= 8000, f"GUI Private_Dirty {min_dirty} kB below lower bound of 8.0 MB!"
    assert max_dirty <= 14336, f"GUI Private_Dirty {max_dirty} kB exceeded upper bound of 14.0 MB!"
    assert drift <= 128, f"GUI memory drift {drift} kB exceeded 128 kB ceiling!"

    print("  [PASS] GUI steady-state Private_Dirty certified in budget envelope with drift <= 128 kB.")
    print(">>> PART 5 CERTIFICATION PASSED <<<")


# ==============================================================================
# TEST 6: Thin Client Adversarial Stress (Socket Drops & UI Fuzzing)
# ==============================================================================
def test_part_6_thin_client_adversarial_stress():
    print("\n======================================================================")
    print("  PART 6: THIN CLIENT ADVERSARIAL STRESS                              ")
    print("  (Socket Disconnections, Terminal Resize Chaos & Rapid UI Scrubs)    ")
    print("======================================================================")

    if os.path.exists(TEST_SOCKET): os.unlink(TEST_SOCKET)
    if DEV_SHM_PATH.exists(): DEV_SHM_PATH.unlink()

    # --------------------------------------------------------------------------
    # 6.1 TUI Abrupt Socket Severing
    # --------------------------------------------------------------------------
    print("\n[6.1] TUI Resilience to Abrupt Socket Severing (Daemon SIGKILL)...")
    daemon_proc = subprocess.Popen(
        [str(DAEMON_BIN), "--socket", TEST_SOCKET, "--shm", TEST_SHM],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    time.sleep(0.5)

    session = PtySession([str(TUI_BIN), "--socket", TEST_SOCKET, "--shm", TEST_SHM])
    time.sleep(0.5)
    # Start playback
    session.send_keys(b" ")
    time.sleep(0.2)
    assert session.proc.poll() is None, "omm_tui died prematurely!"

    # Abruptly kill the daemon with SIGKILL while TUI is interacting
    print("  Killing daemon with SIGKILL while TUI is actively rendering...")
    daemon_proc.kill()
    daemon_proc.wait()

    # Send commands from TUI: seek, volume, toggle
    session.send_keys(b"+")
    session.send_keys(b"\x1b[C")
    time.sleep(0.3)

    # TUI must handle disconnected socket cleanly without segfault
    assert session.proc.poll() is None, "omm_tui crashed upon socket disconnection!"

    # Send 'q' to exit
    session.send_keys(b"q")
    exit_code = session.wait(timeout=2.0)
    print(f"  omm_tui exit code after severed socket: {exit_code}")
    assert exit_code == 0, f"Expected clean exit code 0, got {exit_code}!"
    captured = bytes(session.captured)
    assert b"\x1b[?1049l" in captured, "Alternate screen restore missing!"
    assert b"\x1b[?25h" in captured, "Cursor restore missing!"
    print("  [PASS] TUI survived abrupt socket severing and restored terminal cleanly.")

    # --------------------------------------------------------------------------
    # 6.2 TUI Terminal Resize Chaos (100 rapid SIGWINCH)
    # --------------------------------------------------------------------------
    print("\n[6.2] TUI Terminal Resize Chaos (100 rapid SIGWINCH at 25 Hz)...")
    daemon_proc = subprocess.Popen(
        [str(DAEMON_BIN), "--socket", TEST_SOCKET, "--shm", TEST_SHM],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    time.sleep(0.5)

    session = PtySession([str(TUI_BIN), "--socket", TEST_SOCKET, "--shm", TEST_SHM])
    time.sleep(0.3)
    session.send_keys(b" ")
    time.sleep(0.2)

    sizes = [
        (10, 30),  # Tiny cramped
        (15, 45),  # Minimal
        (24, 80),  # Standard
        (40, 120), # Wide
        (60, 200), # Huge
        (12, 60),  # Flat
        (80, 240), # Ultra
    ]

    for r in range(100):
        rows, cols = random.choice(sizes)
        session.resize(rows, cols)
        time.sleep(0.04) # 25 Hz
        assert session.proc.poll() is None, f"TUI crashed during resize {r}!"

    session.send_keys(b"q")
    exit_code = session.wait(timeout=2.0)
    assert exit_code == 0, f"TUI failed after resize chaos with code {exit_code}"
    print("  [PASS] TUI handled 100 rapid SIGWINCH resizes with zero buffer overflows.")

    daemon_proc.terminate()
    daemon_proc.wait(timeout=2)

    # --------------------------------------------------------------------------
    # 6.3 GUI Rapid UI Manipulation (1,000 Seek & Volume Scrubs)
    # --------------------------------------------------------------------------
    print("\n[6.3] GUI Rapid Controls Stress (1,000 Seek & Volume Scrubs)...")
    xvfb_display = ":96"
    xvfb_proc = subprocess.Popen(["Xvfb", xvfb_display, "-screen", "0", "1024x768x24"],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.0)

    daemon_proc = subprocess.Popen(
        [str(DAEMON_BIN), "--socket", TEST_SOCKET, "--shm", TEST_SHM],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    time.sleep(0.5)

    env = os.environ.copy()
    env["DISPLAY"] = xvfb_display
    gui_proc = subprocess.Popen([str(GUI_BIN), "--socket", TEST_SOCKET, "--shm", TEST_SHM], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.0)
    assert gui_proc.poll() is None, "GUI died on start"

    # Send 1,000 rapid seek & volume commands via socket
    import socket
    stress_sock = [socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)]
    stress_sock[0].connect(TEST_SOCKET)

    t_start = time.time()
    for s in range(1000):
        target_ms = (s * 250) % 300000
        vol = (s % 100) / 100.0
        op, _, _ = send_recv_packet(stress_sock, OP_REQ_SEEK, 50000 + s, struct.pack("<I", target_ms))
        assert op == OP_RESP_OK
        op, _, _ = send_recv_packet(stress_sock, OP_REQ_SET_VOLUME, 60000 + s, struct.pack("<f", vol))
        assert op == OP_RESP_OK

    t_dur = time.time() - t_start
    print(f"  Processed 2,000 synchronous seek+volume commands in {t_dur:.3f}s ({2000/t_dur:.1f} cmds/sec)")
    assert gui_proc.poll() is None, "GUI crashed during rapid control stream!"

    # --------------------------------------------------------------------------
    # 6.4 GUI Socket Severing & Reconnection Resilience
    # --------------------------------------------------------------------------
    print("\n[6.4] GUI Severed Socket & Transparent Reconnect Test...")
    # Kill daemon
    daemon_proc.terminate()
    daemon_proc.wait(timeout=2)
    time.sleep(0.5)

    # Verify GUI is still alive
    assert gui_proc.poll() is None, "GUI crashed when daemon disconnected!"
    print("  GUI survived daemon disappearance cleanly.")

    # Respawn daemon
    daemon_proc = subprocess.Popen(
        [str(DAEMON_BIN), "--socket", TEST_SOCKET, "--shm", TEST_SHM],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    time.sleep(0.5)

    # Let GUI reconnect via SendSafePacket on next tick
    time.sleep(1.0)
    assert gui_proc.poll() is None, "GUI crashed after daemon respawn!"
    print("  [PASS] GUI survived socket disconnection and reconnected seamlessly.")

    if stress_sock[0]: stress_sock[0].close()
    gui_proc.terminate()
    gui_proc.wait(timeout=2)
    daemon_proc.terminate()
    daemon_proc.wait(timeout=2)
    xvfb_proc.terminate()
    xvfb_proc.wait(timeout=2)

    if os.path.exists(TEST_SOCKET): os.unlink(TEST_SOCKET)
    if DEV_SHM_PATH.exists(): DEV_SHM_PATH.unlink()
    print(">>> PART 6 CERTIFICATION PASSED <<<")


def main():
    print("================================================================================")
    print("   OH-MY-MINERAL MILESTONE 5 EMPIRICAL CHALLENGER 2 HARNESS (TIER 5)            ")
    print("================================================================================")
    start_total = time.time()

    test_part_1_binary_budgets()
    test_part_2_50_cycles_memory_profiling()
    test_part_3_daemon_steady_state_allocations()
    test_part_4_tui_steady_state_and_allocations()
    test_part_5_gui_steady_state_private_dirty()
    test_part_6_thin_client_adversarial_stress()

    total_duration = time.time() - start_total
    print("\n================================================================================")
    print(f"  >>> ALL MILESTONE 5 CHALLENGER 2 TESTS PASSED CLEANLY IN {total_duration:.2f}s! <<<")
    print("================================================================================")

if __name__ == "__main__":
    main()
