#!/usr/bin/env python3
"""
Milestone 5 Iteration 2: Empirical Adversarial Challenger Probe
Specifically stress-tests bin/omm_daemon on OP_REQ_VIEWPORT boundary queries,
rapid query pipelining, concurrent multi-client flooding, and malformed packet fuzzing.
"""

import os
import sys
import time
import socket
import struct
import random
import signal
import subprocess
import threading
from pathlib import Path

WORKSPACE = Path(__file__).resolve().parent.parent.parent
DAEMON_BIN = WORKSPACE / "bin" / "omm_daemon"
LIBRARY_BIN = WORKSPACE / "library.bin"
PLUGIN_BIN = WORKSPACE / "bin" / "libomm_mineral.so"
TEST_SOCK = "/tmp/omm_challenger_m5_it2.sock"
TEST_SHM = "/omm_challenger_m5_it2_shm"
TEST_DEV_SHM = Path("/dev/shm") / "omm_challenger_m5_it2_shm"

OMM_MAGIC = 0x4F4D4D50
OMM_VERSION = 1
OMM_PACKET_SIZE = 512

OP_REQ_PING = 0x0001
OP_REQ_GET_STATUS = 0x0002
OP_REQ_VIEWPORT = 0x0010
OP_REQ_QUERY_SIMILAR = 0x0011

OP_RESP_PONG = 0x8001
OP_RESP_STATUS = 0x8002
OP_RESP_OK = 0x8003
OP_RESP_ERROR = 0x8004
OP_RESP_VIEWPORT_HEADER = 0x8010
OP_RESP_VIEWPORT_ITEM = 0x8011
OP_RESP_SIMILAR_HEADER = 0x8012
OP_RESP_SIMILAR_ITEM = 0x8013

def build_packet(opcode, seq_id=1, status=0, payload=b""):
    if len(payload) < 496:
        payload = payload + b"\x00" * (496 - len(payload))
    elif len(payload) > 496:
        payload = payload[:496]
    return struct.pack("<IHHIi", OMM_MAGIC, OMM_VERSION, opcode, seq_id, status) + payload

def parse_packet(data):
    if len(data) < 16:
        return None
    magic, ver, opcode, seq_id, status = struct.unpack("<IHHIi", data[:16])
    return {
        "magic": magic,
        "version": ver,
        "opcode": opcode,
        "seq_id": seq_id,
        "status": status,
        "payload": data[16:]
    }

class DaemonHarness:
    def __init__(self):
        self.proc = None

    def start(self):
        self.stop()
        if os.path.exists(TEST_SOCK):
            os.unlink(TEST_SOCK)
        if os.path.exists(TEST_DEV_SHM):
            os.unlink(TEST_DEV_SHM)

        cmd = [
            str(DAEMON_BIN),
            "--socket", TEST_SOCK,
            "--shm", TEST_SHM,
            "--library", str(LIBRARY_BIN),
            "--plugin", str(PLUGIN_BIN)
        ]
        self.proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        t0 = time.time()
        while time.time() - t0 < 3.0:
            if os.path.exists(TEST_SOCK):
                break
            time.sleep(0.05)
        if not os.path.exists(TEST_SOCK):
            raise RuntimeError("Daemon failed to create socket")

    def is_alive(self):
        return self.proc and (self.proc.poll() is None)

    def stop(self):
        if self.proc:
            if self.is_alive():
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=1.0)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    self.proc.wait(timeout=1.0)
            self.proc = None
        if os.path.exists(TEST_SOCK):
            try: os.unlink(TEST_SOCK)
            except OSError: pass
        if os.path.exists(TEST_DEV_SHM):
            try: os.unlink(TEST_DEV_SHM)
            except OSError: pass

def run_tests():
    harness = DaemonHarness()
    harness.start()

    passed = 0
    failed = 0
    gaps = []

    def check(cond, name, details=""):
        nonlocal passed, failed, gaps
        if cond and harness.is_alive():
            passed += 1
            print(f"  [PASS] {name}")
        else:
            failed += 1
            stderr_out = ""
            if harness.proc and harness.proc.stderr:
                try:
                    stderr_out = harness.proc.stderr.read().decode("utf-8", errors="replace")
                except Exception:
                    pass
            gap_msg = f"{name} FAILED! details: {details} | stderr: {stderr_out.strip()}"
            print(f"  [FAIL] {gap_msg}")
            gaps.append(gap_msg)
            if not harness.is_alive():
                print("  [FATAL] Daemon died! Restarting for subsequent probes...")
                harness.start()

    print("======================================================================")
    print("  Milestone 5 Iteration 2: Empirical Adversarial Challenger Probe")
    print("======================================================================")

    # ------------------------------------------------------------------------
    # PROBE 1: Viewport Boundary & Underflow Matrix
    # ------------------------------------------------------------------------
    print("\n--- PROBE 1: Viewport Boundary & Underflow Matrix ---")

    test_matrix = [
        # (offset, limit, filter_bytes, name)
        (0, 0, b"", "Limit=0, Empty Filter, Offset=0"),
        (0, 0, b"a\x00", "Limit=0, Single-Char Filter 'a', Offset=0"),
        (0, 0, b"Track\x00", "Limit=0, Matching Filter 'Track', Offset=0"),
        (0, 0, b"   \x00", "Limit=0, Whitespace Filter '   ', Offset=0"),
        (0, 0, b"\t\r\n  \t\x00", "Limit=0, Mixed Whitespace Filter, Offset=0"),
        (0, 0, b"nonexistent_pattern_99999\x00", "Limit=0, Non-matching Filter, Offset=0"),
        (1, 0, b"", "Limit=0, Empty Filter, Offset=1"),
        (50, 0, b"", "Limit=0, Empty Filter, Offset=50"),
        (2500, 0, b"", "Limit=0, Empty Filter, Offset=2500 (Mid-Range)"),
        (4999, 0, b"", "Limit=0, Empty Filter, Offset=4999 (Last Track)"),
        (5000, 0, b"", "Limit=0, Empty Filter, Offset=5000 (Equal to Count)"),
        (5001, 0, b"", "Limit=0, Empty Filter, Offset=5001 (Beyond Count)"),
        (0x7FFFFFFF, 0, b"", "Limit=0, Empty Filter, Offset=0x7FFFFFFF"),
        (0xFFFFFFFF, 0, b"", "Limit=0, Empty Filter, Offset=0xFFFFFFFF"),
        (0xFFFFFFFF, 0, b"nonexistent\x00", "Limit=0, Non-matching Filter, Offset=0xFFFFFFFF"),
        (0xFFFFFFFF, 0, b"Track\x00", "Limit=0, Matching Filter, Offset=0xFFFFFFFF"),
        (0, 1, b"", "Limit=1, Empty Filter, Offset=0"),
        (4999, 1, b"", "Limit=1, Empty Filter, Offset=4999"),
        (5000, 1, b"", "Limit=1, Empty Filter, Offset=5000"),
        (5001, 1, b"", "Limit=1, Empty Filter, Offset=5001"),
        (0xFFFFFFFF, 1, b"", "Limit=1, Empty Filter, Offset=0xFFFFFFFF"),
        (0, 128, b"", "Limit=128 (Max Page Size), Offset=0"),
        (0, 129, b"", "Limit=129 (Clamped to 128), Offset=0"),
        (0, 65535, b"", "Limit=65535 (Clamped to 128), Offset=0"),
        (0, 0xFFFFFFFF, b"", "Limit=0xFFFFFFFF (Max uint32 limit), Offset=0"),
        (0, 10, b"' OR 1=1; --\x00", "SQL Injection pattern in filter"),
        (0, 10, b"%s%s%s%n\x00", "Format string pattern in filter"),
        (0, 10, b"\xFF\xFE\xFD\xFC\x00", "Non-ASCII byte pattern in filter"),
    ]

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(TEST_SOCK)
    s.settimeout(2.0)

    for off, lim, filt, desc in test_matrix:
        filt_len = len(filt)
        payload = struct.pack("<IIH", off, lim, filt_len) + filt + b"\x00" * (486 - len(filt))
        s.sendall(build_packet(OP_REQ_VIEWPORT, seq_id=1000, payload=payload))
        resp = s.recv(512)
        p = parse_packet(resp)
        ok = (p is not None and p["opcode"] == OP_RESP_VIEWPORT_HEADER)
        if ok:
            tot, filt_cnt, resp_off, ret_cnt = struct.unpack("<IIII", p["payload"][:16])
            # Drain any item packets if ret_cnt > 0
            if ret_cnt > 0:
                for _ in range(ret_cnt):
                    item_resp = s.recv(512)
                    ip = parse_packet(item_resp)
                    if not ip or ip["opcode"] != OP_RESP_VIEWPORT_ITEM:
                        ok = False
            if lim == 0:
                ok = ok and (ret_cnt == 0)
        check(ok, f"Matrix Query: {desc}", f"Expected OP_RESP_VIEWPORT_HEADER, got {p['opcode'] if p else None}")

    s.close()

    # ------------------------------------------------------------------------
    # PROBE 2: Viewport Filter Text Without Null Terminator
    # ------------------------------------------------------------------------
    print("\n--- PROBE 2: Filter Text Boundary & Non-Null Payload ---")

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(TEST_SOCK)
    s.settimeout(2.0)

    # FilterLen = 126 with solid 'A' characters (no null byte anywhere in 126 bytes)
    dirty_filter = b"A" * 126
    payload = struct.pack("<IIH", 0, 10, 126) + dirty_filter + b"\x00" * (486 - 126)
    s.sendall(build_packet(OP_REQ_VIEWPORT, seq_id=2001, payload=payload))
    resp = s.recv(512)
    p = parse_packet(resp)
    check(p is not None and p["opcode"] == OP_RESP_VIEWPORT_HEADER,
          "FilterText without embedded null byte safely handled",
          "Daemon handled 126 solid bytes")

    # FilterLen = 500 (exceeds payload capacity)
    payload = struct.pack("<IIH", 0, 10, 500) + b"Track\x00" + b"\x00" * 480
    s.sendall(build_packet(OP_REQ_VIEWPORT, seq_id=2002, payload=payload))
    resp = s.recv(512)
    p = parse_packet(resp)
    check(p is not None and p["opcode"] == OP_RESP_VIEWPORT_HEADER,
          "Oversized FilterLen=500 safely handled without buffer overflow")

    s.close()

    # ------------------------------------------------------------------------
    # PROBE 3: Rapid Viewport Query Storm (1,000 Pipelined Queries)
    # ------------------------------------------------------------------------
    print("\n--- PROBE 3: Rapid Viewport Query Storm (1,000 Pipelined Queries) ---")

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(TEST_SOCK)
    s.settimeout(5.0)

    storm_count = 1000
    storm_ok = True
    t_start = time.time()

    filters_pool = [b"", b"   \x00", b"Track\x00", b"000\x00", b"nonexistent\x00"]
    limits_pool = [0, 0, 1, 5, 10, 0, 128]
    offsets_pool = [0, 10, 100, 2500, 4999, 5000, 0xFFFFFFFF]

    for seq in range(1, storm_count + 1):
        off = random.choice(offsets_pool)
        lim = random.choice(limits_pool)
        filt = random.choice(filters_pool)
        payload = struct.pack("<IIH", off, lim, len(filt)) + filt + b"\x00" * (486 - len(filt))
        s.sendall(build_packet(OP_REQ_VIEWPORT, seq_id=seq, payload=payload))

        resp = s.recv(512)
        p = parse_packet(resp)
        if not p or p["opcode"] != OP_RESP_VIEWPORT_HEADER or p["seq_id"] != seq:
            storm_ok = False
            break
        ret_cnt = struct.unpack("<I", p["payload"][12:16])[0]
        for _ in range(ret_cnt):
            item_resp = s.recv(512)
            ip = parse_packet(item_resp)
            if not ip or ip["opcode"] != OP_RESP_VIEWPORT_ITEM or ip["seq_id"] != seq:
                storm_ok = False
                break
        if not storm_ok:
            break

    elapsed = time.time() - t_start
    check(storm_ok, f"1,000 Pipelined Viewport Queries processed in {elapsed:.3f}s ({storm_count/elapsed:.1f} req/s)")
    s.close()

    # ------------------------------------------------------------------------
    # PROBE 4: Concurrent Multi-Client Flooding (16 Threads x 50 Queries = 800)
    # ------------------------------------------------------------------------
    print("\n--- PROBE 4: Concurrent Multi-Client Flooding (16 Threads x 50 Queries) ---")

    threads_count = 16
    queries_per_thread = 50
    thread_errors = []

    def worker_thread(tid):
        try:
            ws = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            ws.connect(TEST_SOCK)
            ws.settimeout(5.0)

            for qid in range(queries_per_thread):
                seq = tid * 1000 + qid
                off = random.choice([0, 10, 50, 100, 0xFFFFFFFF])
                lim = random.choice([0, 0, 1, 10])
                filt = random.choice([b"", b"Track\x00", b"xyz\x00"])
                payload = struct.pack("<IIH", off, lim, len(filt)) + filt + b"\x00" * (486 - len(filt))
                ws.sendall(build_packet(OP_REQ_VIEWPORT, seq_id=seq, payload=payload))

                resp = ws.recv(512)
                p = parse_packet(resp)
                if not p or p["opcode"] != OP_RESP_VIEWPORT_HEADER:
                    thread_errors.append(f"Thread {tid} query {qid} bad header")
                    break
                ret_cnt = struct.unpack("<I", p["payload"][12:16])[0]
                for _ in range(ret_cnt):
                    item = ws.recv(512)
                    ip = parse_packet(item)
                    if not ip or ip["opcode"] != OP_RESP_VIEWPORT_ITEM:
                        thread_errors.append(f"Thread {tid} bad item")
                        break
            ws.close()
        except Exception as e:
            thread_errors.append(f"Thread {tid} exception: {e}")

    threads = []
    t_flood_start = time.time()
    for t_id in range(threads_count):
        th = threading.Thread(target=worker_thread, args=(t_id,))
        threads.append(th)
        th.start()

    for th in threads:
        th.join()

    flood_elapsed = time.time() - t_flood_start
    check(len(thread_errors) == 0,
          f"16 Concurrent Clients completed {threads_count * queries_per_thread} queries in {flood_elapsed:.3f}s with 0 errors",
          f"Errors: {thread_errors[:5]}")

    # ------------------------------------------------------------------------
    # PROBE 5: Malformed Packet Fuzzing & Header Corruption
    # ------------------------------------------------------------------------
    print("\n--- PROBE 5: Malformed Packet Fuzzing & Header Corruption ---")

    fuzz_clean = True
    for fuzz_idx in range(50):
        try:
            fs = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            fs.connect(TEST_SOCK)
            fs.settimeout(1.0)

            mode = fuzz_idx % 5
            if mode == 0:
                # Truncated packet
                trunc_len = random.choice([1, 2, 7, 15, 16, 32, 128, 511])
                fs.sendall(os.urandom(trunc_len))
            elif mode == 1:
                # Valid magic, corrupted version
                pkt = build_packet(OP_REQ_VIEWPORT, seq_id=9000 + fuzz_idx)
                corrupt_pkt = pkt[:4] + struct.pack("<H", 0x9999) + pkt[6:]
                fs.sendall(corrupt_pkt)
            elif mode == 2:
                # Valid magic, invalid opcode
                fs.sendall(build_packet(0xEFFF, seq_id=9100 + fuzz_idx))
            elif mode == 3:
                # Valid magic, valid opcode, totally random payload bytes
                rand_payload = os.urandom(496)
                fs.sendall(build_packet(OP_REQ_VIEWPORT, seq_id=9200 + fuzz_idx, payload=rand_payload))
            elif mode == 4:
                # Random 512 bytes with no valid magic
                fs.sendall(os.urandom(512))

            try:
                fs.recv(512)
            except Exception:
                pass
            fs.close()
        except Exception:
            pass

    time.sleep(0.1)
    check(harness.is_alive(), "Daemon remained alive and responsive across 50 malformed fuzz injections")

    # ------------------------------------------------------------------------
    # PROBE 6: Post-Stress Liveness & Final Health Verification
    # ------------------------------------------------------------------------
    print("\n--- PROBE 6: Post-Stress Liveness & Final Health Verification ---")

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(TEST_SOCK)
    s.settimeout(2.0)

    s.sendall(build_packet(OP_REQ_PING, seq_id=9999))
    resp = s.recv(512)
    p = parse_packet(resp)
    check(p is not None and p["opcode"] == OP_RESP_PONG and p["seq_id"] == 9999,
          "Post-stress Ping/Pong roundtrip verified")

    s.sendall(build_packet(OP_REQ_GET_STATUS, seq_id=10000))
    resp = s.recv(512)
    p = parse_packet(resp)
    check(p is not None and p["opcode"] == OP_RESP_STATUS and p["seq_id"] == 10000,
          "Post-stress GetStatus query verified")

    # Viewport query after all stress
    payload = struct.pack("<IIH", 0, 5, 0) + b"\x00" * 486
    s.sendall(build_packet(OP_REQ_VIEWPORT, seq_id=10001, payload=payload))
    resp = s.recv(512)
    p = parse_packet(resp)
    items_received = 0
    if p and p["opcode"] == OP_RESP_VIEWPORT_HEADER:
        ret_cnt = struct.unpack("<I", p["payload"][12:16])[0]
        for _ in range(ret_cnt):
            it = s.recv(512)
            ip = parse_packet(it)
            if ip and ip["opcode"] == OP_RESP_VIEWPORT_ITEM:
                items_received += 1
    check(p is not None and items_received == 5,
          "Post-stress Viewport query retrieved 5 valid items cleanly")

    s.close()
    harness.stop()

    print("\n======================================================================")
    print(f"  CHALLENGER PROBE SUMMARY: {passed + failed} Tests, {passed} Passed, {failed} Failed")
    if failed == 0:
        print("  >>> VERDICT: CONFIRM (0 Gaps Found) <<<")
    else:
        print(f"  >>> VERDICT: GAP_FOUND ({failed} Gaps Found) <<<")
    print("======================================================================")

    return failed == 0

if __name__ == "__main__":
    success = run_tests()
    sys.exit(0 if success else 1)
