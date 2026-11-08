#!/usr/bin/env python3
"""Original synthetic producer output and independent rejection expectations."""
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import diagnostic_report as producer
import export_guard as guard

class GuardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        source = self.root / 'source'; source.mkdir()
        (source / 'host.log').write_text('帧节拍：交换间隔 1，每帧 16.67 ms（60 帧/秒）\nS2A 标记 MARK：帧 1\n优雅退出完成\n')
        self.out = self.root / 'report'
        with mock.patch.object(producer, 'load_key_values', side_effect=lambda paths: frozenset() if paths == [] else self.fail('default key read')):
            producer.generate(source, self.out, key_paths=[])
        self.manifest = self.manifest_for_output()

    def manifest_for_output(self):
        files = []
        for p in sorted(self.out.rglob('*')):
            if p.is_file():
                name = p.relative_to(self.out).as_posix(); data = p.read_bytes()
                kind = {'report.json':'report-json', 'report.md':'report-markdown', '.complete':'completion'}.get(name, 'sanitized-text')
                files.append(dict(path=name, type=kind, size=len(data), sha256=hashlib.sha256(data).hexdigest()))
        return dict(schema_version=1, policy='diagnostic-report-v1', files=files)

    def deny(self, manifest=None, code=None):
        result = guard.check(self.out, manifest or self.manifest)
        self.assertFalse(result['allowed'], result)
        if code: self.assertEqual(result['reason'], code)
        return result

    def rewrite_json(self, mutate):
        p = self.out / 'report.json'; x=json.loads(p.read_text()); mutate(x); p.write_text(json.dumps(x))
        self.manifest=self.manifest_for_output()

    def test_real_producer_positive(self):
        result=guard.check(self.out,self.manifest); self.assertTrue(result['allowed'], result)
        self.assertEqual(result['policy'], 'diagnostic-report-v1'); self.assertEqual(len(result['files']), 4)

    def test_empty_producer_positive(self):
        source=self.root/'empty';source.mkdir();output=self.root/'empty-report'
        producer.generate(source,output,key_paths=[])
        self.out=output; self.manifest=self.manifest_for_output()
        self.assertTrue(guard.check(self.out,self.manifest)['allowed'])

    def test_cli_positive_and_duplicate_manifest(self):
        import subprocess
        p=self.root/'manifest.json';p.write_text(json.dumps(self.manifest))
        cmd=[sys.executable,str(ROOT/'tools/export_guard.py'),'--directory',str(self.out),'--manifest',str(p)]
        run=subprocess.run(cmd,capture_output=True,text=True);self.assertEqual(run.returncode,0,run.stdout)
        p.write_text(p.read_text().replace('"schema_version": 1','"schema_version": 1, "schema_version": 1'))
        run=subprocess.run(cmd,capture_output=True,text=True);self.assertEqual(run.returncode,1)

    def test_ancestor_symlink_positive(self):
        alias=self.root/'system-tmp';alias.symlink_to(self.root,target_is_directory=True)
        result=guard.check(alias/'report',self.manifest)
        self.assertTrue(result['allowed'],result)

    def test_cli_ancestor_symlink_positive(self):
        import subprocess
        alias=self.root/'system-var';alias.symlink_to(self.root,target_is_directory=True)
        p=self.root/'manifest.json';p.write_text(json.dumps(self.manifest))
        run=subprocess.run([sys.executable,str(ROOT/'tools/export_guard.py'),
                            '--directory',str(alias/'report'),'--manifest',str(alias/'manifest.json')],
                           capture_output=True,text=True)
        self.assertEqual(run.returncode,0,run.stdout)

    def test_root_symlink_below_trusted_alias_rejected(self):
        alias=self.root/'system-tmp';alias.symlink_to(self.root,target_is_directory=True)
        (self.root/'linked-report').symlink_to(self.out,target_is_directory=True)
        self.assertFalse(guard.check(alias/'linked-report',self.manifest)['allowed'])

    def test_cli_manifest_symlink_rejected(self):
        import subprocess
        p=self.root/'manifest.json';p.write_text(json.dumps(self.manifest))
        link=self.root/'linked-manifest.json';link.symlink_to(p)
        run=subprocess.run([sys.executable,str(ROOT/'tools/export_guard.py'),
                            '--directory',str(self.out),'--manifest',str(link)],capture_output=True,text=True)
        self.assertEqual(run.returncode,1)
        self.assertEqual(json.loads(run.stdout)['reason'],'invalid-manifest')

    def test_unlisted_synthetic_game_rejected(self):
        (self.out/'game.nsp').write_text('original synthetic marker, not game data')
        self.deny(code='directory-mismatch')

    def test_linked_logs_directory_rejected(self):
        logs=self.out/'logs';moved=self.root/'moved-logs';logs.rename(moved)
        logs.symlink_to(moved,target_is_directory=True)
        self.deny(code='unsafe-entry')

    def test_producer_guard_field_binding(self):
        # Real producer, maximized within this policy (not its unsupported extensions).
        source=self.root/'binding-source';source.mkdir()
        (source/'host.log').write_text('[心跳] 帧 10，热状态 0，进程实占 100 MB\n'
                                      '[声] 稳态窗口：输出峰值 0.5\n优雅退出完成\n')
        (source/'jobs').mkdir()
        (source/'jobs/one.txt').write_text(json.dumps({'state':'done','stage':'synthetic','diagnostics':None}))
        metadata={section:{key:'synthetic' for key in keys} for section,keys in producer.FIELDS.items()}
        for section,key in [('game','updates'),('game','dlc'),('test','steps'),
                            ('reproduction','shortest_steps'),('untested','items')]:
            metadata[section][key]=['synthetic']
        metadata['package']['switches']={}
        meta=self.root/'binding-metadata.json';meta.write_text(json.dumps(metadata))
        output=self.root/'binding-report';producer.generate(source,output,metadata=meta,key_paths=[])
        self.out=output;report=json.loads((output/'report.json').read_text())
        self.assertEqual({k:set(v) for k,v in producer.FIELDS.items()},
                         {k:set(v) for k,v in guard.FIELDS.items()})
        # Collect emitted keys by shared schema identity: SCORE's optional fields
        # occur on scores/operability, while sound intentionally emits status only.
        observed={};schemas={}
        def bind(value,schema):
            if isinstance(schema,str):return
            kind=schema[0]
            if kind=='nullable':
                if value is not None:bind(value,schema[1])
            elif kind=='list':
                for item in value:bind(item,schema[1])
            elif kind=='object':
                required,optional=schema[1:];allowed={**required,**optional}
                self.assertLessEqual(set(required),set(value))
                self.assertLessEqual(set(value),set(allowed))
                observed.setdefault(id(schema),set()).update(value);schemas[id(schema)]=allowed
                for key,child in value.items():bind(child,allowed[key])
        bind(report,guard.REPORT)
        for identity,keys in observed.items():self.assertEqual(keys,set(schemas[identity]))
        self.assertTrue(report['sessions']);self.assertTrue(report['jobs']);self.assertTrue(report['warnings'])
        self.assertTrue(guard.check(output,self.manifest_for_output())['allowed'])

    def test_same_size_content_tamper(self):
        p=self.out/'logs/0000.txt';data=p.read_bytes();p.write_bytes(b'X'+data[1:]);self.deny(code='content-mismatch')

    def test_boolean_size_not_integer(self):
        self.manifest['files'][0]['size']=True;self.deny(code='manifest-schema')

    def test_nonempty_dynamic_switches_rejected(self):
        self.rewrite_json(lambda x:x['package'].update(switches={'arbitrary':'synthetic'}));self.deny(code='report-schema')

    def test_unregistered_producer_extension_rejected(self):
        self.rewrite_json(lambda x:x.update(producer={'arbitrary':'synthetic'}));self.deny(code='report-schema')

    def test_unknown_policy(self):
        self.manifest['policy']='attacker'; self.deny(code='manifest-schema')

    def test_manifest_cannot_add_permissions(self):
        self.manifest['allow_types']=['game']; self.deny(code='manifest-schema')

    def test_manifest_extra_file_field(self):
        self.manifest['files'][0]['allow']=True; self.deny(code='manifest-schema')

    def test_unlisted_file(self):
        (self.out/'unlisted.txt').write_text('synthetic'); self.deny(code='directory-mismatch')

    def test_forbidden_file_even_listed(self):
        (self.out/'game.nsp').write_text('synthetic marker'); self.manifest=self.manifest_for_output(); self.deny(code='manifest-schema')

    def test_duplicate_manifest_entry(self):
        self.manifest['files'].append(copy.deepcopy(self.manifest['files'][0])); self.deny(code='manifest-schema')

    def test_path_traversal(self):
        self.manifest['files'][0]['path']='../outside'; self.deny(code='manifest-schema')

    def test_symlink(self):
        p=self.out/'logs/0000.txt'; p.unlink(); p.symlink_to(self.root/'source/host.log'); self.deny(code='unsafe-entry')

    def test_root_symlink(self):
        p=self.root/'linked';p.symlink_to(self.out,target_is_directory=True)
        self.assertFalse(guard.check(p,self.manifest)['allowed'])

    def test_fifo(self):
        import os
        p=self.out/'logs/0000.txt';p.unlink();os.mkfifo(p);self.deny(code='unsafe-entry')

    def test_content_tamper(self):
        (self.out/'logs/0000.txt').write_text('different synthetic bytes'); self.deny(code='content-mismatch')

    def test_extra_report_field(self):
        self.rewrite_json(lambda x:x.update(unexpected='synthetic'));self.deny(code='report-schema')

    def test_nested_extra_report_field(self):
        self.rewrite_json(lambda x:x['device'].update(unexpected='synthetic'));self.deny(code='report-schema')

    def test_nested_observation_extra(self):
        self.rewrite_json(lambda x:x['sessions'][0]['observations'].update(unexpected='synthetic'));self.deny(code='report-schema')

    def test_duplicate_json_key(self):
        p=self.out/'report.json';p.write_text(p.read_text().replace('"schema_version": 1','"schema_version": 1, "schema_version": 1'))
        self.manifest=self.manifest_for_output();self.deny(code='invalid-json')

    def test_markdown_tamper_with_updated_hash(self):
        p=self.out/'report.md';p.write_text(p.read_text()+'synthetic extra')
        self.manifest=self.manifest_for_output();self.deny(code='render-mismatch')

    def test_evidence_reference_mismatch(self):
        self.rewrite_json(lambda x:x['evidence'][0].update(sanitized_path='logs/9999.txt'));self.deny(code='evidence-mismatch')

    def test_empty_directory(self):
        (self.out/'extra').mkdir();self.deny(code='directory-mismatch')

    def test_completion_marker(self):
        (self.out/'.complete').write_text('not complete');self.manifest=self.manifest_for_output();self.deny(code='completion-mismatch')

    def test_reason_does_not_echo_content(self):
        self.rewrite_json(lambda x:x.update(SYNTHETIC_PRIVATE_VALUE='DO_NOT_ECHO'))
        result=self.deny();self.assertNotIn('SYNTHETIC_PRIVATE_VALUE',json.dumps(result));self.assertNotIn('DO_NOT_ECHO',json.dumps(result))

if __name__ == '__main__': unittest.main()
