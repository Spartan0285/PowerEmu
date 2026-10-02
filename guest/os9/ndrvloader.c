/* Copyright (c) 2023 Elliot Nunn */
/* Licensed under the MIT license */

/*
 * Adapted from classicvirtio's ndrvloader for PowerEmu's paravirtual sound
 * device.  An Open Firmware client program: it walks the device tree and
 * writes the NDRV into the node's driver,AAPL,MacOS,PowerPC property, which
 * is the one thing Mac OS needs in order to find a driver for a PCI device
 * it has never heard of.
 *
 * Changes from the original:
 *   - matches one device by vendor/device id (1b36:5045) rather than
 *     dispatching on a virtio device type
 *   - finds the driver in the concatenated blob by its own nameInfoStr,
 *     "mtej\0\0\0\0\x0cpci1b36,"
 *   - resolves the memory BAR from the node's assigned-addresses and
 *     patches it into the driver image before installing it; see the
 *     comment at that code for why the driver cannot look it up itself
 */

#include <stdarg.h>
#include <stddef.h>
#include <string.h>

// Globals
void *ofcode; // Client Interface (raw machine code, not a tvector)
long stdout; // OF ihandle

// Prototypes
int of(const char *s, int narg, ...);
void ofprint(const char *s);
void ofhex(long x);
long dtroot(void);
long dtstep(long prev);
void putNDRVs(void);
long readhex(const char *s, int len);
void chain9p(void);
void chainNormalBoot(void);
int virtiotype(int deviceid);

// Entry point (via the asm glue in ndrvloader.s)
void ofmain(void *initrd, long initrdsize, void *ci) {
	ofcode = ci; // the vector for calling into Open Firmware
	of("interpret",
		1, "stdout @",
		2, NULL, &stdout); // get handle for logging

	putNDRVs();
	chain9p();
	chainNormalBoot();
}

// Call wrapper for Open Firmware Client Interface
// Call as: if (of("name",
//                 narg, arg1, arg2, ...
//                 nret, ret1, ret2, ...)) {panic("failed")}
int of(const char *s, int narg, ...) {
	// array to contain {nameptr, narg, arg1..., nret, ret1...}
	long array[16] = {(long)s, narg, 0 /*nret will go here*/};
	va_list list;

	va_start(list, narg);
	for (int i=0; i<narg; i++) {
		array[3+i] = va_arg(list, long);
	}

	int nret = array[2] = va_arg(list, int);

	// Need asm glue because ofcode is a raw code pointer, not a full function ptr
	int result;
	asm volatile (
		"mtctr   %[ofcode]  \n"
		"mr      3,%[array] \n"
		"bctrl              \n"
		"mr      %[result],3\n"
		: [result] "=r" (result)
		: [array] "r" (array), [ofcode] "r" (ofcode) // args
		: "ctr", "lr", "r3", "r4", "r5", "r6", "r7", "r8", "memory" // clobbers
	);

	if (result == 0) {
		for (int i=0; i<nret; i++) {
			long *ptr = va_arg(list, long *);
			if (ptr) *ptr = array[3+narg+i];
		}
	}
	va_end(list);

	return result;
}

// I couldn't bear to static-link another printf implementation
void ofprint(const char *s) {
	of("write",
		3, stdout, s, strlen(s),
		1, NULL); // discard "bytes written"
}

void ofhex(long x) {
	const char *hex = "0123456789abcdef";
	char s[] = "00000000 ";
	for (int i=0; i<8; i++) {
		s[i] = hex[15 & (x >> (28-i*4))];
	}
	ofprint(s);
}

long dtroot(void) {
	long phandle;
	of("finddevice",
		1, "/",
		1, &phandle);
	return phandle;
}

long dtstep(long prev) {
	long phandle = 0;
	of("child",
		1, prev,
		1, &phandle);
	if (phandle != 0) return phandle;

	for (;;) {
		of("peer",
			1, prev,
			1, &phandle);
		if (phandle != 0) return phandle;
		of("parent",
			1, prev,
			1, &prev);
		if (prev == 0) return 0; // finished
	}
}

// Acquire large blob of concatenated NDRVs
extern const char allndrv[];
extern const long allndrvlen;
asm (
	".section .data                 \n"
	".balign 4                      \n"
	".global allndrv, allndrvlen    \n"
	"allndrvlen:                    \n"
	".long allndrvend-allndrv       \n"
	"allndrv:                       \n"
	".incbin \"build/ndrv/allndrv\" \n"
	"allndrvend:                    \n"
	".section .text                 \n"
);

void putNDRVs(void) {
	struct support {
		const void *ndrv;
		long len;
		const char *name;
	};

	struct support supported[64] = {};

	ofprint("PowerEmu audio NDRV loader (");
	const char *next = allndrv;
	while (next < allndrv + allndrvlen) {
		const char *this = next;

		for (;;) {
			next++;
			if (next >= allndrv + allndrvlen) break;
			if (next[0]=='J' && next[1]=='o' && next[2]=='y' && next[3]=='!' && next[4]=='p') break;
		}

		// Find TheDriverDescription (better not be compressed)
		const char *mtej = this;
		for (;;) {
			mtej++;
			if (mtej + 0x70 >= next) {
				mtej = NULL;
				break;
			}

			if (!memcmp(mtej, "mtej" "\0\0\0\0" "\x0cpci1b36,", 17)) break;
		}
		if (!mtej) continue;

		/* One driver, not a table of virtio types: always slot 1. */
		int vid = 1;

		supported[vid] = (struct support) {.ndrv=this, .len=next-this, .name=mtej+0x31};
		if (this != allndrv) ofprint(" ");
		ofprint(supported[vid].name);
	}
	ofprint(")\n");

	ofprint("Copying NDRVs to device tree:\n");

	for (long ph=dtroot(); ph!=0; ph=dtstep(ph)) {
		long vendorid = 0, deviceid = 0;
		of("getprop",
			4, ph, "vendor-id", &vendorid, sizeof vendorid,
			1, NULL);
		of("getprop",
			4, ph, "device-id", &deviceid, sizeof deviceid,
			1, NULL);

		// poweremu-audio only
		int vid = 1;
		if (vendorid != 0x1b36 || deviceid != 0x5045) continue;

		if (supported[vid].ndrv) {
			long len = 0;

			/*
			 * Patch the BAR address into the driver image.
			 *
			 * The driver cannot look this up itself.  It is
			 * prepared during PCI enumeration, when the only CFM
			 * libraries that exist are the ones in ROM, so an
			 * import of NameRegistryLib (RegistryPropertyGet) or
			 * PCILib makes CFM refuse the fragment and DoDriverIO
			 * is never called -- with no error reported anywhere.
			 * Open Firmware has no such problem, so the lookup
			 * happens here instead and the answer is written into
			 * the image before Mac OS ever sees it.
			 *
			 * assigned-addresses is five words per BAR:
			 *   phys-hi phys-mid phys-lo size-hi size-lo
			 * and phys-lo of the first entry is our memory BAR.
			 */
			unsigned long assigned[10];
			long alen = 0;
			of("getprop",
				4, ph, "assigned-addresses", assigned, sizeof assigned,
				1, &alen);
			if (alen >= 20) {
				unsigned char *img = (unsigned char *)supported[vid].ndrv;
				long i;
				for (i = 0; i + 12 <= supported[vid].len; i += 4) {
					if (img[i+0]==0x50 && img[i+1]==0x45 &&
					    img[i+2]==0x41 && img[i+3]==0x55 &&
					    img[i+4]==0x42 && img[i+5]==0x41 &&
					    img[i+6]==0x52 && img[i+7]==0x30) {
						unsigned long bar = assigned[2];
						img[i+8]  = (bar >> 24) & 0xff;
						img[i+9]  = (bar >> 16) & 0xff;
						img[i+10] = (bar >>  8) & 0xff;
						img[i+11] =  bar        & 0xff;
						ofprint("  BAR patched\n");
						break;
					}
				}
			}

			of("setprop",
				4, ph, "driver,AAPL,MacOS,PowerPC", supported[vid].ndrv, supported[vid].len,
				1, &len);

			ofprint("  ");
			ofprint(supported[vid].name);
			ofprint("\n");
		} else {
			ofprint("  no NDRV for Virtio type ");
			ofhex(vid);
			ofprint("\n");
		}
	}
}

void chain9p(void) {
	void *loadbase = (void *)0x4000000;
	void *bootinfo = (void *)0x4400000;

	if (memcmp(bootinfo, "<CHRP-BOOT", 10)) return;

	ofprint("Chainloading Mac OS ROM file to start from 9P...\n");

	long len=0x400000; // always shorter than 4 MB and never ends with a null
	while (((char *)bootinfo)[len-1] == 0) len--;

	memmove(loadbase, bootinfo, len);

	of("interpret",
		2, "!load-size", len,
		0);

	char path[512] = {};

	// Set the CHOSEN property
	for (long ph=dtroot(); ph!=0; ph=dtstep(ph)) {
		long vendorid = 0, deviceid = 0;
		of("getprop",
			4, ph, "vendor-id", &vendorid, sizeof vendorid,
			1, NULL);
		of("getprop",
			4, ph, "device-id", &deviceid, sizeof deviceid,
			1, NULL);

		// Virtio 9P devices only
		if (vendorid == 0x1af4 && virtiotype(deviceid) == 9) {
			of("package-to-path",
				3, ph, path, sizeof path,
				1, NULL);
			strcat(path, ":,\\\\:tbxi");
			break;
		}
	}

	long chosenph = 0;
	of("finddevice",
		1, "/chosen",
		1, &chosenph);

	if (chosenph) {
		of("setprop",
			4, chosenph, "bootpath", path, strlen(path)+1,
			1, NULL);
	}

	// OpenBIOS doesn't offer the "chain" service
	of("interpret",
		1, "init-program go",
		0);
}

void chainNormalBoot(void) {
	of("interpret",
		1, "boot",
		0);
}

// Very basic hex reader, treat bad chars as zero
long readhex(const char *s, int len) {
	long n = 0;
	for (int i=0; i<len; i++) {
		n <<= 4;
		char c = s[i];
		if (c >= '0' && c <= '9') n += c - '0';
		else if (c >= 'a' && c <= 'f') n += c - 'a' + 16;
		else if (c >= 'A' && c <= 'F') n += c - 'A' + 16;
	}
	return n;
}

int virtiotype(int deviceid) {
	// Legacy Virtio range
	if (deviceid >= 0x1000 && deviceid <= 0x1009) {
		const char table[] = {1, 2, 5, 3, 8, 4, 0, 0, 0, 9};
		return table[deviceid - 0x1000];
	}

	// Virtio v1 range
	if (deviceid >= 0x1041 && deviceid <= 0x107f) return deviceid - 0x1041;

	// Not a Virtio device
	return 0;
}
