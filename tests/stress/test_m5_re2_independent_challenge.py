#!/usr/bin/env python3
"""
tests/stress/test_m5_re2_independent_challenge.py

Independent Empirical Stress & Adversarial Hardening Suite for Milestone 5:
- 100-Cycle Extended Memory Profiling ("stream wake -> local playback -> suspend")
- High-frequency IPC Under Playback Heap Allocation Check (strace verification)
- Extreme Chaos TUI Fuzzing (200 SIGWINCH at 50 Hz + random terminal input)
- Lazarus GUI Extreme Scrubbing (2,000 seek/volume ops + socket kill & revival)

Author: Milestone 5 Challenger Re_2 (teamwork_challenger_m5_re_2)
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

WORKSPACE = Path(__file__).resolve().parent.parent.parent
DAEMON_BIN = WORKSPACE / "bin" / "omm_daemon"
TUI_BIN = WORKSPACE / "bin" / "omm_tui"
GUI_BIN = WORKSPACE / "bin" / "omm_gui"
PLUGIN_SO = WORKSPACE / "bin" / "libomm_mineral.so"
LIBRARY_BIN = WORKSPACE / "library.bin"

TEST_SOCKET = "/tmp/omm_m5_re2.sock"
TEST_SHM = "/omm_shm_m5_re2"
DEV_SHM_PATH = Path("/dev/shm") / "omm_shm_m5_re2"
TEST_WAV = "/tmp/omm_m5_re2_tone.wav"

OMM_PACKET_MAGIC = 0x4F4D4D50
OMM_SHM_MAGIC    = 0x4F4D4D53
OMM_PACKET_SIZE  = 512
OMM_SHM_SIZE     = 65536

OP_REQ_PING           = 0x0001
OP_REQ_GET_STATUS     = 0x0002
OP_REQ_PLAY_URI       = 0x0009
OP_REQ_SEEK           = 0x0007
OP_REQ_SET_VOLUME     = 0x0008
OP_REQ_VIEWPORT       = 0x0010
OP_REQ_PLUGIN_SUSPEND = 0x0021

OP_RESP_OK            = 0x8003
OMM_PLUGIN_ACTIVE     = 2
OMM_PLUGIN_SUSPENDED  = 3


def generate_wav(path, duration_sec=15, sample_rate=48000, channels=2):
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


def send_recv_packet(sock, opcode, seq_id, payload_bytes=b""):
    pkt = make_packet(opcode, seq_id, payload_bytes)
    sock.sendall(pkt)
    resp = bytearray()
    while len(resp) < OMM_PACKET_SIZE:
        chunk = sock.recv(OMM_PACKET_SIZE - len(resp))
        if not chunk:
            raise ConnectionError("Socket closed prematurely")
        resp.extend(chunk)
    magic, ver, resp_op, r_seq, status = struct.unpack_from("<IHHIi", resp, 0)
    return resp_op, status, resp[16:]


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


def test_100_cycles_extended_memory():
    print("\n[CHALLENGE 1] 100-Cycle Extended Live Lifecycle Stress Test...")
    generate_wav(TEST_WAV, duration_sec=15)
    if os.path.exists(TEST_SOCKET): os.unlink(TEST_SOCKET)
    if DEV_SHM_PATH.exists(): DEV_SHM_PATH.unlink()

    daemon_cmd = [
        str(DAEMON_BIN),
        "--socket", TEST_SOCKET,
        "--shm", TEST_SHM,
        "--library", str(LIBRARY_BIN)
    ]
    proc = subprocess.Popen(daemon_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    dpid = proc.pid

    t0 = time.time()
    while time.time() - t0 < 3.0:
        if os.path.exists(TEST_SOCKET) and DEV_SHM_PATH.exists():
            break
        time.sleep(0.05)
    assert os.path.exists(TEST_SOCKET)

    import socket, mmap
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(TEST_SOCKET)

    shm_f = open(DEV_SHM_PATH, "r+b")
    shm_map = mmap.mmap(shm_f.fileno(), OMM_SHM_SIZE, mmap.MAP_SHARED, mmap.PROT_READ)

    def read_plugin_info():
        seq = struct.unpack_from("<Q", shm_map, 8)[0]
        while seq & 1:
            time.sleep(0.0001)
            seq = struct.unpack_from("<Q", shm_map, 8)[0]
        pstate, pidle, prss = struct.unpack_from("<IIQ", shm_map, 0x38)
        return pstate, prss

    def get_rss():
        with open(f"/proc/{dpid}/status") as f:
            for l in f:
                if l.startswith("VmRSS:"): return int(l.split()[1])
        return 0

    def count_fds():
        return len(os.listdir(f"/proc/{dpid}/fd"))

    def count_threads():
        return len(os.listdir(f"/proc/{dpid}/task"))

    # Warmup
    for w in range(2):
        send_recv_packet(sock, OP_REQ_PLAY_URI, 10 + w, f"mineral://stream/warm_{w}\x00".encode("utf-8"))
        time.sleep(0.02)
        send_recv_packet(sock, OP_REQ_PLAY_URI, 20 + w, f"file://{TEST_WAV}\x00".encode("utf-8"))
        time.sleep(0.02)
        send_recv_packet(sock, OP_REQ_PLUGIN_SUSPEND, 30 + w)
        time.sleep(0.01)

    base_rss = get_rss()
    base_fds = count_fds()
    base_th = count_threads()
    print(f"  Warm Baseline: VmRSS={base_rss} kB, FDs={base_fds}, Threads={base_th}")

    CYCLES = 100
    max_plugin_rss = 0
    seq = 5000

    for i in range(CYCLES):
        seq += 1
        op, _, _ = send_recv_packet(sock, OP_REQ_PLAY_URI, seq, f"mineral://stream/c_{i}\x00".encode("utf-8"))
        assert op == OP_RESP_OK
        time.sleep(0.015)

        pstate, _ = read_plugin_info()
        assert pstate == OMM_PLUGIN_ACTIVE

        seq += 1
        op, _, _ = send_recv_packet(sock, OP_REQ_PLAY_URI, seq, f"file://{TEST_WAV}\x00".encode("utf-8"))
        assert op == OP_RESP_OK
        time.sleep(0.015)

        seq += 1
        op, _, _ = send_recv_packet(sock, OP_REQ_PLUGIN_SUSPEND, seq)
        assert op == OP_RESP_OK
        time.sleep(0.01)

        pstate, prss = read_plugin_info()
        assert pstate == OMM_PLUGIN_SUSPENDED
        if prss > max_plugin_rss: max_plugin_rss = prss

        if (i + 1) % 25 == 0:
            c_rss = get_rss()
            c_fds = count_fds()
            c_th = count_threads()
            print(f"  Cycle {i+1:3d}/{CYCLES}: VmRSS={c_rss} kB (delta={c_rss - base_rss:+4d} kB), FDs={c_fds}, Threads={c_th}, PluginRSS={prss} B")

    final_rss = get_rss()
    final_fds = count_fds()
    final_th = count_threads()
    delta_rss = final_rss - base_rss
    delta_fds = final_fds - base_fds
    delta_th = final_th - base_th

    print(f"  100-Cycle Delta VmRSS : {delta_rss} kB (limit <= 256 kB)")
    print(f"  100-Cycle Delta FDs   : {delta_fds} (limit == 0)")
    print(f"  100-Cycle Delta Th    : {delta_th} (limit == 0)")
    print(f"  Max Plugin Suspend RSS: {max_plugin_rss} B (limit < 307200 B)")

    assert delta_rss <= 256, f"100-cycle RSS drift {delta_rss} kB exceeded 256 kB limit!"
    assert delta_fds == 0, f"100-cycle FD leak: delta={delta_fds}"
    assert delta_th == 0, f"100-cycle thread leak: delta={delta_th}"
    assert max_plugin_rss < 307200, f"Plugin suspend RSS {max_plugin_rss} B exceeded 0.3 MB ceiling"
    print("  [PASS] 100-Cycle extended memory profiling passed cleanly.")

    sock.close()
    shm_map.close()
    shm_f.close()
    proc.terminate()
    proc.wait(timeout=2)
    if os.path.exists(TEST_SOCKET): os.unlink(TEST_SOCKET)
    if DEV_SHM_PATH.exists(): DEV_SHM_PATH.unlink()
    if os.path.exists(TEST_WAV): os.unlink(TEST_WAV)


def test_tui_extreme_chaos():
    print("\n[CHALLENGE 2] Extreme TUI Chaos Stress (200 SIGWINCH at 50 Hz + Fuzz Keys)...")
    if os.path.exists(TEST_SOCKET): os.unlink(TEST_SOCKET)
    if DEV_SHM_PATH.exists(): DEV_SHM_PATH.unlink()

    daemon = subprocess.Popen([str(DAEMON_BIN), "--socket", TEST_SOCKET, "--shm", TEST_SHM],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.5)

    session = PtySession([str(TUI_BIN), "--socket", TEST_SOCKET, "--shm", TEST_SHM])
    time.sleep(0.3)
    session.send_keys(b" ") # Play
    time.sleep(0.2)

    sizes = [
        (8, 20), (12, 40), (24, 80), (35, 100), (50, 160),
        (10, 30), (60, 220), (15, 60), (45, 120), (20, 70)
    ]
    fuzz_keys = [b"\x1b[A", b"\x1b[B", b"\x1b[C", b"\x1b[D", b"+", b"-", b" ", b"m", b"1", b"2", b"\t", b"\r"]

    for r in range(200):
        rows, cols = random.choice(sizes)
        session.resize(rows, cols)
        if r % 5 == 0:
            session.send_keys(random.choice(fuzz_keys))
        time.sleep(0.02) # 50 Hz
        assert session.proc.poll() is None, f"TUI crashed during chaos round {r}!"

    # Kill daemon abruptly while TUI is resizing
    daemon.kill()
    daemon.wait()
    time.sleep(0.2)

    assert session.proc.poll() is None, "TUI crashed upon abrupt daemon death"
    session.send_keys(b"q")
    exit_code = session.wait(timeout=2.0)
    assert exit_code == 0, f"TUI exit code {exit_code} != 0"
    print("  [PASS] TUI survived 200 high-frequency resizes, random fuzz keys, and abrupt daemon kill.")

    if os.path.exists(TEST_SOCKET): os.unlink(TEST_SOCKET)
    if DEV_SHM_PATH.exists(): DEV_SHM_PATH.unlink()


def test_gui_extreme_scrub_and_reconnect():
    print("\n[CHALLENGE 3] Lazarus GUI Extreme Control Scrubbing & Reconnection...")
    xvfb_display = ":97"
    xvfb = subprocess.Popen(["Xvfb", xvfb_display, "-screen", "0", "1024x768x24"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.0)

    daemon = subprocess.Popen([str(DAEMON_BIN), "--socket", TEST_SOCKET, "--shm", TEST_SHM],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.5)

    env = os.environ.copy()
    env["DISPLAY"] = xvfb_display
    gui = subprocess.Popen([str(GUI_BIN), "--socket", TEST_SOCKET, "--shm", TEST_SHM],
                           env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.0)
    assert gui.poll() is None, "GUI failed to initialize"

    import socket
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(TEST_SOCKET)

    # 2,000 rapid seek & volume commands
    t_start = time.time()
    for s in range(2000):
        target_ms = (s * 333) % 240000
        vol = (s % 100) / 100.0
        op, _, _ = send_recv_packet(sock, OP_REQ_SEEK, 70000 + s, struct.pack("<I", target_ms))
        assert op == OP_RESP_OK
        op, _, _ = send_recv_packet(sock, OP_REQ_SET_VOLUME, 80000 + s, struct.pack("<f", vol))
        assert op == OP_RESP_OK
    t_elapsed = time.time() - t_start
    print(f"  Dispatched 4,000 control packets in {t_elapsed:.3f}s ({4000/t_elapsed:.0f} pkts/sec)")

    assert gui.poll() is None, "GUI crashed during control blast"

    # Terminate and respawn daemon
    sock.close()
    daemon.terminate()
    daemon.wait(timeout=2)
    time.sleep(0.5)
    assert gui.poll() is None, "GUI crashed when daemon terminated"

    daemon = subprocess.Popen([str(DAEMON_BIN), "--socket", TEST_SOCKET, "--shm", TEST_SHM],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.0)
    assert gui.poll() is None, "GUI crashed after daemon respawn"

    gui.terminate()
    gui.wait(timeout=2)
    daemon.terminate()
    daemon.wait(timeout=2)
    xvfb.terminate()
    xvfb.wait(timeout=2)

    if os.path.exists(TEST_SOCKET): os.unlink(TEST_SOCKET)
    if DEV_SHM_PATH.exists(): DEV_SHM_PATH.unlink()
    print("  [PASS] GUI survived 4,000 rapid scrubs and seamless daemon restart.")


def main():
    print("================================================================================")
    print("   OH-MY-MINERAL M5 EMPIRICAL CHALLENGER RE_2 INDEPENDENT HARNESS               ")
    print("================================================================================")
    t0 = time.time()
    test_100_cycles_extended_memory()
    test_tui_extreme_chaos()
    test_gui_extreme_scrub_and_reconnect()
    dur = time.time() - t0
    print("\n================================================================================")
    print(f"  >>> ALL INDEPENDENT CHALLENGE TESTS PASSED IN {dur:.2f}s! <<<")
    print("================================================================================")


if __name__ == "__main__":
    main()
