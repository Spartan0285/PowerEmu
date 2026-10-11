# Minimal-map source qualification

Prefix discovery six ordered candidates >=5 host-monotonic seconds apart; each independently prefix-trained fixed offset and gain. No rate fit, local alignment, or timewarp. Expected game times never constrain host times.

Candidates do not prove all six sounds delivered. Mode labels require verified complete script/CUA sequence. Qualification proves identity, not clean fidelity; unqualified reference is not a loss score.

Capture retained: True. Complete sequence verified: False.

| Candidate | Presumed mode | Training corr | Full corr | Heldout pass | Qualified |
|---:|---|---:|---:|---:|---|
| 1 | PCM44100 | 0.929187 | 0.631963 | 8/18 | False |
| 2 | PCM44100 | 1.000000 | 0.602236 | 8/18 | False |
| 3 | PCM44100 | 1.000000 | 0.414389 | 4/18 | False |
| 4 | EXACT-MP3 | 0.782597 | 0.329298 | 0/18 | False |
| 5 | EXACT-MP3 | 0.999999 | 0.853763 | 12/18 | False |
| 6 | EXACT-MP3 | 0.999999 | 0.999991 | 18/18 | False |
