/* Build on macOS and run locally; this exercises only loopback sockets. */
#include <stdio.h>
#include <string.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/time.h>
#include <unistd.h>
#include "../src/PEBoundedConnect.h"

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s errno=%d\n", __LINE__, #x, errno); return 1; } } while (0)

static volatile sig_atomic_t alarmCount;
static uint64_t timeoutElapsedUsec;
static sig_atomic_t timeoutInterrupts;

static void interruptConnectWait(int signo)
{
    (void)signo;
    if (++alarmCount >= 40) alarm(0);
}

int main(void)
{
    uint64_t start = 1000000;
    uint64_t converted = 0;
    mach_timebase_info_data_t scale = {1, 1};
    CHECK(PEBoundedConnectTicksToUsec(KERN_SUCCESS, 1234, scale, &converted) == 0);
    CHECK(converted == 1);
    CHECK(PEBoundedConnectTicksToUsec(KERN_FAILURE, 1234, scale, &converted) < 0);
    CHECK(errno == EIO);
    CHECK(PEBoundedConnectRemainingUsec(start, start, 5000) == 5000);
    CHECK(PEBoundedConnectRemainingUsec(start, start + 4999, 5000) == 1);
    CHECK(PEBoundedConnectRemainingUsec(start, start + 5000, 5000) == 0);
    CHECK(PEBoundedConnectRemainingUsec(start, start + 9000, 5000) == 0);

    {
        int listener = socket(AF_INET, SOCK_STREAM, 0), client, flags;
        struct sockaddr_in address;
        socklen_t size = sizeof address;
        CHECK(listener >= 0);
        memset(&address, 0, sizeof address);
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        CHECK(bind(listener, (struct sockaddr *)&address, sizeof address) == 0);
        CHECK(listen(listener, 1) == 0);
        CHECK(getsockname(listener, (struct sockaddr *)&address, &size) == 0);
        client = socket(AF_INET, SOCK_STREAM, 0);
        CHECK(client >= 0);
        flags = fcntl(client, F_GETFL, 0);
        CHECK(flags >= 0 && !(flags & O_NONBLOCK));
        CHECK(fcntl(client, F_SETFL, flags | O_NONBLOCK) == 0);
        CHECK(PEBoundedConnect(client, (struct sockaddr *)&address,
                               sizeof address, 1000) == 0);
        CHECK(fcntl(client, F_GETFL, 0) == (flags | O_NONBLOCK));
        {
            int accepted = accept(listener, NULL, NULL);
            CHECK(accepted >= 0);
            close(accepted);
        }
        close(client); close(listener);
    }

    {
        int reservation = socket(AF_INET, SOCK_STREAM, 0), client, result, flags;
        struct sockaddr_in address;
        socklen_t size = sizeof address;
        struct sigaction action, oldAction;
        struct itimerval timer, oldTimer, stoppedTimer;
        uint64_t began, ended;
        CHECK(reservation >= 0);
        memset(&address, 0, sizeof address);
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        CHECK(bind(reservation, (struct sockaddr *)&address, sizeof address) == 0);
        CHECK(getsockname(reservation, (struct sockaddr *)&address, &size) == 0);
        client = socket(AF_INET, SOCK_STREAM, 0);
        CHECK(client >= 0);
        flags = fcntl(client, F_GETFL, 0);
        CHECK(flags >= 0 && !(flags & O_NONBLOCK));
        CHECK(fcntl(client, F_SETFL, flags | O_NONBLOCK) == 0);
        memset(&action, 0, sizeof action);
        action.sa_handler = interruptConnectWait;
        sigemptyset(&action.sa_mask);
        CHECK(sigaction(SIGALRM, &action, &oldAction) == 0);
        memset(&timer, 0, sizeof timer);
        CHECK(setitimer(ITIMER_REAL, &timer, &oldTimer) == 0);
        memset(&timer, 0, sizeof timer);
        timer.it_value.tv_usec = 3000;
        timer.it_interval.tv_usec = 3000;
        alarmCount = 0;
        CHECK(setitimer(ITIMER_REAL, &timer, NULL) == 0);
        CHECK(PEBoundedConnectNowUsec(&began) == 0);
        result = PEBoundedConnect(client, (struct sockaddr *)&address,
                                  sizeof address, 250);
        CHECK(PEBoundedConnectNowUsec(&ended) == 0);
        memset(&stoppedTimer, 0, sizeof stoppedTimer);
        CHECK(setitimer(ITIMER_REAL, &stoppedTimer, NULL) == 0);
        CHECK(sigaction(SIGALRM, &oldAction, NULL) == 0);
        CHECK(setitimer(ITIMER_REAL, &oldTimer, NULL) == 0);
        /* Darwin keeps a bound-but-not-listening port silent; this held
         * reservation deterministically exercises the deadline path. */
        CHECK(result < 0 && errno == ETIMEDOUT);
        CHECK(alarmCount >= 10);
        CHECK(ended >= began && ended - began >= 200000 && ended - began < 500000);
        timeoutElapsedUsec = ended - began;
        timeoutInterrupts = alarmCount;
        CHECK(fcntl(client, F_GETFL, 0) == (flags | O_NONBLOCK));
        close(client); close(reservation);
    }

    /* A failed descriptor is discarded by the caller; a fresh socket can
     * still connect successfully, with its own original flags preserved. */
    {
        int listener = socket(AF_INET, SOCK_STREAM, 0), client, flags;
        struct sockaddr_in address;
        socklen_t size = sizeof address;
        CHECK(listener >= 0);
        memset(&address, 0, sizeof address);
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        CHECK(bind(listener, (struct sockaddr *)&address, sizeof address) == 0);
        CHECK(listen(listener, 1) == 0);
        CHECK(getsockname(listener, (struct sockaddr *)&address, &size) == 0);
        client = socket(AF_INET, SOCK_STREAM, 0);
        CHECK(client >= 0);
        flags = fcntl(client, F_GETFL, 0);
        CHECK(flags >= 0 && !(flags & O_NONBLOCK));
        CHECK(PEBoundedConnect(client, (struct sockaddr *)&address,
                               sizeof address, 1000) == 0);
        CHECK(fcntl(client, F_GETFL, 0) == flags);
        {
            int accepted = accept(listener, NULL, NULL);
            CHECK(accepted >= 0);
            close(accepted);
        }
        close(client); close(listener);
    }

    {
        int reservation = socket(AF_INET, SOCK_STREAM, 0), client, result, flags;
        struct sockaddr_in address;
        socklen_t size = sizeof address;
        CHECK(reservation >= 0);
        memset(&address, 0, sizeof address);
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        CHECK(bind(reservation, (struct sockaddr *)&address, sizeof address) == 0);
        CHECK(getsockname(reservation, (struct sockaddr *)&address, &size) == 0);
        CHECK(listen(reservation, 1) == 0);
        close(reservation);
        client = socket(AF_INET, SOCK_STREAM, 0);
        CHECK(client >= 0);
        flags = fcntl(client, F_GETFL, 0);
        CHECK(flags >= 0 && !(flags & O_NONBLOCK));
        result = PEBoundedConnect(client, (struct sockaddr *)&address,
                                  sizeof address, 1000);
        CHECK(result < 0 && errno == ECONNREFUSED);
        CHECK(fcntl(client, F_GETFL, 0) == flags);
        close(client);
    }
    printf("PASS deadline gates, timeout=%llu us under %d EINTRs, loopback success/refusal, flag preservation, and fresh-socket reuse\n",
           (unsigned long long)timeoutElapsedUsec, (int)timeoutInterrupts);
    return 0;
}
