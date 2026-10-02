/*
 * PEDriverProbe -- is .PEAudio in the unit table, and will it open?
 *
 * The driver is installed on the device-tree node -- dumping the node from
 * Open Firmware shows driver,AAPL,MacOS,PowerPC with a valid PEF in it --
 * and the device still sees nothing at all.  A write hardcoded to the BAR
 * address as the first statement of Initialize, depending on no lookup of
 * any kind, never lands either, so DoDriverIO is not being called.
 *
 * That leaves two possibilities which look identical from the host side:
 * Mac OS never brought the property into the Name Registry, or it did and
 * then declined to load or open the driver.  Three things tell them apart,
 * and this asks all three:
 *
 *   1. is driver,AAPL,MacOS,PowerPC on the node in the *Name Registry*?
 *      Apple: "All drivers with a driver,AAPL,MacOS,PowerPC property are
 *      brought into the Mac OS Name Registry."  If it is missing here but
 *      present in Open Firmware, the Trampoline dropped it.
 *   2. is there a driver-ref property?  Apple's boot sequence creates one
 *      "if a PCI ROM device driver is marked as kDriverIsOpenedUponLoad"
 *      -- so its absence says the open step did not happen for us.
 *   3. does OpenDriver(".PEAudio") succeed?  If the driver is in the unit
 *      table this opens it and Initialize runs, which the host trace will
 *      show.  If it is not, the error says so.
 *
 * Run with PEAU_TRACE=1 in the emulator's environment: any register access
 * this provokes is visible from outside, so the answer does not depend on
 * trusting what the guest prints.
 *
 * Build: see BUILDING.md, same as PEAudioProbe.
 */

#include <stdio.h>
#include <string.h>
#include <MacTypes.h>

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

typedef struct OpaqueRegPropertyIter *RegPropertyIter;
typedef char RegPropertyNameBuf[33];

extern OSStatus RegistryPropertyIterateCreate(const RegEntryID *entry,
                                              RegPropertyIter *cookie);
extern OSStatus RegistryPropertyIterateDispose(RegPropertyIter *cookie);
extern OSStatus RegistryPropertyIterate(RegPropertyIter *cookie,
                                        RegPropertyNameBuf foundProperty,
                                        Boolean *done);
extern OSStatus RegistryPropertyGetSize(const RegEntryID *entryID,
                                        const char *propertyName,
                                        RegPropertyValueSize *propertySize);


extern OSErr OpenDriver(ConstStr255Param name, short *drvrRefNum);
extern OSErr CloseDriver(short drvrRefNum);

/*
 * The Driver Loader, declared here for the same reason as the Name
 * Registry: Retro68's multiversal headers do not cover it, but
 * DriverLoaderLib has the symbols.  Layouts from Universal Interfaces
 * 3.4.1, Devices.h.
 *
 * These are the steps Mac OS performs for us at startup when a node's
 * driver is marked kDriverIsLoadedUponDiscovery | kDriverIsOpenedUponLoad.
 * Calling them by hand says which of those steps fails, and with what
 * error -- the boot path reports nothing at all.
 */
typedef void *CFragConnectionID;
typedef void *DriverEntryPointPtr;
typedef void *DriverDescriptionPtr;
typedef short DriverRefNum;
typedef UInt32 UnitNumber;

extern OSErr GetDriverForDevice(RegEntryID *device,
                                CFragConnectionID *fragmentConnID,
                                DriverEntryPointPtr *fragmentMain,
                                DriverDescriptionPtr *driverDesc);
extern OSErr InstallDriverForDevice(RegEntryID *device,
                                    UnitNumber beginningUnit,
                                    UnitNumber endingUnit,
                                    DriverRefNum *refNum);
extern OSErr OpenInstalledDriver(DriverRefNum refNum, SInt8 ioPermission);

#define PEAU_ID         0x00
#define PEAU_MAGIC      0x50454155UL        /* 'PEAU' */

#define NODE_NAME       "pci1b36,5045"
#define DRIVER_PROP     "driver,AAPL,MacOS,PowerPC"

static OSStatus FindDevice(RegEntryID *found, char *pathOut, int pathMax)
{
    RegEntryIter iter;
    RegEntryID   entry;
    Boolean      done = false;
    OSStatus     err;
    char         name[512];

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
            if (strstr(name, NODE_NAME) != NULL) {
                strncpy(pathOut, name, pathMax - 1);
                pathOut[pathMax - 1] = 0;
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
    RegEntryID           entry;
    RegPropertyValueSize size;
    OSStatus             err;
    char                 path[512];
    short                refNum = 0;
    UInt32               assigned[10];
    volatile UInt32     *regs;

    printf("PEDriverProbe\n\n");

    printf("1. the node in the Name Registry\n");
    err = FindDevice(&entry, path, sizeof(path));
    if (err != noErr) {
        printf("   NOT FOUND (%d) -- no node named %s\n", (int)err, NODE_NAME);
        printf("\nDone.  Press return.\n");
        getchar();
        return 1;
    }
    printf("   %s\n", path);

    printf("\n2. every property on it\n");
    {
        RegPropertyIter    pit;
        RegPropertyNameBuf pname;
        Boolean            pdone = false;

        if (RegistryPropertyIterateCreate(&entry, &pit) == noErr) {
            for (;;) {
                RegPropertyValueSize psize = 0;

                if (RegistryPropertyIterate(&pit, pname, &pdone) != noErr || pdone) {
                    break;
                }
                if (RegistryPropertyGetSize(&entry, pname, &psize) != noErr) {
                    psize = 0;
                }
                printf("   %-28s %lu bytes\n", pname, (unsigned long)psize);
            }
            RegistryPropertyIterateDispose(&pit);
        }
    }

    /* The two that decide it. */
    printf("\n3. the two properties that matter\n");
    size = 0;
    err = RegistryPropertyGetSize(&entry, DRIVER_PROP, &size);
    if (err == noErr) {
        printf("   %-28s present, %lu bytes\n", DRIVER_PROP, (unsigned long)size);
    } else {
        printf("   %-28s ABSENT (%d)\n", DRIVER_PROP, (int)err);
        printf("      -> Open Firmware had it; Mac OS does not.  The property\n");
        printf("         did not survive into the Name Registry.\n");
    }
    size = 0;
    err = RegistryPropertyGetSize(&entry, "driver-ref", &size);
    if (err == noErr) {
        UInt32 ref = 0;
        size = sizeof(ref);
        RegistryPropertyGet(&entry, "driver-ref", &ref, &size);
        printf("   %-28s present (0x%08lX) -- the driver was opened\n",
               "driver-ref", (unsigned long)ref);
    } else {
        printf("   %-28s ABSENT (%d) -- the open step never ran\n",
               "driver-ref", (int)err);
    }

    /*
     * driver-descriptor is Mac OS's own copy of TheDriverDescription, read
     * out of our PEF -- so it says what Mac OS believes our runtime flags
     * and names are, rather than what we think we wrote.  If the load step
     * ran and the open step did not, the answer is in here.
     *
     * Layout (Universal Interfaces 3.4.1, DriverFamilyMatching.h):
     *   +0x00 signature 'mtej'      +0x04 descriptorVersion
     *   +0x08 nameInfoStr (Str31, 32 bytes)
     *   +0x28 version (NumVersion, 4)
     *   +0x2C driverRuntime flags   +0x30 driverName (Str31, 32 bytes)
     *   +0x50 driverDescReserved[8] (32 bytes)
     *   +0x70 nServices             +0x74 first service
     */
    printf("\n3b. driver-descriptor, as Mac OS parsed it\n");
    {
        unsigned char dd[128];
        RegPropertyValueSize dsize = sizeof(dd);

        memset(dd, 0, sizeof(dd));
        if (RegistryPropertyGet(&entry, "driver-descriptor", dd, &dsize) == noErr) {
            int i;
            for (i = 0; i < (int)dsize && i < 128; i += 16) {
                int j;
                printf("   %02X:", i);
                for (j = 0; j < 16 && i + j < (int)dsize; j++) {
                    printf(" %02X", dd[i + j]);
                }
                printf("\n");
            }
            printf("   signature     '%c%c%c%c'\n", dd[0], dd[1], dd[2], dd[3]);
            printf("   nameInfoStr   %d:'%.*s'\n", dd[8], dd[8], &dd[9]);
            printf("   driverRuntime 0x%02X%02X%02X%02X\n",
                   dd[0x2C], dd[0x2D], dd[0x2E], dd[0x2F]);
            printf("   driverName    %d:'%.*s'\n", dd[0x30], dd[0x30], &dd[0x31]);
            printf("   nServices     0x%02X%02X%02X%02X\n",
                   dd[0x70], dd[0x71], dd[0x72], dd[0x73]);
            printf("   service[0]    '%.4s' '%.4s'\n", &dd[0x74], &dd[0x78]);
        } else {
            printf("   absent\n");
        }
    }

    printf("\n4. opening .PEAudio by name\n");
    err = OpenDriver("\p.PEAudio", &refNum);
    if (err == noErr) {
        printf("   OPENED, refNum %d -- Initialize has now run\n", (int)refNum);
    } else {
        printf("   FAILED (%d)\n", (int)err);
        printf("      -27 is unitEmptyErr, -28 notOpenErr, -192 resNotFound;\n");
        printf("      any of those means the driver is not in the unit table.\n");
    }

    /*
     * Do by hand what the boot sequence declined to do.  driver-ptr says
     * the code was loaded and driver-ref says it was never opened, so the
     * failure is between those two steps; these three calls are those
     * steps, and unlike the boot path they return an error code.
     */
    printf("\n4b. driving the Driver Loader by hand\n");
    {
        CFragConnectionID    conn = NULL;
        DriverEntryPointPtr  entryPt = NULL;
        DriverDescriptionPtr desc = NULL;
        DriverRefNum         ref = 0;
        OSErr                e;

        e = GetDriverForDevice(&entry, &conn, &entryPt, &desc);
        printf("   GetDriverForDevice     %d", (int)e);
        if (e == noErr) {
            printf("  conn=%p main=%p desc=%p\n", conn, entryPt, desc);
        } else {
            printf("   <- could not load the fragment\n");
        }

        e = InstallDriverForDevice(&entry, 0, 0, &ref);
        printf("   InstallDriverForDevice %d", (int)e);
        if (e == noErr) {
            printf("  refNum=%d  <- Initialize has now run\n", (int)ref);
        } else {
            printf("\n");
        }

        if (e == noErr) {
            e = OpenInstalledDriver(ref, 3 /* fsRdWrPerm */);
            printf("   OpenInstalledDriver    %d\n", (int)e);
        }
    }

    printf("\n5. reading the device directly\n");
    size = sizeof(assigned);
    memset(assigned, 0, sizeof(assigned));
    if (RegistryPropertyGet(&entry, "assigned-addresses", assigned, &size) == noErr
        && size >= 5 * sizeof(UInt32)) {
        printf("   assigned-addresses[2] = 0x%08lX\n", (unsigned long)assigned[2]);
        regs = (volatile UInt32 *)assigned[2];
        printf("   ID = 0x%08lX", (unsigned long)regs[PEAU_ID / 4]);
        printf((regs[PEAU_ID / 4] == PEAU_MAGIC) ? "  'PEAU'\n" : "  (not us)\n");
    } else {
        printf("   assigned-addresses unreadable\n");
    }

    if (refNum != 0) {
        CloseDriver(refNum);
    }
    printf("\nDone.  Press return.\n");
    getchar();
    return 0;
}
