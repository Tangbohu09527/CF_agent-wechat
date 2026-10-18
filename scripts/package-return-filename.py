#!/usr/bin/env python3
"""Package two reviewed file replacements over the locked Ubuntu 22.04 image.

Run in an isolated Linux CI runner only. No WeChat entrypoint, login, networked
container or production mount is used. The generated context is a rebuild
candidate; identical Docker image IDs across Docker versions are not promised.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT=Path(__file__).resolve().parents[1]
BASE_IMAGE='ghcr.io/thisnick/agent-wechat@sha256:97d5a99f933592c15897a7579b4e2b2cbbb5f4dda856228f8271f91dd7cafb43'
BASE_CONFIG='sha256:3b14e58c908ec11e9163ef0bbb51522bea15c1568c8e1012a29890b9adadc48e'
UPSTREAM='96c2e90c497d999bf5189a134a9b3b293731f42e'
FILES={'agent-server':'/opt/agent-server/agent-server','paste-file':'/opt/tools/paste-file'}


def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
    return h.hexdigest()


def run(argv,timeout=120):
    p=subprocess.run(argv,check=True,capture_output=True,text=True,timeout=timeout)
    return p.stdout.strip()


def require(value,message):
    if not value:raise ValueError(message)


def dockerfile(revision):
    require(re.fullmatch('[0-9a-f]{40}',revision) is not None,'invalid overlay revision')
    return (f'FROM {BASE_IMAGE}\n'
            'COPY --chown=0:0 --chmod=0755 agent-server /opt/agent-server/agent-server\n'
            'COPY --chown=0:0 --chmod=0755 paste-file /opt/tools/paste-file\n'
            f'LABEL org.opencontainers.image.source="https://github.com/Tangbohu09527/CF_agent-wechat" org.opencontainers.image.revision="{revision}" cf.upstream.revision="{UPSTREAM}" cf.base.config="{BASE_CONFIG}"\n')


def source_proof(source,applied):
    require(run(['git','-C',str(source),'rev-parse','HEAD'])==UPSTREAM,'wrong upstream HEAD')
    require(applied['schema']=='cf-return-filename-overlay/v1' and applied['applied'] is True and applied['upstream_revision']==UPSTREAM,'invalid overlay receipt')
    spec=importlib.util.spec_from_file_location('fixed_filename_overlay',ROOT/'scripts/apply-return-filename.py')
    overlay=importlib.util.module_from_spec(spec);spec.loader.exec_module(overlay)
    originals={name:subprocess.check_output(['git','-C',str(source),'show','HEAD:'+name]) for name in overlay.EXPECTED}
    transformed=overlay.transform(originals,ROOT/'upstream/return-filename')
    require(set(transformed)==set(applied['sha256']),'incomplete overlay receipt')
    for name,data in transformed.items():
        expected=hashlib.sha256(data).hexdigest()
        require(expected==applied['sha256'][name] and sha(source/name)==expected,'modified overlay output')
    changed=set(run(['git','-C',str(source),'diff','--name-only','HEAD']).splitlines())
    untracked=set(run(['git','-C',str(source),'ls-files','--others','--exclude-standard']).splitlines())
    require(changed|untracked==set(transformed),'unreviewed upstream changes')
    lock=json.loads((ROOT/'upstream/media-retrieval.lock.json').read_text())['candidate']
    require(sha(source/'packages/agent-server-rust/Cargo.lock')==lock['source_files_sha256']['packages/agent-server-rust/Cargo.lock'],'Cargo dependency lock drift')
    return {name:sha(source/name) for name in sorted(transformed)}


def inspect_image(image):
    return json.loads(run(['docker','image','inspect',image]))[0]


def runtime_config(value):
    result=dict(value['Config']);result.pop('Labels',None)
    # BuildKit updates the informational image identifier only; runtime command,
    # environment, entrypoint, volumes, user and healthcheck must stay exact.
    result.pop('Image',None)
    return result


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source',type=Path,required=True)
    p.add_argument('--applied',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    args=p.parse_args()
    require(os.name=='posix','Linux CI runner required')
    require(not args.output.exists(),'refuse existing output directory')
    revision=run(['git','-C',str(ROOT),'rev-parse','HEAD'])
    applied=json.loads(args.applied.read_text())
    source=args.source.resolve();proof=source_proof(source,applied)
    built=source/'packages/agent-server-rust/target/release/agent-server'
    require(built.is_file() and built.stat().st_size>1000000,'release binary missing')
    release_hash=sha(built)
    require(run(['rustc','--version']).startswith('rustc 1.93.0 '),'unexpected Rust compiler')
    os_release=dict(line.split('=',1) for line in Path('/etc/os-release').read_text().splitlines() if '=' in line)
    require(os_release.get('ID')=='ubuntu' and os_release.get('VERSION_ID')=='"22.04"','release must build on Ubuntu 22.04')
    versions=run(['readelf','--version-info',str(built)])
    glibc=sorted(set(re.findall(r'GLIBC_([0-9]+\.[0-9]+)',versions)),key=lambda x:tuple(map(int,x.split('.'))))
    require(glibc and tuple(map(int,glibc[-1].split('.')))<=(2,35),'release requires a newer glibc than Ubuntu 22.04')
    run(['docker','pull','--platform','linux/amd64',BASE_IMAGE],timeout=600)
    base=inspect_image(BASE_IMAGE)
    require(base['Id']==BASE_CONFIG and base['Architecture']=='amd64' and base['Os']=='linux','base image config mismatch')
    lock=json.loads((ROOT/'upstream/media-retrieval.lock.json').read_text())['candidate']
    require(lock['image']==BASE_IMAGE and lock['config_digest']==BASE_CONFIG,'base lock mismatch')
    args.output.mkdir(parents=True)
    context=args.output/'context';context.mkdir()
    shutil.copyfile(built,context/'agent-server')
    shutil.copyfile(source/'docker/tools/paste-file',context/'paste-file')
    (context/'Dockerfile').write_text(dockerfile(revision))
    for name in FILES:(context/name).chmod(0o755)
    tag='cf-return-filename:'+revision
    run(['docker','build','--network','none','--pull=false','--tag',tag,str(context)],timeout=300)
    image=inspect_image(tag)
    require(image['RootFS']['Layers'][:-2]==base['RootFS']['Layers'],'overlay is not exactly two filesystem layers')
    require(runtime_config(image)==runtime_config(base),'runtime configuration changed')
    copied={}
    with tempfile.TemporaryDirectory(prefix='cf-filename-extracted-') as temporary:
        temp=Path(temporary)
        for label,ref in [('base',BASE_IMAGE),('candidate',tag)]:
            cid=run(['docker','create','--network','none','--entrypoint','/bin/true',ref])
            try:
                names=dict(lock['image_files_sha256'])
                names['opt/tools/paste-file']='64938f4656f8507e3487afb622db9e14b1b3e439950cd46e6c2a9b5047630a89'
                for relative,expected in names.items():
                    dest=temp/label/relative;dest.parent.mkdir(parents=True,exist_ok=True)
                    run(['docker','cp',cid+':/'+relative,str(dest)])
                    observed=sha(dest)
                    if label=='base' and expected:require(observed==expected,'base binary/helper identity mismatch: '+relative)
                    if label=='candidate':
                        if '/'+relative in FILES.values():
                            source_name=next(n for n,d in FILES.items() if d=='/'+relative)
                            require(observed==sha(context/source_name),'copied release identity mismatch')
                        else:require(observed==expected,'unrelated runtime file changed: '+relative)
                    copied[label+'/'+relative]=observed
            finally:run(['docker','rm','-v',cid])
    probe=r'''set -eu
 test ! -e /data/auth-token
 /lib64/ld-linux-x86-64.so.2 --verify /opt/agent-server/agent-server
 /lib64/ld-linux-x86-64.so.2 --list /opt/agent-server/agent-server
 getconf GNU_LIBC_VERSION
 bash -n /opt/tools/paste-file
'''
    output=run(['docker','run','--rm','--network','none','--read-only','--entrypoint','/bin/sh',tag,'-c',probe])
    require('not found' not in output.lower() and 'glibc 2.35' in output,'runtime dependency check failed')
    (args.output/'runtime-dependencies.txt').write_text(output+'\n')
    hashes={n:sha(context/n) for n in ('Dockerfile','agent-server','paste-file')}
    (context/'SHA256SUMS').write_text(''.join(h+'  '+n+'\n' for n,h in sorted(hashes.items())))
    archive=args.output/'return-filename-overlay.tar.gz'
    with tarfile.open(archive,'w:gz') as packed:
        for name in sorted([*hashes,'SHA256SUMS']):packed.add(context/name,arcname=name,recursive=False)
    result=dict(schema='cf-return-filename-release/v1',overlay_checkout_revision=revision,upstream_revision=UPSTREAM,
        github_head_revision=os.environ.get('CF_HEAD_SHA'),github_test_revision=os.environ.get('GITHUB_SHA'),
        base_image=BASE_IMAGE,base_config=BASE_CONFIG,candidate_image_id=image['Id'],candidate_tag=tag,
        candidate_layers=image['RootFS']['Layers'][-2:],overlay_source_sha256=proof,
        cargo_lock_sha256=sha(source/'packages/agent-server-rust/Cargo.lock'),release_binary_sha256=release_hash,
        compiler=run(['rustc','--version','--verbose']),build_os=os_release,required_glibc_versions=glibc,
        context_sha256=hashes,archive_sha256=sha(archive),extracted_sha256=copied,
        runtime_config_preserved=True,elf_loader_verified=True,live_wechat_started=False,login_or_production_mounts=False,
        service_health_verified=False,recipient_acceptance_verified=False,
        rebuild_note='Use the pinned base and packaged bytes; record rebuilt image ID. Cross-engine byte-identical image IDs are not asserted.')
    (args.output/'release-proof.json').write_text(json.dumps(result,sort_keys=True,indent=2)+'\n')
    print(json.dumps(result,sort_keys=True))


if __name__=='__main__':main()
