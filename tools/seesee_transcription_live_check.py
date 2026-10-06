#!/usr/bin/env python3
"""真实隔离应用、stdio MCP、无字幕真实媒体；不发送 agent 消息、不操作键鼠。"""
from pathlib import Path
import argparse, hashlib, uuid, http.server, json, os, plistlib, select, shutil, signal, socket, subprocess, tempfile, threading, time, urllib.parse

parser = argparse.ArgumentParser()
parser.add_argument('--media', required=True)
parser.add_argument('--language', choices=['en', 'zh'], required=True)
parser.add_argument('--proof', required=True)
parser.add_argument('--app', default='dist/seesee.app')
parser.add_argument('--claude', action='store_true', help='真实 URL-only Claude 会话')
parser.add_argument('--correct-original', action='store_true', help='真实Claude纠正原文，并核对初版退回')
parser.add_argument('--fixtures', action='store_true', help='实际应用的下载字幕构造条目验证')
parser.add_argument('--helper', default='/private/tmp/seesee-asr-background-codex')
args = parser.parse_args()
proof = Path(args.proof).resolve(); proof.mkdir(parents=True, exist_ok=True)
media = Path(args.media).resolve()
assert media.is_file()
root = Path(tempfile.mkdtemp(prefix='ssasr.', dir='/private/tmp')).resolve()
if args.correct_original:
    assert args.claude and args.language == 'en' and not args.fixtures
bundle_id = 'ai.openmy.seesee.correct-original.' + uuid.uuid4().hex[:8] if args.correct_original else 'ai.openmy.seesee.mcp'
app = root/'check.app'; home = root/'home'
data_dir = home/'Library/Application Support/seesee'; movies = home/'Movies/seesee'
queues = [p for p in [Path.home() / 'Library/Application Support/seesee/queue.json'] if p.is_file()]
playback_fields = {'playbackPosition', 'watchedAt', 'watchStatus', 'hasPlayedThreeSeconds', 'inInbox'}
def hashes():
    if not args.correct_original:
        return {str(p): hashlib.sha1(p.read_bytes()).hexdigest() for p in queues}
    result = {}
    for path in queues:
        rows = json.loads(path.read_text())
        fixed = [{k:v for k,v in row.items() if k not in playback_fields} for row in rows]
        fixed.sort(key=lambda v:v['id'])
        canonical = json.dumps(fixed,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()
        result[str(path)] = {'itemCount':len(rows),'nonPlaybackSHA256':hashlib.sha256(canonical).hexdigest()}
    return result
before = hashes(); (proof/'boss-before.json').write_text(json.dumps(before, indent=2))
pid = None; bridge = None; server = None; errorfile = None; owns_preferences = False
prefs = root/'old-preferences.plist'; old_preferences = None
responses = []
agent = None; agent_output = None; agent_errors = None
fixture_ids = []; fixture_hashes = {}
capture_time = 8
initial_hashes = {}
agent_version = None

class MediaHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *values): pass
    def do_HEAD(self): self.send_media(False)
    def do_GET(self): self.send_media(True)
    def send_media(self, body):
        if urllib.parse.unquote(self.path.split('?')[0]) != '/字幕验证.mp4':
            self.send_error(404); return
        self.send_response(200)
        self.send_header('Content-Type', 'video/mp4')
        self.send_header('Content-Length', str(media.stat().st_size)); self.end_headers()
        if body:
            try:
                with media.open('rb') as stream: shutil.copyfileobj(stream, self.wfile)
            except (BrokenPipeError, ConnectionResetError): pass

def run(*command, **kw): return subprocess.run(command, check=True, **kw)
next_id = 0

def rpc(method, params):
    global next_id
    next_id += 1
    bridge.stdin.write(json.dumps({'jsonrpc':'2.0', 'id':next_id, 'method':method, 'params':params}, ensure_ascii=False)+'\n'); bridge.stdin.flush()
    ready, _, _ = select.select([bridge.stdout], [], [], 30)
    assert ready, f'MCP timeout: {method}'
    line = bridge.stdout.readline(); assert line, 'bridge exited'
    reply = json.loads(line); assert reply.get('id') == next_id and 'error' not in reply, reply
    return reply['result']

def call(tool, arguments=None):
    result = rpc('tools/call', {'name':tool, 'arguments':arguments or {}})
    text = '\n'.join(v.get('text','') for v in result.get('content',[]) if v.get('type') == 'text')
    payload = json.loads(text)
    responses.append({'tool':tool, 'arguments':arguments or {}, 'isError':result.get('isError',False), 'payload':payload})
    return result.get('isError',False), payload

try:
    run('ditto', str(Path(args.app).resolve()), str(app))
    plist = app/'Contents/Info.plist'
    info = plistlib.loads(plist.read_bytes()); info['CFBundleIdentifier']=bundle_id; info['CFBundleExecutable']='seesee-mcp'
    plist.write_bytes(plistlib.dumps(info)); (app/'Contents/MacOS/seesee').rename(app/'Contents/MacOS/seesee-mcp')
    tools = app/'Contents/Resources/Tools'; tools.mkdir(parents=True, exist_ok=True)
    ffmpeg = shutil.which('ffmpeg'); assert ffmpeg
    shutil.copy2(ffmpeg, tools/'ffmpeg')
    run('codesign', '--force', '--deep', '--sign', '-', str(app), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    data_dir.mkdir(parents=True); movies.mkdir(parents=True)
    if args.fixtures:
        seeded = []
        for is_manual in [False, True]:
            item_id = str(uuid.uuid4()).upper(); fixture_ids.append(item_id)
            movie = movies/(item_id+'.mp4'); shutil.copy2(media, movie)
            en = movies/(item_id+'.en.srt'); zh = movies/(item_id+('.zh.srt' if is_manual else '.zh-Hans-en.srt'))
            en.write_text('1\n00:00:06,000 --> 00:00:07,000\nWelcome\n\n2\n00:00:07,000 --> 00:00:09,000\nto the test.\n\n3\n00:00:10,000 --> 00:00:12,000\nThe final\n')
            zh.write_text('1\n00:00:06,000 --> 00:00:07,000\n欢迎\n\n2\n00:00:07,000 --> 00:00:09,000\n来到测试。\n\n3\n00:00:10,000 --> 00:00:12,000\n最后的\n')
            fixture_hashes.update({str(v):hashlib.sha256(v.read_bytes()).hexdigest() for v in [en,zh]})
            seeded.append({'id':item_id,'urlString': ('https://example.invalid/manual' if is_manual else 'https://www.youtube.com/watch?v=AbCdEfGhIJK'),
                'title': '人工字幕样本' if is_manual else '自动翻译样本', 'author':'隔离检查','duration':90,'chapters':[],
                'addedAt':'2026-10-06T00:00:00Z','state':'ready','progress':1,'progressLabel':'已下载','localFilePath':str(movie),'subtitleFilePath':str(en)})
        (data_dir/'queue.json').write_text(json.dumps(seeded,ensure_ascii=False))
    run(args.helper, 'preflight', str(app), stdout=subprocess.DEVNULL)
    exported = subprocess.run(['defaults','export',bundle_id,str(prefs)], capture_output=True)
    if exported.returncode == 0: old_preferences = prefs.read_bytes()
    owns_preferences = True
    subprocess.run(['defaults','delete',bundle_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    run('defaults','write',bundle_id,'MediaFolderPath',str(movies))
    run('defaults','write',bundle_id,'subtitlesEnabled','-bool','true')
    pid = int(subprocess.check_output([args.helper,'launch',str(app),str(home)], text=True).strip())
    (proof/'owned-pid.txt').write_text(str(pid))
    if args.correct_original:
        (proof/'boss-comparison-policy.json').write_text(json.dumps({'reason':'本机正式 seesee 可能正在播放并定时保存进度；只比较，不回写或恢复本机队列','ignoredPlaybackFields':sorted(playback_fields),'compare':'条目数及去掉播放字段、按id排序后的其余完整字段','ownedBundleID':bundle_id,'ownedRoot':str(root)},ensure_ascii=False,indent=2))
    env = os.environ.copy(); env['CFFIXED_USER_HOME'] = str(home)
    errorfile = (proof/'bridge-stderr.txt').open('w')
    bridge = subprocess.Popen([str(app/'Contents/MacOS/seesee-mcp'),'--mcp-stdio'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errorfile, text=True, env=env)
    rpc('initialize', {'protocolVersion':'2024-11-05','capabilities':{},'clientInfo':{'name':'transcription-live-check','version':'1'}})
    for _ in range(100):
        error, listing = call('list_queue')
        if not error: break
        time.sleep(.2)
    assert not error and listing['total'] == (2 if args.fixtures else 0), listing
    assert (data_dir/'queue.json').is_file(), 'isolated queue not created'
    assert hashes() == before, 'boss queue changed before test intake'
    if args.correct_original:
        run(args.helper,'screenshot',str(app),str(pid),str(proof/'before-intake.png'))
    server = http.server.ThreadingHTTPServer(('127.0.0.1',0), MediaHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f'http://127.0.0.1:{server.server_port}/'+urllib.parse.quote('字幕验证.mp4')
    (proof/'url.txt').write_text(url)
    if args.claude:
        config = root/'mcp.json'
        config.write_text(json.dumps({'mcpServers':{'seesee':{'command':str(app/'Contents/MacOS/seesee-mcp'),'args':['--mcp-stdio'],'env':{'CFFIXED_USER_HOME':str(home)}}}}))
        agent_output = (proof/'claude.jsonl').open('w'); agent_errors = (proof/'claude-stderr.txt').open('w')
        command = ['claude','-p',url,'--tools','','--allowedTools','mcp__seesee__*','--strict-mcp-config','--mcp-config',str(config),
                   '--setting-sources','','--no-session-persistence','--output-format','stream-json','--verbose']
        (proof/'claude-command.json').write_text(json.dumps(command,ensure_ascii=False,indent=2))
        agent = subprocess.Popen(command,cwd=root,stdout=agent_output,stderr=agent_errors)
        for _ in range(400):
            error, listing = call('list_queue'); assert not error, listing
            if listing['items']: break
            if agent.poll() is not None: raise AssertionError('URL-only Claude exited without adding link')
            time.sleep(.3)
        assert listing['items'], 'URL-only Claude did not add a video'
        item_id = listing['items'][0]['itemID']
    elif args.fixtures:
        item_id = fixture_ids[0]
        for _ in range(100):
            error, listing = call('list_queue'); assert not error, listing
            machine = next(v for v in listing['items'] if v['itemID'] == item_id)
            manual = next(v for v in listing['items'] if v['itemID'] == fixture_ids[1])
            if machine['translationSource'] == 'youtube_auto' and manual['translationSource'] == 'author': break
            time.sleep(.2)
        assert machine['translationPolishable'] and not manual['translationPolishable'], listing
    else:
        error, added = call('add_links', {'urls':[url]}); assert not error, added
        item_id = added['added'][0]['itemID']
    last_state = None
    for _ in range(600):
        error, listing = call('list_queue')
        assert not error, listing
        item = next(v for v in listing['items'] if v['itemID'] == item_id)
        state = item['transcription']['state']
        if state != last_state:
            print(f"download={item['download']['state']} transcription={state} language={item['transcription'].get('language')}", flush=True); last_state=state
        if state == 'failed': raise AssertionError(item['transcription'])
        if state == 'ready' or (args.fixtures and state == 'not_needed'): break
        time.sleep(.3)
    assert state == ('not_needed' if args.fixtures else 'ready'), item
    if args.correct_original:
        assert item.get('originalCorrectable') is True, item
        # 自动转写的状态先发布、随后延迟保存；等初版真正落盘再取校验和。
        for _ in range(100):
            row = next(v for v in json.loads((data_dir/'queue.json').read_text()) if v['id'] == item_id)
            if row.get('originalSubtitlePath') and row.get('initialSubtitlePath'): break
            time.sleep(.05)
        assert row.get('originalSubtitlePath') and row.get('initialSubtitlePath'), 'initial subtitle files not saved'
        assert all(str(Path(row[key]).resolve()).startswith(str(root)+'/') for key in ['originalSubtitlePath','initialSubtitlePath']), 'initial paths escaped isolated root'
        initial_hashes = {row[key]: hashlib.sha256(Path(row[key]).read_bytes()).hexdigest() for key in ['originalSubtitlePath','initialSubtitlePath']}
    if not args.fixtures:
        assert item['transcription']['language'] == args.language, item
        assert item['transcription'].get('languageFallback') is not True, 'real known language should not use fallback'
        assert item['translationPolishable'] == (args.language == 'en'), item
    if agent:
        for _ in range(1000):
            if agent.poll() is not None: break
            time.sleep(.3)
        assert agent.poll() == 0, 'URL-only Claude failed or timed out'
        agent_output.flush()
        transcript = (proof/'claude.jsonl').read_text()
        assert 'mcp__seesee__add_links' in transcript and 'mcp__seesee__list_queue' in transcript, 'agent skipped MCP intake/status'
        error, listing = call('list_queue'); assert not error
        item = next(v for v in listing['items'] if v['itemID'] == item_id)
        if args.language == 'en':
            assert item['translationSource'] == 'agent' and 'mcp__seesee__write_subtitle_translations' in transcript, 'agent did not polish English initial translation'
        else:
            assert item['translationSource'] is None and not item['translationPolishable'], 'pure Chinese must remain original-only'
    error, track = call('read_subtitles', {'item_id':item_id, 'max_cues':4000}); assert not error, track
    assert track['totalCues'] > 0 and track['returned'] == track['totalCues'], track
    if args.language == 'en': assert all(v['translation'] for v in track['cues']), track
    else: assert all(v.get('translation') is None for v in track['cues']), track
    if args.correct_original:
        blocks = []
        for line in (proof/'claude.jsonl').read_text().splitlines():
            event = json.loads(line)
            blocks.extend(v for v in event.get('message',{}).get('content',[]) if isinstance(v,dict) and v.get('type') == 'tool_use')
        writes = [v['input'] for v in blocks if v.get('name') == 'mcp__seesee__write_subtitle_translations']
        assert any(any('original' in v and 'translation' in v for v in write.get('translations',[])) for write in writes), 'agent did not submit both original and translation'
        (proof/'agent-corrected-track.json').write_text(json.dumps(track,ensure_ascii=False,indent=2))
        row = next(v for v in json.loads((data_dir/'queue.json').read_text()) if v['id'] == item_id)
        agent_version = Path(row['subtitleFilePath']); shutil.copy2(agent_version,proof/'agent-version.vtt')
        preferred = next((v for v in track['cues'] if 'SpeechAnalyzer' in v['original']), track['cues'][0])
        capture_time = (preferred['start'] + preferred['end']) / 2
        error, seek = call('seek_to', {'item_id':item_id,'seconds':capture_time,'play':False}); assert not error, seek
        time.sleep(2)
        opened = subprocess.run(['lsof','-nP','-p',str(pid)],capture_output=True,text=True,check=True).stdout
        (proof/'owned-lsof.txt').write_text(opened)
        assert not any(str(path) in opened for path in queues), 'test process opened boss queue'
        data_lines = [line for line in opened.splitlines() if any(v in line for v in ['Application Support/seesee','/Movies/seesee/'])]
        # lsof的unix socket写/tmp，文件写/private/tmp；先解析真实路径，不能用字符串前缀判越界。
        data_paths = [Path(line[line.index('/'):]).resolve() for line in data_lines]
        assert all(path.is_relative_to(home.resolve()) for path in data_paths), 'test process opened data outside isolated home'
        (proof/'owned-open-data-paths.json').write_text(json.dumps([str(path) for path in data_paths],ensure_ascii=False,indent=2))
        assert data_paths, 'lsof did not observe any owned queue/media file'
        run(args.helper,'screenshot',str(app),str(pid),str(proof/'agent-corrected.png'))
        error, restored = call('restore_initial_translation', {'item_id':item_id}); assert not error, restored
        error, initial = call('read_subtitles', {'item_id':item_id,'max_cues':4000}); assert not error, initial
        differences = [{'index':a['index'],'before':a['original'],'after':b['original']} for a,b in zip(initial['cues'],track['cues']) if a['original'] != b['original']]
        assert differences, 'real ASR original was not corrected'
        assert [(v['index'],v['start'],v['end']) for v in initial['cues']] == [(v['index'],v['start'],v['end']) for v in track['cues']], 'correction changed numbering or time'
        assert {p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in initial_hashes} == initial_hashes, 'initial files changed'
        assert agent_version.is_file(), 'restoring removed agent history'
        (proof/'initial-restored-track.json').write_text(json.dumps(initial,ensure_ascii=False,indent=2))
        (proof/'correction-differences.json').write_text(json.dumps(differences,ensure_ascii=False,indent=2))
        time.sleep(1); run(args.helper,'screenshot',str(app),str(pid),str(proof/'initial-restored.png'))
        # 初次agent写回已单独留图和文件；以下只用其原值重建版本，验证退回后的再写与重开。
        values = [{k:v[k] for k in ['index','original','translation']} for v in track['cues']]
        error, rewritten = call('write_subtitle_translations', {'item_id':item_id,'revision':initial['revision'],'translations':values}); assert not error, rewritten
        error, track = call('read_subtitles', {'item_id':item_id,'max_cues':4000}); assert not error, track
        assert {p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in initial_hashes} == initial_hashes
        (proof/'immutable-initial-hashes.json').write_text(json.dumps({'before':initial_hashes,'after':{p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in initial_hashes}},indent=2))
        print(f'original_correction_live=passed changed_cues={len(differences)} original_and_initial_immutable=true',flush=True)
    if args.fixtures:
        revision = track['revision']; cues = track['cues']
        assert len(cues) == 2 and [v['index'] for v in cues] == [0,1], track
        raw_before = {v:hashlib.sha256(Path(v).read_bytes()).hexdigest() for v in fixture_hashes}
        partial = [{'index':0,'translation':'大家好，欢迎进入字幕测试。'}]
        error, partial_reply = call('write_subtitle_translations', {'item_id':item_id,'revision':revision,'translations':partial})
        assert error and partial_reply['error'] == 'invalid_arguments', partial_reply
        values = partial+[{'index':1,'translation':'最后的'}]
        error, written = call('write_subtitle_translations', {'item_id':item_id,'revision':revision,'translations':values}); assert not error, written
        error, polished = call('read_subtitles', {'item_id':item_id}); assert not error
        assert polished['cues'][0]['translation'] == '大家好，欢迎进入字幕测试。' and polished['revision'] != revision
        assert [(v['original'],v['start'],v['end']) for v in polished['cues']] == [(v['original'],v['start'],v['end']) for v in cues]
        error, stale = call('write_subtitle_translations', {'item_id':item_id,'revision':revision,'translations':values})
        assert error and stale['error'] == 'subtitles_changed', stale
        error, refused = call('write_subtitle_translations', {'item_id':fixture_ids[1],'revision':revision,'translations':values})
        assert error and refused['error'] == 'translation_not_polishable', refused
        error, seek = call('seek_to', {'item_id':item_id,'seconds':8,'play':False}); assert not error, seek
        time.sleep(1); run(args.helper,'screenshot',str(app),str(pid),str(proof/'polished.png'))
        error, restored = call('restore_initial_translation', {'item_id':item_id}); assert not error, restored
        error, initial = call('read_subtitles', {'item_id':item_id}); assert not error
        assert [v['translation'] for v in initial['cues']] == [v['translation'] for v in cues], initial
        raw_after = {v:hashlib.sha256(Path(v).read_bytes()).hexdigest() for v in fixture_hashes}
        assert raw_after == raw_before
        (proof/'downloaded-subtitle-hashes.json').write_text(json.dumps({'before':raw_before,'after':raw_after},indent=2))
    error, playing = call('seek_to', {'item_id':item_id,'seconds':capture_time,'play':True}); assert not error, playing
    time.sleep(.5)
    error, seek = call('seek_to', {'item_id':item_id,'seconds':capture_time,'play':False}); assert not error, seek
    error, paused = call('now_playing'); assert not error and paused['playing'] is False, paused
    position = paused['positionSeconds']
    time.sleep(1)
    error, later = call('now_playing'); assert not error and later['playing'] is False and abs(later['positionSeconds']-position)<.3, later
    run(args.helper,'screenshot',str(app),str(pid),str(proof/'subtitles.png'))
    if args.claude:
        # 重开真实应用验证活动版本持久化与初次挂载；保留首轮截图，不覆盖。
        active_before = json.loads((data_dir/'queue.json').read_text())[0]['subtitleFilePath']
        bridge.stdin.close(); bridge.wait(timeout=5)
        run(args.helper,'stop',str(app),str(pid))
        for _ in range(50):
            try: os.kill(pid,0)
            except ProcessLookupError: break
            time.sleep(.1)
        else: raise AssertionError('owned application failed to stop before reopen')
        pid = int(subprocess.check_output([args.helper,'launch',str(app),str(home)],text=True).strip())
        (proof/'reopened-pid.txt').write_text(str(pid))
        bridge = subprocess.Popen([str(app/'Contents/MacOS/seesee-mcp'),'--mcp-stdio'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=errorfile,text=True,env=env)
        rpc('initialize', {'protocolVersion':'2024-11-05','capabilities':{},'clientInfo':{'name':'reopen-check','version':'1'}})
        for _ in range(100):
            error, listing = call('list_queue')
            if not error: break
            time.sleep(.2)
        assert not error
        error, reopened = call('read_subtitles', {'item_id':item_id,'max_cues':2000}); assert not error
        assert reopened['revision'] == track['revision'], 'reopening changed the active subtitle revision'
        error, seek = call('seek_to', {'item_id':item_id,'seconds':capture_time,'play':False}); assert not error, seek
        time.sleep(2)
        assert json.loads((data_dir/'queue.json').read_text())[0]['subtitleFilePath'] == active_before, 'rescan replaced the polished version'
        error, visible = call('current_subtitles'); assert not error, visible
        run(args.helper,'screenshot',str(app),str(pid),str(proof/'reopened-subtitles.png'))
    print(f"transcription_live_check=passed language={args.language} cues={track['totalCues']}", flush=True)
finally:
    if agent and agent.poll() is None:
        agent.terminate()
        try: agent.wait(timeout=5)
        except subprocess.TimeoutExpired: agent.kill(); agent.wait(timeout=5)
    if agent_output: agent_output.close()
    if agent_errors: agent_errors.close()
    if bridge:
        bridge.stdin.close()
        try: bridge.wait(timeout=5)
        except subprocess.TimeoutExpired: bridge.terminate(); bridge.wait(timeout=5)
    if pid:
        subprocess.run([args.helper,'stop',str(app),str(pid)], capture_output=True)
        for _ in range(50):
            try: os.kill(pid,0)
            except ProcessLookupError: break
            time.sleep(.1)
        else:
            os.kill(pid,signal.SIGKILL)
            for _ in range(50):
                try: os.kill(pid,0)
                except ProcessLookupError: break
                time.sleep(.1)
            else: raise RuntimeError(f'own app PID {pid} did not exit')
    if server: server.shutdown(); server.server_close()
    if errorfile: errorfile.close()
    (proof/'responses.json').write_text(json.dumps(responses, ensure_ascii=False, indent=2))
    if (data_dir/'queue.json').exists():
        shutil.copy2(data_dir/'queue.json',proof/'saved-queue.json')
        for item in json.loads((data_dir/'queue.json').read_text()):
            for key in ['originalSubtitlePath','initialSubtitlePath','subtitleFilePath']:
                if item.get(key) and Path(item[key]).is_file(): shutil.copy2(item[key],proof/Path(item[key]).name)
    if owns_preferences:
        subprocess.run(['defaults','delete',bundle_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if old_preferences is not None:
            prefs.write_bytes(old_preferences); run('defaults','import',bundle_id,str(prefs), stdout=subprocess.DEVNULL)
    shutil.rmtree(root)
    after=hashes(); (proof/'boss-after.json').write_text(json.dumps(after,indent=2))
    (proof/'cleanup.txt').write_text(f'PID {pid} exited; isolated root {root} removed; server closed; own test preferences restored; boss hashes equal={after == before}.\n')
    if args.correct_original:
        port_closed = True
        if server:
            try:
                with socket.create_connection(('127.0.0.1',server.server_port),timeout=.5): port_closed = False
            except OSError: pass
        preferences_removed = subprocess.run(['defaults','read',bundle_id],capture_output=True).returncode != 0 if old_preferences is None else None
        (proof/'cleanup-readback.json').write_text(json.dumps({'rootExists':root.exists(),'mediaPortClosed':port_closed,'uniquePreferencesRemoved':preferences_removed,'bossNonPlaybackEqual':after == before,'finalOwnedPIDExited':pid},indent=2))
        assert not root.exists() and port_closed and preferences_removed is not False, 'owned resources remain after cleanup'
    assert after == before, 'boss queues changed during isolated test'
