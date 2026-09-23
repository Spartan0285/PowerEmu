/*
 * PowerEmu network helper: puts a virtual Mac straight on to the network.
 *
 *   poweremu-netd <interface> <helper-socket> <emulator-socket> [uid]
 *
 * Normally a virtual Mac lives behind the emulator on a private address:
 * it can reach out, but nothing on the network can reach it and it cannot
 * see anybody else -- Bonjour never crosses that boundary.  Bridged to a
 * real network interface it becomes an ordinary machine on the network,
 * with its own address from the same router, visible to and able to see
 * every other Mac.
 *
 * macOS only lets root open a bridged interface, so this is the only piece
 * that needs privilege: it does nothing but move ethernet frames between
 * Apple's vmnet and a Unix datagram socket the emulator is connected to.
 * The emulator itself, and PowerEmu, stay as they were.  That is the whole
 * reason this exists as a separate program rather than as a privileged
 * emulator.
 *
 * It speaks the emulator's "dgram" network backend:
 *
 *   -netdev dgram,id=net0,local.type=unix,local.path=<emulator-socket>,
 *                         remote.type=unix,remote.path=<helper-socket>
 *
 * Copyright (c) 2026 Spartan0285
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <dispatch/dispatch.h>
#include <vmnet/vmnet.h>

#define MAX_FRAME 2048          /* one ethernet frame, with room to spare */
#define BATCH     64            /* frames read from vmnet in one go */

static interface_ref iface;
static int sock = -1;                   /* our datagram socket */
static struct sockaddr_un emulator;     /* where the emulator listens */
static const char *helper_path;
static uid_t owner_uid = (uid_t)-1;     /* who PowerEmu runs as */
static volatile sig_atomic_t stopping;

static void tidy_up(int sig)
{
    (void)sig;
    stopping = 1;
    if (helper_path) {
        char path[1100];
        unlink(helper_path);
        snprintf(path, sizeof(path), "%s.mac", helper_path);
        unlink(path);
    }
    _exit(0);
}

/* ---- frames from the network, into the virtual Mac ---- */

static void forward_to_emulator(void)
{
    struct vmpktdesc packets[BATCH];
    struct iovec iovs[BATCH];
    static uint8_t buffers[BATCH][MAX_FRAME];
    int count = BATCH;

    for (int i = 0; i < BATCH; i++) {
        iovs[i].iov_base = buffers[i];
        iovs[i].iov_len = MAX_FRAME;
        packets[i].vm_pkt_iov = &iovs[i];
        packets[i].vm_pkt_iovcnt = 1;
        packets[i].vm_pkt_size = MAX_FRAME;
        packets[i].vm_flags = 0;
    }
    if (vmnet_read(iface, packets, &count) != VMNET_SUCCESS) {
        return;
    }
    for (int i = 0; i < count; i++) {
        ssize_t n = sendto(sock, buffers[i], packets[i].vm_pkt_size, 0,
                           (struct sockaddr *)&emulator, sizeof(emulator));
        /*
         * The emulator not being there yet, or having gone, is ordinary:
         * the machine may not have started, or may have been shut down.
         * Frames for it are simply dropped, as they would be on a wire.
         */
        if (n < 0 && errno != ENOENT && errno != ECONNREFUSED && errno != EAGAIN) {
            fprintf(stderr, "poweremu-netd: sending to the emulator: %s\n", strerror(errno));
        }
    }
}

/* ---- frames from the virtual Mac, out to the network ---- */

static void forward_to_network(const uint8_t *frame, size_t len)
{
    struct iovec iov = { .iov_base = (void *)frame, .iov_len = len };
    struct vmpktdesc packet = {
        .vm_pkt_iov = &iov,
        .vm_pkt_iovcnt = 1,
        .vm_pkt_size = len,
        .vm_flags = 0,
    };
    int count = 1;

    if (vmnet_write(iface, &packet, &count) != VMNET_SUCCESS) {
        fprintf(stderr, "poweremu-netd: the network would not take a frame\n");
    }
}

/* ---- setting up ---- */

static int open_socket(const char *path, uid_t owner)
{
    struct sockaddr_un addr;
    int fd = socket(AF_UNIX, SOCK_DGRAM, 0);

    if (fd < 0) {
        fprintf(stderr, "poweremu-netd: socket: %s\n", strerror(errno));
        return -1;
    }
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof(addr.sun_path)) {
        fprintf(stderr, "poweremu-netd: the socket's name is too long\n");
        close(fd);
        return -1;
    }
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    unlink(path);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "poweremu-netd: bind %s: %s\n", path, strerror(errno));
        close(fd);
        return -1;
    }
    /*
     * The emulator runs as the reader, not as root, and has to be able to
     * send to this socket -- but nobody else should.
     */
    if (owner != (uid_t)-1) {
        if (chown(path, owner, (gid_t)-1) < 0) {
            fprintf(stderr, "poweremu-netd: chown %s: %s\n", path, strerror(errno));
        }
    }
    chmod(path, 0600);

    int size = 1 << 20;                 /* room for a burst of frames */
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, sizeof(size));
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, sizeof(size));
    return fd;
}

static bool start_bridge(const char *interface_name, dispatch_queue_t queue)
{
    xpc_object_t desc = xpc_dictionary_create(NULL, NULL, 0);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block bool ok = false;

    xpc_dictionary_set_uint64(desc, vmnet_operation_mode_key, VMNET_BRIDGED_MODE);
    xpc_dictionary_set_string(desc, vmnet_shared_interface_name_key, interface_name);

    iface = vmnet_start_interface(desc, queue, ^(vmnet_return_t status, xpc_object_t params) {
        if (status == VMNET_SUCCESS) {
            ok = true;
            const char *mac = xpc_dictionary_get_string(params, vmnet_mac_address_key);
            if (mac) {
                /*
                 * The address the network gave us.  PowerEmu gives the
                 * guest's card the same one, so the network sees a single
                 * machine rather than two.  It goes in a file beside the
                 * socket because this program is started by way of the
                 * administrator prompt, which keeps no output.
                 */
                char path[1100];
                snprintf(path, sizeof(path), "%s.mac", helper_path);
                FILE *f = fopen(path, "w");
                if (f) {
                    fprintf(f, "%s\n", mac);
                    fclose(f);
                    if (owner_uid != (uid_t)-1) {
                        if (chown(path, owner_uid, (gid_t)-1) != 0) { /* the reader can live without it */ }
                    }
                }
                printf("mac %s\n", mac);
                fflush(stdout);
            }
        } else {
            fprintf(stderr, "poweremu-netd: could not bridge %s (vmnet status %d)\n",
                    interface_name, (int)status);
        }
        dispatch_semaphore_signal(done);
    });
    xpc_release(desc);
    if (!iface) {
        return false;
    }
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return ok;
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s <interface> <helper-socket> <emulator-socket> [uid]\n", argv[0]);
        return 2;
    }
    const char *interface_name = argv[1];
    helper_path = argv[2];
    const char *emulator_path = argv[3];
    uid_t owner = argc > 4 ? (uid_t)strtoul(argv[4], NULL, 10) : (uid_t)-1;
    owner_uid = owner;

    signal(SIGTERM, tidy_up);
    signal(SIGINT, tidy_up);
    signal(SIGPIPE, SIG_IGN);

    memset(&emulator, 0, sizeof(emulator));
    emulator.sun_family = AF_UNIX;
    if (strlen(emulator_path) >= sizeof(emulator.sun_path)) {
        fprintf(stderr, "poweremu-netd: the emulator's socket name is too long\n");
        return 1;
    }
    strncpy(emulator.sun_path, emulator_path, sizeof(emulator.sun_path) - 1);

    sock = open_socket(helper_path, owner);
    if (sock < 0) {
        return 1;
    }

    dispatch_queue_t queue = dispatch_queue_create("poweremu-netd", DISPATCH_QUEUE_SERIAL);
    if (!start_bridge(interface_name, queue)) {
        fprintf(stderr, "poweremu-netd: bridging needs to run as root\n");
        unlink(helper_path);            /* leave no socket behind */
        return 1;
    }
    vmnet_interface_set_event_callback(iface, VMNET_INTERFACE_PACKETS_AVAILABLE, queue,
                                       ^(interface_event_t event, xpc_object_t params) {
        (void)event; (void)params;
        forward_to_emulator();
    });

    printf("ready\n");
    fflush(stdout);

    /* The other direction, in this thread: whatever the guest sends. */
    uint8_t frame[MAX_FRAME];
    while (!stopping) {
        ssize_t n = recv(sock, frame, sizeof(frame), 0);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            fprintf(stderr, "poweremu-netd: reading from the emulator: %s\n", strerror(errno));
            break;
        }
        if (n > 0) {
            forward_to_network(frame, (size_t)n);
        }
    }
    tidy_up(0);
    return 0;
}
