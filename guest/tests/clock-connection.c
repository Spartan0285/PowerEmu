/* Exercise the production clock protocol without changing system time. */
#include <assert.h>
#include <pthread.h>
static unsigned short test_port;
#define HOST_PORT test_port
#define HOST_ADDR "127.0.0.1"
#define main clock_daemon_main
#include "../src/PEClock.c"
#undef main

static int listener, accepted;
static void *server(void *unused)
{
    int session;
    for (session = 0; session < 6; session++) {
        int c = accept(listener, NULL, NULL);
        assert(c >= 0);
        accepted++;
        int count = session == 0 ? 10 : 5, i;
        for (i = 0; i < count; i++) {
            char request, reply[64];
            assert(read(c, &request, 1) == 1 && request == '\n');
            if (session == 1) {
                assert(write(c, "not-a-time\n", 11) == 11);
                break;
            }
            if (session == 2 || session == 4) {
                assert(write(c, "1700000000.", 11) == 11);
                if (session == 4) sleep(4); /* incomplete response times out */
                break;
            }
            if (session == 3) {
                assert(write(c, "nan\n", 4) == 4);
                break;
            }
            struct timeval tv;
            gettimeofday(&tv, NULL);
            int n = snprintf(reply, sizeof reply, "%ld.%06d\n", tv.tv_sec, tv.tv_usec);
            /* A split response verifies the framing, not a one-read assumption. */
            assert(write(c, reply, n / 2) == n / 2);
            usleep(1000);
            assert(write(c, reply + n / 2, n - n / 2) == n - n / 2);
        }
        close(c);
    }
    return NULL;
}

int main(void)
{
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_len = sizeof a;
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    listener = socket(AF_INET, SOCK_STREAM, 0);
    assert(listener >= 0 && bind(listener, (struct sockaddr *)&a, sizeof a) == 0);
    socklen_t len = sizeof a;
    assert(getsockname(listener, (struct sockaddr *)&a, &len) == 0);
    test_port = ntohs(a.sin_port);
    assert(listen(listener, 4) == 0);
    pthread_t thread;
    assert(pthread_create(&thread, NULL, server, NULL) == 0);
    int connection = -1;
    double offset, rtt;
    assert(measure(&connection, &offset, &rtt) == 0);
    int first = connection;
    assert(fabs(offset) < .05 && rtt >= 0 && rtt < .2);
    assert(measure(&connection, &offset, &rtt) == 0 && connection == first);
    /* Peer closure discards the stream rather than accepting partial time. */
    assert(measure(&connection, &offset, &rtt) == -1 && connection == -1);
    /* A malformed reply cannot become a clock correction. */
    assert(measure(&connection, &offset, &rtt) == -1 && connection == -1);
    assert(measure(&connection, &offset, &rtt) == -1 && connection == -1);
    assert(measure(&connection, &offset, &rtt) == -1 && connection == -1);
    assert(measure(&connection, &offset, &rtt) == -1 && connection == -1);
    assert(measure(&connection, &offset, &rtt) == 0);
    assert(isfinite(offset) && rtt >= 0);
    disconnect_host(&connection);
    assert(connection == -1);
    pthread_join(thread, NULL);
    assert(accepted == 6);
    close(listener);
    puts("clock connection reuse, fragmented replies, EOF, malformed/partial/nonfinite replies, timeout and recovery pass");
    return 0;
}
