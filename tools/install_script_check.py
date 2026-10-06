#!/usr/bin/env python3
"""真实本地包、真实旧版进程、隔离安装目录；不启动正式应用。"""
from pathlib import Path
import argparse, hashlib, json, os, plistlib, re, signal, subprocess, time, uuid

parser = argparse.ArgumentParser()
parser.add_argument('--root', required=True)
parser.add_argument('--proof', required=True)
parser.add_argument('--script', type=Path)
parser.add_argument('--expect-bridge-block', action='store_true')
args = parser.parse_args()
root = Path(args.root).resolve()
assert root.parent == Path('/private/tmp') and root.name.startswith('ss-install-check-codex.')
proof = Path(args.proof).resolve(); proof.mkdir(parents=True, exist_ok=True)
script = args.script.resolve() if args.script else Path(__file__).resolve().parents[1] / 'scripts/install.sh'
package = root/'seesee-v1.1.1-apple-silicon.zip'; checksum = Path(str(package)+'.sha256')
old_zip = root/'seesee-v1.1.0-apple-silicon.zip'
domain = 'ai.openmy.seesee.install-check.'+uuid.uuid4().hex
cases = root/('cases-'+uuid.uuid4().hex[:8]); cases.mkdir()
processes = []; bridges = []; backups = []

def run(*command, **kw): return subprocess.run(command, check=True, **kw)
def snapshot(directory):
    result = {}
    for file in sorted(directory.rglob('*')):
        if file.is_symlink(): result[str(file.relative_to(directory))] = 'link:'+os.readlink(file)
        elif file.is_file(): result[str(file.relative_to(directory))] = hashlib.sha256(file.read_bytes()).hexdigest()
    return result
def pids(executable):
    lines = subprocess.check_output(['/bin/ps','-axww','-o','pid=,comm='], text=True).splitlines()
    return [int(line.strip().split(None,1)[0]) for line in lines if len(line.strip().split(None,1)) == 2 and line.strip().split(None,1)[1].startswith('/') and Path(line.strip().split(None,1)[1]).resolve() == executable.resolve()]
def install(name, directory, expected=0, pipe=False, **variables):
    env = os.environ.copy()
    for key in ['SEESEE_VERSION','SEESEE_ZIP','SEESEE_SHA256_FILE','SEESEE_INSTALL_DIR','SEESEE_TEST_SKIP_NOTARIZATION','SEESEE_ALLOW_DOWNGRADE']: env.pop(key,None)
    env.update(TMPDIR=str(root)+'/',SEESEE_ZIP=str(package), SEESEE_SHA256_FILE=str(checksum), SEESEE_INSTALL_DIR=str(directory), SEESEE_TEST_SKIP_NOTARIZATION='1')
    env.update(variables)
    command = ['/bin/bash'] if pipe else ['/bin/bash',str(script)]
    result = subprocess.run(command, input=script.read_text() if pipe else None, env=env, capture_output=True, text=True, timeout=120)
    (proof/(name+'.txt')).write_text(result.stdout+result.stderr+f'\nexit={result.returncode}\n')
    if expected == 0: assert result.returncode == 0, (name,result.stdout,result.stderr)
    else: assert result.returncode != 0, (name,result.stdout,result.stderr)
    print(name, 'passed', flush=True)
    return result.stdout+result.stderr
def version(app): return plistlib.loads((app/'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
def prepare_old(directory, identifier=domain):
    directory.mkdir(parents=True)
    run('/usr/bin/ditto','-x','-k',str(old_zip),str(directory))
    app = directory/'seesee.app'
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes()); assert info['CFBundleShortVersionString'] == '1.1.0'
    info['CFBundleIdentifier'] = identifier
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    run('/usr/bin/codesign','--force','--deep','--sign','-',str(app),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    return app
def launch(app, home):
    home.mkdir(parents=True,exist_ok=True)
    pid = int(subprocess.check_output([str(root/'background'),str(root),str(app),str(home)], text=True).strip())
    processes.append((pid,app/'Contents/MacOS/seesee'))
    return pid
def alive(pid):
    try: os.kill(pid,0); return True
    except ProcessLookupError: return False
def user_data(home):
    result = {}
    for directory in [home/'Library/Application Support/seesee',home/'Movies/seesee']:
        for name, digest in snapshot(directory).items():
            if not name.startswith('agent-link/'): result[str(directory.relative_to(home))+'/'+name] = digest
    return result

boss_executable = Path('/Applications/seesee.app/Contents/MacOS/seesee')
boss_pids = pids(boss_executable)
result = {}
try:
    assert hashlib.sha256(old_zip.read_bytes()).hexdigest() == Path(str(old_zip)+'.sha256').read_text().split()[0]
    first = cases/"首装 apps'路径"; first.mkdir()
    text = install('1-首装-pipe-bash',first,pipe=True)
    assert version(first/'seesee.app') == '1.1.1'
    executable = str(first/'seesee.app/Contents/MacOS/seesee')
    quoted = "'"+executable.replace("'", "'\\''")+"'"
    assert 'claude mcp add --scope user seesee -- '+quoted+' --mcp-stdio' in text
    original = snapshot(first); inode = (first/'seesee.app').stat().st_ino
    install('2-同版本不重装',first)
    assert snapshot(first) == original and (first/'seesee.app').stat().st_ino == inode

    bad = cases/'bad.sha256'; bad.write_text('0'*64+'  '+package.name+'\n')
    install('3-校验和失败',first,expected=1,SEESEE_SHA256_FILE=str(bad))
    assert snapshot(first) == original
    install('4-未公证包拒绝',first,expected=1,SEESEE_TEST_SKIP_NOTARIZATION='0')
    assert snapshot(first) == original
    install('5-低版本拒绝',first,expected=1,SEESEE_VERSION='v1.1.0')
    assert snapshot(first) == original
    # TEST只跳过公证；真实ad-hoc包仍须在Developer ID检查处拒绝。
    adhoc_dir = cases/'adhoc'; adhoc_dir.mkdir()
    run('/usr/bin/ditto',str(first/'seesee.app'),str(adhoc_dir/'seesee.app'))
    run('/usr/bin/codesign','--force','--deep','--sign','-',str(adhoc_dir/'seesee.app'),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    adhoc_zip = cases/'adhoc.zip'
    run('/usr/bin/ditto','-c','-k','--sequesterRsrc','--keepParent',str(adhoc_dir/'seesee.app'),str(adhoc_zip))
    adhoc_sha = cases/'adhoc.sha256'; adhoc_sha.write_text(hashlib.sha256(adhoc_zip.read_bytes()).hexdigest()+'  adhoc.zip\n')
    install('6-TEST仍拒绝非DeveloperID',first,expected=1,SEESEE_ZIP=str(adhoc_zip),SEESEE_SHA256_FILE=str(adhoc_sha))
    assert snapshot(first) == original
    text = install('8-线上旧包链接校验与最低版本',first,expected=1,SEESEE_ZIP=str(old_zip),SEESEE_SHA256_FILE=str(Path(str(old_zip)+'.sha256')))
    assert '包内应用必须是 1.1.1' in text and snapshot(first) == original

    upgrade = cases/'升级 apps'; old = prepare_old(upgrade)
    decoy = prepare_old(cases/'其他副本')
    home = cases/'isolated-home'; media = home/'Movies/seesee'; support = home/'Library/Application Support/seesee'
    media.mkdir(parents=True); support.mkdir(parents=True)
    (support/'queue.json').write_text('[ \n ]'); (support/'用户数据.txt').write_text('保留这份记录')
    (media/'用户视频.mp4').write_bytes(b'preserved-user-media')
    run('/usr/bin/defaults','write',domain,'MediaFolderPath',str(media))
    target_pid = launch(old,home)
    decoy_pid = launch(decoy,cases/'decoy-home')
    for _ in range(100):
        if target_pid in pids(old/'Contents/MacOS/seesee') and (support/'queue.json').read_text() != '[ \n ]': break
        time.sleep(.1)
    assert target_pid in pids(old/'Contents/MacOS/seesee') and alive(decoy_pid)
    opened = subprocess.check_output(['/usr/sbin/lsof','-nP','-p',str(target_pid)],text=True)
    (proof/'升级前副本-lsof.txt').write_text(opened)
    assert str(Path.home()/'Library/Application Support/seesee') not in opened
    data_paths = [Path(line[line.index('/'):]).resolve() for line in opened.splitlines() if 'Application Support/seesee' in line]
    assert all(path.is_relative_to(home) for path in data_paths)
    (proof/'旧副本隔离回读.json').write_text(json.dumps({'dataPathsHeldAtLsof':[str(p) for p in data_paths],'queueWrittenByOldApp':(support/'queue.json').read_text() != '[ \n ]','home':str(home),'bundleID':domain,'note':'只核对实际持有的数据描述符；不把没有持有描述符当成越界。旧版是否写入隔离队列另行回读。'},ensure_ascii=False,indent=2)+'\n')
    bridge_env = os.environ.copy(); bridge_env['CFFIXED_USER_HOME'] = str(home)
    bridge = subprocess.Popen([str(old/'Contents/MacOS/seesee'),'--mcp-stdio'],stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,env=bridge_env)
    bridges.append(bridge); time.sleep(1)
    assert bridge.poll() is None
    before_data = user_data(home); before_old = snapshot(old)
    text = install('7-运行中升级',upgrade,expected=1 if args.expect_bridge_block else 0)
    for _ in range(50):
        if not alive(target_pid): break
        time.sleep(.1)
    assert not alive(target_pid) and alive(decoy_pid) and bridge.poll() is None
    if args.expect_bridge_block:
        assert '旧应用尚未退出' in text and version(old) == '1.1.0' and snapshot(old) == before_old
        assert user_data(home) == before_data and pids(boss_executable) == boss_pids
        (proof/'旧提交挡路回读.json').write_text(json.dumps({'bridgePID':bridge.pid,'bridgeSurvived':True,'oldGUIExited':True,'decoySurvived':True,'oldAppUnchanged':True,'userDataUnchanged':True,'bossPIDs':boss_pids},ensure_ascii=False,indent=2)+'\n')
        print('旧提交：图形应用已退出，桥接仍在，升级被误拦截；回归已复现',flush=True)
        raise SystemExit(0)
    backup = Path(re.search(r'^旧应用备份：(.+)$',text,re.M)[1])
    backups.append((backup,domain))
    assert backup.name.startswith('seesee-1.1.0') and version(backup) == '1.1.0'
    assert snapshot(backup) == before_old and version(upgrade/'seesee.app') == '1.1.1'
    assert user_data(home) == before_data
    # SIGTERM/SIGKILL 精确中断点由 install_script_rework_check.py 单独验证。
    assert all(alive(pid) for pid in boss_pids) and pids(boss_executable) == boss_pids
    result = {'firstInstall':True,'sameVersionInodeUnchanged':True,'checksumFailureDirectoryUnchanged':True,'notarizationFailureDirectoryUnchanged':True,'testStillChecksDeveloperID':True,'oldVersion':'1.1.0','installedVersion':'1.1.1','oldPID':target_pid,'oldExited':True,'decoyPID':decoy_pid,'decoySurvived':True,'backup':str(backup),'backupEqual':True,'bridgePID':bridge.pid,'bridgeSurvived':bridge.poll() is None,'dataBefore':before_data,'dataAfter':user_data(home),'bossPIDsUnchanged':boss_pids,'oldCloneChanges':'仅改独立测试bundle id、ad-hoc重签及隔离家目录；旧版代码与工具来自线上v1.1.0','sameTestBundleIDForOldAndDecoy':domain}
    (proof/'路径回读.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print('install_script_check=passed',flush=True)
finally:
    for bridge in bridges:
        if bridge.poll() is None: bridge.terminate()
        bridge.wait(timeout=10)
    quit_script = '''use framework "AppKit"
on run argv
set runningApp to current application's NSRunningApplication's runningApplicationWithProcessIdentifier:((item 1 of argv) as integer)
if runningApp is missing value then return
set actualURL to runningApp's executableURL()'s URLByResolvingSymlinksInPath()
set expectedURL to (current application's NSURL's fileURLWithPath:(item 2 of argv))'s URLByResolvingSymlinksInPath()
if (actualURL's isEqual:expectedURL) as boolean is false then error "路径不符"
runningApp's terminate()
end run'''
    for pid, executable in processes:
        if alive(pid):
            assert executable.is_relative_to(root) and pid in pids(executable)
            subprocess.run(['/usr/bin/osascript','-l','AppleScript','-e',quit_script,str(pid),str(executable)],capture_output=True)
            for _ in range(50):
                if not alive(pid): break
                time.sleep(.1)
            if alive(pid): os.kill(pid,signal.SIGKILL)
    subprocess.run(['/usr/bin/defaults','delete',domain],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    (proof/'进程清理.json').write_text(json.dumps({'bridgePIDs':[p.pid for p in bridges],'bridgesExited':all(p.poll() is not None for p in bridges),'ownedPIDs':[pid for pid,_ in processes],'allExited':all(not alive(pid) for pid,_ in processes),'domain':domain,'bossPIDs':pids(boss_executable),'ownedBackups':[str(p) for p,_ in backups]},ensure_ascii=False,indent=2)+'\n')
