/*
 * PowerEmu Clock - keeps the virtual Mac's clock with the host's.
 *
 * Runs as root (a LaunchDaemon installed by Install PowerEmu Tools when
 * asked).  Every 30 seconds it checks over a reused connection to 10.0.2.100:7701.
 * PowerEmu
 * answers each newline with the host's time as "SECONDS.MICROSECONDS\n".
 * An error over a second (the host slept, the emulator was paused) is
 * stepped at once; smaller ones are slewed with adjtime(2) so time never
 * runs backwards in small jumps.
 *
 *   PowerEmuClock        run as the daemon
 *   PowerEmuClock -n     print the offset once and change nothing
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <syslog.h>
#include <sys/time.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netinet/tcp.h>

#ifndef HOST_ADDR
#define HOST_ADDR "10.0.2.100"
#endif
#ifndef HOST_PORT
#define HOST_PORT 7701
#endif
#define INTERVAL  30

static double now(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec / 1e6;
}

/* Offset of the host's clock from ours, in seconds.  Connecting is slow
 * (the host starts a relay for each connection), so ask a few times over one
 * connection and trust the quickest exchange, whose midpoint is closest to
 * when the host read its clock.  0 on success, -1 on failure. */
static void disconnect_host(int *connection)
{
    if (*connection >= 0) close(*connection);
    *connection = -1;
}

static int connect_host(void)
{
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return -1;
    struct timeval to = { 3, 0 };
    int one = 1;
    /* A retained connection can disappear when the host app restarts.
     * Return a normal write error instead of terminating on SIGPIPE. */
    if (setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one) != 0 ||
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &to, sizeof to) != 0 ||
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &to, sizeof to) != 0) {
        close(s);
        return -1;
    }
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_len = sizeof a;
    a.sin_family = AF_INET;
    a.sin_port = htons(HOST_PORT);
    a.sin_addr.s_addr = inet_addr(HOST_ADDR);
    if (connect(s, (struct sockaddr *)&a, sizeof a) != 0) {
        close(s);
        return -1;
    }
    return s;
}

static int measure(int *connection, double *offset, double *rtt)
{
    if (*connection < 0) *connection = connect_host();
    if (*connection < 0) return -1;
    int s = *connection;
    int i, got = 0;
    for (i = 0; i < 5; i++) {
        char buf[64], *end;
        int n = 0;
        double t0 = now();
        ssize_t written;
        do { written = write(s, "\n", 1); } while (written < 0 && errno == EINTR);
        if (written != 1) goto failed;
        /* Read exactly one complete reply. Never reuse a stream containing
         * a partial/timed-out response, or the next check could use stale time. */
        while (n < (int)sizeof buf - 1) {
            ssize_t r = read(s, buf + n, sizeof buf - 1 - n);
            if (r < 0 && errno == EINTR) continue;
            if (r <= 0) goto failed;
            n += r;
            if (memchr(buf, '\n', n)) break;
        }
        double t1 = now();
        if (!n || buf[n - 1] != '\n') goto failed;
        buf[n] = 0;
        double host = strtod(buf, &end);
        if (!isfinite(host) || host < 1e9 || end != buf + n - 1) goto failed;
        if (!got || t1 - t0 < *rtt) {
            *rtt = t1 - t0;
            *offset = host + *rtt / 2 - t1;
            got = 1;
        }
    }
    return 0;
failed:
    disconnect_host(connection);
    return -1;
}

static void correct(double offset)
{
    if (offset > 1.0 || offset < -1.0) {
        struct timeval tv;
        double t = now() + offset;
        tv.tv_sec = (time_t)t;
        tv.tv_usec = (suseconds_t)((t - tv.tv_sec) * 1e6);
        if (settimeofday(&tv, NULL) == 0)
            syslog(LOG_NOTICE, "clock stepped by %.3f s to match PowerEmu", offset);
        else
            syslog(LOG_ERR, "settimeofday: %s", strerror(errno));
    } else if (offset > 0.05 || offset < -0.05) {
        struct timeval delta;
        delta.tv_sec = (time_t)offset;
        delta.tv_usec = (suseconds_t)((offset - delta.tv_sec) * 1e6);
        adjtime(&delta, NULL);
    }
}

int main(int argc, char **argv)
{
    double offset, rtt;
    int connection = -1;
    if (argc > 1 && strcmp(argv[1], "-n") == 0) {
        if (measure(&connection, &offset, &rtt) != 0) { fprintf(stderr, "PowerEmu did not answer\n"); return 1; }
        disconnect_host(&connection);
        printf("offset %+.3f s (round trip %.3f s)\n", offset, rtt);
        return 0;
    }
    openlog("PowerEmuClock", LOG_PID, LOG_DAEMON);
    for (;;) {
        /* A slow answer says little about the time; skip it. */
        if (measure(&connection, &offset, &rtt) == 0 && rtt < 0.2)
            correct(offset);
        sleep(INTERVAL);
    }
}
