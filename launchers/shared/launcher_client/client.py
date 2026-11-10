"""Read-only job projections and a thin client of the existing Jobs CLI.

No scheduler, worker, persistence or target implementation lives here.
"""
from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import subprocess
import stat
import sys


class ProtocolError(ValueError):
    pass


def task_id(value):
    if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,80}', value):
        raise ProtocolError('无效的任务标识')
    return value


class Lines:
    """Decode only whole NDJSON lines; a trailing partial record is not success."""
    def __init__(self):
        self.pending = b''

    def feed(self, data):
        self.pending += data
        if len(self.pending) > 4 * 1024 * 1024:
            raise ProtocolError('事件缓冲超过原型上限')
        out = []
        while b'\n' in self.pending:
            line, self.pending = self.pending.split(b'\n', 1)
            if line.strip():
                try:
                    event = json.loads(line)
                except (ValueError, UnicodeError) as error:
                    raise ProtocolError('非法 NDJSON 事件') from error
                if not isinstance(event, dict):
                    raise ProtocolError('事件必须是对象')
                out.append(event)
        return out

    def finish(self):
        if self.pending:
            raise ProtocolError('事件流在半行处中断')
        return []


class Projection:
    """Ephemeral current-worker display, matching Mac's aliases/progress reset.

Never feed historical attempts into this projection. Reconnection uses get.
"""
    def __init__(self, task):
        self.task = task_id(task)
        self.state = 'running'
        self.done = self.total = self.unit = self.counters = None
        self.terminal = False
        self.cancel_requested = False

    def consume(self, event):
        if (type(event.get('schema')) is not int or event['schema'] != 1
                or (event.get('taskId') or event.get('jobId')) != self.task):
            raise ProtocolError('事件 schema 或任务身份不匹配')
        if event.get('type') == 'stage' or event.get('resetProgress') is True:
            self.done = self.total = self.unit = self.counters = None
        if 'done' in event or 'total' in event:
            self.done, self.total = event.get('done'), event.get('total')
            self.unit = event.get('unit')
        if 'counters' in event:
            self.counters = event['counters']
        state = event.get('state')
        if event.get('type') == 'result':
            state = 'completed' if state == 'succeeded' else state
            if state not in ('completed', 'failed', 'cancelled'):
                raise ProtocolError('非法作业终态')
            self.state, self.terminal = state, True
        elif state not in (None, 'running'):
            raise ProtocolError('非 result 事件不能完成作业')

    def cancel_ack(self, response):
        self.cancel_requested = response.get('cancelled') is True
        # ACK only means signal sent. A result or subsequent get decides state.

    def eof(self, returncode):
        if not self.terminal:
            self.state = 'cancelled' if returncode == 130 else 'interrupted'


def device_view(result, *, quick=False, previous=None):
    """Preserve the Mac targetDevice result shape; unsupported != zero devices."""
    if result is None:
        return {'supported': False, 'reason': '本 Linux 原型未接入设备探测；不能判定是否连接设备'}
    if any(not isinstance(result.get(k), list) for k in ('connected', 'models', 'osChoices')):
        raise ProtocolError('非法 targetDevice 结果')
    return dict(result, supported=True,
                connected=(previous or {}).get('connected', []) if quick else result['connected'])


@dataclass
class Cursor:
    # Physical lines and bytes, never get.events, returned count or event.seq.
    line: int = 0
    offset: int = 0
    identity: tuple | None = None


class Client:
    def __init__(self, repository, private_root):
        self.repository = Path(repository).resolve()
        self.private = Path(private_root).expanduser().resolve()
        self.entry = self.repository / 'pack/jobs/main.py'

    def job_dirs(self):
        """任务记录目录，同 pack/jobs/core.py _job_dirs 的规则（客户端是独立程序，不导入后端）：索引表 library-index.json 第一项（默认位置）
        建好了（有 .s2arm-library.json）是 <默认位置>/logs/jobs，否则 <私有目录>/logs/jobs；再退回游戏库结构改造前的 <私有目录>/jobs"""
        home = self.private
        try:
            locations = json.loads((self.private / 'library-index.json').read_text(encoding='utf-8')).get('locations') or []
            library = Path(locations[0]['path']).expanduser().resolve() if locations else None
            if library and (library / '.s2arm-library.json').is_file():
                home = library
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            pass
        return list(dict.fromkeys([home / 'logs' / 'jobs', self.private / 'logs' / 'jobs', self.private / 'jobs']))

    def call(self, command, *args):
        if command not in ('get', 'events', 'cancel'):
            raise ProtocolError('本原型未实现此操作：不执行导入、出包、安装或续跑')
        env = dict(os.environ)
        env.pop('PYTHONPATH', None); env.pop('PYTHONHOME', None)
        p = subprocess.run([sys.executable, '-B', '-I', str(self.entry), command,
                            '--private-root', str(self.private), *args],
                           capture_output=True, env=env, timeout=30)
        if p.returncode:
            raise ProtocolError(f'Jobs {command} 失败（退出 {p.returncode}），请核对任务记录')
        parser = Lines()
        events = parser.feed(p.stdout); parser.finish()
        if command == 'events':
            return events
        if len(events) != 1:
            raise ProtocolError('Jobs 响应不是单个对象')
        return events[0]

    def get(self, task):
        result = self.call('get', '--task', task_id(task))
        if result.get('job', {}).get('id') != task:
            raise ProtocolError('任务快照身份不匹配')
        return result

    def cancel(self, task):
        return self.call('cancel', '--task', task_id(task), '--signal', 'TERM')

    def events(self, task, cursor):
        """Read a frozen complete physical prefix through the canonical CLI.

        Count valid JSON in that prefix solely to bound --limit. Concurrent
        appends cannot enter this response; incomplete tails remain unread.
        Historical events are display-only, not the current attempt's state.
        """
        task_id(task)
        path = next((d / (task + '.events.jsonl') for d in self.job_dirs() if (d / (task + '.events.jsonl')).exists()),
                    self.job_dirs()[0] / (task + '.events.jsonl'))
        if path.is_symlink() or path.parent.is_symlink():
            raise ProtocolError('拒绝链接事件文件')
        try:
            with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), 'rb') as stream:
                st = os.fstat(stream.fileno())
                if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():
                    raise ProtocolError('事件源必须是当前用户的普通文件')
                identity = (st.st_dev, st.st_ino)
                if cursor.identity not in (None, identity) or st.st_size < cursor.offset:
                    raise ProtocolError('事件源被替换或截短，请重新取得快照')
                stream.seek(cursor.offset)
                raw = stream.read(4 * 1024 * 1024 + 1)
                if len(raw) > 4 * 1024 * 1024:
                    raise ProtocolError('事件增量超过原型上限，请分开检查历史记录')
                end = raw.rfind(b'\n') + 1
                prefix = raw[:end]
                try:
                    lines = prefix.decode('utf-8').splitlines()
                except UnicodeError as error:
                    raise ProtocolError('事件源不是 UTF-8') from error
                expected = []
                for line in lines:
                    if not line.strip():
                        continue
                    try:
                        expected.append(json.loads(line))
                    except (ValueError, UnicodeError):
                        continue  # Same malformed-line behavior as Jobs read_events.
                got = self.call('events', '--task', task, '--since', str(cursor.line),
                                '--limit', str(len(expected))) if expected else []
                # Compare the canonical response with the frozen prefix. This is
                # source-race checking, not a second producer or state machine.
                stream.seek(cursor.offset)
                current = path.stat()
                if ((current.st_dev, current.st_ino) != identity
                        or stream.read(len(prefix)) != prefix or got != expected):
                    raise ProtocolError('读取期间事件源变化；游标未推进')
        except FileNotFoundError:
            if cursor.identity is not None:
                raise ProtocolError('事件源已消失')
            return []
        cursor.line += len(lines)
        cursor.offset += len(prefix)
        cursor.identity = identity
        return got
