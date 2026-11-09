"""Tests for session.py: ids, scopes, the plan, and finding recordings again.

    python3 -m pytest scripts/recording/test_session.py
"""

import datetime as dt
import importlib.util
from pathlib import Path

import pytest

_SCRIPT = Path(__file__).resolve().with_name('session.py')
_spec = importlib.util.spec_from_file_location('session', _SCRIPT)
assert _spec is not None and _spec.loader is not None, _SCRIPT
session = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(session)


def test_new_id_format():
    now = dt.datetime(2026, 11, 9, 21, 3, 4)
    assert session.new_id('', now) == '20261109_210304'
    assert session.new_id('campus-loop', now) == '20261109_210304_campus-loop'
    assert session.valid_id('20261109_210304_campus-loop')
    assert not session.valid_id('20261109_210304_')
    assert not session.valid_id('master_20261109_210304')


@pytest.mark.parametrize('bad', ['a_b', 'a b', '../x', 'x/y', 'é'])
def test_new_id_rejects_bad_names(bad):
    with pytest.raises(ValueError):
        session.new_id(bad)


def test_repo_scopes_parse():
    data = session.load_scopes()
    assert data['default'] == 'drive'
    assert set(data['scopes']) == {'all', 'drive', 'raw', 'can', 'ros'}
    allm = session.scope_entry(data, 'all', 'master')
    assert allm['ros'] == 'all' and allm['disk'] == 'refuse'
    assert {'can0', 'can1'} <= set(allm['can'])
    assert session.scope_entry(data, 'raw', 'orin')['ros'] == 'none'
    assert session.scope_entry(data, 'can', 'orin')['pcap'] == []
    assert session.scope_entry(data, 'drive', 'master')['ros'] == 'list'


def test_unknown_role_is_the_union(tmp_path):
    f = tmp_path / 'scopes.yaml'
    f.write_text(
        'default: a\n'
        'scopes:\n'
        '  a:\n'
        '    master: {ros: list, can: [can0], pcap: [{iface: e1}]}\n'
        '    orin: {ros: all, can: [can0, can9], pcap: [{iface: e1}, {iface: e2, filter: x}]}\n')
    data = session.load_scopes(f)
    e = session.scope_entry(data, 'a', 'local')
    assert e['ros'] == 'all'
    assert e['can'] == ['can0', 'can9']
    assert [p['iface'] for p in e['pcap']] == ['e1', 'e2']
    assert len(e['topic_files']) == 2
    m = session.scope_entry(data, 'a', 'master')
    assert m['ros'] == 'list' and m['can'] == ['can0']


@pytest.mark.parametrize('body, msg', [
    ('default: zz\nscopes:\n  a: {}\n', 'default'),
    ('default: a\nscopes:\n  a:\n    master: {ros: some}\n', 'ros'),
    ('default: a\nscopes:\n  a:\n    master: {pcap: [eth0]}\n', 'iface'),
])
def test_bad_scopes_rejected(tmp_path, body, msg):
    f = tmp_path / 'scopes.yaml'
    f.write_text(body)
    with pytest.raises(ValueError, match=msg):
        session.load_scopes(f)


def test_unknown_scope():
    with pytest.raises(ValueError, match='unknown scope'):
        session.scope_entry(session.load_scopes(), 'nope', 'master')


def _net(tmp_path, name, operstate, flags='0x1003'):
    d = tmp_path / name
    d.mkdir()
    (d / 'operstate').write_text(operstate + '\n')
    (d / 'flags').write_text(flags + '\n')


def test_iface_state(tmp_path):
    _net(tmp_path, 'eth0', 'up')
    _net(tmp_path, 'eth1', 'down')
    _net(tmp_path, 'can0', 'unknown', '0xc1')
    _net(tmp_path, 'can1', 'unknown', '0x80')
    assert session.iface_state('eth0', tmp_path) == 'up'
    assert session.iface_state('eth1', tmp_path) == 'down'
    assert session.iface_state('can0', tmp_path) == 'up'
    assert session.iface_state('can1', tmp_path) == 'down'
    assert session.iface_state('nope', tmp_path) == 'missing'


def test_plan_skips_missing_and_uncapturable(tmp_path, monkeypatch):
    f = tmp_path / 'scopes.yaml'
    f.write_text('default: a\nscopes:\n  a:\n'
                 '    master: {can: [canX], pcap: [{iface: ethX, filter: "not port 22", snaplen: 128}]}\n')
    data = session.load_scopes(f)
    monkeypatch.setattr(session, 'iface_state', lambda n: 'up' if n == 'canX' else 'missing')
    monkeypatch.setattr(session.shutil, 'which', lambda n: '/usr/bin/' + n)
    monkeypatch.setattr(session, 'capture_ready', lambda: None)
    recs = session.plan(data, 'a', 'master', tmp_path)
    can, pcap = recs
    assert can['status'] == 'planned' and can['cmd'] == ['candump', '-L', 'canX']
    assert pcap['status'] == 'skipped' and 'missing' in pcap['reason']
    assert pcap['cmd'][-4:] == ['-f', 'not port 22', '-s', '128']
    monkeypatch.setattr(session, 'iface_state', lambda n: 'up')
    monkeypatch.setattr(session, 'capture_ready', lambda: 'no permission')
    pcap = session.plan(data, 'a', 'master', tmp_path)[1]
    assert pcap['status'] == 'skipped' and pcap['reason'] == 'no permission'


def test_args_file_roundtrip(tmp_path):
    f = tmp_path / '.golfcart-record.args'
    session.write_args_file('20261109_210304_x', 'raw', f)
    assert session.read_args_file(f) == {'id': '20261109_210304_x', 'scope': 'raw'}
    assert session.read_args_file(tmp_path / 'missing') == {}


def _bag(d):
    d.mkdir(parents=True)
    (d / 'metadata.yaml').write_text('rosbag2_bagfile_information: {}\n')


def test_latest_and_resolve(tmp_path, monkeypatch):
    monkeypatch.setenv('GOLFCART_RECORDINGS_DIR', str(tmp_path))
    _bag(tmp_path / '20261101_100000' / 'master' / 'bag')
    _bag(tmp_path / '20261102_100000_b' / 'master' / 'bag')
    _bag(tmp_path / '20261102_100000_b' / 'merged')
    (tmp_path / '20261103_100000' / 'orin').mkdir(parents=True)
    (tmp_path / '20261103_100000' / 'orin' / 'bag').mkdir()      # unfinalized
    assert session.latest('bag') == tmp_path / '20261102_100000_b' / 'merged'
    assert session.resolve_bag('20261101_100000', 'master') == \
        tmp_path / '20261101_100000' / 'master' / 'bag'
    assert session.resolve_bag('20261103_100000', 'master') is None
    log = tmp_path / '20261101_100000' / 'master' / 'can0.log'
    log.write_text('(1.0) can0 123#00\n')
    (tmp_path / '20261102_100000_b' / 'master' / 'can0.log').write_text('')
    assert session.latest('can') == log
    assert session.newest_id(None) == '20261103_100000'
