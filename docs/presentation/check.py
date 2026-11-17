"""Standard-library stored-artifact and exact subtitle-timing reader."""
from pathlib import Path
import json,hashlib,re,xml.etree.ElementTree as ET
P=Path(__file__).parent;m=json.loads((P/'MANIFEST.json').read_text())
for name,digest in m['sha256'].items():assert hashlib.sha256((P/name).read_bytes()).hexdigest()==digest,name
r=json.loads((P/'receipt.json').read_text())
for file,key in [('note.srt','originalSHA256'),('converted.vtt','convertedSHA256'),('existing.vtt','collisionSHA256')]:assert hashlib.sha256((P/file).read_bytes()).hexdigest()==r[key]
def cues(name):
 out=[]
 for g in re.findall(r'(\d{2}):(\d{2}):(\d{2})[,.](\d{3}) --> (\d{2}):(\d{2}):(\d{2})[,.](\d{3})\n([^\n]+)',(P/name).read_text()):
  n=list(map(int,g[:8]));out.append({'start':((n[0]*60+n[1])*60+n[2])*1000+n[3],'end':((n[4]*60+n[5])*60+n[6])*1000+n[7],'text':g[8]})
 return out
c=cues('note.srt');assert len(c)==2 and c==cues('converted.vtt');f=json.loads((P/'figure-manifest.json').read_text());assert c==f['cues']
for name,key in [('copy.svg','desktop'),('copy-mobile.svg','phone')]:
 root=ET.parse(P/name).getroot();rects=[x for x in root.iter()if 'data-cue'in x.attrib];assert len(rects)==4;mapping=f['mapping'][key];scale=mapping['width']/mapping['maximumMs']
 for rect in rects:
  cue=c[int(rect.attrib['data-cue'])];assert abs(float(rect.attrib['x'])-(mapping['x0']+cue['start']*scale))<1e-7;assert abs(float(rect.attrib['width'])-(cue['end']-cue['start'])*scale)<1e-7
assert r['before']['jobs'][0]['state']=='complete_verified';assert r['sameByteReplacement']['jobs'][0]['state']=='output_changed';assert r['newExplicitConversion']['jobs'][0]['state']=='complete_verified';assert r['originalAndCollisionPreserved']and r['invalidReversedCuePreservedOutputs']
print(f"Verified {len(m['sha256'])} exact payloads, two native cue intervals/texts, all shared-scale bars and recorded states. Stored evidence only; actual native replay is separate.")
