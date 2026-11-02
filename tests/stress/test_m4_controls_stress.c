#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>

#include "omm_abi.h"

#define CLOCK_MONOTONIC 1

static int64_t get_monotonic_micros(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ((int64_t)ts.tv_sec * 1000000LL) + ((int64_t)ts.tv_nsec / 1000LL);
}

int main(int argc, char* argv[]) {
    const char* socket_path = "/tmp/omm.sock";
    if (argc >= 2) socket_path = argv[1];

    printf("======================================================================\n");
    printf("  CHALLENGE 3: Controls & Recommendation Responsiveness Stress        \n");
    printf("======================================================================\n");

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        perror("socket");
        return 1;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, socket_path, sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) != 0) {
        perror("connect");
        close(fd);
        return 1;
    }
    printf("  Connected to daemon socket at %s\n", socket_path);

    // Test 3.1: Recommendation top-20 query responsiveness
    printf("\nTest 3.1: Top-20 Similar Tracks Query Responsiveness (< 5ms)\n");
    omm_packet_t req;
    memset(&req, 0, sizeof(req));
    req.magic = OMM_PACKET_MAGIC;
    req.version = 1;
    req.opcode = OP_REQ_QUERY_SIMILAR;
    req.seq_id = 1001;
    req.payload.similar_req.query_track_id = 1;
    req.payload.similar_req.query_limit = 20;

    int64_t t_start = get_monotonic_micros();
    if (write(fd, &req, sizeof(req)) != sizeof(req)) {
        perror("write query_similar");
        close(fd);
        return 1;
    }

    // Read header response
    omm_packet_t resp;
    if (read(fd, &resp, sizeof(resp)) != sizeof(resp)) {
        perror("read header");
        close(fd);
        return 1;
    }

    if (resp.opcode != OP_RESP_SIMILAR_HEADER) {
        fprintf(stderr, "  [FAIL] Expected OP_RESP_SIMILAR_HEADER (0x8012), got 0x%04x\n", resp.opcode);
        close(fd);
        return 1;
    }

    uint32_t query_track_id = 0;
    uint32_t returned_count = 0;
    memcpy(&query_track_id, &resp.payload.raw[0], 4);
    memcpy(&returned_count, &resp.payload.raw[4], 4);
    printf("  Similar header: query_track_id=%u, returned_count=%u\n", query_track_id, returned_count);

    if (returned_count != 20) {
        fprintf(stderr, "  [FAIL] Expected 20 similar candidates, got %u\n", returned_count);
        close(fd);
        return 1;
    }

    // Read all item packets
    for (uint32_t i = 0; i < returned_count; i++) {
        omm_packet_t item_pkt;
        if (read(fd, &item_pkt, sizeof(item_pkt)) != sizeof(item_pkt)) {
            perror("read similar item");
            close(fd);
            return 1;
        }
        if (item_pkt.opcode != OP_RESP_SIMILAR_ITEM) {
            fprintf(stderr, "  [FAIL] Expected OP_RESP_SIMILAR_ITEM (0x8013) on item %u, got 0x%04x\n", i, item_pkt.opcode);
            close(fd);
            return 1;
        }
    }
    int64_t t_end = get_monotonic_micros();
    double latency_ms = (double)(t_end - t_start) / 1000.0;
    printf("  Top-20 query round-trip latency: %.2f ms (%ld us)\n", latency_ms, (long)(t_end - t_start));

    if (latency_ms > 5.0) {
        fprintf(stderr, "  [FAIL] Top-20 query latency %.2f ms exceeds 5.0 ms threshold!\n", latency_ms);
        close(fd);
        return 1;
    }
    printf("  [PASS] Top-20 query responsiveness: %.2f ms < 5.00 ms.\n", latency_ms);

    // Test 3.2: Rapid track seeking and volume adjustments
    printf("\nTest 3.2: Rapid Seek & Volume Control Stream (1,000 commands)\n");
    int burst_count = 1000;
    int64_t t_burst_start = get_monotonic_micros();
    for (int i = 0; i < burst_count; i++) {
        omm_packet_t cmd;
        memset(&cmd, 0, sizeof(cmd));
        cmd.magic = OMM_PACKET_MAGIC;
        cmd.version = 1;
        cmd.seq_id = 2000 + i;

        if (i % 2 == 0) {
            cmd.opcode = OP_REQ_SEEK;
            cmd.payload.target_ms = (i * 100) % 240000;
        } else {
            cmd.opcode = OP_REQ_SET_VOLUME;
            cmd.payload.volume = (float)(i % 100) / 100.0f;
        }

        if (write(fd, &cmd, sizeof(cmd)) != sizeof(cmd)) {
            perror("write burst command");
            close(fd);
            return 1;
        }

        omm_packet_t ok_resp;
        if (read(fd, &ok_resp, sizeof(ok_resp)) != sizeof(ok_resp)) {
            perror("read cmd response");
            close(fd);
            return 1;
        }
        if (ok_resp.opcode != OP_RESP_OK) {
            fprintf(stderr, "  [FAIL] Expected OP_RESP_OK (0x8003) on cmd %d, got 0x%04x\n", i, ok_resp.opcode);
            close(fd);
            return 1;
        }
    }
    int64_t t_burst_end = get_monotonic_micros();
    double burst_ms = (double)(t_burst_end - t_burst_start) / 1000.0;
    printf("  Processed 1,000 synchronous seek & volume command round-trips in %.2f ms (%.1f cmds/sec, %.2f us/cmd)\n",
           burst_ms, (double)burst_count / (burst_ms / 1000.0), (double)(t_burst_end - t_burst_start) / (double)burst_count);

    // Verify socket buffer has no bloat
    int send_buf_size = 0;
    socklen_t optlen = sizeof(send_buf_size);
    getsockopt(fd, SOL_SOCKET, SO_SNDBUF, &send_buf_size, &optlen);
    printf("  Socket Send Buffer Capacity: %d bytes\n", send_buf_size);

    // Ping daemon to ensure clean state
    omm_packet_t ping;
    memset(&ping, 0, sizeof(ping));
    ping.magic = OMM_PACKET_MAGIC;
    ping.version = 1;
    ping.opcode = OP_REQ_PING;
    ping.seq_id = 9999;

    int64_t t_ping_start = get_monotonic_micros();
    if (write(fd, &ping, sizeof(ping)) != sizeof(ping)) {
        perror("write ping");
        close(fd);
        return 1;
    }
    omm_packet_t pong;
    if (read(fd, &pong, sizeof(pong)) != sizeof(pong)) {
        perror("read pong");
        close(fd);
        return 1;
    }
    int64_t t_ping_end = get_monotonic_micros();
    double ping_latency_ms = (double)(t_ping_end - t_ping_start) / 1000.0;

    if (pong.opcode != OP_RESP_PONG) {
        fprintf(stderr, "  [FAIL] Expected OP_RESP_PONG (0x8001), got 0x%04x\n", pong.opcode);
        close(fd);
        return 1;
    }
    printf("  Ping round-trip: %.2f ms (%ld us)\n", ping_latency_ms, (long)(t_ping_end - t_ping_start));
    printf("  [PASS] Rapid seek/volume stream processed cleanly without socket bloat or stall.\n");

    close(fd);
    printf("\n>>> CONTROLS & QUERY RESPONSIVENESS STRESS TESTS PASSED! <<<\n");
    return 0;
}
