/*
 * PEAudioProbe -- does Mac OS 9 see poweremu-audio, and can it read it?
 *
 * The first milestone of the paravirtual sound work, deliberately smaller
 * than the sound component it leads to.  It answers three questions that
 * all have to be yes before a component is worth writing:
 *
 *   1. is the device-tree node PowerEmu publishes visible in the Name
 *      Registry?
 *   2. does its AAPL,address property come back as the address the
 *      emulator mapped the device at?
 *   3. does a load from that address actually reach the device?
 *
 * The third is checkable from outside: PowerEmu's device logs every
 * register access when PEAU_TRACE=1 is set in its environment, so a run
 * that prints the right values *and* shows up in that log has proved the
 * whole chain.
 *
 * Build: CodeWarrior, a C console application (SIOUX), PowerPC.  Link
 * against InterfaceLib, StdCLib, MSL C, and NameRegistryLib.
 *
 * Expect:
 *     AAPL,address = 0x80017000
 *     ID           = 0x50454155 'PEAU'
 *     VERSION      = 1
 *     CAPS         = 0x00100001
 *
 * If the ID reads as a repeated byte pattern (0xa5a5a5a5 and the like),
 * the load is not reaching the device: the address is unmapped rather
 * than wrong.  Turn virtual memory off in the Memory control panel and
 * try again -- with VM on, this address is not the one the hardware is at.
 */

#include <stdio.h>
#include <string.h>
#include <MacTypes.h>

/*
 * The Name Registry, declared here rather than included.
 *
 * Retro68's multiversal interfaces do not cover it -- there is no
 * NameRegistry.h and no RegEntryID in them -- but the import library is
 * there, so the symbols link.  Retro68's own NDRV sample does the same
 * thing for the driver interfaces, for the same reason.  Layouts are from
 * Apple's Universal Interfaces 3.4.1.
 */
enum { kRegIterContinue = 1, kRegIterDescendants = 2 };
enum { nrNotFoundErr = -2545 };

typedef SInt32 OSStatus;
typedef struct RegEntryID { UInt32 contents[4]; } RegEntryID;
typedef struct OpaqueRegEntryIter *RegEntryIter;
typedef UInt32 RegEntryIterationOp;
typedef UInt32 RegPropertyValueSize;
typedef char   RegEntryNameBuf[48];
typedef char   RegCStrPathName;
typedef UInt32 RegPathNameSize;

extern OSStatus RegistryEntryIterateCreate(RegEntryIter *cookie);
extern OSStatus RegistryEntryIterateDispose(RegEntryIter *cookie);
extern OSStatus RegistryEntryIterate(RegEntryIter *cookie,
                                     RegEntryIterationOp relationship,
                                     RegEntryID *foundEntry, Boolean *done);
extern OSStatus RegistryEntryIDDispose(RegEntryID *id);
extern OSStatus RegistryCStrEntryToPath(const RegEntryID *entryID,
                                        RegCStrPathName *pathName,
                                        RegPathNameSize pathSize);
extern OSStatus RegistryPropertyGet(const RegEntryID *entryID,
                                    const char *propertyName,
                                    void *propertyValue,
                                    RegPropertyValueSize *propertySize);

#define PEAU_ID         0x00
#define PEAU_VERSION    0x04
#define PEAU_CAPS       0x08

#define PEAU_MAGIC      0x50454155UL        /* 'PEAU' */

static OSStatus FindDevice(RegEntryID *found)
{
    /*
     * Look the node up by name rather than by walking the tree: the Name
     * Registry indexes every entry, and the emulator always publishes this
     * one under mac-io with the same name.
     */
    RegEntryIter     iter;
    RegEntryID       entry;
    Boolean          done = false;
    OSStatus         err;
    char             name[512];

    err = RegistryEntryIterateCreate(&iter);
    if (err != noErr) {
        return err;
    }

    for (;;) {
        err = RegistryEntryIterate(&iter, kRegIterContinue, &entry, &done);
        if (err != noErr || done) {
            break;
        }
        if (RegistryCStrEntryToPath(&entry, name, sizeof(name)) == noErr) {
            if (strstr(name, "poweremu-audio") != NULL) {
                printf("  found at: %s\n", name);
                *found = entry;
                RegistryEntryIterateDispose(&iter);
                return noErr;
            }
        }
        RegistryEntryIDDispose(&entry);
    }

    RegistryEntryIterateDispose(&iter);
    return (err == noErr) ? (OSStatus)nrNotFoundErr : err;
}

int main(void)
{
    RegEntryID          entry;
    RegPropertyValueSize size;
    UInt32              base = 0;
    OSStatus            err;
    volatile UInt32    *regs;

    printf("PEAudioProbe\n\n");

    printf("1. looking for poweremu-audio in the Name Registry\n");
    err = FindDevice(&entry);
    if (err != noErr) {
        printf("  NOT FOUND (%d)\n", (int)err);
        printf("\n  The node is published by PowerEmu's Open Firmware\n");
        printf("  boot-command, and only for a classic guest.\n");
        return 1;
    }

    printf("\n2. reading its AAPL,address property\n");
    size = sizeof(base);
    err = RegistryPropertyGet(&entry, "AAPL,address", &base, &size);
    if (err != noErr) {
        printf("  FAILED (%d)\n", (int)err);
        return 1;
    }
    printf("  AAPL,address = 0x%08lX\n", (unsigned long)base);

    printf("\n3. reading the device's registers\n");
    regs = (volatile UInt32 *)base;
    printf("  ID      = 0x%08lX", (unsigned long)regs[PEAU_ID / 4]);
    if (regs[PEAU_ID / 4] == PEAU_MAGIC) {
        printf("  'PEAU'  <- the device answered\n");
    } else {
        printf("  (expected 0x%08lX)\n", (unsigned long)PEAU_MAGIC);
    }
    printf("  VERSION = 0x%08lX\n", (unsigned long)regs[PEAU_VERSION / 4]);
    printf("  CAPS    = 0x%08lX\n", (unsigned long)regs[PEAU_CAPS / 4]);

    printf("\nDone.  Press return.\n");
    getchar();
    return 0;
}
