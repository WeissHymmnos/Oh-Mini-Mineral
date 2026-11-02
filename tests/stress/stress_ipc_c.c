#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <assert.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <sys/time.h>
#include <signal.h>
#include "omm_abi.h"

#define C_STRESS_SOCK "/tmp/omm_stress_c.sock"

static int g_passed = 0;
static int g_failed = 0;
static int g_total = 0;

static void check(bool condition, const char* msg) {
    g_total++;
    if (condition) {
        g_passed++;
        printf("  [PASS] %s\n", msg);
    } else {
        g_failed++;
        printf("  [FAIL] %s\n", msg);
    }
}

static int count_open_fds(void) {
    int count = 0;
    char path[64];
    for (int fd = 0; fd < 1024; ++fd) {
        snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);
        if (access(path, F_OK) == 0) {
            count++;
        }
    }
    return count;
}

static bool send_packet_c(int sock_fd, const omm_packet_t* pkt) {
    size_t total = 0;
    const uint8_t* buf = (const uint8_t*)pkt;
    while (total < sizeof(omm_packet_t)) {
        ssize_t n = write(sock_fd, buf + total, sizeof(omm_packet_t) - total);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            return false;
        }
        total += (size_t)n;
    }
    return true;
}

static bool recv_packet_c(int sock_fd, omm_packet_t* pkt) {
    size_t total = 0;
    uint8_t* buf = (uint8_t*)pkt;
    while (total < sizeof(omm_packet_t)) {
        ssize_t n = read(sock_fd, buf + total, sizeof(omm_packet_t) - total);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            return false;
        }
        total += (size_t)n;
    }
    return (pkt->magic == OMM_PACKET_MAGIC);
}

static void init_packet_c(omm_packet_t* pkt, uint16_t opcode, uint32_t seq_id, int32_t status) {
    memset(pkt, 0, sizeof(omm_packet_t));
    pkt->magic = OMM_PACKET_MAGIC;
    pkt->version = 1;
    pkt->opcode = opcode;
    pkt->seq_id = seq_id;
    pkt->status_code = status;
}

static void test_c_connection_churn(int iterations) {
    printf("------------------------------------------------------------\n");
    printf("[C TEST 1] High-Frequency Connection Churn (%d iterations)\n", iterations);
    printf("------------------------------------------------------------\n");

    unlink(C_STRESS_SOCK);
    int srv_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    check(srv_fd >= 0, "C server socket creation");

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, C_STRESS_SOCK, sizeof(addr.sun_path) - 1);

    int rc = bind(srv_fd, (struct sockaddr*)&addr, sizeof(addr));
    check(rc == 0, "C server socket bind");
    rc = listen(srv_fd, 32);
    check(rc == 0, "C server socket listen");

    pid_t pid = fork();
    if (pid == 0) {
        // Child: rapidly connect and close
        for (int i = 0; i < iterations; ++i) {
            int cli_fd = socket(AF_UNIX, SOCK_STREAM, 0);
            if (cli_fd < 0 || connect(cli_fd, (struct sockaddr*)&addr, sizeof(addr)) != 0) {
                if (cli_fd >= 0) close(cli_fd);
                exit(1);
            }
            close(cli_fd);
        }
        exit(0);
    } else {
        // Parent: accept and close
        int accepted = 0;
        for (int i = 0; i < iterations; ++i) {
            int conn_fd = accept(srv_fd, NULL, NULL);
            if (conn_fd >= 0) {
                accepted++;
                close(conn_fd);
            }
        }
        int status = 0;
        waitpid(pid, &status, 0);
        check(accepted == iterations, "C server accepted all churn connections");
        check(WIFEXITED(status) && WEXITSTATUS(status) == 0, "C child finished cleanly");
        close(srv_fd);
        unlink(C_STRESS_SOCK);
    }
}

static void test_c_fragmented_packet(size_t chunk_size, const char* name) {
    printf("  Testing C fragmented write: %s (chunk_size=%zu)\n", name, chunk_size);
    unlink(C_STRESS_SOCK);
    int srv_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, C_STRESS_SOCK, sizeof(addr.sun_path) - 1);

    bind(srv_fd, (struct sockaddr*)&addr, sizeof(addr));
    listen(srv_fd, 4);

    omm_packet_t send_pkt;
    init_packet_c(&send_pkt, OP_REQ_PLAY_URI, 9999, 0);
    snprintf(send_pkt.payload.uri, sizeof(send_pkt.payload.uri), "mineral://track/stream/test_flac_48k");
    for (size_t i = 64; i < sizeof(send_pkt.payload.raw); ++i) {
        send_pkt.payload.raw[i] = (uint8_t)((i * 31 + 7) & 0xFF);
    }

    pid_t pid = fork();
    if (pid == 0) {
        // Child: write fragmented
        int cli_fd = socket(AF_UNIX, SOCK_STREAM, 0);
        connect(cli_fd, (struct sockaddr*)&addr, sizeof(addr));
        const uint8_t* p = (const uint8_t*)&send_pkt;
        size_t offset = 0;
        while (offset < sizeof(omm_packet_t)) {
            size_t wlen = chunk_size;
            if (offset + wlen > sizeof(omm_packet_t)) {
                wlen = sizeof(omm_packet_t) - offset;
            }
            write(cli_fd, p + offset, wlen);
            offset += wlen;
            usleep(20);
        }
        close(cli_fd);
        exit(0);
    } else {
        int conn_fd = accept(srv_fd, NULL, NULL);
        omm_packet_t recv_pkt;
        memset(&recv_pkt, 0, sizeof(recv_pkt));
        bool ok = recv_packet_c(conn_fd, &recv_pkt);
        check(ok, "C recv_packet returned true for fragmented stream");
        check(memcmp(&send_pkt, &recv_pkt, sizeof(omm_packet_t)) == 0, "C 512-byte packet matches byte-for-byte");
        close(conn_fd);
        int status = 0;
        waitpid(pid, &status, 0);
        close(srv_fd);
        unlink(C_STRESS_SOCK);
    }
}

static void test_c_corrupt_magic(void) {
    printf("------------------------------------------------------------\n");
    printf("[C TEST 3] Corrupt Magic & Truncation Handling\n");
    printf("------------------------------------------------------------\n");

    unlink(C_STRESS_SOCK);
    int srv_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, C_STRESS_SOCK, sizeof(addr.sun_path) - 1);

    bind(srv_fd, (struct sockaddr*)&addr, sizeof(addr));
    listen(srv_fd, 4);

    pid_t pid = fork();
    if (pid == 0) {
        int cli_fd = socket(AF_UNIX, SOCK_STREAM, 0);
        connect(cli_fd, (struct sockaddr*)&addr, sizeof(addr));

        // 1. Invalid magic
        omm_packet_t bad_pkt;
        init_packet_c(&bad_pkt, OP_REQ_PLAY, 1, 0);
        bad_pkt.magic = 0xBADF00D;
        send_packet_c(cli_fd, &bad_pkt);

        // 2. Truncated 10 bytes then close
        uint8_t short_buf[10] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10};
        write(cli_fd, short_buf, sizeof(short_buf));
        close(cli_fd);
        exit(0);
    } else {
        int conn_fd = accept(srv_fd, NULL, NULL);
        omm_packet_t pkt;
        bool res1 = recv_packet_c(conn_fd, &pkt);
        check(!res1, "Corrupted magic 0xBADF00D safely rejected (returned false)");
        bool res2 = recv_packet_c(conn_fd, &pkt);
        check(!res2, "Truncated 10-byte stream safely rejected (returned false)");
        close(conn_fd);
        int status = 0;
        waitpid(pid, &status, 0);
        close(srv_fd);
        unlink(C_STRESS_SOCK);
    }
}

static void test_c_leak_audit(void) {
    printf("------------------------------------------------------------\n");
    printf("[C TEST 4] File Descriptor Leak Audit\n");
    printf("------------------------------------------------------------\n");

    int initial_fds = count_open_fds();
    unlink(C_STRESS_SOCK);
    int srv_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, C_STRESS_SOCK, sizeof(addr.sun_path) - 1);

    bind(srv_fd, (struct sockaddr*)&addr, sizeof(addr));
    listen(srv_fd, 16);

    for (int i = 0; i < 100; ++i) {
        int cli_fd = socket(AF_UNIX, SOCK_STREAM, 0);
        connect(cli_fd, (struct sockaddr*)&addr, sizeof(addr));
        int conn_fd = accept(srv_fd, NULL, NULL);

        omm_packet_t pkt;
        init_packet_c(&pkt, OP_REQ_PING, (uint32_t)i, 0);
        send_packet_c(cli_fd, &pkt);
        recv_packet_c(conn_fd, &pkt);

        init_packet_c(&pkt, OP_RESP_PONG, (uint32_t)i, 0);
        send_packet_c(conn_fd, &pkt);
        recv_packet_c(cli_fd, &pkt);

        close(cli_fd);
        close(conn_fd);
    }

    close(srv_fd);
    unlink(C_STRESS_SOCK);

    int final_fds = count_open_fds();
    printf("  Initial FDs: %d, Final FDs: %d (Delta: %d)\n", initial_fds, final_fds, final_fds - initial_fds);
    check(initial_fds == final_fds, "Zero file descriptor leaks after 100 ping-pong cycles");
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);

    printf("============================================================\n");
    printf("   Oh-My-Mineral: C ABI Empirical Stress Harness (GCC)     \n");
    printf("============================================================\n");

    test_c_connection_churn(150);

    printf("------------------------------------------------------------\n");
    printf("[C TEST 2] Partial / Fragmented Packet Stress\n");
    printf("------------------------------------------------------------\n");
    test_c_fragmented_packet(1, "1-byte chunks (512 writes)");
    test_c_fragmented_packet(7, "7-byte chunks (73 writes)");
    test_c_fragmented_packet(256, "256-byte chunks (2 writes)");

    test_c_corrupt_magic();
    test_c_leak_audit();

    printf("============================================================\n");
    printf("C STRESS SUMMARY: Total=%d, Passed=%d, Failed=%d\n", g_total, g_passed, g_failed);
    printf("============================================================\n");

    return (g_failed > 0) ? 1 : 0;
}
