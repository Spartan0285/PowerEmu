/*
 * A small, deliberate OpenGL workload, to find out what GLEngine asks of a
 * renderer during real rendering.
 *
 * The point is not to draw anything interesting.  It is that every GL call
 * here is one we will have to support, made in isolation and announced in
 * the renderer's own log, so the gld* calls that follow each marker can be
 * attributed to it.  A trace from a whole application says which entry
 * points are used; this says which entry points each *kind of work* uses,
 * which is what tells us the order to implement them in.
 *
 * It renders off-screen through CGL, so it needs no window server and can
 * be run over ssh.
 *
 * Copyright (c) 2026 Spartan0285
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include <OpenGL/OpenGL.h>
#include <OpenGL/gl.h>
#include <OpenGL/glext.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define W 256
#define H 256

static FILE *log_file;

/*
 * Markers go into the renderer's own log, not stdout: interleaved with the
 * gld* calls they cause, in one file, in order.  Two streams would have to
 * be correlated by timestamp, and these calls are far too fast for that.
 */
static void mark(const char *what)
{
    if (log_file) {
        fprintf(log_file, "\n== %s\n", what);
        fflush(log_file);
    }
    printf("== %s\n", what);
    fflush(stdout);
}

static void check(const char *what)
{
    GLenum e = glGetError();

    if (e != GL_NO_ERROR) {
        printf("   GL error 0x%04x after %s\n", e, what);
        if (log_file) {
            fprintf(log_file, "   GL error 0x%04x after %s\n", e, what);
        }
    }
}

int main(void)
{
    /*
     * Room for an optional kCGLPFARendererID pair: without it CGL is free to
     * pick whichever renderer it likes best, which on this workload is
     * Apple's software one, and then nothing is learned about ours.
     */
    CGLPixelFormatAttribute attrs[12];
    int na = 0;
    const char *want = getenv("PEGL_WANT_ID");
    CGLPixelFormatObj pix = NULL;
    CGLContextObj ctx = NULL;
    GLint npix = 0;
    CGLError err;
    void *buf;
    GLuint tex = 0;
    unsigned int *texels;
    int i;

    const char *lp = getenv("PEGLD_LOG");
    if (lp) {
        log_file = fopen(lp, "a");
    }

    buf = calloc(1, W * H * 4);
    texels = malloc(64 * 64 * 4);
    if (!buf || !texels) {
        return 1;
    }
    for (i = 0; i < 64 * 64; i++) {
        texels[i] = 0xFF000000u | (unsigned int)(i * 7);
    }

    attrs[na++] = kCGLPFAOffScreen;
    attrs[na++] = kCGLPFAColorSize;
    attrs[na++] = (CGLPixelFormatAttribute)32;
    attrs[na++] = kCGLPFADepthSize;
    attrs[na++] = (CGLPixelFormatAttribute)16;
    if (want) {
        attrs[na++] = kCGLPFARendererID;
        attrs[na++] = (CGLPixelFormatAttribute)strtoul(want, NULL, 0);
        printf("   asking for renderer ID %s\n", want);
    }
    attrs[na++] = (CGLPixelFormatAttribute)0;

    mark("CGLChoosePixelFormat");
    err = CGLChoosePixelFormat(attrs, &pix, &npix);
    if (err || !pix) {
        printf("CGLChoosePixelFormat failed: %d (%s)\n", err,
               CGLErrorString(err));
        return 1;
    }
    printf("   %d pixel format(s)\n", (int)npix);

    mark("CGLCreateContext");
    err = CGLCreateContext(pix, NULL, &ctx);
    if (err || !ctx) {
        printf("CGLCreateContext failed: %d (%s)\n", err, CGLErrorString(err));
        return 1;
    }

    mark("CGLSetCurrentContext + CGLSetOffScreen");
    CGLSetCurrentContext(ctx);
    err = CGLSetOffScreen(ctx, W, H, W * 4, buf);
    if (err) {
        printf("CGLSetOffScreen failed: %d (%s)\n", err, CGLErrorString(err));
        return 1;
    }

    /* Which renderer actually got picked -- the whole trace depends on it. */
    printf("   GL_RENDERER: %s\n", (const char *)glGetString(GL_RENDERER));
    printf("   GL_VENDOR:   %s\n", (const char *)glGetString(GL_VENDOR));
    printf("   GL_VERSION:  %s\n", (const char *)glGetString(GL_VERSION));
    if (log_file) {
        fprintf(log_file, "   renderer: %s / %s\n",
                (const char *)glGetString(GL_VENDOR),
                (const char *)glGetString(GL_RENDERER));
    }

    mark("viewport + clear");
    glViewport(0, 0, W, H);
    glClearColor(0.1f, 0.2f, 0.3f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    check("clear");

    mark("matrix setup");
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glOrtho(0, W, 0, H, -1, 1);
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();
    check("matrices");

    mark("immediate-mode triangle");
    glBegin(GL_TRIANGLES);
    glColor4f(1.0f, 0.0f, 0.0f, 1.0f); glVertex3f(10, 10, 0);
    glColor4f(0.0f, 1.0f, 0.0f, 1.0f); glVertex3f(200, 20, 0);
    glColor4f(0.0f, 0.0f, 1.0f, 1.0f); glVertex3f(100, 200, 0);
    glEnd();
    check("immediate triangle");

    mark("texture upload");
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 64, 64, 0,
                 GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, texels);
    check("texture upload");

    mark("textured quad");
    glEnable(GL_TEXTURE_2D);
    glBegin(GL_QUADS);
    glTexCoord2f(0, 0); glVertex3f(10, 10, 0);
    glTexCoord2f(1, 0); glVertex3f(120, 10, 0);
    glTexCoord2f(1, 1); glVertex3f(120, 120, 0);
    glTexCoord2f(0, 1); glVertex3f(10, 120, 0);
    glEnd();
    glDisable(GL_TEXTURE_2D);
    check("textured quad");

    mark("blending + depth test");
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glEnable(GL_DEPTH_TEST);
    glBegin(GL_TRIANGLES);
    glColor4f(1.0f, 1.0f, 0.0f, 0.5f); glVertex3f(50, 50, 0);
    glColor4f(1.0f, 1.0f, 0.0f, 0.5f); glVertex3f(220, 60, 0);
    glColor4f(1.0f, 1.0f, 0.0f, 0.5f); glVertex3f(140, 230, 0);
    glEnd();
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_BLEND);
    check("blended triangle");

    mark("vertex arrays");
    {
        static const GLfloat verts[] = {
            20, 20, 0,  90, 25, 0,  55, 95, 0,
            120, 20, 0, 190, 25, 0, 155, 95, 0
        };
        static const GLubyte cols[] = {
            255,0,0,255,  0,255,0,255,  0,0,255,255,
            255,255,0,255, 0,255,255,255, 255,0,255,255
        };
        glEnableClientState(GL_VERTEX_ARRAY);
        glEnableClientState(GL_COLOR_ARRAY);
        glVertexPointer(3, GL_FLOAT, 0, verts);
        glColorPointer(4, GL_UNSIGNED_BYTE, 0, cols);
        glDrawArrays(GL_TRIANGLES, 0, 6);
        glDisableClientState(GL_COLOR_ARRAY);
        glDisableClientState(GL_VERTEX_ARRAY);
    }
    check("vertex arrays");

    mark("glFinish");
    glFinish();
    check("finish");

    mark("readback");
    {
        unsigned int *p = buf;
        int nonzero = 0;

        glReadPixels(0, 0, W, H, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, buf);
        for (i = 0; i < W * H; i++) {
            if (p[i]) {
                nonzero++;
            }
        }
        printf("   %d of %d pixels non-zero\n", nonzero, W * H);
        if (log_file) {
            fprintf(log_file, "   readback: %d of %d non-zero\n",
                    nonzero, W * H);
        }
    }

    mark("teardown");
    glDeleteTextures(1, &tex);
    CGLSetCurrentContext(NULL);
    CGLClearDrawable(ctx);
    CGLDestroyContext(ctx);
    CGLDestroyPixelFormat(pix);

    mark("done");
    if (log_file) {
        fclose(log_file);
    }
    free(texels);
    free(buf);
    return 0;
}
