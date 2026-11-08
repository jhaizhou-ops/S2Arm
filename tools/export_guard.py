#!/usr/bin/env python3
"""Offline structural postcondition for a versioned diagnostic export snapshot.

Not a sanitizer, uploader, or proof that free-form text contains no private data.
Policies live here, never in the untrusted manifest. Future producers must register
an audited policy; a receipt binds bytes observed now, not a later pathname read.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat

POLICY = 'diagnostic-report-v1'
MAX_FILES = 1002
MAX_FILE = 16 * 1024 * 1024
MAX_TOTAL = 256 * 1024 * 1024
MAX_ITEMS = 10000
MAX_TEXT = 1024 * 1024

class Refusal(ValueError):
    pass

def require(ok, reason):
    if not ok:
        raise Refusal(reason)

def object_pairs(pairs):
    out = {}
    for key, value in pairs:
        require(key not in out, 'invalid-json')
        out[key] = value
    return out

def load_json(data):
    try:
        return json.loads(data, object_pairs_hook=object_pairs,
                          parse_constant=lambda _: (_ for _ in ()).throw(Refusal('invalid-json')))
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise Refusal('invalid-json') from exc

# Schemas are fixed structural contracts, not inferred from submitted values.
TEXT = 'text'
SCALAR = 'scalar'
def obj(required, optional=None): return ('object', required, optional or {})
def seq(schema): return ('list', schema)
def nullable(schema): return ('nullable', schema)
def literal(value): return ('literal', value)

def validate(value, schema, depth=0):
    require(depth < 24, 'report-schema')
    if schema == TEXT:
        require(type(value) is str and len(value) <= MAX_TEXT, 'report-schema'); return
    if schema == SCALAR:
        require(value is None or type(value) in (str, int, float, bool), 'report-schema')
        if type(value) is str: require(len(value) <= MAX_TEXT, 'report-schema')
        if type(value) is float: require(math.isfinite(value), 'report-schema')
        return
    kind = schema[0]
    if kind == 'nullable':
        if value is not None: validate(value, schema[1], depth+1)
    elif kind == 'literal':
        require(type(value) is type(schema[1]) and value == schema[1], 'report-schema')
    elif kind == 'list':
        require(type(value) is list and len(value) <= MAX_ITEMS, 'report-schema')
        for entry in value: validate(entry, schema[1], depth+1)
    else:
        required, optional = schema[1:]
        require(type(value) is dict and set(required) <= set(value) <= set(required)|set(optional), 'report-schema')
        for key, child in value.items(): validate(child, required.get(key, optional.get(key)), depth+1)

FIELDS = {
    'task': ('id', 'platform'), 'code': ('commit',),
    'package': ('id','version','commit','sha256','switches','signing','build_id','target_arch'),
    'game': ('name','id','version','updates','dlc'),
    'device': ('model','soc','memory','os','gpu_family'),
    'test': ('steps','scene','route','save_id'),
    'reproduction': ('shortest_steps','first_failure'), 'untested': ('items','reason'),
}
LIST_FIELDS = {'game.updates','game.dlc','test.steps','reproduction.shortest_steps','untested.items'}
SECTIONS = {section: obj({key: nullable(seq(SCALAR)) if section+'.'+key in LIST_FIELDS else
                         nullable(obj({})) if section+'.'+key == 'package.switches' else SCALAR
                         for key in keys}) for section, keys in FIELDS.items()}
SCORE = obj({'status': TEXT}, {'legacy':TEXT, 'reason':nullable(TEXT)})
OBSERVATIONS = obj({key: SCALAR for key in ('结局','MARK','帧数','热状态最高','实占峰值MB','崩溃签名','红行','首遇现编')})
SESSION = obj({
    'source':TEXT, 'status':TEXT, 'evidence_completeness':TEXT, 'truncated_files':seq(TEXT),
    'observations':OBSERVATIONS, 'scores':obj({k:SCORE for k in ('能玩','画面','帧率','能耗','首局','分配')}),
    'reading':nullable(TEXT), 'invalid_reason':nullable(TEXT), 'operability':SCORE, 'picture':SCORE,
    'sound':SCORE, 'frame_time_stutter':SCORE, 'termination':obj({'status':TEXT,'kind':SCALAR}),
    'heartbeat_status':TEXT, 'firstuse_status':TEXT, 'frame_source':nullable(TEXT),
})
EVIDENCE = obj({'path':TEXT,'type':TEXT,'size':SCALAR,'sha256':TEXT,'availability':TEXT,
                'sanitized_path':nullable(TEXT),'truncated':SCALAR})
# Dynamic job diagnostics / producer extensions / switches are not yet a supported
# export policy. Reject rather than accepting arbitrary nested payload fields.
REPORT = obj({'schema_version':literal(1), **SECTIONS, 'field_sources':SCALAR,
              'missing_fields':seq(TEXT),'warnings':seq(obj({'source':TEXT,'message':TEXT})),
              'sessions':seq(SESSION),'jobs':seq(obj({'source':TEXT,'parse_status':TEXT,'diagnostics':literal(None),'game_result':TEXT}, {'state':SCALAR,'stage':SCALAR})),
              'evidence':seq(EVIDENCE),'media_policy':literal('index_only; manual review before sharing')})

def file_type(path):
    known = {'report.json':'report-json','report.md':'report-markdown','.complete':'completion'}
    return known.get(path, 'sanitized-text' if re.fullmatch(r'logs/[0-9]{4}\.txt', path) else None)

def manifest_files(manifest):
    require(type(manifest) is dict and set(manifest)=={'schema_version','policy','files'}, 'manifest-schema')
    require(type(manifest['schema_version']) is int and manifest['schema_version']==1 and manifest['policy']==POLICY, 'manifest-schema')
    entries=manifest['files']; require(type(entries) is list and 3 <= len(entries) <= MAX_FILES, 'manifest-schema')
    result={}; total=0
    for e in entries:
        require(type(e) is dict and set(e)=={'path','type','size','sha256'}, 'manifest-schema')
        name=e['path']; require(type(name) is str and file_type(name) is not None and name not in result, 'manifest-schema')
        require(e['type']==file_type(name) and type(e['size']) is int and 0 <= e['size'] <= MAX_FILE, 'manifest-schema')
        require(type(e['sha256']) is str and re.fullmatch('[0-9a-f]{64}',e['sha256']), 'manifest-schema')
        total+=e['size']; require(total<=MAX_TOTAL,'manifest-schema');result[name]=e
    require({'report.json','report.md','.complete'} <= result.keys(),'manifest-schema')
    return result

def open_directory(root):
    flags=os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW
    # Caller trusts ancestors (macOS /tmp and /var are system symlinks).
    # Resolve only the parent: the selected root itself must still not be a link.
    path=Path(root).absolute()
    parts=(path.parent.resolve(strict=True)/path.name).parts
    fd=os.open(parts[0],flags)
    try:
        for part in parts[1:]:
            next_fd=os.open(part,flags,dir_fd=fd);os.close(fd);fd=next_fd
        return fd
    except BaseException:
        os.close(fd);raise

def read_snapshot(root, expected):
    """Trust root ancestors; no follow at selected root or below; bound/hash bytes."""
    require(all(hasattr(os,k) for k in ('O_NOFOLLOW','O_DIRECTORY','O_NONBLOCK')), 'unsupported-platform')
    flags=os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW
    fd=open_directory(root)
    try:
        data={};seen=set();total=0;count=0
        def walk(directory, prefix=''):
            nonlocal total,count
            names=os.listdir(directory)
            count+=len(names);require(count<=MAX_FILES+1,'size-limit')
            for name in sorted(names):
                path=prefix+name
                st=os.stat(name,dir_fd=directory,follow_symlinks=False)
                if stat.S_ISDIR(st.st_mode):
                    require(path=='logs','directory-mismatch')
                    child=os.open(name,flags,dir_fd=directory)
                    try: walk(child,'logs/')
                    finally:os.close(child)
                    continue
                require(stat.S_ISREG(st.st_mode), 'unsafe-entry')
                require(path in expected,'directory-mismatch');seen.add(path)
                require(st.st_nlink==1,'unsafe-entry')
                f=os.open(name,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=directory)
                try:
                    before=os.fstat(f)
                    require(stat.S_ISREG(before.st_mode) and before.st_nlink==1,'unsafe-entry')
                    require((before.st_dev,before.st_ino)==(st.st_dev,st.st_ino),'input-changed')
                    require(before.st_size==expected[path]['size'],'content-mismatch')
                    chunks=[];n=0
                    while True:
                        b=os.read(f,min(65536,MAX_FILE+1-n))
                        if not b: break
                        n+=len(b);require(n<=MAX_FILE,'size-limit');chunks.append(b)
                    after=os.fstat(f)
                    require((before.st_size,before.st_mtime_ns,before.st_ctime_ns)==(after.st_size,after.st_mtime_ns,after.st_ctime_ns),'input-changed')
                finally:os.close(f)
                payload=b''.join(chunks);total+=len(payload);require(total<=MAX_TOTAL,'size-limit')
                require(len(payload)==expected[path]['size'] and hashlib.sha256(payload).hexdigest()==expected[path]['sha256'],'content-mismatch')
                data[path]=payload
        walk(fd);require(seen==set(expected),'directory-mismatch');return data
    finally:os.close(fd)

def validate_report(report, data):
    require(type(report) is dict,'report-schema')
    sources=report.get('field_sources');require(type(sources) is dict,'report-schema')
    known={s+'.'+k for s,ks in FIELDS.items() for k in ks}
    for i in range(len(report.get('sessions',[])) if type(report.get('sessions')) is list else 0):
        known.update(f'sessions[{i}].{k}' for k in ('operability','picture','sound','frame_time_stutter','firstuse'))
    require(set(sources)<=known,'report-schema')
    for v in sources.values():validate(v,TEXT)
    # field_sources is checked separately to retain the closed dynamic namespace.
    copy=dict(report);copy['field_sources']=None;validate(copy,REPORT)
    referenced=set()
    for e in report['evidence']:
        require(e['type'] in ('manifest','metrickit','job','diagnostic','log','media'),'evidence-mismatch')
        require(type(e['size']) is int and e['size']>=0 and re.fullmatch('[0-9a-f]{64}',e['sha256']),'evidence-mismatch')
        require(type(e['truncated']) is bool or e['truncated'] is None,'evidence-mismatch')
        name=e['sanitized_path']
        if e['availability']=='indexed_only':
            require(e['type']=='media' and name is None,'evidence-mismatch')
        else:
            require(e['availability']=='sanitized_copy' and e['type']!='media' and name in data and file_type(name)=='sanitized-text' and name not in referenced,'evidence-mismatch');referenced.add(name)
    require(referenced=={p for p in data if p.startswith('logs/')},'evidence-mismatch')
    # Existing renderer performs no filesystem or credential access.
    from diagnostic_report import markdown
    require(data['report.md']==markdown(report).encode('utf-8'),'render-mismatch')

def check(root, manifest):
    """Return fixed refusal codes only; never echo submitted fields or content."""
    try:
        expected=manifest_files(manifest);data=read_snapshot(root,expected)
        require(data['.complete']==b's2arm diagnostic report schema 1\n','completion-mismatch')
        for payload in data.values():
            try: text=payload.decode('utf-8')
            except UnicodeError as exc: raise Refusal('invalid-text') from exc
            require('\0' not in text,'invalid-text')
        validate_report(load_json(data['report.json']),data)
        return {'allowed':True,'policy':POLICY,'reason':'structural-policy-pass',
                'files':[dict(expected[k]) for k in sorted(expected)]}
    except Refusal as exc:return {'allowed':False,'reason':str(exc)}
    except (OSError,ValueError,TypeError,KeyError,RecursionError):return {'allowed':False,'reason':'unreadable-or-invalid-input'}

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory',required=True);parser.add_argument('--manifest',required=True)
    args=parser.parse_args()
    try:
        # Explicit manifest is supplied by the caller; no home/config discovery.
        path=Path(args.manifest).absolute();parent=open_directory(path.parent.resolve(strict=True))
        try:
            fd=os.open(path.name,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=parent)
            try:
                st=os.fstat(fd);require(stat.S_ISREG(st.st_mode) and st.st_size<=MAX_FILE,'invalid-manifest')
                with os.fdopen(fd,'rb',closefd=False) as stream: payload=stream.read(MAX_FILE+1)
                require(len(payload)<=MAX_FILE,'invalid-manifest')
            finally:os.close(fd)
        finally:os.close(parent)
        manifest=load_json(payload);result=check(args.directory,manifest)
    except (OSError,ValueError):result={'allowed':False,'reason':'invalid-manifest'}
    print(json.dumps(result,ensure_ascii=False,sort_keys=True));return 0 if result['allowed'] else 1

if __name__=='__main__':raise SystemExit(main())
