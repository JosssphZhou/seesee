#!/usr/bin/env python3
"""安装返工回归：真实包/桥接；精确中断和权限失败只在检查副本中注入。"""
from pathlib import Path
import argparse, hashlib, json, os, plistlib, re, signal, subprocess, time, uuid

parser = argparse.ArgumentParser()
parser.add_argument('--root', required=True)
parser.add_argument('--proof', required=True)
parser.add_argument('--script', required=True)
parser.add_argument('--baseline', action='store_true')
args = parser.parse_args()
root = Path(args.root).resolve()
assert root.parent == Path('/private/tmp') and root.name.startswith('ss-install-check-codex.')
proof = Path(args.proof).resolve(); proof.mkdir(parents=True, exist_ok=True)
source = Path(args.script).resolve(); text = source.read_text()
cases = root/('rework-'+uuid.uuid4().hex[:8]); cases.mkdir()
package = root/'seesee-v1.1.1-apple-silicon.zip'
old_zip = root/'seesee-v1.1.0-apple-silicon.zip'
backups = []; results = {}; children = []

def snapshot(directory):
    result = {}
    for path in directory.rglob('*'):
        if path.is_symlink(): result[str(path.relative_to(directory))] = 'link:'+os.readlink(path)
        elif path.is_file(): result[str(path.relative_to(directory))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result

def version(app): return plistlib.loads((app/'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
def prepare(name, old=False):
    directory = cases/name; directory.mkdir()
    if old: subprocess.run(['/usr/bin/ditto','-x','-k',str(old_zip),str(directory)],check=True)
    return directory

def env(directory):
    variables = os.environ.copy()
    for key in ['SEESEE_VERSION','SEESEE_ALLOW_DOWNGRADE']: variables.pop(key,None)
    variables.update(TMPDIR=str(root)+'/',SEESEE_ZIP=str(package), SEESEE_SHA256_FILE=str(package)+'.sha256', SEESEE_INSTALL_DIR=str(directory), SEESEE_TEST_SKIP_NOTARIZATION='1')
    return variables

def record(name, output, status):
    (proof/(name+'.txt')).write_text(output+f'\nexit={status}\n')
    for path in re.findall(r'^旧应用备份：(.+)$', output, re.M):
        if path not in backups: backups.append(path)

def install(name, directory, code=text, **extra):
    variables = env(directory); variables.update(extra)
    process = subprocess.run(['/bin/bash'],input=code,env=variables,text=True,capture_output=True,timeout=120)
    output = process.stdout+process.stderr; record(name,output,process.returncode)
    return process, output

def note(name, old_failed, fixed_passed):
    ok = old_failed if args.baseline else fixed_passed
    assert ok, (name, '未复现旧问题' if args.baseline else '修后检查失败')
    results[name] = '旧提交问题已复现' if args.baseline else '修后通过'
    print(name,results[name],flush=True)

try:
    for file in [package,old_zip]:
        assert hashlib.sha256(file.read_bytes()).hexdigest() == Path(str(file)+'.sha256').read_text().split()[0]
    directory = prepare('bridge',old=True); app = directory/'seesee.app'
    old_contents = snapshot(app)
    home = cases/'bridge-home'; home.mkdir()
    variables = os.environ.copy(); variables['CFFIXED_USER_HOME'] = str(home)
    bridge = subprocess.Popen([str(app/'Contents/MacOS/seesee'),'--mcp-stdio'],stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,env=variables)
    children.append(bridge); time.sleep(1)
    assert bridge.poll() is None
    opened = subprocess.check_output(['/usr/sbin/lsof','-nP','-p',str(bridge.pid)],text=True)
    (proof/'bridge-lsof.txt').write_text(opened)
    assert str(Path.home()/'Library/Application Support/seesee') not in opened
    ns = subprocess.run(['/usr/bin/osascript','-l','JavaScript','-e',f'ObjC.import("AppKit"); $.NSRunningApplication.runningApplicationWithProcessIdentifier({bridge.pid}).isNil() ? "nil" : "found"'],capture_output=True,text=True,check=True).stdout.strip()
    assert ns == 'nil'
    process, output = install('1-MCP桥接升级',directory)
    alive = bridge.poll() is None
    note('1-MCP桥接升级',process.returncode != 0 and '旧应用尚未退出' in output and version(app) == '1.1.0' and alive,process.returncode == 0 and version(app) == '1.1.1' and alive and '会话要重开' in output)
    results['bridge'] = {'pid':bridge.pid,'NSRunningApplication':ns,'survivedUpgrade':alive,'isolatedHome':str(home)}
    bridge.terminate(); bridge.wait(timeout=10)

    # 在原脚本副本的真实旧版改名之后暂停，精确命中极短的两次改名间隙。
    move = 'mv -n "$app" "$old_staged" || fail "无法保留旧应用。"'
    assert text.count(move) == 1
    for name, sig in [('2-SIGKILL恢复',signal.SIGKILL),('2b-SIGTERM恢复',signal.SIGTERM)]:
        if args.baseline and sig == signal.SIGTERM: continue
        directory = prepare(name,old=True); app = directory/'seesee.app'; before = snapshot(app)
        marker = directory/'paused'
        injected = text.replace(move,move+'\n    touch "$install_dir/paused"\n    sleep 60')
        check_script = cases/(name+'.sh'); check_script.write_text(injected)
        with (proof/(name+'-中断.txt')).open('w') as output_file:
            process = subprocess.Popen(['/bin/bash',str(check_script)],env=env(directory),stdout=output_file,stderr=subprocess.STDOUT,start_new_session=True)
            children.append(process)
            try:
                for _ in range(12000):
                    if marker.exists(): break
                    assert process.poll() is None, name
                    time.sleep(.005)
                assert marker.exists() and not app.exists()
                staged = list(directory.glob('.seesee-install.*/old.app')); assert len(staged) == 1
                (proof/(name+'-间隙.json')).write_text(json.dumps({'targetMissing':True,'oldStaged':str(staged[0]),'lockPID':(directory/'.seesee-install.lock/pid').read_text().strip() if (directory/'.seesee-install.lock/pid').exists() else None,'backupAlreadySaved':'旧应用备份：' in (proof/(name+'-中断.txt')).read_text(),'instrumentation':'仅在检查副本旧版真实改名后插入暂停，信号与重跑恢复执行真实路径'},ensure_ascii=False,indent=2)+'\n')
                os.killpg(process.pid,sig); status = process.wait(timeout=30)
            finally:
                if process.poll() is None: os.killpg(process.pid,signal.SIGKILL); process.wait(timeout=10)
            output_file.write(f'\nexit={status}\n')
        interrupted_output = (proof/(name+'-中断.txt')).read_text(); record(name+'-中断',interrupted_output,status)
        marker.unlink()
        if sig == signal.SIGTERM:
            assert status == 143 and snapshot(app) == before and not list(directory.glob('.seesee-install.*'))
            results[name] = '修后通过'; print(name,'修后通过',flush=True); continue
        process, output = install(name+'-重跑',directory)
        note(name,process.returncode != 0 and not app.exists() and (directory/'.seesee-install.lock').exists(),process.returncode == 0 and version(app) == '1.1.1' and '已恢复旧应用' in output and '.seesee-install.lock' in output and not list(directory.glob('.seesee-install.*')))

    directory = prepare('downgrade',old=True); app = directory/'seesee.app'
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes()); info['CFBundleShortVersionString'] = '1.1.2'
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info)); before = snapshot(app)
    process, output = install('3-拒绝降级',directory)
    note('3-拒绝降级',process.returncode == 0 and version(app) == '1.1.1',process.returncode != 0 and '停止降级' in output and snapshot(app) == before)
    if not args.baseline:
        process, output = install('3b-明确允许降级',directory,SEESEE_ALLOW_DOWNGRADE='1')
        assert process.returncode == 0 and version(app) == '1.1.1'; results['3b-明确允许降级']='修后通过'

    # 注入一个 rm 失败，其他删除仍用系统命令；不改变校验、复制或改名。
    directory = prepare('cleanup')
    injected = text.replace('export PATH=/usr/bin:/bin:/usr/sbin:/sbin','export PATH=/usr/bin:/bin:/usr/sbin:/sbin\nrm() { if [[ "$*" == *"$stage"* && -n "$stage" ]]; then printf "检查注入：暂存目录删除失败\\n" >&2; return 1; fi; /bin/rm "$@"; }',1)
    process, output = install('4-清理删除失败',directory,code=injected)
    note('4-清理删除失败',process.returncode != 0 and version(directory/'seesee.app') == '1.1.1',process.returncode == 0 and version(directory/'seesee.app') == '1.1.1' and '删除失败' in output and not (directory/'.seesee-install.lock').exists())

    directory = prepare('Ünï')
    process, output = install('5-UTF8路径引用',directory,LC_ALL='en_US.UTF-8')
    expected = "'"+str(directory/'seesee.app/Contents/MacOS/seesee')+"'"
    note('5-UTF8路径引用',process.returncode == 0 and expected not in output,process.returncode == 0 and expected in output)
    directory = prepare('truncated')
    # 断在最后一行调用之前；旧版已经执行安装，新版只有完整函数定义。
    process, output = install('5b-管道缺末行',directory,code=text.rstrip().rsplit('\n',1)[0]+'\n')
    note('5b-管道缺末行',(directory/'seesee.app').exists(),not (directory/'seesee.app').exists() and not list(directory.iterdir()))

    directory = prepare('fallback',old=True); before = snapshot(directory/'seesee.app')
    # 不重设 HOME、不碰真实废纸篓权限；仅模拟该路径 mktemp 返回 EACCES。
    injected = text.replace('export PATH=/usr/bin:/bin:/usr/sbin:/sbin','export PATH=/usr/bin:/bin:/usr/sbin:/sbin\nmktemp() { case "$*" in *"$HOME/.Trash/"*) return 1 ;; esac; /usr/bin/mktemp "$@"; }',1)
    process, output = install('6-废纸篓拒绝写入',directory,code=injected)
    backup = directory/'seesee-1.1.0.app'
    assert process.returncode == 0 and snapshot(backup) == before
    note('6-废纸篓提示', '确认新版没问题后可以删掉' not in output,'确认新版没问题后可以删掉' in output and str(backup) in output)
    if not args.baseline:
        for command in ['ditto','mv']:
            directory = prepare('fallback-'+command,old=True); before = snapshot(directory/'seesee.app')
            wrapper = '\n'+command+'() { case "$*" in *"$HOME/.Trash/"*) printf "检查注入：废纸篓操作拒绝\\n" >&2; return 1 ;; esac; '+('/bin/' if command == 'mv' else '/usr/bin/')+command+' "$@"; }'
            injected = text.replace('export PATH=/usr/bin:/bin:/usr/sbin:/sbin','export PATH=/usr/bin:/bin:/usr/sbin:/sbin'+wrapper,1)
            process, output = install('6b-废纸篓拒绝-'+command,directory,code=injected)
            assert process.returncode == 0 and snapshot(directory/'seesee-1.1.0.app') == before and '确认新版没问题后可以删掉' in output
            results['6b-废纸篓拒绝-'+command] = '修后通过'
    print('install_script_rework_check=passed',flush=True)
finally:
    for child in children:
        if child.poll() is None: child.terminate(); child.wait(timeout=10)
    results.update(source=str(source),sourceSHA256=hashlib.sha256(text.encode()).hexdigest(),baseline=args.baseline,ownedBackups=backups,allChildrenExited=all(p.poll() is not None for p in children),cases=str(cases))
    (proof/'结果.json').write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')
