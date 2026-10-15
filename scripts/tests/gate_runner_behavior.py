import contextlib, io, os, runpy, tempfile, sys, threading
from pathlib import Path
source_root=Path(sys.argv[1])
r=runpy.run_path(str(source_root/"scripts/gate_runner.py"))
with tempfile.TemporaryDirectory(prefix='la_runner_proposal.') as directory:
 root=Path(directory);cap=root/'capture';cap.mkdir();scripts=root/'scripts';scripts.mkdir();ledger=root/'all.launch';ledger.write_text('')
 def gate(name, body, shell=False, **flags):
  path=scripts/name;path.write_text(('#!/bin/sh\n' if shell else '#!/usr/bin/env python3\n')+body);path.chmod(0o755)
  return dict(name=name,label=name,script='scripts/'+name,kind='headless',marker='OK',mutations=[],args=[],env={},needs=[],launches=False,capture_reader=False,last=False,timeout_s=5,**flags)
 def reader(name, other):
  g=gate(name, '''import os,time
from pathlib import Path
root=Path.cwd()
if os.environ.get('LA_LINT_CAPTURE'):
 (root/'STARTED_NAME').write_text('yes')
 deadline=time.monotonic()+3
 while not (root/'STARTED_OTHER').exists():
  assert time.monotonic()<deadline, 'capture readers did not overlap'
  time.sleep(.01)
else:
 marker=root/'running'
 descriptor=os.open(marker,os.O_CREAT|os.O_EXCL|os.O_WRONLY)
 try:
  time.sleep(.03)
  with open(os.environ['LA_LAUNCH_LOG'],'a') as out: out.write('engine\\n')
 finally:
  os.close(descriptor);marker.unlink()
print('OK')
'''.replace('STARTED_NAME',name).replace('STARTED_OTHER',other))
  g['capture_reader']=True;return g
 rows=[reader('first','second'),reader('second','first')]
 last=gate('last', '''from pathlib import Path
assert len(Path('all.launch').read_text().splitlines())==2
print('OK')
''');last['last']=True
 os.environ['LA_LINT_CAPTURE']=str(cap)
 records=[]
 with contextlib.redirect_stdout(io.StringIO()):r['drain'](rows,str(root),2,str(root),str(ledger),False,lambda *x:records.append(x),pooled=True)
 assert all(row[1]==0 and row[-1]==0 for row in records),records
 os.environ.pop('LA_LINT_CAPTURE')
 records=[]
 with contextlib.redirect_stdout(io.StringIO()):r['drain'](rows+[last],str(root),2,str(root),str(ledger),False,lambda *x:records.append(x),pooled=False)
 assert [row[1] for row in records]==[0,0,0] and [row[-1] for row in records]==[1,1,0],records
 strict=gate('strict', "import os\nwith open(os.environ['LA_LAUNCH_LOG'],'a') as out: out.write('engine\\n')\nprint('OK')\n")
 assert r['run_gate'](strict,str(root),str(root/'strict.launch'),False)[0]==1
 missing=cap/'absent';missing.mkdir();os.environ['LA_LINT_CAPTURE']=str(missing)
 fallback=rows[0]
 assert not r['effective_launcher'](fallback,True)
 doc=root/'gates.toml';doc.write_text('[[gate]]\nname="a"\nscript="a"\nkind="text"\nmarker="OK"\nmutation=["one","two"]\nneeds=["build"]\ncapture_reader=true\n')
 loaded=r['load_gates'](str(doc));assert loaded[0]['mutations']==['one','two']
 doc.write_text(doc.read_text().replace('capture_reader=true','capture_reader="true"'))
 try:r['load_gates'](str(doc))
 except ValueError:pass
 else:raise AssertionError('string capture_reader accepted')
 os.environ.pop('LA_LINT_CAPTURE',None)
 globals_=r['arm_scratch'].__globals__;globals_['ROOT']=str(root)
 ext=root/globals_['EXT_REL'];(ext/'scripts').mkdir(parents=True);(ext/'thirdparty').mkdir()
 build=ext/'scripts/build_extension.sh';build.write_text('#!/bin/sh\ntouch built\n');build.chmod(0o755)
 assert r['arm_scratch'](dict(needs=['build'],last=False),str(root)) and (root/'built').exists()
 for name,body in [('silent','exec sleep 2\n'),
                   ('printing',"printf 'PROGRESS_PAYLOAD\\n'; exec sleep 2\n"),
                   ('partial',"printf PARTIAL_PAYLOAD; exec sleep 2\n")]:
  serial=gate(name,body,shell=True);serial['timeout_s']=.5
  with contextlib.redirect_stdout(io.StringIO()): result=r['run_gate'](serial,str(root),str(root/(name+'.launch')),True)
  assert result[0]==2,(name,'serial deadline was not enforced',result)
  if name=='printing': assert 'PROGRESS_PAYLOAD' in result[1], 'output control never reached its marker'
  if name=='partial': assert 'PARTIAL_PAYLOAD' in result[1], 'partial-line control never reached its write'
  assert not any(thread.name.startswith('gate-output-') for thread in threading.enumerate()),'output reader survived deadline'
 descendants=gate('descendants', "sleep 20 &\n",shell=True)
 descendants['timeout_s']=.5
 with contextlib.redirect_stdout(io.StringIO()):result=r['run_gate'](descendants,str(root),str(root/'descendants.launch'),True)
 assert result[0]==2 and not any(thread.name.startswith('gate-output-') for thread in threading.enumerate()),result
 timeout_gate=gate('timeout', "exec sleep 2\n",shell=True)
 timeout_gate['timeout_s']=.5
 assert r['run_gate'](timeout_gate,str(root),str(root/'timeout.launch'),False)[0]==2
 import shutil
 globals_['stage_scratch']=lambda scratch:shutil.copytree(scripts,Path(scratch)/'scripts',dirs_exist_ok=True)
 globals_['arm_scratch']=lambda *args,**kwargs:True
 globals_['git']=lambda *args,**kwargs:None
 mutable=gate('mutable', "printf 'OK\\n'\n",shell=True)
 mutable['timeout_s']=.5
 mutation="python3 -c \"from pathlib import Path; Path('scripts/mutable').write_text('#!/bin/sh\\nexec sleep 2\\n')\""
 assert r['run_gate'](mutable,str(root),str(root/'mutable-baseline.launch'),False)[0]==0, 'mutable baseline did not run'
 output=io.StringIO()
 with contextlib.redirect_stdout(output): result=r['mutate_one'](mutable,mutation)
 assert result==2 and 'could not run under' in output.getvalue() and 'MUTATION_KILLED' not in output.getvalue(),output.getvalue()
 output=io.StringIO()
 skipped="python3 -c \"from pathlib import Path; Path('scripts/mutable').write_text('#!/bin/sh\\nexit 3\\n')\""
 with contextlib.redirect_stdout(output):result=r['mutate_one'](mutable,skipped)
 assert result==2 and 'could not run under' in output.getvalue() and 'MUTATION_KILLED' not in output.getvalue(),output.getvalue()
 print('gate runner: captured parallel readers, serial fallbacks, strict launch rejection, final ledger ordering, array mutations, boolean validation and build preparation passed')

import subprocess
source=(source_root/'scripts/lib_capture.sh').read_text()
with tempfile.TemporaryDirectory(prefix='la_rig_behavior.') as directory:
    root=Path(directory)
    (root/'lib_capture.sh').write_text(source)
    launcher=root/'run_sim_offscreen.sh'
    launcher.write_text('#!/bin/sh\necho EXPECTED_MARKER\nexit "$FAKE_RC"\n')
    launcher.chmod(0o755)
    for status, expected in [(0,0),(1,1),(124,2)]:
        run=subprocess.run(['bash','-c','source "$1/lib_capture.sh"; la_rig probe EXPECTED_MARKER res://probe','_',directory],
                           env=dict(os.environ,FAKE_RC=str(status),LA_LINT_CAPTURE=''),capture_output=True,text=True)
        assert run.returncode==expected,(status,run)
    (root/'capture').mkdir()
    run=subprocess.run(['bash','-c','source "$1/lib_capture.sh"; LA_LINT_CAPTURE="$1/capture" la_rig probe EXPECTED_MARKER res://probe','_',directory],capture_output=True,text=True)
    assert run.returncode==2 and 'EXPECTED_MARKER' not in run.stdout,run
    callers=[]
    for script in (source_root/'scripts').glob('check_bench*.sh'):
        callers.extend(line for line in script.read_text().splitlines() if line.startswith('out="$(la_rig '))
    assert len(callers)==7
    for line in callers:
        run=subprocess.run(['bash','-c',"la_rig() { echo EXPECTED_MARKER; return 1; }; PROBE=probe; "+line+'\nexit 99'],capture_output=True,text=True)
        assert run.returncode==1,(line,run)
print('runner rig failure controls passed')

import json
with tempfile.TemporaryDirectory(prefix='la_budget_behavior.') as directory:
    root=Path(directory);scripts=root/'scripts';scripts.mkdir();docs=root/'docs';docs.mkdir();capture=root/'capture';capture.mkdir();logs=root/'logs';logs.mkdir()
    for name in ['check_field_budget.sh','check_lint_budget.sh','lib_capture.sh']:
        (scripts/name).write_text((source_root/'scripts'/name).read_text())
    (scripts/'gate_runner.py').write_text((source_root/'scripts/gate_runner.py').read_text())
    (scripts/'lib_godot_lock.sh').write_text((source_root/'scripts/lib_godot_lock.sh').read_text())
    (docs/'FIELD_MS_CEILING').write_text('0\n');(docs/'LINT_SECONDS_CEILING').write_text('0\n')
    (capture/'arm').write_text('LADDER_ARM={"slice":"fixture"}\n');(capture/'rung').write_text('0\n')
    (capture/'report.json').write_text(json.dumps({'gauges':{'field_ms':{'max':1.25}}}))
    timing=root/'seconds';timing.write_text('1.0\tfirst\n1.0\tsecond\n')
    waits=root/'waits';waits.write_text('0.5\tGPU\n')
    env=dict(os.environ,LA_LINT_CAPTURE=str(capture),LA_LINT_TIMING_LOG=str(timing),LA_LOCK_WAIT_LOG=str(waits))
    for name,marker in [('field','FIELD_BUDGET='),('lint','LINT_BUDGET=')]:
        run=subprocess.run(['bash',str(scripts/('check_'+name+'_budget.sh'))],env=env,capture_output=True,text=True)
        assert run.returncode==3 and marker in run.stdout,(name,run)
    text=(source_root/'scripts/write_ceilings.sh').read_text()
    function=text[text.index('bank_from_lint() {'):text.index('\nbank_from_lint LINT_SECONDS_CEILING')]
    shell='TREE="$1"; LOG_DIR="$1/logs"; lower() { return 0; }; '+function+'\nbank_from_lint FIELD_MS_CEILING FIELD_BUDGET worst_ms 1\n'
    def bank():
        return subprocess.run(['bash','-c',shell,'_',str(root)],capture_output=True,text=True)
    log=logs/'agent_harness_lint_test.log'
    log.write_text('LINT_TREE='+str(root)+'\nFIELD_BUDGET={"worst_ms":1.25}\n')
    assert bank().returncode==0 and (docs/'FIELD_MS_CEILING').read_text().strip()=='0','incomplete/filtered/CPU run banked'
    log.write_text(log.read_text()+'LINT_BANKABLE=1\n')
    assert bank().returncode==0 and (docs/'FIELD_MS_CEILING').read_text().strip()=='2','complete full-run measurement did not bank'
print('budget bootstrap and complete-run banking controls passed')
