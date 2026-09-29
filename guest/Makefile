# PowerEmu Tools for the guest: Mac OS X 10.4+ on PowerPC.
# Built on a PowerPC Mac with Xcode 2.5/3.1 (gcc-4.0, 10.4u SDK):
#   scripts/build.sh [host]    (from a modern Mac; default host g4)
CC      = gcc-4.0
SDK     = /Developer/SDKs/MacOSX10.4u.sdk
CFLAGS  = -arch ppc -isysroot $(SDK) -mmacosx-version-min=10.4 -Os -Wall -Wno-unused-parameter
LDFLAGS = -arch ppc -isysroot $(SDK) -Wl,-syslibroot,$(SDK) -mmacosx-version-min=10.4
AGENT   = build/PowerEmu Agent.app
INST    = build/Install PowerEmu Tools.app
UNINST  = build/Uninstall PowerEmu Tools.app

all: agent clock installer

clock: build/PowerEmuClock

agent: build/PowerEmuAgent
	rm -rf "$(AGENT)"; mkdir -p "$(AGENT)/Contents/MacOS"
	cp build/PowerEmuAgent "$(AGENT)/Contents/MacOS/PowerEmu Agent"
	cp Resources/Agent-Info.plist "$(AGENT)/Contents/Info.plist"

installer: build/PowerEmuInstaller agent clock
	rm -rf "$(INST)"; mkdir -p "$(INST)/Contents/MacOS" "$(INST)/Contents/Resources"
	cp build/PowerEmuInstaller "$(INST)/Contents/MacOS/Install PowerEmu Tools"
	cp Resources/Installer-Info.plist "$(INST)/Contents/Info.plist"
	cp Resources/PowerEmu.icns "$(INST)/Contents/Resources/"
	rm -rf "$(UNINST)"; mkdir -p "$(UNINST)/Contents/MacOS" "$(UNINST)/Contents/Resources"
	cp build/PowerEmuInstaller "$(UNINST)/Contents/MacOS/Uninstall PowerEmu Tools"
	cp Resources/Uninstaller-Info.plist "$(UNINST)/Contents/Info.plist"
	cp Resources/PowerEmu.icns "$(UNINST)/Contents/Resources/"
	cp -R "$(AGENT)" "$(INST)/Contents/Resources/"
	cp build/PowerEmuClock Resources/com.spartan0285.poweremu.clock.plist "$(INST)/Contents/Resources/"

build/PowerEmuAgent: src/PEAgent.m src/PEAccessibility.h src/PEPixelPack.h src/PEFullscreenState.h src/PETilePack.h src/PEFileTransfer.inc src/PETransferZip.h src/PESheets.inc
	mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $< -framework Cocoa -framework Carbon -lz

build/PowerEmuInstaller: src/PEInstaller.m src/PEAccessibility.h
	mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $< -framework Cocoa -framework Security

build/PowerEmuClock: src/PEClock.c
	mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

clean:
	rm -rf build
