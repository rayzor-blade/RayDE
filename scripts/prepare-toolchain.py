#!/usr/bin/env python3
"""Prepare an integrity-checked, disk-only MSB toolchain template on a Linux host."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import secrets
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parent.parent
HAXE_SHA256='810e1752c8eb3065dbff54c050b20a712ce276f407741f0bf94696b454a597ad'

def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()

def copy_binary(source,destination,libraries):
    source=source.resolve(strict=True)
    with source.open('rb') as stream:
        header=stream.read(20)
        if len(header)!=20 or header[:6]!=b'\x7fELF\x02\x01' or int.from_bytes(header[18:20],'little')!=62:
            raise ValueError('Toolchain executables must be Linux x86_64 ELF files')
    shutil.copy2(source,destination);destination.chmod(0o755)
    # The builder and guest use the same Ubuntu ABI; libc remains supplied by the base image.
    output=subprocess.run(['ldd',str(source)],text=True,capture_output=True)
    if 'not found' in output.stdout:
        raise ValueError('A toolchain executable has an unresolved native dependency')
    for name,path in re.findall(r'^\s*(\S+) => (/\S+)',output.stdout,re.M):
        if re.match(r'^(libc|libm|libpthread|libdl|librt|libutil|libresolv)\.so',name):
            continue
        target=libraries/name
        if target.exists() and digest(target)!=digest(Path(path)):
            raise ValueError('Conflicting toolchain runtime libraries')
        shutil.copy2(Path(path).resolve(),target)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--msb',type=Path,default=Path.home()/'.local/bin/msb')
    parser.add_argument('--ash',type=Path,required=True)
    parser.add_argument('--rayzor',type=Path,required=True)
    parser.add_argument('--extension-host',type=Path,required=True)
    parser.add_argument('--stdlib',type=Path,required=True)
    parser.add_argument('--haxe-archive',type=Path,required=True)
    parser.add_argument('--base',default='ubuntu:26.04')
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    if platform.system()!='Linux' or platform.machine()!='x86_64':
        parser.error('This profile builds the Linux x86_64 toolchain on a compatible Linux host')
    if digest(args.haxe_archive)!=HAXE_SHA256 or not (args.stdlib/'StdTypes.hx').is_file():
        parser.error('The pinned Haxe archive or Rayzor standard library is invalid')
    if args.output.exists():
        parser.error('Choose a new output file; existing template configuration is preserved')
    def msb(*command,timeout=60,capture=False):
        return subprocess.run([str(args.msb),*map(str,command)],env={**os.environ,'MSB_BACKEND':'local'},check=True,timeout=timeout,text=True,stdout=subprocess.PIPE if capture else None)
    builder='rayde-toolchain-build-'+secrets.token_hex(8)
    created=False
    args.output.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='rayde-toolchain-',dir=args.output.parent.resolve()) as temporary:
        payload=Path(temporary)/'rayde';(payload/'bin').mkdir(parents=True);(payload/'lib').mkdir()
        for source,name in [(args.ash,'ash'),(args.rayzor,'rayzor'),(args.extension_host,'rayde-extension-host')]:
            copy_binary(source,payload/'bin'/name,payload/'lib')
        for source in args.ash.parent.glob('*.hdll'):
            shutil.copy2(source,payload/'bin'/source.name)
        shutil.copytree(args.stdlib,payload/'haxe-std',symlinks=False)
        shutil.copytree(ROOT/'extensions',payload/'extensions',ignore=shutil.ignore_patterns('target','.git'))
        shutil.copytree(ROOT/'site/demo',payload/'pocket-studio',ignore=shutil.ignore_patterns('bin','.rayde','.rayzor','.haxelib','.git'))
        for name in ['bootstrap.sh','finalize.py']:
            shutil.copy2(ROOT/'native/runner/toolchain'/name,payload/name)
        shutil.copy2(args.haxe_archive,payload/'haxe.tar.gz')
        environment={'PATH':'/opt/rayde/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin','LD_LIBRARY_PATH':'/opt/rayde/lib','HAXE_STD_PATH':'/opt/rayde/haxe/std/','HAXELIB_PATH':'/opt/rayde/haxelib','RAYZOR_STD_PATH':'/opt/rayde/haxe-std'}
        (payload/'environment.json').write_text(json.dumps(environment)+'\n')
        variables=[part for key,value in environment.items() for part in ['--env',key+'='+value]]
        try:
            created=True
            msb('create',args.base,'--name',builder,'--cpus','1','--memory','1024M','--security','restricted','--deployment-profile','multi-tenant',
                '--mkdir','/workspace','--mkdir','/state','--copy-dir',str(payload)+':/opt/rayde','--max-duration','1800s','--label','rayde.toolchain-builder=true',*variables,timeout=90)
            msb('exec',builder,'--quiet','--no-stdin','--','/bin/sh','/opt/rayde/bootstrap.sh',timeout=1200)
            result=msb('exec',builder,'--quiet','--no-stdin','--','sha256sum','/opt/rayde/toolchain.json',capture=True)
            identity=result.stdout.split()[0]
            if not re.fullmatch('[0-9a-f]{64}',identity):
                raise ValueError('Builder returned an invalid toolchain identity')
            member='linux-x86_64-'+identity[:24]
            msb('stop',builder,timeout=30)
            msb('snapshot','create',member,'--sandbox',builder,'--group','rayde-toolchains','--integrity',timeout=120)
            selector='rayde-toolchains:'+member
            msb('snapshot','verify',selector,timeout=120)
            args.output.parent.mkdir(parents=True,exist_ok=True)
            with args.output.open('x') as output:
                json.dump({'snapshot':selector,'digest':identity},output,indent=2);output.write('\n')
            print('Verified toolchain configuration: '+str(args.output),flush=True)
        finally:
            if created:
                msb('remove','--force',builder,timeout=45)

if __name__=='__main__':
    main()
