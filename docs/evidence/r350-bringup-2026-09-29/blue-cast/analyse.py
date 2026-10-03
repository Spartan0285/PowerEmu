#!/usr/bin/env python3
"""Recompute the per-phase rates from a bench run's samples.json."""
import json, re, sys, pathlib

def report(run):
    s = json.load(open(pathlib.Path(run) / 'samples.json'))
    out = {'run': pathlib.Path(run).name}
    for phase in ('idle', 'chess', 'motion'):
        pts = [x for x in s if x['phase'] == phase]
        if len(pts) < 2:
            continue
        a, b = pts[0], pts[-1]
        dt = b['t'] - a['t']
        r = {'seconds': round(dt, 1)}
        for k in ('frames', 'draws', 'tex_vram', 'tex_agp',
                  'r350_draws', 'r350_rejected'):
            if k not in b and k not in a:
                continue
            r[k + '/s'] = round((b.get(k, 0) - a.get(k, 0)) / dt, 1)
        r['agp_MB/s'] = round((b.get('agp_bytes', 0) - a.get('agp_bytes', 0)) / dt / 1048576, 2)
        r['vram_high_MB'] = round(b.get('vram_high', 0) / 1048576, 1)
        if 'r350_draw_ns' in b:
            ns = b['r350_draw_ns'] - a.get('r350_draw_ns', 0)
            r['r350_metal_%_of_wall'] = round(100 * ns / 1e9 / dt, 1)
            n = b.get('r350_draws', 0) - a.get('r350_draws', 0)
            r['r350_ms_per_draw'] = round(ns / 1e6 / n, 2) if n else None
            for key, label in (('r350_target_bytes', 'r350_target_MB/s'),
                               ('r350_texture_bytes', 'r350_texture_MB/s')):
                r[label] = round((b.get(key, 0) - a.get(key, 0)) / dt / 1048576, 1)
        if 'proc_cpu_s' in b and 'proc_cpu_s' in a:
            r['host_cpu_%_of_one_core'] = round(
                100 * (b['proc_cpu_s'] - a['proc_cpu_s']) / dt, 1)
        rej = {k[len('r350_reject_'):]: b[k] - a.get(k, 0)
               for k in b if k.startswith('r350_reject_') and b[k] - a.get(k, 0) > 0}
        if rej:
            total = sum(rej.values())
            r['rejected_by_reason'] = {k: '%d (%.0f%%)' % (v, 100 * v / total)
                                       for k, v in sorted(rej.items(),
                                                          key=lambda kv: -kv[1])}
        cpu = [k for k in b if re.fullmatch(r'cpu\d+_ns', k)]
        if cpu:
            ns = sum(b[k] - a.get(k, 0) for k in cpu)
            r['vcpu_%_of_one_host_core'] = round(100 * ns / 1e9 / dt, 1)
        out[phase] = r
    return out

for run in sys.argv[1:]:
    print(json.dumps(report(run), indent=2))
