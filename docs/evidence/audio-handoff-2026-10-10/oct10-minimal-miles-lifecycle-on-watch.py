import json,socket,subprocess,time
from pathlib import Path
pid=51399
root=Path('/tmp/pe9800')
for i in range(60):
    command=subprocess.run(['ps','-p',str(pid),'-o','command='],capture_output=True,text=True).stdout
    if 'oct08-autonomous-support' not in command:break
    time.sleep(20)
else:
    command=subprocess.run(['ps','-p',str(pid),'-o','command='],capture_output=True,text=True).stdout
    if 'oct08-autonomous-support' in command:
        c=socket.socket(socket.AF_UNIX)
        c.settimeout(5)
        c.connect('/var/folders/w4/jybr8qmd72z_fcvht4gbndmh0000gn/T/poweremu-bvvqf8.qmp')
        f=c.makefile('r');f.readline()
        c.sendall(b'{"execute":"qmp_capabilities"}\n')
        while 'return' not in f.readline():pass
        c.sendall(b'{"execute":"quit"}\n');c.close()
        print('Stopped owned isolated capture after twenty-minute limit',flush=True)
print('Capture watcher finished',flush=True)
