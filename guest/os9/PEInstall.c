/*
 * PEInstall -- put "PowerEmu Audio" into the Extensions folder.
 *
 * The component has to be in Extensions for the Component Manager to find
 * it at startup, which is what makes it appear in the Sound control panel
 * as an output device.  It cannot be put there from the host: the guest's
 * volume is HFS+ inside an HFS wrapper, and hfsutils -- the only thing
 * this Mac has that can write an HFS volume at all, macOS having dropped
 * HFS entirely -- sees only the wrapper.  So the copy happens in the
 * guest, from the disc this was launched from.
 *
 * Both forks are copied by hand rather than with one of the File Manager's
 * copy calls, because those are not in every system's shared libraries and
 * this has to work on a stock Mac OS 9 with nothing installed.
 */

#include <stdio.h>
#include <MacTypes.h>
#include <Files.h>
#include <Folders.h>
#include <Resources.h>
#include <Script.h>

#define kCompName   "\pPowerEmu Audio"
#define kCompType   FOUR_CHAR_CODE('thng')
#define kCompCreator FOUR_CHAR_CODE('PEmu')

#define kCopyBuf    (32L * 1024L)

static OSErr CopyFork(short srcRef, short dstRef, long *total)
{
    Ptr   buf = NewPtr(kCopyBuf);
    OSErr err = noErr;
    long  eof = 0;

    if (buf == NULL) {
        return memFullErr;
    }
    GetEOF(srcRef, &eof);
    SetFPos(srcRef, fsFromStart, 0);
    SetFPos(dstRef, fsFromStart, 0);
    SetEOF(dstRef, 0);
    *total = 0;

    while (*total < eof) {
        long n = eof - *total;

        if (n > kCopyBuf) {
            n = kCopyBuf;
        }
        err = FSRead(srcRef, &n, buf);
        if (err != noErr && err != eofErr) {
            break;
        }
        if (n <= 0) {
            break;
        }
        err = FSWrite(dstRef, &n, buf);
        if (err != noErr) {
            break;
        }
        *total += n;
    }
    DisposePtr(buf);
    return (err == eofErr) ? noErr : err;
}

int main(void)
{
    FSSpec  src, dst;
    short   vRef = 0, srcRef = 0, dstRef = 0;
    long    dirID = 0, bytes = 0;
    OSErr   err;
    FInfo   fi;

    printf("PowerEmu Audio installer\n\n");

    printf("1. the component, next to this application\n");
    err = FSMakeFSSpec(0, 0, kCompName, &src);
    if (err != noErr) {
        printf("   not found (%d).  Keep \"PowerEmu Audio\" beside this\n", (int)err);
        printf("   application and run it again.\n");
        goto done;
    }
    printf("   found\n");

    printf("\n2. the Extensions folder\n");
    err = FindFolder(kOnSystemDisk, kExtensionFolderType, kDontCreateFolder,
                     &vRef, &dirID);
    if (err != noErr) {
        printf("   FindFolder failed (%d)\n", (int)err);
        goto done;
    }
    err = FSMakeFSSpec(vRef, dirID, kCompName, &dst);
    if (err != noErr && err != fnfErr) {
        printf("   FSMakeFSSpec failed (%d)\n", (int)err);
        goto done;
    }
    printf("   vRefNum %d, dirID %ld\n", (int)vRef, dirID);

    printf("\n3. copying\n");
    if (err == noErr) {              /* already there: replace it */
        FSpDelete(&dst);
    }
    err = FSpCreate(&dst, kCompCreator, kCompType, smSystemScript);
    if (err != noErr) {
        printf("   FSpCreate failed (%d)\n", (int)err);
        goto done;
    }
    FSpCreateResFile(&dst, kCompCreator, kCompType, smSystemScript);

    /* data fork */
    err = FSpOpenDF(&src, fsRdPerm, &srcRef);
    if (err == noErr) {
        err = FSpOpenDF(&dst, fsWrPerm, &dstRef);
        if (err == noErr) {
            err = CopyFork(srcRef, dstRef, &bytes);
            FSClose(dstRef);
            printf("   data fork: %ld bytes (%d)\n", bytes, (int)err);
        }
        FSClose(srcRef);
    }
    if (err != noErr) {
        printf("   data fork failed (%d)\n", (int)err);
        goto done;
    }

    /* resource fork */
    srcRef = dstRef = 0;
    err = FSpOpenRF(&src, fsRdPerm, &srcRef);
    if (err == noErr) {
        err = FSpOpenRF(&dst, fsWrPerm, &dstRef);
        if (err == noErr) {
            err = CopyFork(srcRef, dstRef, &bytes);
            FSClose(dstRef);
            printf("   resource fork: %ld bytes (%d)\n", bytes, (int)err);
        }
        FSClose(srcRef);
    }
    if (err != noErr) {
        printf("   resource fork failed (%d)\n", (int)err);
        goto done;
    }

    /* type and creator, so the Component Manager scans it */
    if (FSpGetFInfo(&dst, &fi) == noErr) {
        fi.fdType    = kCompType;
        fi.fdCreator = kCompCreator;
        FSpSetFInfo(&dst, &fi);
    }

    printf("\nInstalled.  Restart, then open the Sound control panel and\n");
    printf("choose \"PowerEmu Audio\" under Output.\n");

done:
    printf("\nPress return.\n");
    getchar();
    return 0;
}
