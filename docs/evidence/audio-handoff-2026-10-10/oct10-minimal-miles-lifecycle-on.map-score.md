# Minimal-map source qualification

Prefix discovery six ordered candidates >=5 host-monotonic seconds apart; each independently prefix-trained fixed offset and gain. No rate fit, local alignment, or timewarp. Expected game times never constrain host times.

Candidates do not prove all six sounds delivered. Mode labels require verified complete script/CUA sequence. Qualification proves identity, not clean fidelity; unqualified reference is not a loss score.

Capture retained: True. Complete sequence verified: True.

| Candidate | Presumed mode | Training corr | Full corr | Heldout pass | Qualified |
|---:|---|---:|---:|---:|---|
| 1 | EXACT-MP3 | 0.999999 | 0.491181 | 3/18 | True |
| 2 | EXACT-MP3 | 0.465681 | -0.000596 | 0/18 | False |
| 3 | EXACT-MP3 | 0.999999 | 0.368985 | 3/18 | True |
| 4 | PCM44100 | 1.000000 | 0.415967 | 4/18 | True |
| 5 | PCM44100 | 0.764097 | 0.323329 | 0/18 | False |
| 6 | PCM44100 | 1.000000 | 0.699037 | 8/18 | True |
