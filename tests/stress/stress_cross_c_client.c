#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/un.h>
#include "omm_abi.h"

int main(int argc, char** argv) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <socket_path> <mode>\n", argv[0]);
        fprintf(stderr, "Modes: churn, frag, corrupt\n");
        return 1;
    }

    const char* sock_path = argv[1];
    const char* mode = argv[2];

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, sock_path, sizeof(addr.sun_path) - 1);

    if (strcmp(mode, "churn") == 0) {
        int count = (argc >= 4) ? atoi(argv[3]) : 100;
        for (int i = 0; i < count; ++i) {
            int fd = socket(AF_UNIX, SOCK_STREAM, 0);
            if (fd < 0 || connect(fd, (struct sockaddr*)&addr, sizeof(addr)) != 0) {
                if (fd >= 0) close(fd);
                return 10;
            }
            close(fd);
        }
        return 0;
    }

    if (strcmp(mode, "frag") == 0) {
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0 || connect(fd, (struct sockaddr*)&addr, sizeof(addr)) != 0) {
            if (fd >= 0) close(fd);
            return 20;
        }

        // Send 1-byte fragmented packet
        omm_packet_t pkt;
        memset(&pkt, 0, sizeof(pkt));
        pkt.magic = OMM_PACKET_MAGIC;
        pkt.version = 1;
        pkt.opcode = OP_REQ_PLAY_URI;
        pkt.seq_id = 8888;
        pkt.status_code = 0;
        snprintf(pkt.payload.uri, sizeof(pkt.payload.uri), "file:///tmp/cross_lang_test.wav");
        for (size_t i = 64; i < sizeof(pkt.payload.raw); ++i) {
            pkt.payload.raw[i] = (uint8_t)(i ^ 0x3C);
        }

        const uint8_t* p = (const uint8_t*)&pkt;
        for (size_t i = 0; i < sizeof(omm_packet_t); ++i) {
            if (write(fd, &p[i], 1) != 1) {
                close(fd);
                return 21;
            }
            usleep(10);
        }

        // Receive response from Pascal server
        omm_packet_t resp;
        size_t total = 0;
        uint8_t* r = (uint8_t*)&resp;
        while (total < sizeof(omm_packet_t)) {
            ssize_t n = read(fd, r + total, sizeof(omm_packet_t) - total);
            if (n <= 0) {
                close(fd);
                return 22;
            }
            total += (size_t)n;
        }

        if (resp.magic != OMM_PACKET_MAGIC || resp.opcode != OP_RESP_OK || resp.seq_id != 8888) {
            close(fd);
            return 23;
        }

        close(fd);
        return 0;
    }

    if (strcmp(mode, "corrupt") == 0) {
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0 || connect(fd, (struct sockaddr*)&addr, sizeof(addr)) != 0) {
            if (fd >= 0) close(fd);
            return 30;
        }

        omm_packet_t bad_pkt;
        memset(&bad_pkt, 0, sizeof(bad_pkt));
        bad_pkt.magic = 0xCAFEBABE;
        bad_pkt.version = 1;
        bad_pkt.opcode = OP_REQ_PING;

        if (write(fd, &bad_pkt, sizeof(bad_pkt)) != (ssize_t)sizeof(bad_pkt)) {
            close(fd);
            return 31;
        }

        close(fd);
        return 0;
    }

    return 1;
}
