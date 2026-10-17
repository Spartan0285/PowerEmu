/* Bounded nonblocking connect for the 10.4 guest agent. */
#ifndef PE_BOUNDED_CONNECT_H
#define PE_BOUNDED_CONNECT_H

#include <sys/types.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <sys/time.h>
#include <mach/mach_time.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>

static int PEBoundedConnectTicksToUsec(kern_return_t status, uint64_t ticks,
                                      mach_timebase_info_data_t scale,
                                      uint64_t *usec)
{
    uint64_t whole, rem;
    if (status != KERN_SUCCESS || scale.denom == 0 || !usec) {
        errno = EIO;
        return -1;
    }
    whole = ticks / scale.denom;
    rem = ticks % scale.denom;
    *usec = (whole * scale.numer + (rem * scale.numer) / scale.denom) / 1000;
    return 0;
}

static int PEBoundedConnectNowUsec(uint64_t *usec)
{
    mach_timebase_info_data_t scale;
    kern_return_t status = mach_timebase_info(&scale);
    if (status != KERN_SUCCESS) {
        errno = EIO;
        return -1;
    }
    return PEBoundedConnectTicksToUsec(status, mach_absolute_time(), scale, usec);
}

static uint64_t PEBoundedConnectRemainingUsec(uint64_t began, uint64_t now,
                                               uint64_t budget)
{
    uint64_t elapsed = now >= began ? now - began : budget;
    return elapsed >= budget ? 0 : budget - elapsed;
}

static int PEBoundedConnect(int fd, const struct sockaddr *address,
                            socklen_t length, unsigned int timeoutMS)
{
    int oldFlags, result, savedError;
    uint64_t began, now, remaining;
    oldFlags = fcntl(fd, F_GETFL, 0);
    if (oldFlags < 0) return -1;
    if (fd >= FD_SETSIZE) { errno = EINVAL; return -1; }
    if (fcntl(fd, F_SETFL, oldFlags | O_NONBLOCK) < 0) return -1;
    if (PEBoundedConnectNowUsec(&began) < 0) goto fail;
    result = connect(fd, address, length);
    if (result == 0) goto restore;
    if (errno != EINPROGRESS && errno != EALREADY && errno != EWOULDBLOCK && errno != EAGAIN && errno != EINTR)
        goto fail;

    for (;;) {
        fd_set writeSet, errorSet;
        struct timeval wait;
        int selected, socketError = 0;
        socklen_t errorLength = sizeof socketError;
        if (PEBoundedConnectNowUsec(&now) < 0) goto fail;
        remaining = PEBoundedConnectRemainingUsec(began, now,
            (uint64_t)timeoutMS * 1000);
        if (remaining == 0) { errno = ETIMEDOUT; goto fail; }
        FD_ZERO(&writeSet); FD_ZERO(&errorSet);
        FD_SET(fd, &writeSet); FD_SET(fd, &errorSet);
        wait.tv_sec = (long)(remaining / 1000000);
        wait.tv_usec = (long)(remaining % 1000000);
        selected = select(fd + 1, NULL, &writeSet, &errorSet, &wait);
        if (selected < 0) {
            if (errno == EINTR) continue;
            goto fail;
        }
        if (selected == 0) { errno = ETIMEDOUT; goto fail; }
        if (PEBoundedConnectNowUsec(&now) < 0) goto fail;
        if (PEBoundedConnectRemainingUsec(began, now,
                (uint64_t)timeoutMS * 1000) == 0) { errno = ETIMEDOUT; goto fail; }
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) < 0) goto fail;
        if (socketError != 0) { errno = socketError; goto fail; }
        goto restore;
    }

restore:
    if (fcntl(fd, F_SETFL, oldFlags) < 0) goto fail;
    return 0;
fail:
    savedError = errno;
    (void)fcntl(fd, F_SETFL, oldFlags);
    errno = savedError;
    return -1;
}

#endif
