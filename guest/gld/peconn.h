/*
 * Attach the renderer to the paravirtual GPU.  See peconn.c.
 *
 * Copyright (c) 2026 Spartan0285
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#ifndef PECONN_H
#define PECONN_H

#include "pering.h"
#include "../gpu/src/PEGpuShared.h"

typedef struct PEConn {
    unsigned int conn;          /* io_connect_t, kept opaque to callers */
    void *ctrl;                 /* the trapping control page */
    void *shared;               /* ring + data; protocol offset zero */
    unsigned int features;      /* PE_GPU_FEAT_* the host advertises */
    PERing ring;
} PEConn;

#define PE_CONN_OK           0
#define PE_CONN_NO_DEVICE   -1
#define PE_CONN_NO_MAP      -2
#define PE_CONN_BAD_VERSION -3

int pe_conn_open(PEConn *c);
void pe_conn_close(PEConn *c);
const char *pe_conn_strerror(int rc);

void pe_conn_enable(PEConn *c, int on);
unsigned int pe_conn_fence(PEConn *c);
unsigned int pe_conn_error(PEConn *c);
void pe_conn_clear_error(PEConn *c);
int pe_conn_wait(PEConn *c, unsigned int fence, unsigned int spins);

#endif /* PECONN_H */
