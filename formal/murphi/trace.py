import re,sys
t=open(sys.argv[1]).read()
if 'error trace' not in t: sys.exit()
body=t.split('error trace')[1]
prev={}
for s in re.split(r'\nRule |\nStartstate ', body)[1:]:
    head=s.split('\n')[0].replace(' fired.','')
    kv=dict(re.findall(r'^(latest\[\d\]|mem\[\d\]|l1d\.\w+|l2\.\w+|sw\.\w+|dma|daddr|l1i_\w+|qn|q\[\d\]|pushed):(\S+)',s,re.M))
    ch={k:v for k,v in kv.items() if prev.get(k)!=v}; prev.update(kv)
    print(head[:75],'|',' '.join(f'{k}={v}' for k,v in ch.items()))
