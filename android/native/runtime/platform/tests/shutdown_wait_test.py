#!/usr/bin/env python3
"""Production shutdown acquisition caller, real pthread contention; no guest/GPU claim."""
import os
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]


def main():
    source = (ROOT/'runtime/src/lifecycle.c').read_text()
    marker = 'static int android_shutdown_writers_begin(void)'
    start = source.index(marker)
    end = source.index('{', start)+1
    depth = 1
    while depth:
        depth += (source[end] == '{')-(source[end] == '}')
        end += 1
    helper = source[start:end]
    body = source[source.index('void s2a_host_shutdown('):]
    assert body.index('s2a_android_shutdown_watchdog_start()') < body.index('s2a_svc_park_all(300)') < body.index('android_shutdown_writers_begin()') < body.index('s2a_cs_shutdown(why)'), 'wait is only after terminal park, bounded by existing watchdog'
    fixture = (HERE/'shutdown_wait_fixture.c.in').read_text()
    # Compile the actual terminal adapter too: normal memory transactions still
    # observe cancellation, and any writer failure stays a failure.
    thread_source = (ROOT/'android/native/runtime/fault/thread_android.inc').read_text()
    start = thread_source.index('int s2a_android_guest_shutdown_writers_begin(void)')
    end = thread_source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (thread_source[end] == '{') - (thread_source[end] == '}')
        end += 1
    terminal_adapter = thread_source[start:end]
    adapter_fixture = r"""
#include <assert.h>
#include <errno.h>
static int android_vm_memory_scope, stopped, injected;
static int s2a_svc_stopping(void) { return stopped; }
static int s2a_android_guest_writers_begin(void) {
    if (android_vm_memory_scope && stopped) return ECANCELED;
    return injected;
}
PRODUCTION_ADAPTER
int main(void) {
    android_vm_memory_scope = 1;
    assert(s2a_android_guest_shutdown_writers_begin() == EINVAL && android_vm_memory_scope == 1);
    stopped = 1;
    assert(s2a_android_guest_writers_begin() == ECANCELED);
    assert(s2a_android_guest_shutdown_writers_begin() == 0 && android_vm_memory_scope == 1);
    injected = EDEADLK;
    assert(s2a_android_guest_shutdown_writers_begin() == EDEADLK && android_vm_memory_scope == 1);
    return 0;
}
""".replace('PRODUCTION_ADAPTER', terminal_adapter)
    with tempfile.TemporaryDirectory(prefix='s2a-shutdown-wait-') as directory:
        out = Path(directory)
        adapter = out/'adapter.c'
        adapter.write_text(adapter_fixture)
        binary = out/'adapter'
        subprocess.run([os.environ.get('CC','cc'),'-std=c11','-Wall','-Wextra','-Werror',str(adapter),'-o',str(binary)],check=True)
        subprocess.run([str(binary)],check=True,timeout=5)
        print('PASS terminal writer adapter: stop gate, memory scope, error propagation',flush=True)
        for name, production, cases in [
            ('positive',helper,[('normal',0),('busy',0),('hung',124),('fatal',125),('unready',125)]),
            ('no-retry',marker+' { return s2a_android_guest_shutdown_writers_begin(); }',[('busy',125)]),
            ('fake-success',marker+' { return 0; }',[('fatal',86)]),
        ]:
            c = out/(name+'.c'); binary = out/name
            c.write_text(fixture.replace('PRODUCTION_HELPER',production))
            subprocess.run([os.environ.get('CC','cc'),'-std=c11','-D_POSIX_C_SOURCE=200809L','-Wall','-Wextra','-Werror','-pthread',str(c),'-o',str(binary)],check=True)
            print('SHUTDOWN_WAIT_COMPILED',name,flush=True)
            for mode, expected in cases:
                result = subprocess.run([str(binary),mode],capture_output=True,text=True,timeout=5)
                assert result.returncode==expected,(name,mode,result.returncode,result.stdout,result.stderr)
                if name=='positive' and expected==0: assert 'PASS shutdown wait' in result.stdout
                print(name,mode,'PASS',result.returncode,flush=True)


if __name__ == '__main__':
    main()
