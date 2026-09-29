# Keep Finder running: isolated Tiger experiment

Test host: Adam's MacBook Air. Guest: isolated Tiger 10.4.11, SSH port 24225. This is not Mac Studio or Leopard validation.

The experiment sets `PE_HARMONY_KEEP_FINDER=1` in a guest harness and enables complete capture mode. Production Harmony transitions skip writing CreateDesktop and skip restarting Finder under that condition. Normal installed Tools 2.16 behavior is unchanged; the experimental switch has not been enabled in the shipped app.

Before testing, the isolated guest's CreateDesktop setting was enabled and Finder restarted once to establish a visible desktop baseline. `pekeepfinder.m` then opened one unique and two duplicate-title windows and exercised three Harmony on/off cycles, waiting 12 seconds on entry and two seconds on exit. Every Finder window's AppleScript ID remained identical across all transitions. Finder PID remained 1605. Production WINDOWS reports were checked for negative-level desktop windows; none were included. A separate CGS inventory confirmed live wallpaper and desktop-icon windows at negative levels.

Individual captures using the same private capture API as PEAgent produced clean front, fully covered, and moved Finder images, visually inspected in the attached PNGs. The covered capture shows PE-keep-A rather than the PE-keep-B window above it. Moving the front window from (40,66) to (400,278) retained a clean image. These are settled captures, not a full host-compositor drag-animation test.

Result: promising and passed for the tested guest-side paths. No Finder restart is necessary for these complete-window captures. Before making this the default, validate the actual host proxies during dragging, minimization, resolution changes, and exit, plus Leopard. The legacy framebuffer-mask path remains outside this experiment. Prior Tools installations that left CreateDesktop disabled also need a deliberate recovery path.

The isolated VM was paused again after testing. The user's running guest was not modified.
