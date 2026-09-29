# Tools 2.16 window preservation

Tools 2.15 still closed real Finder windows. The captured live trace shows delayed `reopened-and-reclosed` operations with empty and nonempty title lists. A successful query and a session token do not make title-based classification safe, particularly for renamed, duplicate, and newly opened windows.

Tools 2.16 removes the snapshot, delayed selector, and AppleScript close routine entirely. Finder still restarts to apply desktop visibility preferences; its restored windows are preserved instead of automatically pruned. This may restore older Finder windows during transitions.

Validation on the MacBook Air's isolated Tiger 10.4.11 test VM used `guest/tools/pefinderpreserve.m`, compiled with the production PEAgent.m and the 10.4u SDK. It exercised actual Harmony entry, rapid off/on, and exit, opened windows during the former cleanup delay, and checked them after 12 seconds. Unique windows, duplicate-title windows, and windows opened after off/on and exit survived. See tiger-regression.log. This is a guest-side regression check, not a claim of a physical gesture test of the user's production VM.

The PPC build completed without warnings. The signed host bundle passed deep/strict verification. Its mounted Tools package reports 2.16. The isolated test VM was paused again after testing. The user's running Tiger guest was not updated automatically.

Candidate: `build/Harmony Window Preservation/PowerEmu.app`.
