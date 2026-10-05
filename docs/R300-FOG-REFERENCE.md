# R300/R350 fog — what the hardware actually does

Reference notes for implementing fog in `ppc_mac_gpu`, gathered 5 October 2026
from AMD's published documents and from Mesa. Written down because the fog
registers are easy to read wrongly in three separate ways, and we have already
been caught by one of them.

## The blend

```
final.rgb = colour.rgb * f + fog_colour.rgb * (1 - f)
f = saturate(f)
final.a   = colour.a            /* alpha is NOT fogged */
```

**`f = 1` means no fog; `f = 0` means fully fogged.** This is the opposite of
the sense one reaches for first. It is the only sense consistent with the one
directional statement AMD does make, for `FG_FOG_BLEND.ENABLE`:

> `00 - Disables fog (output matches input color).`

The formula itself is not stated in either AMD document — both give fields and
no equation. It comes from Mesa's `src/mesa/state_tracker/st_nir_lower_fog.c`,
which also saturates `f` and re-inserts the original alpha afterwards.

## Where the factor comes from — not from RS

This is the part that misleads. For `LINEAR`, `EXP` and `EXP2` the fog value
does **not** travel through the RS block. There is no fog field in `RS_COUNT`,
`RS_INST_COUNT` or `RS_IP_n`, and no fog interpolator. Looking for one and
finding nothing proves nothing.

It is selected by **`GB_SELECT` (0x401C)**, field `FOG_SELECT` bits 2:0:

| Value | Source |
|---|---|
| 0–3 | alpha of vertex colour 0–3 |
| 4 | `1/(1/W)` |
| 5 | `Z` |

and mapped onto 0..1 by two IEEE **float32** registers:

| Register | Address |
|---|---|
| `GA_FOG_SCALE` | 0x4294 |
| `GA_FOG_OFFSET` | 0x4298 |

*(Inference, not quoted: these almost certainly implement the standard linear
MAD, `f = source * scale + offset`, with `scale = -1/(end-start)` and
`offset = end/(end-start)`, matching Mesa's optimised fog params. The names,
the float format and their position in GA all fit, but AMD does not state it.)*

**`FG_FOG_FACTOR` (0x4BC4) applies only to the CONSTANT function (FN=3).**
Reading zero from it on a linear draw is meaningless — a red herring that cost
us time.

## Fog colour scale

`FG_FOG_COLOR_R/G/B` at 0x4BC8 / 0x4BCC / 0x4BD0 are **10-bit** fixed point in
bits 9:0, so divide by 1024. Not 8-bit.

Warcraft III's menu sets `0x02c, 0x050, 0x02c` = (0.043, 0.078, 0.043) — a very
dark desaturated green, which is exactly the stormy sky the 9200 shows and we
do not.

## Pipeline position

`US (fragment shader) -> FG (fog, then alpha test) -> ZB -> CB (alpha blend)`.

So fog applies **after** the shader output and **before** both the alpha test
and the colour blend. `US_OUT_FMT` is documented as specifying how the shader
output is written "to the fog unit", which places FG immediately downstream.

Fog is only supported for a few output formats: `C4_8`, `C4_8_GAMMA` and the
packed YUV ones. Every 16/32-bit and floating-point target has `Fog = No` in
AMD's format table, so the blend must be gated on `US_OUT_FMT_0.OUT_FMT`.

## Do it in the fragment program

Both Mesa drivers **disable the fixed-function FG fog block outright** and
lower fog into the fragment shader instead:

- Gallium `r300_context.c` writes `FG_FOG_BLEND = 0` once in its invariant
  state and never touches it again; `GA_FOG_SCALE`, `GA_FOG_OFFSET` and
  `FOG_SELECT` are defined in its headers and never used.
- The legacy DRI driver has one fog line in 2416 lines of state code:
  `/* disable fog unit */`.

Which means the shader lowering is the well-trodden path, and it ports
directly into our Metal translator:

```metal
float f = saturate(fma(fogc, scale, offset));       /* LINEAR */
rgb = fma(colour.rgb, f, fog_colour.rgb * (1.0 - f));
/* alpha untouched */
```

## Sources

- AMD, *R5xx Acceleration* v1.5 — §11.3 (FG registers), §10.7.6 (fog stuffing),
  GA fog registers, `GB_SELECT`, format tables.
  https://www.x.org/docs/AMD/old/R5xx_Acceleration_v1.5.pdf
- AMD, *R3xx 3D Registers* — §1.2 fog registers, §1.4 `RS_COUNT`, `US_OUT_FMT`.
  https://www.x.org/docs/AMD/old/R3xx_3D_Registers.pdf
- Mesa `src/mesa/state_tracker/st_nir_lower_fog.c` — the formula, the
  saturation, and alpha passthrough.
- Mesa `src/gallium/drivers/r300/` and the legacy `dri/r300` driver — both
  disable the FG block.
