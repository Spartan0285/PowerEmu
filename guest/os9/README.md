# Mac OS 9 guest code

Built on a Mac OS 9 machine with CodeWarrior, not on the G4 -- the G4's
Xcode 2.5 emits Mach-O, and this is PowerPC CFM.  See
`docs/PARAVIRTUAL-SOUND.md` for why any of this exists.

## PEAudioProbe.c

The first milestone: does Mac OS 9 see the `poweremu-audio` node, does its
`AAPL,address` resolve, and does a load from there reach the device?  A
plain console application, so none of the Component Manager machinery is
in the way of the answer.

CodeWarrior: new C console (SIOUX) project, PowerPC target.  Add
`InterfaceLib`, `StdCLib`, the MSL C runtime, and `NameRegistryLib`.

Run it with the virtual Mac started by a PowerEmu build whose emulator has
`PEAU_TRACE=1` in its environment: the device logs every register access,
so the host log and the program's output confirm each other.
