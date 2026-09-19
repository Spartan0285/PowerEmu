/*
 * PowerEmu Clock - keeps the virtual Mac's clock with the host's.
 *
 * Runs as root (a LaunchDaemon installed by Install PowerEmu Tools when
 * asked).  Every 30 seconds it connects to 10.0.2.100:7701, where PowerEmu
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
#include <syslog.h>
#include <sys/time.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netinet/tcp.h>

#define HOST_ADDR "10.0.2.100"
#define HOST_PORT 7701
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
static int measure(double *offset, double *rtt)
{
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return -1;
    struct timeval to = { 3, 0 };
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &to, sizeof to);
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &to, sizeof to);
    int one = 1;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_len = sizeof a;
    a.sin_family = AF_INET;
    a.sin_port = htons(HOST_PORT);
    a.sin_addr.s_addr = inet_addr(HOST_ADDR);
    if (connect(s, (struct sockaddr *)&a, sizeof a) != 0) { close(s); return -1; }

    int i, got = 0;
    for (i = 0; i < 5; i++) {
        char buf[64];
        int n = 0, r;
        double t0 = now();
        if (write(s, "\n", 1) != 1) break;
        while (n < (int)sizeof buf - 1 && (r = read(s, buf + n, sizeof buf - 1 - n)) > 0) {
            n += r;
            if (memchr(buf, '\n', n)) break;
        }
        double t1 = now();
        if (n <= 0) break;
        buf[n] = 0;
        double host = strtod(buf, NULL);
        if (host < 1e9) break;
        if (!got || t1 - t0 < *rtt) {
            *rtt = t1 - t0;
            *offset = host + *rtt / 2 - t1;
            got = 1;
        }
    }
    close(s);
    return got ? 0 : -1;
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
    if (argc > 1 && strcmp(argv[1], "-n") == 0) {
        if (measure(&offset, &rtt) != 0) { fprintf(stderr, "PowerEmu did not answer\n"); return 1; }
        printf("offset %+.3f s (round trip %.3f s)\n", offset, rtt);
        return 0;
    }
    openlog("PowerEmuClock", LOG_PID, LOG_DAEMON);
    for (;;) {
        /* A slow answer says little about the time; skip it. */
        if (measure(&offset, &rtt) == 0 && rtt < 0.2)
            correct(offset);
        sleep(INTERVAL);
    }
}
