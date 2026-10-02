/*
 * PowerEmu Audio -- the Sound Manager output device, packaged for the
 * Extensions folder.
 *
 * Three resources make a disk-based PowerPC component.  'thng' is the
 * registration record the Component Manager scans Extensions for; its
 * platform array points at a 'dlle', which holds nothing but the name of
 * the entry point; and 'cfrg' tells the Code Fragment Manager that the
 * code is the whole of the data fork.  The file's type must be 'thng'.
 *
 * platformPowerPCNativeEntryPoint (5), not platformPowerPC (2): the entry
 * point is an ordinary CFM function, not a routine descriptor.  That is
 * the same distinction that made the Time Manager unusable from this
 * component -- see the note on SetInterruptTimer in PESoundComponent.c.
 *
 * 'thng' and 'dlle' are emitted as data rather than through Apple's
 * templates in Components.r, because Rez here cannot parse the "cstring"
 * in that file's 'dlle' declaration.  The bytes follow those templates
 * exactly; the layout is spelled out below so it can be checked.
 */

#include "CodeFragments.r"

/*  'thng' (ExtComponentResource):
 *    'sdev' 'PEau' 'PEmu'      type, subtype, manufacturer
 *    0, 0                      componentFlags, flagsMask
 *    0, 0                      code type/id (the platform array has it)
 *    'STR ' 128, 'STR ' 129    name, info
 *    0, 0                      icon
 *    0x00010000                version 1.0
 *    8                         componentHasMultiplePlatforms
 *    0                         icon family
 *    1                         one platform, then:
 *      0, 'dlle' 128, 5        flags, code, platformPowerPCNativeEntryPoint
 */
data 'thng' (128, "PowerEmu Audio") {
        $"736465765045617550456D7500000000"
        $"00000000000000000000535452200080"
        $"53545220008100000000000000010000"
        $"0000000800000000000100000000646C"
        $"6C6500800005"
};

/*  'dlle': the entry point's name, as a C string. */
data 'dlle' (128) {
        $"5045417564696F436F6D706F6E656E74"
        $"456E74727900"
};

resource 'STR ' (128) { "PowerEmu Audio" };
resource 'STR ' (129) { "Sound output through PowerEmu's paravirtual audio device." };

resource 'cfrg' (0) {
    {
        kPowerPC, kFullLib, kNoVersionNum, kNoVersionNum,
        0, 0,
        kIsLib, kOnDiskFlat, kZeroOffset, kWholeFork,
        "PowerEmu Audio"
    }
};
