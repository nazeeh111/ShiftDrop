"""Draw exact native subtitle intervals and recorded publication states."""
from pathlib import Path
import json,re,html,hashlib
P=Path(__file__).parent
r=json.loads((P/'receipt.json').read_text())
def cues(path):
 text=path.read_text();pattern=r'(\d{2}):(\d{2}):(\d{2})[,.](\d{3}) --> (\d{2}):(\d{2}):(\d{2})[,.](\d{3})\n([^\n]+)'
 out=[]
 for m in re.finditer(pattern,text):
  n=list(map(int,m.groups()[:8]));out.append({'start':((n[0]*60+n[1])*60+n[2])*1000+n[3],'end':((n[4]*60+n[5])*60+n[6])*1000+n[7],'text':m.group(9)})
 return out
c=cues(P/'note.srt');assert c==cues(P/'converted.vtt')and len(c)==2
for mobile in [False,True]:
 w,h=(375,920)if mobile else(1120,650);pad=22 if mobile else 36;start=pad if mobile else 180;length=w-pad*2 if mobile else 904;scale=length/8000
 parts=[f'<svg xmlns="http://www.w3.org/2000/svg" width="100%" viewBox="0 0 {w} {h}" role="img" aria-labelledby="t d"><title id="t">Original kept. Converted copy verified.</title><desc id="d">Two actual synthetic subtitle cues preserve 1.007 to 2.999 seconds and 5.120 to 7.250 seconds when converted to a numbered VTT copy. A fresh process verifies the result. Replacing it with identical bytes in a different file is held. An explicit new conversion produces another verified copy. This is actual windowless native conversion, not a new Finder interaction capture.</desc><rect width="{w}" height="{h}" fill="#17211B"/>']
 def t(x,y,value,size=16,color='#F5F4ED',font='Arial, Helvetica, sans-serif'):parts.append(f'<text x="{x}" y="{y}" font-size="{size}" fill="{color}" font-family="{font}">{html.escape(value)}</text>')
 t(pad,33,'ShiftDrop / Saved-copy case',12)
 for i,line in enumerate(['Original kept.','Copy verified.']if mobile else['Original kept. Converted copy verified.']):t(pad,80+i*36,line,30 if mobile else 36)
 for row,label in enumerate(['Original note.srt',r['outputName']]):
  y=(196+row*126)if mobile else(226+row*108);t(pad,y-26,label,15)
  parts.append(f'<path d="M{start},{y+20}h{length}" stroke="#8B958C" stroke-width="1"/>')
  for i,item in enumerate(c):
   x=start+item['start']*scale;ww=(item['end']-item['start'])*scale;fill='#F5F4ED'if row==0 else'#D0FA6B';parts.append(f'<rect data-row="{row}" data-cue="{i}" x="{x:.9f}" y="{y}" width="{ww:.9f}" height="10" fill="{fill}"/>')
   if row==1:t(x,y+64,f'{item["start"]/1000:.3f}–{item["end"]/1000:.3f}s',10 if mobile else 14)
  for sec in [0,2,4,6,8]:t(start+sec*1000*scale-(7 if sec==8 else 0),y+34,str(sec),10)
 t(pad,420 if mobile else 436,'Same linear 0–8 second scale. Both cue texts preserved.',11 if mobile else 15)
 statuses=[('Fresh process',r['before']['jobs'][0]['state']),('Same bytes, different file',r['sameByteReplacement']['jobs'][0]['state']),('Explicit new conversion',r['newExplicitConversion']['jobs'][0]['state'])]
 for i,(label,status)in enumerate(statuses):
  x=pad if mobile else pad+i*355;y=498+i*109 if mobile else 494;t(x,y,label,13);t(x,y+29,status,17,'#D0FA6B'if status=='complete_verified'else'#F5F4ED','Courier New, Courier, monospace')
 t(pad,872 if mobile else 588,'Existing collision and original bytes remain unchanged.',11 if mobile else 15);t(pad,h-22,'Actual packaged CLI. Native drag and picker not retested.',11)
 parts.append('</svg>');(P/('copy-mobile.svg'if mobile else'copy.svg')).write_text(''.join(parts))
(P/'figure-manifest.json').write_text(json.dumps({'inputs':{n:hashlib.sha256((P/n).read_bytes()).hexdigest()for n in['note.srt','converted.vtt','receipt.json']},'cues':c,'timeUnit':'milliseconds','mapping':{'desktop':{'x0':180,'width':904,'maximumMs':8000},'phone':{'x0':22,'width':331,'maximumMs':8000}},'meaning':'Equal source/output timing; status schematic from native commands. No runtime speed or native-UI measurement.'},indent=2)+'\n')
