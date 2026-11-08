#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Actual provider Stop/Destroy wrappers and unchanged retirement bodies, not GPU proof."""
import os
from pathlib import Path
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[2]
NATIVE=ROOT/'android/native'
HERE=Path(__file__).resolve().parent

def function(text, signature):
    start=text.index(signature); begin=text.index('{',start); depth=1; end=begin+1
    while depth:
        depth+=(text[end]=='{')-(text[end]=='}'); end+=1
    return text[start:end]

def main():
    source=(NATIVE/'direct/provider_vk.c').read_text()
    names=['static int provider_w2_enabled(', 'static void provider_w2_begin(',
           'static int provider_w2_write(', 'static void provider_w2_export(',
           'static int32_t request_stop_impl(', 'static int32_t request_stop(',
           'static int32_t destroy_impl(', 'static int32_t destroy(']
    bodies='struct provider_w2_sink { const char *dir; char name[128]; };\n'+'\n'.join(function(source,n) for n in names)
    # Init is called only after the original PREPARED check, never from prepare().
    activate=function(source,'static int32_t activate(')
    assert activate.count('provider_w2_begin(ctx);')==1
    assert activate.index('ctx->state != S2A_DIRECT_PREPARED') < activate.index('provider_w2_begin(ctx);') < activate.index('s2a_vk_adapter_init(')
    assert 'provider_w2_' not in function(source,'static int32_t prepare(')
    with tempfile.TemporaryDirectory(prefix='w2-observe-lifecycle-') as directory:
        td=Path(directory); (td/'sys').mkdir()
        (td/'sys/system_properties.h').write_text('#pragma once\n#define PROP_VALUE_MAX 92\nint __system_property_get(const char*,char*);\n')
        (td/'provider_context.h').write_text(function(source,'struct provider_context {')+';\n')
        variants={'positive':bodies,
            'omit-seal':bodies.replace('(void)s2a_w2_seal(window, rc == S2A_DIRECT_RES_OK,\n                          rc == S2A_DIRECT_RES_OK && !ctx->engine_ok);','/* seal deliberately omitted */'),
            'seal-failed-stop':bodies.replace('rc == S2A_DIRECT_RES_OK && !ctx->engine_ok','1').replace('s2a_w2_seal(window, rc == S2A_DIRECT_RES_OK,','s2a_w2_seal(window, 1,'),
            'bypass-gate':bodies.replace('s2a_debug_entries_open() &&','1 &&'),
            'omit-destroy-seal':bodies.replace('(void)s2a_w2_seal(window, rc == S2A_DIRECT_RES_OK, rc == S2A_DIRECT_RES_OK);',
                                             '/* destroy seal deliberately omitted */'),
            'omit-destroy-export':bodies.replace('provider_w2_export(window, dir, session, generation);',
                                               '(void)dir; (void)session; (void)generation;')}
        for debug in (0,1):
            for name,text in variants.items():
                if name!='positive': assert text!=bodies, name
                (td/'provider_bodies.h').write_text(text)
                exe=td/(str(debug)+name)
                flags=[os.environ.get('CC','cc'),'-std=c11','-Wall','-Wextra','-Werror','-pthread','-D__ANDROID__','-DS2A_ANDROID_VK_ENGINE=1','-DS2A_ANDROID_VK_BACKEND_NVN_VK=1','-DW2_EXPECT_DEBUG='+str(debug),'-I'+str(td),'-I'+str(NATIVE)]
                if debug: flags+=['-DS2A_ANDROID_DEBUG_ENV=1']
                subprocess.run(flags+[str(HERE/'w2_observation_lifecycle_test.c'),'-o',str(exe)],check=True,timeout=30)
                failures=[]; errors={}
                for mode in range(11):
                    run=subprocess.run([str(exe),str(mode)],text=True,capture_output=True,timeout=5)
                    if run.returncode: failures.append(mode); errors[mode]=run.stderr
                    if name=='positive':
                        print(run.stdout+run.stderr,end=''); assert run.returncode==0,(debug,mode)
                if name!='positive' and not debug:
                    assert not failures, (name, 'release compiled gate must still block runtime bypass', errors)
                if name!='positive' and debug:
                    assert failures,(debug,name,'survived')
                    if name=='omit-destroy-seal':
                        assert 8 in failures and 'sink_snapshot.state==S2A_W2_SEALED' in errors[8], errors
                    if name=='omit-destroy-export':
                        assert 0 in failures and 'writes==before_writes+1' in errors[0], errors
                    print(name,'debug',debug,'expected red',failures)
        print('PASS: 22 provider lifecycle cases; failed retirement preserved; unsealed/gate negatives')
if __name__=='__main__': main()
