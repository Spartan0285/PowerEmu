from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[2]
checker=root/'scripts/check-tools-executables.sh'
paths=[
 'Install PowerEmu Tools.pkg/Contents/Resources/Install PowerEmu Tools.app/Contents/MacOS/Install PowerEmu Tools',
 'Install PowerEmu Tools.pkg/Contents/Resources/Install PowerEmu Tools.app/Contents/Resources/PowerEmu Agent.app/Contents/MacOS/PowerEmu Agent',
 'Install PowerEmu Tools.pkg/Contents/Resources/Install PowerEmu Tools.app/Contents/Resources/PowerEmuClock',
 'Uninstall PowerEmu Tools.pkg/Contents/Resources/Uninstall PowerEmu Tools.app/Contents/MacOS/Uninstall PowerEmu Tools']
with tempfile.TemporaryDirectory(prefix='pe-tools-mode-') as tmp:
 folder=Path(tmp)
 for item in paths:
  p=folder/item;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('fixture');p.chmod(0o755)
 def run():return subprocess.run(['sh',str(checker),str(folder)],capture_output=True,text=True)
 assert run().returncode==0
 agent=folder/paths[1];agent.chmod(0o644)
 r=run();assert r.returncode!=0 and str(agent) in r.stderr
 agent.chmod(0o755);assert run().returncode==0
 missing=folder/paths[0];missing.unlink();assert run().returncode!=0
 print('PASS: complete Tools payload accepted; non-executable Agent and missing installer rejected')
