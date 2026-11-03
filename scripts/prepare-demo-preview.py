#!/usr/bin/env python3
"""Prepare and verify the public demo through RayDE's normal preview pipeline."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile
import urllib.parse
from demo_inputs import inputs

ROOT=Path(__file__).resolve().parent.parent

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--session',default=shutil.which('rayde-session'))
    parser.add_argument('--ash',default=os.environ.get('ASH') or shutil.which('ash'))
    parser.add_argument('--helper',type=Path,default=ROOT/'bin/prepare-demo-preview.hl')
    parser.add_argument('--tools',type=Path,default=ROOT/'bin/preview-tools')
    args=parser.parse_args()
    if not args.session or not args.ash or not args.helper.is_file():
        parser.error('Provide an installed Ash/session executable and the compiled PrepareDemoPreview helper')
    expected=inputs(ROOT/'site/demo')
    with tempfile.TemporaryDirectory(prefix='landing-prepare-',dir=ROOT/'bin') as temporary:
        temporary=Path(temporary);workspace=temporary/'workspace';shutil.copytree(ROOT/'site/demo',workspace)
        subprocess.run(['git','init','-q',str(workspace)],check=True)
        token=temporary/'token';token.write_text(secrets.token_hex(32));token.chmod(0o600)
        environment=dict(os.environ)
        environment['PATH']=str(Path(args.ash).resolve().parent)+os.pathsep+environment.get('PATH','')
        session=subprocess.Popen([args.session,'--root',str(workspace),'--state-root',str(temporary/'state'),'--port','0','--token-file',str(token),'--exec','--preview-tools',str(args.tools.resolve())],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=environment)
        try:
            address=None
            for line in session.stdout:
                if line.strip().startswith('http://'):
                    address=urllib.parse.urlsplit(line.strip()).netloc;break
            if not address:raise RuntimeError('The preparation session did not start')
            files=temporary/'files'
            subprocess.run([args.ash,str(args.helper.resolve()),address,str(token),str(files)],env=environment,check=True,timeout=600)
            if inputs(workspace)!=expected:raise RuntimeError('The preparation changed the demo inputs')
            configuration=json.loads((files/'configuration.json').read_text());(files/'configuration.json').unlink()
            metadata=files/'rayde-preview-metadata.mjs';shutil.copy2(ROOT/'preview/app-metadata.mjs',metadata)
            index=files/'index.html';page=index.read_text()
            if 'data-rayde-preview-metadata' not in page:
                index.write_text(page+'\n<script type="module" data-rayde-preview-metadata src="./rayde-preview-metadata.mjs"></script>\n')
            hashes={p.relative_to(files).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in files.rglob('*') if p.is_file()}
            identity={'inputs':expected,'configuration':configuration,'files':hashes}
            release=hashlib.sha256(json.dumps(identity,sort_keys=True,separators=(',',':')).encode()).hexdigest()
            output=ROOT/'bin/demo-preview';output.mkdir(exist_ok=True)
            if (output/'files').exists():shutil.rmtree(output/'files')
            shutil.copytree(files,output/'files')
            (output/'manifest.json').write_text(json.dumps({'release':release,**identity},sort_keys=True)+'\n')
            print('Prepared Pocket Studio '+release)
        finally:
            session.terminate()
            try:session.wait(timeout=5)
            except subprocess.TimeoutExpired:session.kill();session.wait()

if __name__=='__main__':main()
