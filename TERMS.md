# Before you use PowerEmu

I'm Adam. I made PowerEmu on my own, for the fun of it, because I wanted to
run Mac OS X for PowerPC on a modern Mac. It costs nothing and I am not
selling you anything — but there are some things you should know before you
start, and I would rather say them plainly than bury them.

## It is one person's side project

There is no company behind PowerEmu and nobody testing it but me. I have
tried it on the Macs I own with the software I happen to have. I have not
tried every Mac, every version of Mac OS X, or every program you might run
inside it — I couldn't. Parts of it are marked as still being tested, and
that means exactly what it says.

## It can lose your work, on both sides

A virtual Mac's disk is one large file on your Mac. Forcing a virtual Mac to
power off can damage it, the same way pulling the plug on a real Mac can. A
sleeping virtual Mac may fail to wake — after PowerEmu updates itself, it
will not wake at all and starts fresh instead. Folders you share with a
virtual Mac are real folders on your Mac, and a mistake inside the guest
reaches the real files.

**Keep a copy of anything you would mind losing** — inside the virtual Mac
and on your own.

## Use it at your own risk

PowerEmu comes with no warranty of any kind. I am not responsible for lost
data, damaged disks, lost time, or anything else that follows from using it.
That is what sections 11 and 12 of the GNU General Public License already
say; it is repeated here in plain words because that licence is long and
nobody reads it.

## It does not include Mac OS X

PowerEmu emulates a Power Macintosh. It contains no Apple software at all:
no Mac OS X, no Mac OS 9, no Apple drivers, no ROMs. You supply your own
installation media, and having the right to use that media is up to you.

PowerEmu is not affiliated with, authorised by, or endorsed by Apple. Mac,
Mac OS X and Apple are trademarks of Apple Inc.

## What it does on a network

Left alone, PowerEmu keeps to your Mac. These reach further, and each one is
off until you turn it on:

- Sharing a virtual Mac on your network lets other computers reach it.
- The music server is *meant* to be reached by other Macs on your network.
- The mail bridge signs in to your real mail account on the virtual Mac's
  behalf, with a password you give it.
- Shared folders give the virtual Mac access to the folders you choose.

Turn them on when you are on a network you trust.

## What it sends

PowerEmu asks GitHub whether there is a newer version — when it opens, and
then at most once a day. You can turn that off in Settings.

Nothing else leaves your Mac unless you ask it to. If you send feedback,
PowerEmu shows you the exact list of what travels with your message before
anything is sent.

## Your rights

PowerEmu is free software under the GNU General Public License, version 2 or
later. You may use it, study it, change it, and pass it on. **Nothing here
takes any of that away.** The source is at
<https://github.com/Spartan0285/PowerEmu>.

## No promise of support

I answer what I can, when I can. There is no guarantee of a reply, a fix, or
a next version.
