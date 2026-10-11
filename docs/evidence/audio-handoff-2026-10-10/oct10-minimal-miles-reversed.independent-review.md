# Independent reversed-order review

PID 47405, recorder-light Warcraft-only fixture, MP3 first then native PCM. Six sounds fit the intended ~10-second spacing (6.334, 16.281, 26.298, 36.3, 46.305, 56.334 capture seconds; use the scorer's precise JSON for timestamps). All source windows fully retained. PCM/metadata drops zero, contiguous metadata ends at captured byte count, no logged flush errors. Host supply is complete in every window and callback maximum gaps stay about 11.7 ms.

The scorer uses explicit MP3-first ordering and the correct quantized written-WAV reference for PCM. It selects six independent prefixes with five-second exclusion and then fits one fixed offset/gain per source. It does not timewarp or convert failed identity fits into loss scores. Candidates 3 and 5 fail its held-out identity gate and remain globally unscored.

## Source-local evidence

MP3 trial 1 has exact source chunks at phase zero through frame 49152, then a 567-frame zero island at 55296. An intact block at 57344 matches the source 567 frames behind. Later exact blocks match at offsets -1268, -1591 and -1894. MP3 trial 2 stays at zero offset with all 18 held-out blocks accepted and full correlation .999991.

PCM trial 4 has exact early source chunks at phase zero, a 798-frame zero island at 25600, and then exact chunks 286 frames behind (798 minus 512). Later intact blocks match at offsets -867, -1160 and -2374. PCM trial 6 stays at zero offset throughout with all 18 blocks accepted and full correlation .999999945.

Trials 3 and 5 also contain many independently exact local chunks with staircase offsets and zero islands, but these local diagnostics must not replace the failed fixed global quality gate or yield precise missing-frame totals. Search radius +/-4096 and block length 2048 were declared before fitting; no corrected recording is produced.

## Actionable conclusion

The native PCM reproducer eliminates MP3 decoding as a necessary cause. Reversed order eliminates a simple format preference or monotonic cold-start explanation. Correctly rendered minimal-map repeats reproduce the fault without the added guest HAL helper or heavy instrumentation. This is now a qualified reproducible single-game source fault, rather than an asset identification problem.

The important shape is intermittent zero output with intact source resuming at a different phase, not a continuous sample-rate error. Several shifts involve a 512-frame difference from zero-island length. This supports inspecting the normal 512-frame guest feed/mix deadline and cursor advancement contract; it does not prove which layer introduces the zeros. Host adaptive resampling, decoder substitution, greater host buffering and arbitrary timestamp shifts do not address the demonstrated boundary.

Stop further source/order permutations. Use this exact fixture as the acceptance gate for the next narrowly justified producer/guest scheduling change. A candidate needs all six complete sources qualified and intact under the same fixed model, zero recorder drops/full host supply, plus reverse candidate-off control. If no concrete change is justified yet, acquire one bounded stage-local observation at the existing game feed boundary before another playback patch; another global correlation run adds little.

Local diagnostics: oct10-minimal-miles-reversed.independent-local-audit.json. Reproducer: oct10-audit-reversed-local.py. Production code and guest processes unchanged.
