#!/usr/bin/env python3
"""Validate complete cooperative guest/host runs; never infer scanout FPS."""
import json,re,sys,statistics
host=json.load(open(sys.argv[1]));text=open(sys.argv[2]).read()
def fields(line):return dict(re.findall(r'(\w+)=([^ ]+)',line))
def percent(values):
 values=sorted(values)
 return {'median':statistics.median(values),'p95':values[min(len(values)-1,int(len(values)*.95))],'max':max(values)}
summaries=[fields(x) for x in text.splitlines() if x.startswith('SUMMARY ')]
assert len(summaries)==1
s={k:int(v) for k,v in summaries[0].items()};rows=host['rows']
assert host['error'] is None and s['produced']==240 and s['sent']+s['replaced']==240
assert s['errors']==s['workerErrors']==0 and s['references']==6
assert host['published']==len(rows)==s['sent'] and rows[-1]['sequence']==240
assert all(a['sequence']<b['sequence'] for a,b in zip(rows,rows[1:]))
refs=[fields(x) for x in text.splitlines() if x.startswith('REFERENCE ')]
assert [int(r['seq']) for r in refs]==[40,80,120,160,200,240]
orientation=[]
for r in refs:
 assert int(r['mismatch'])==0 or int(r['flippedMismatch'])==0
 orientation.append('direct' if int(r['mismatch'])==0 else 'flipped')
assert len(set(orientation))==1
push=[fields(x) for x in text.splitlines() if x.startswith('PUSH ')]
assert [int(x['seq']) for x in push]==[r['sequence'] for r in rows]
result={'passed':True,'scope':'validation-loaded sequence publication, not scanout or input latency','produced':s['produced'],'published':len(rows),'replaced':s['replaced'],'orientation':orientation[0],'sequencePublicationsPerSecond':(len(rows)-1)/(rows[-1]['published']-rows[0]['published']),'changingPublications':sum(r['pixelChanged'] for r in rows),'commitToAckMS':percent([float(p['ackMS']) for p in push]),'captureCallMS':percent([float(r['captureMS']) for r in refs]),'captureFlushMS':percent([float(r['flushMS']) for r in refs])}
for key in ['transferDecodeVerifyMS','publishMS']:result[key]=percent([r[key] for r in rows])
draw=[fields(x) for x in text.splitlines() if x.startswith('DRAW ')]
if draw:
 assert [int(d['seq']) for d in draw]==list(range(1,241))
 result['guestDrawingMS']={k:percent([float(d[k]) for d in draw]) for k in ['generationMS','displayMS','flushMS']}
print(json.dumps(result,indent=2))
