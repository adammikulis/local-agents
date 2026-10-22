import contextlib, io, os, runpy, tempfile, sys, threading
from pathlib import Path
source_root=Path(sys.argv[1])
sys.dont_write_bytecode=True
for name in ('LA_LINT_TIMING_LOG','LA_LOCK_WAIT_LOG','LA_LINT_LAUNCHES','LA_LAUNCH_LOG'):os.environ.pop(name,None)
sys.path.insert(0,str(source_root/"scripts"))
r=runpy.run_path(str(source_root/"scripts/gate_runner.py"))
with tempfile.TemporaryDirectory(prefix='la_runner_proposal.') as directory:
 root=Path(directory);cap=root/'capture';cap.mkdir();scripts=root/'scripts';scripts.mkdir();ledger=root/'all.launch';ledger.write_text('')
 def gate(name, body, shell=False, **flags):
  path=scripts/name;path.write_text(('#!/bin/sh\n' if shell else '#!/usr/bin/env python3\n')+body);path.chmod(0o755)
  return dict(name=name,label=name,script='scripts/'+name,kind='headless',tier='fast',marker='OK',mutations=[],args=[],env={},needs=[],launches=False,capture_reader=False,last=False,exclusive=False,inputs=None,raw={},timeout_s=5,**flags)
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
  g['capture_reader']=True;g['kind']='gpu';g['tier']='slow';return g
 rows=[reader('first','second'),reader('second','first')]
 last=gate('last', '''from pathlib import Path
assert len(Path('all.launch').read_text().splitlines())==2
print('OK')
''');last['last']=True
 def drained(gates,capture):
  lint=r['Lint'](gates,str(root),2,str(root),str(ledger),False,None,set(range(len(gates))),None)
  records=[]
  lint.start();lint.release(capture)
  with contextlib.redirect_stdout(io.StringIO()):lint.replay(records.append)
  lint.finish()
  return [(job.rc,job.launches) for job in records]
 os.environ.pop('LA_LINT_CAPTURE',None)
 records=drained(rows,str(cap))
 assert records==[(0,0),(0,0)],records
 records=drained(rows+[last],None)
 assert [row[0] for row in records]==[0,0,0] and [row[1] for row in records]==[1,1,0],records
 timing=root/'seconds.log';timing.write_text('');os.environ['LA_LINT_TIMING_LOG']=str(timing)
 quick=[gate('quick_a',"print('OK')\n"),gate('quick_b',"print('OK')\n")]
 seen=gate('seen', '''import os
from pathlib import Path
assert len(Path(os.environ['LA_LINT_TIMING_LOG']).read_text().splitlines())==2
print('OK')
''');seen['last']=True
 records=drained(quick+[seen],None)
 assert [row[0] for row in records]==[0,0,0] and len(timing.read_text().splitlines())==2,(records,timing.read_text())
 os.environ.pop('LA_LINT_TIMING_LOG')
 strict=gate('strict', "import os\nwith open(os.environ['LA_LAUNCH_LOG'],'a') as out: out.write('engine\\n')\nprint('OK')\n")
 assert r['run_gate'](strict,str(root),str(root/'strict.launch'))[0]==1
 missing=cap/'absent';missing.mkdir();os.environ['LA_LINT_CAPTURE']=str(missing)
 fallback=rows[0]
 assert not r['effective_launcher'](fallback,True)
 doc=root/'gates.toml';doc.write_text('[[gate]]\nname="a"\nscript="a"\nkind="text"\nmarker="OK"\nmutation=["one","two"]\nneeds=["build"]\ncapture_reader=true\n')
 loaded=r['load_gates'](str(doc));assert loaded[0]['mutations']==[{'cmd':cmd,'exit':None,'says':None} for cmd in ['one','two']]
 doc.write_text(doc.read_text().replace('capture_reader=true','capture_reader="true"'))
 try:r['load_gates'](str(doc))
 except ValueError:pass
 else:raise AssertionError('string capture_reader accepted')
 os.environ.pop('LA_LINT_CAPTURE',None)
 globals_=r['arm_scratch'].__globals__;globals_['ROOT']=str(root)
 ext=root/globals_['EXT_REL'];(ext/'scripts').mkdir(parents=True);(ext/'thirdparty').mkdir()
 build=ext/'scripts/build_extension.sh';build.write_text('#!/bin/sh\ntouch built\n');build.chmod(0o755)
 assert r['arm_scratch'](dict(needs=['build'],last=False),str(root)) and (root/'built').exists()
 from concurrent.futures import ThreadPoolExecutor
 cases=[('silent','exec sleep 20\n'),('printing',"printf 'PROGRESS_PAYLOAD\\n'; exec sleep 20\n"),
        ('partial',"printf PARTIAL_PAYLOAD; exec sleep 20\n"),('descendants',"sleep 20 &\n"),('timeout',"exec sleep 20\n"),
        ('launch_timeout','printf "engine\\n" >> "$LA_LAUNCH_LOG"; exec sleep 20\n')]
 def deadline(case):
  name,body=case
  held=gate(name,body,shell=True);held['timeout_s']=5
  streamed=[];return name,streamed,r['run_gate'](held,str(root),str(root/(name+'.launch')),streamed.append)
 with ThreadPoolExecutor(max_workers=len(cases)) as pool:ran={n:(streamed,result) for n,streamed,result in pool.map(deadline,cases)}
 for name in ('silent','printing','partial'):
  streamed,result=ran[name]
  assert 'LINT_SLOW: %s ran'%name in ''.join(streamed),(name,'the deadline message never reached the sink',streamed)
  assert result[0]==1,(name,'a gate past its budget must FAIL, not be unrunnable',result)
  if name=='printing': assert 'PROGRESS_PAYLOAD' in result[1] and 'PROGRESS_PAYLOAD' in ''.join(streamed), 'output control never reached its marker'
  if name=='partial': assert 'PARTIAL_PAYLOAD' in result[1], 'partial-line control never reached its write'
 assert ran['descendants'][1][0]==1,ran['descendants']
 assert ran['timeout'][1][0]==1
 assert ran['launch_timeout'][1][0]==1 and 'despite its no-launch declaration' in ran['launch_timeout'][1][1],ran['launch_timeout']
 assert not any(thread.name.startswith('gate-output-') for thread in threading.enumerate()),'output reader survived deadline'
 import shutil
 globals_['stage_scratch']=lambda scratch:shutil.copytree(scripts,Path(scratch)/'scripts',dirs_exist_ok=True)
 globals_['arm_scratch']=lambda *args,**kwargs:True
 globals_['git']=lambda *args,**kwargs:None
 mutable=gate('mutable', "printf 'OK\\n'\n",shell=True)
 mutable['timeout_s']=5
 mutation="python3 -c \"from pathlib import Path; Path('scripts/mutable').write_text('#!/bin/sh\\nexec sleep 20\\n')\""
 baseline = r['run_gate'](dict(mutable, timeout_s=5),str(root),str(root/'mutable-baseline.launch'))
 assert baseline[0]==0, ('mutable baseline did not run', baseline)
 output=io.StringIO()
 with contextlib.redirect_stdout(output): result=r['mutate_one'](mutable,r['mutation_of']('mutable',mutation))
 assert result==2 and 'ran past its time budget' in output.getvalue() and 'MUTATION_KILLED' not in output.getvalue(),output.getvalue()
 output=io.StringIO()
 skipped="python3 -c \"from pathlib import Path; Path('scripts/mutable').write_text('#!/bin/sh\\nexit 3\\n')\""
 with contextlib.redirect_stdout(output):result=r['mutate_one'](mutable,r['mutation_of']('mutable',skipped))
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
    timing=root/'seconds';timing.write_text('1.0\tfirst\tslow\n1.0\tsecond\tslow\n')
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

from types import SimpleNamespace
with tempfile.TemporaryDirectory(prefix='la_launch_unavailable.') as directory:
    subprocess.run(['git','-C',directory,'init','-q'],check=True)
    glob=r['cmd_lint'].__globals__
    glob['ROOT']=directory
    row=dict(name='strict',label='strict',script='strict',kind='text',tier='fast',marker='OK',launches=False,capture_reader=False,last=False,exclusive=False,inputs=None,raw={},needs=[],timeout_s=5)
    glob['load_doc']=lambda:([row],{})
    glob['make_capture']=lambda **kwargs:(directory,'')
    glob['note_seconds']=lambda *args:None
    def lint_once(rc,out):
        def fake(g,root,ledger,sink=None,extra_env=None):
            with open(ledger,'a') as engine: engine.write('engine\n')
            return rc,out,1.0
        glob['run_gate']=fake
        output=io.StringIO()
        with contextlib.redirect_stdout(output):
            status=r['cmd_lint'](SimpleNamespace(only=None,body=False,jobs=1,timing=False,json=None,no_cache=True,tier='fast',affected_by=None))
        os.environ.pop('LA_LAUNCH_LOG',None)
        return status,output.getvalue()
    status,text=lint_once(2,'no completed verdict')
    assert status==2 and 'LINT_UNRUNNABLE: strict' in text and 'LINT_FAIL:' not in text,text
    status,text=lint_once(0,'OK')
    assert status==1 and 'LINT_FAIL: strict' in text and 'fast-tier' in text,text
print('unavailable launch violations stay unexamined')

with tempfile.TemporaryDirectory(prefix='la_tiers.') as directory:
    doc=Path(directory)/'gates.toml'
    def tiers(rows):
        doc.write_text(''.join('[[gate]]\nname="%s"\nscript="s"\nmarker="OK"\n%s\n' % (name,body) for name,body in rows))
        import tomllib
        return {g['name']:g['tier'] for g in r['parse_doc'](tomllib.loads(doc.read_text()),{})[0]}
    got=tiers([('text','kind="text"'),('headless_quiet','kind="headless"\nlaunches=false'),('headless','kind="headless"'),
               ('gpu','kind="gpu"\nlaunches=false'),('reader','kind="text"\ncapture_reader=true'),
               ('slow_text','kind="text"\ntier="slow"')])
    assert got=={'text':'fast','headless_quiet':'fast','headless':'slow','gpu':'slow','reader':'slow','slow_text':'slow'},got
    for body,said in [('kind="headless"\ntier="fast"','launches'),('kind="gpu"\ntier="fast"','device'),
                      ('kind="text"\ncapture_reader=true\ntier="fast"','capture'),('kind="text"\ntier="fast"','restates'),
                      ('kind="gpu"\ntier="slow"','restates'),('kind="text"\ntier="medium"','tier must be')]:
        try:tiers([('row',body)])
        except ValueError as error:assert said in str(error),(body,error)
        else:raise AssertionError('a contradicting or redundant tier was accepted: '+body)
    quiet=dict(name='q',label='q',marker='OK',kind='text',tier='fast',launches=False,capture_reader=False)
    assert r['verdict'](quiet,0,'OK',1,False)=='undeclared_launch','a fast gate that launched passed'
    assert r['verdict'](dict(quiet,launches=True,tier='slow'),0,'OK',1,False)=='pass','a slow launcher failed'
    assert r['verdict'](dict(quiet,kind='gpu',tier='slow'),0,'OK',1,False)=='undeclared_launch','a slow gate declaring no launch launched'
print('tier derivation, declared-tier contradictions and fast-tier launches passed')

with tempfile.TemporaryDirectory(prefix='la_seconds.') as directory:
    work=Path(directory);(work/'docs').mkdir()
    entries=work/'docs/GATE_SECONDS'
    entries.write_text('# a comment\nquick 1\nslowish 8 # trailing\n')
    read=r['read_seconds'](str(work))
    assert read=={'quick':1,'slowish':8},read
    budget=r['budget_of']
    assert budget('quick','fast',read)==60 and budget('slowish','slow',read)==80,'a budget is ten times its entry, never under sixty seconds'
    assert budget('unlisted','fast',read)==30 and budget('unlisted','slow',read)==300,'an unlisted gate has its tier default'
    entries.write_text('quick one\n')
    try:r['read_seconds'](str(work))
    except ValueError:pass
    else:raise AssertionError('a malformed entry was accepted')
    g=r['run_gate'].__globals__
    glob_root=g['ROOT'];g['ROOT']=str(work)
    try:
        entries.write_text('quick 4\nslowish 2\n')
        log=work/'lint.log'
        log.write_text('LINT_TIMING={"quick.sh":9.2,"slowish.sh":0.4,"cached.sh":0.0,"new.sh":0.2}\nAll fast-tier lint gates passed (x).\n')
        g['load_doc']=lambda:([dict(name=n,label=n+'.sh') for n in ('quick','slowish','cached','new')],{})
        assert r['cmd_bank_seconds'](str(log))==0
        banked=r['read_seconds'](str(work))
        assert banked=={'quick':4,'slowish':1,'new':1},('an entry rose, a cached gate was banked or a new one was not',banked)
        log.write_text('LINT_TIMING={"quick.sh":1.0}\n')
        entries.write_text('quick 4\n')
        assert r['cmd_bank_seconds'](str(log))==0 and r['read_seconds'](str(work))=={'quick':4},'a lint that did not pass was banked'
    finally:
        g['ROOT']=glob_root
print('a gate has a time budget from docs/GATE_SECONDS, which only falls')

import shutil, subprocess
with tempfile.TemporaryDirectory(prefix='la_affected.') as directory:
    repo=Path(directory)
    def sh(*argv):
        return subprocess.run(['git','-C',directory,'-c','user.name=gate','-c','user.email=gate@local']+list(argv),check=True,capture_output=True,text=True).stdout.strip()
    def put(rel,text,mode=0o755):
        path=repo/rel;path.parent.mkdir(parents=True,exist_ok=True);path.write_text(text);path.chmod(mode)
    for name in ('gate_runner.py','lib_gate_cache.py'):
        put('scripts/'+name,(source_root/'scripts'/name).read_text(),0o644)
    put('scripts/lint_capture.sh','#!/bin/sh\ntouch "$PWD/capture_ran"\nmkdir -p "$PWD/.cap" && printf "%s\\n" "$PWD/.cap"\n')
    put('scripts/check_fast.sh','#!/bin/sh\necho "fast: OK"\n')
    for name in ('data','other','lib','last'):
        put('scripts/check_%s.sh'%name,'#!/bin/sh\n%secho "%s: OK"\n'%('. "$(dirname "$0")/lib_helper.sh"\n' if name=='lib' else '',name))
    put('scripts/lib_helper.sh','x=1\n',0o644)
    put('data/a.txt','a\n',0o644);put('other/b.txt','b\n',0o644);put('docs/note.md','n\n',0o644)
    put('.gitignore','capture_ran\n.cap/\n',0o644)
    def row(name,body):
        return '[[gate]]\nname="check_%s"\nscript="scripts/check_%s.sh"\nmarker="^%s: OK"\n%s\n'%(name,name,name,body)
    slow='kind="gpu"\nlaunches=false\n'
    rows={'fast':row('fast','kind="text"'),'data':row('data',slow+'inputs=["data/**"]'),
          'other':row('other',slow+'inputs=["@own"]'),'lib':row('lib',slow+'inputs=["nowhere/**"]'),
          'last':row('last',slow+'last=true')}
    def write_rows(**over):
        put('scripts/gates.toml','[sets]\nown=["other/**"]\n\n'+''.join({**rows,**over}.values()),0o644)
    write_rows()
    sh('init','-q');sh('add','-A');sh('commit','-q','-m','base');base=sh('rev-parse','HEAD')
    env={k:v for k,v in os.environ.items() if k not in ('CI','LA_INTEGRATE_BRANCH','LA_LAUNCH_LOG','LA_LINT_CAPTURE','LA_NO_GPU')}
    def run(*flags):
        (repo/'capture_ran').unlink(missing_ok=True)
        done=subprocess.run([sys.executable,'scripts/gate_runner.py','--no-cache','--affected-by',base,*flags],cwd=directory,env=env,capture_output=True,text=True)
        picked={ln.split(': ',1)[1].split(' (')[0]:ln.split(' (',1)[1].rstrip(')') for ln in done.stdout.splitlines() if ln.startswith('LINT_SELECTED: ')}
        return done.returncode,done.stdout,picked,(repo/'capture_ran').exists()
    def change(edit):
        sh('checkout','-q','-B','work',base);edit();sh('add','-A');sh('commit','-q','-m','change')
    change(lambda:put('docs/note.md','changed\n',0o644))
    code,out,picked,engine=run('--slow')
    assert code==0 and picked=={} and not engine and 'LINT_AFFECTED={"changed":1,"selected":0,"skipped":4}' in out,(code,out,picked,engine)
    assert 'LINT_UNAFFECTED: check_data.sh, check_other.sh, check_lib.sh, check_last.sh' in out,out
    code,out,picked,engine=run('--all')
    assert code==0 and picked=={} and not engine and 'fast: OK' in out and 'data: OK' not in out,(code,out,picked,engine)
    change(lambda:put('data/a.txt','changed\n',0o644))
    code,out,picked,engine=run('--slow')
    assert picked=={'check_data.sh':'data/a.txt','check_last.sh':'it weighs the slow gates selected beside it'} and engine and 'other: OK' not in out,(code,out,picked,engine)
    change(lambda:put('scripts/lib_helper.sh','x=2\n',0o644))
    code,out,picked,engine=run('--slow')
    assert picked.get('check_lib.sh')=='scripts/lib_helper.sh' and 'check_data.sh' not in picked,(picked,out)
    change(lambda:(repo/'data/a.txt').unlink())
    code,out,picked,engine=run('--slow')
    assert picked.get('check_data.sh')=='data/a.txt',('a deleted input was not noticed',picked)
    change(lambda:sh('mv','other/b.txt','other/c.txt'))
    code,out,picked,engine=run('--slow')
    assert picked.get('check_other.sh')=='other/b.txt' and 'check_data.sh' not in picked,('a renamed input was not noticed by its old path',picked)
    change(lambda:write_rows(other=row('other',slow+'inputs=["@own","extra/**"]')))
    code,out,picked,engine=run('--slow')
    assert picked.get('check_other.sh')=='its row in scripts/gates.toml changed' and 'check_data.sh' not in picked,(picked,out)
    change(lambda:put('scripts/gates.toml',(repo/'scripts/gates.toml').read_text().replace('own=["other/**"]','own=["elsewhere/**"]'),0o644))
    code,out,picked,engine=run('--slow')
    assert picked.get('check_other.sh')=='its row in scripts/gates.toml changed' and 'check_data.sh' not in picked,('a changed [sets] entry was not noticed',picked)
    change(lambda:(write_rows(bare=row('bare',slow)),put('scripts/check_bare.sh','#!/bin/sh\necho "bare: OK"\n'),put('docs/note.md','again\n',0o644)))
    code,out,picked,engine=run('--slow')
    assert picked.get('check_bare.sh')=='declares no inputs' and 'check_data.sh' not in picked and engine,(picked,out)
    uncommitted=lambda:(repo/'data/new.txt').write_text('fresh\n')
    sh('checkout','-q','-B','work',base);uncommitted()
    code,out,picked,engine=run('--slow')
    assert picked.get('check_data.sh')=='data/new.txt',('an uncommitted file was not noticed',picked)
print('affected selection: inputs, scripts and libs, deletions, renames, rows, sets, no-input rows, last rows and no engine on a docs diff passed')

with tempfile.TemporaryDirectory(prefix='la_fast_budget.') as directory:
    root=Path(directory);scripts=root/'scripts';scripts.mkdir();docs=root/'docs';docs.mkdir()
    for name in ('check_lint_fast_budget.sh','check_lint_budget.sh'):
        (scripts/name).write_text((source_root/'scripts'/name).read_text())
    (scripts/'gate_runner.py').write_text((source_root/'scripts/gate_runner.py').read_text())
    (scripts/'lib_godot_lock.sh').write_text((source_root/'scripts/lib_godot_lock.sh').read_text())
    (docs/'LINT_FAST_SECONDS_CEILING').write_text('5\n');(docs/'LINT_SECONDS_CEILING').write_text('5\n')
    def weigh(name,lines):
        timing=root/'seconds';timing.write_text(lines)
        return subprocess.run(['bash',str(scripts/name)],env=dict(os.environ,LA_LINT_TIMING_LOG=str(timing),LA_LOCK_WAIT_LOG='/dev/null'),capture_output=True,text=True).returncode
    quick='1.0\ta\tfast\n1.0\tb\tfast\n'
    assert weigh('check_lint_fast_budget.sh',quick+'999.0\tengine\tslow\n')==0,'a slow gate counted against the fast tier'
    assert weigh('check_lint_fast_budget.sh',quick+'999.0\tdrag\tfast\n')==1,'a slow fast-tier gate passed'
    assert weigh('check_lint_fast_budget.sh','999.0\tengine\tslow\n999.0\tcapture\tslow\n')==2,'a run with no fast gate was weighed'
    slowlines='1.0\tc\tslow\n1.0\td\tslow\n'
    assert weigh('check_lint_budget.sh',slowlines+'999.0\tdrag\tfast\n')==0,'a fast gate counted against the slow tier'
    assert weigh('check_lint_budget.sh',slowlines+'999.0\tdrag\tslow\n')==1,'a slow-tier overrun passed'
print('fast and slow budgets each weigh only their own tier')
