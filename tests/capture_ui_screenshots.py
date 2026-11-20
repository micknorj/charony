"""Capture actual simulator PNGs; all application data comes from labelled fixtures."""
import argparse
import hashlib
import html
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import time
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'io.github.micknorj.charony.gallery'


def run(args, *, timeout=180, capture=False, env=None):
    result = subprocess.run(args, check=True, timeout=timeout, text=True,
                            stdout=subprocess.PIPE if capture else None, env=env)
    return result.stdout.strip() if capture else ''


def capture_states(device, prefix, output, record):
    data = Path(run(['xcrun', 'simctl', 'get_app_container', device, BUNDLE, 'data'], capture=True))
    documents = data / 'Documents'
    documents.mkdir(exist_ok=True)
    for name in ['capture-state.json', 'capture-ack.txt', 'capture-done.json', 'capture-failed.json']:
        (documents / name).unlink(missing_ok=True)
    run(['xcrun', 'simctl', 'launch', device, BUNDLE])
    entries = []
    previous = None
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        failure = documents / 'capture-failed.json'
        if failure.exists():
            shutil.copyfile(failure, output / f'{prefix}_failure.json')
            raise RuntimeError(f'Fixture state failure: {failure.read_text()}')
        done = documents / 'capture-done.json'
        if done.exists():
            return entries, json.loads(done.read_text())['missing']
        state_file = documents / 'capture-state.json'
        if state_file.exists():
            state = json.loads(state_file.read_text())
            if state['sequence'] != previous:
                previous = state['sequence']
                name = f'{prefix}_{state["id"]}_fixture.png'
                target = output / name
                run(['xcrun', 'simctl', 'io', device, 'screenshot', str(target)], timeout=60)
                contents = target.read_bytes()
                if contents[:8] != b'\x89PNG\r\n\x1a\n':
                    raise RuntimeError('simctl did not produce a PNG')
                state.update(file=name, width=struct.unpack('>I', contents[16:20])[0],
                             height=struct.unpack('>I', contents[20:24])[0],
                             sha256=hashlib.sha256(contents).hexdigest())
                entries.append(state)
                record(state)
                (documents / 'capture-ack.txt').write_text(state['id'])
                deadline = time.monotonic() + 90
        time.sleep(0.2)
    raise TimeoutError(f'No state transition for {prefix}; {entries[-1:]!r}')


def recovery(device, prefix, output):
    environment = dict(os.environ, WQ_SIMULATOR_UDID=device)
    text = run(['bash', 'tests/run_scan_ui_tests.sh'], timeout=240, capture=True, env=environment)
    (output / f'{prefix}_recovery-validation.log').write_text(text)
    match = re.search(r'Artifacts in (.+)', text)
    if not match:
        raise RuntimeError('Lifecycle harness did not report a successful recovery artifact')
    source = Path(match.group(1).strip()) / 'recovery.png'
    name = f'{prefix}_scan-interruption-recovery_fixture.png'
    shutil.copyfile(source, output / name)
    contents = (output / name).read_bytes()
    return {'id':'scan-interruption-recovery','title':'Scan interruption and cold-relaunch recovery',
            'note':'Actual terminate/relaunch fixture from the standard UIKit lifecycle harness; no protected sandbox access',
            'fixture':True,'file':name,'width':struct.unpack('>I',contents[16:20])[0],
            'height':struct.unpack('>I',contents[20:24])[0], 'sha256':hashlib.sha256(contents).hexdigest()}


def index(output, entries, missing, metadata):
    (output / 'manifest.json').write_text(json.dumps({'metadata':metadata,'screenshots':entries,'missing':missing},indent=2)+'\n')
    lines=['# Charony UI screenshot gallery', '',
           '**Every PNG is an actual `simctl` capture of running UIKit, using disposable, clearly labelled fixtures.**', '',
           'The fixture host compiles the production controllers, tab shell, alerts and mutation engines from the validated source. Discovery is supplied by fixtures. Operation screenshots use disposable files; this does not verify actual iOS 27.2.1 access or device signing.', '',
           f'Source: `{metadata["commit"]}`. Workflow: {metadata["workflow_url"]}. Runtime: `{metadata["runtime"]}` ({metadata["runtime_version"]}, build {metadata["runtime_build"]}). Capture complete: **{metadata["capture_complete"]}**.', '',
           'No separate app-details screen exists. Storage appears in the Apps rows. The standard lifecycle harness supplies genuine terminate/relaunch recovery frames.', '',
           '## Screenshots', '', '| Device | System appearance | Text size | UI state | PNG |', '| --- | --- | --- | --- | --- |']
    cards=[]
    for entry in entries:
        lines.append(f'| {entry["device"]} | {entry["system_appearance"]} | {entry["text_size"]} | {entry["title"]} | [{entry["file"]}]({entry["file"]}) |')
        caption=f'{entry["device"]} · {entry["system_appearance"]} · {entry["text_size"]} · FIXTURE'
        cards.append(f'<figure data-device="{html.escape(entry["device"])}"><a href="{html.escape(entry["file"])}"><img loading="lazy" src="{html.escape(entry["file"])}" alt="{html.escape(entry["title"])}"></a><figcaption><b>{html.escape(entry["title"])}</b><br>{html.escape(caption)}<br>{html.escape(entry["note"])}</figcaption></figure>')
    lines += ['', '## Missing or unverified states', '']
    seen=set()
    for item in missing:
        key=json.dumps(item,sort_keys=True)
        if key in seen:continue
        seen.add(key)
        lines.append(f'- **{item["state"]}:** {item["reason"]}')
    lines += ['', 'Keyboard visibility is recorded from actual UIKit keyboard notifications. Review the PNGs for visual placement. A request for keyboard focus alone is not evidence of an on-screen keyboard.', '',
              'VoiceOver speech/touch navigation, actual iPhone 11 Pro access, final sideloaded entitlements and layered icon appearances remain unverified. Device UI captures are not security certification.', '']
    (output / 'INDEX.md').write_text('\n'.join(lines))
    page='<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Charony fixture UI gallery</title><style>body{font:16px system-ui;margin:24px;background:#eee;color:#111}main{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:24px}figure{margin:0;padding:16px;background:white;border-radius:12px}img{width:100%;height:440px;object-fit:contain}figcaption{margin-top:12px;line-height:1.4}header{max-width:1000px;margin-bottom:24px}</style><header><h1>Charony UI screenshots</h1><p>Actual running UIKit · disposable fixtures · no real user data. All states are labelled fixtures. See INDEX.md and manifest.json for runtime, source provenance and missing states.</p><label>Filter <input id="filter" placeholder="state, appearance or device"></label></header><main>'+''.join(cards)+'</main><script>document.getElementById("filter").oninput=e=>{for(const f of document.querySelectorAll("figure"))f.hidden=!f.textContent.toLowerCase().includes(e.target.value.toLowerCase())}</script>'
    (output / 'index.html').write_text(page)


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--app',type=Path,required=True)
    parser.add_argument('--runtime',required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    args.output.mkdir(parents=True,exist_ok=True)
    # A fresh run only writes in the caller's ignored output directory.
    if any(args.output.iterdir()):
        raise RuntimeError('Gallery output must be empty')
    inventory=json.loads(run(['xcrun','simctl','list','devicetypes','--json'],capture=True))['devicetypes']
    runtimes=json.loads(run(['xcrun','simctl','list','runtimes','--json'],capture=True))['runtimes']
    runtime=next(r for r in runtimes if r['identifier']==args.runtime and r['isAvailable'])
    supported={d['identifier'] for d in runtime['supportedDeviceTypes']}
    inventory=[d for d in inventory if d['identifier'] in supported]
    phone=next((d for d in inventory if d['identifier']=='com.apple.CoreSimulator.SimDeviceType.iPhone-11-Pro'), None)
    if phone is None:
        phone=next(d for d in inventory if d['identifier']=='com.apple.CoreSimulator.SimDeviceType.iPhone-17')
    pads=[d for d in inventory if d.get('productFamily')=='iPad' or d['name'].startswith('iPad')]
    devices=[('iphone',phone)]
    if pads:devices.append(('ipad',pads[0]))
    entries=[];missing=[];owned=[]
    if not pads:missing.append({'state':'ipad','reason':'No iPad simulator device type was available'})
    metadata={'runtime_version':runtime['version'],'runtime_build':runtime['buildversion'],'capture_complete':False,'commit':run(['git','rev-parse','HEAD'],capture=True),'runtime':args.runtime,
              'workflow_url':f'https://github.com/{os.environ.get("GITHUB_REPOSITORY","micknorj/charony")}/actions/runs/{os.environ.get("GITHUB_RUN_ID","local")}',
              'keyboard_setup':'One-time OS slide-to-type introduction marked as already seen on these disposable simulators','capture_method':'xcrun simctl io screenshot','fixture_host':True,'devices':[]}
    try:
        run(['defaults','write','com.apple.iphonesimulator','ConnectHardwareKeyboard','-bool','NO'])
        for family,definition in devices:
            device=run(['xcrun','simctl','create',f'charony-gallery-{family}',definition['identifier'],args.runtime],capture=True)
            owned.append(device)
            metadata['devices'].append({'family':family,'name':definition['name'],'identifier':definition['identifier'],'udid':device})
            run(['xcrun','simctl','boot',device])
            run(['xcrun','simctl','bootstatus',device,'-b'],timeout=300)
            # This OS keyboard tip is outside Charony. Record the disposable
            # simulator as having seen it, without changing application UI.
            for domain,key in [('com.apple.keyboard.preferences','DidShowGestureKeyboardIntroduction'),
                               ('com.apple.keyboard.preferences','KeyboardDidShowContinuousPathIntroduction'),
                               ('com.apple.Preferences','UIKeyboardDidShowContinuousPathIntroduction')]:
                run(['xcrun','simctl','spawn',device,'defaults','write',domain,key,'-bool','YES'])
            run(['xcrun','simctl','install',device,str(args.app)])
            for appearance in ['light','dark']:
                for text_size in (['normal','accessibility-extra-extra-extra-large'] if family=='iphone' else ['normal']):
                    run(['xcrun','simctl','ui',device,'appearance',appearance])
                    size='large' if text_size=='normal' else text_size
                    run(['xcrun','simctl','ui',device,'content_size',size])
                    prefix=f'{family}_{appearance}_{"standard" if text_size=="normal" else "accessibility"}'
                    def record(entry):
                        entry.update(device=definition['name'],system_appearance=appearance,text_size=text_size)
                        entries.append(entry)
                        index(args.output,entries,missing,metadata)
                    _,gaps=capture_states(device,prefix,args.output,record)
                    missing.extend(gaps)
                    run(['xcrun','simctl','terminate',device,BUNDLE])
                    restored=recovery(device,prefix,args.output)
                    restored.update(device=definition['name'],system_appearance=appearance,text_size=text_size)
                    entries.append(restored)
                    index(args.output,entries,missing,metadata)
            run(['xcrun','simctl','shutdown',device])
        metadata['capture_complete']=True
    except Exception as error:
        missing.append({'state':'capture-aborted','reason':f'{type(error).__name__}: {error}'})
        raise
    finally:
        for device in owned:
            subprocess.run(['xcrun','simctl','delete',device],check=False)
        index(args.output,entries,missing,metadata)
        with zipfile.ZipFile(args.output.parent/'charony-ui-gallery.zip','w',zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(args.output.iterdir()):
                if path.is_file():archive.write(path,'charony-ui-gallery/'+path.name)
    print(f'Captured {len(entries)} actual simulator PNGs; gallery ZIP ready')


if __name__=='__main__':main()
