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
    assert set(data['scopes']) == {'all', 'drive', 'localize', 'autonomy', 'raw', 'can', 'ros'}
    allm = session.scope_entry(data, 'all', 'master')
    assert allm['ros'] == 'all' and allm['disk'] == 'refuse'
    assert {'can0', 'can1'} <= set(allm['can'])
    assert session.scope_entry(data, 'raw', 'orin')['ros'] == 'none'
    assert session.scope_entry(data, 'can', 'orin')['pcap'] == []
    assert session.scope_entry(data, 'drive', 'master')['ros'] == 'classes'


TOPICS = (
    'classes:\n'
    '  sens:\n'
    '    kind: first-hand\n'
    '    master: [/a, /b]\n'
    '    orin: [/z]\n'
    '    both: [/tf_static]\n'
    '  loc:\n'
    '    kind: computed\n'
    '    master: [/loc/pose, /b]\n'
    'replay:\n'
    '  stack_patterns: ["/planning(/.*)?"]\n'
    '  tf_computed: [{parent: map, child: base_link}]\n')


def _files(tmp_path, scopes, topics=TOPICS):
    f, t = tmp_path / 'scopes.yaml', tmp_path / 'topics.yaml'
    f.write_text(scopes)
    t.write_text(topics)
    return f, t


def test_unknown_role_is_the_union(tmp_path):
    f, t = _files(tmp_path,
        'default: a\n'
        'scopes:\n'
        '  a:\n'
        '    master: {ros: [sens], can: [can0], pcap: [{iface: e1}]}\n'
        '    orin: {ros: all, can: [can0, can9], pcap: [{iface: e1}, {iface: e2, filter: x}]}\n')
    data = session.load_scopes(f, t)
    e = session.scope_entry(data, 'a', 'local')
    assert e['ros'] == 'all'
    assert e['can'] == ['can0', 'can9']
    assert [p['iface'] for p in e['pcap']] == ['e1', 'e2']
    m = session.scope_entry(data, 'a', 'master')
    assert m['ros'] == 'classes' and m['can'] == ['can0']


def test_classes_per_role_and_kind_words(tmp_path):
    f, t = _files(tmp_path, 'default: a\nscopes:\n  a: {ros: [first-hand, loc]}\n'
                            '  old: {master: {ros: list}}\n')
    data = session.load_scopes(f, t)
    m = session.scope_entry(data, 'a', 'master')
    assert m['classes'] == ['sens', 'loc']
    # /b is in both classes; it is counted once, under the first.
    assert m['topics_by_class'] == {'sens': ['/a', '/b', '/tf_static'], 'loc': ['/loc/pose']}
    assert session.scope_topics(session.scope_entry(data, 'a', 'orin')) == ['/z', '/tf_static']
    assert session.scope_topics(session.scope_entry(data, 'a', 'local')) == \
        ['/a', '/b', '/z', '/tf_static', '/loc/pose']
    # The pre-class `ros: list` reads as the first-hand classes.
    assert session.scope_entry(data, 'old', 'master')['classes'] == ['sens']
    assert session.scope_entry(data, 'old', 'orin')['ros'] == 'none'


def test_unknown_class_rejected(tmp_path):
    f, t = _files(tmp_path, 'default: a\nscopes:\n  a: {ros: [sens, nope]}\n')
    with pytest.raises(ValueError, match="unknown topic class 'nope'"):
        session.load_scopes(f, t)


@pytest.mark.parametrize('topics, msg', [
    ('classes:\n  x: {kind: derived, master: [/a]}\n', 'kind'),
    ('classes:\n  x: {kind: computed, master: [a]}\n', 'not a topic'),
    ('classes:\n  x: {kind: computed, host: [/a]}\n', 'unknown key'),
    ('classes:\n  computed: {kind: computed}\n', 'reserved'),
])
def test_bad_topics_rejected(tmp_path, topics, msg):
    t = tmp_path / 'topics.yaml'
    t.write_text(topics)
    with pytest.raises(ValueError, match=msg):
        session.load_topics(t)


def test_extra_topics_is_gone(tmp_path):
    f, t = _files(tmp_path, 'default: a\nscopes:\n  a:\n'
                            '    master: {ros: list, extra_topics: [x.txt]}\n')
    with pytest.raises(ValueError, match='extra_topics'):
        session.load_scopes(f, t)


def test_replay_plan_excludes_computed(tmp_path):
    _, t = _files(tmp_path, '')
    topics = session.load_topics(t)
    assert session.computed_topics(topics) == ['/loc/pose', '/b']
    bag = ['/a', '/b', '/loc/pose', '/tf', '/planning/x', '/planning', '/driver/extra']
    p = session.replay_plan(bag, topics, computed=False)
    assert p['exclude_computed'] == ['/b', '/loc/pose']
    assert p['exclude_pattern'] == ['/planning/x', '/planning']
    assert p['include'] == ['/a', '/tf', '/driver/extra']
    assert p['tf_filter']
    everything = session.replay_plan(bag, topics, computed=True)
    assert everything['include'] is None and not everything['tf_filter']
    # Nothing computed in the bag: play it as before, no --topics, no filter.
    plain = session.replay_plan(['/a', '/z'], topics, computed=False)
    assert plain['include'] is None and plain['exclude'] == [] and not plain['tf_filter']


def test_repo_topics_and_replay_of_a_drive_bag():
    """The repo's own files: drive records NDT; replay drops it and keeps sensors."""
    data = session.load_scopes()
    topics = data['topics']
    kinds = {n: b['kind'] for n, b in topics['classes'].items()}
    assert kinds['localization'] == kinds['diagnostics'] == 'computed'
    assert kinds['lidar'] == kinds['tf'] == 'first-hand'
    m = session.scope_entry(data, 'drive', 'master')
    t = session.scope_topics(m)
    assert '/localization/pose_estimator/nearest_voxel_transformation_likelihood' in t
    assert '/localization/kinematic_state' in t
    assert '/sensing/lidar/vlp32/velodyne_points' in t
    assert len(t) == len(set(t))
    assert session.scope_entry(data, 'localize', 'master')['classes'] == m['classes']
    ros = session.scope_entry(data, 'ros', 'master')
    assert all(kinds[c] == 'first-hand' for c in ros['classes'])
    o = session.scope_topics(session.scope_entry(data, 'drive', 'orin'))
    assert '/sensing/camera/zed/imu/data' in o and not any(x.startswith('/localization') for x in o)
    p = session.replay_plan(t, topics, computed=False)
    assert not any(x.startswith(('/localization', '/control', '/diagnostics')) for x in p['include'])
    assert '/sensing/lidar/vlp32/velodyne_points' in p['include'] and '/tf' in p['include']
    assert p['tf_filter']


def test_plan_records_classes(tmp_path, monkeypatch):
    f, t = _files(tmp_path, 'default: a\nscopes:\n  a: {ros: [sens, loc]}\n')
    data = session.load_scopes(f, t)
    rec = session.plan(data, 'a', 'master', tmp_path)[0]
    assert rec['mode'] == 'classes' and rec['topics_requested'] == 4
    assert rec['classes'] == {'sens': {'kind': 'first-hand', 'topics': 3},
                              'loc': {'kind': 'computed', 'topics': 1}}
    assert rec['cmd'][-4:] == ['/a', '/b', '/tf_static', '/loc/pose']


@pytest.mark.parametrize('body, msg', [
    ('default: zz\nscopes:\n  a: {}\n', 'default'),
    ('default: a\nscopes:\n  a:\n    master: {ros: some}\n', 'ros'),
    ('default: a\nscopes:\n  a:\n    master: {ros: [nope]}\n', 'unknown topic class'),
    ('default: a\nscopes:\n  a:\n    master: {pcap: [eth0]}\n', 'iface'),
])
def test_bad_scopes_rejected(tmp_path, body, msg):
    f, t = _files(tmp_path, body)
    with pytest.raises(ValueError, match=msg):
        session.load_scopes(f, t)


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
    f, t = _files(tmp_path, 'default: a\nscopes:\n  a:\n'
                  '    master: {can: [canX], pcap: [{iface: ethX, filter: "not port 22", snaplen: 128}]}\n')
    data = session.load_scopes(f, t)
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


def test_play_dry_run(tmp_path, capsys):
    spec = importlib.util.spec_from_file_location('play', _SCRIPT.with_name('play.py'))
    play = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(play)
    bag = tmp_path / 'bag'
    bag.mkdir()
    names = ['/sensing/lidar/vlp32/velodyne_points', '/diagnostics', '/tf',
             '/localization/kinematic_state', '/planning/scenario_planning/trajectory']
    (bag / 'metadata.yaml').write_text(
        'rosbag2_bagfile_information:\n  topics_with_message_count:\n'
        + ''.join(f'    - topic_metadata: {{name: {n}}}\n      message_count: 1\n' for n in names))
    assert play.main(['--dry-run', str(bag), '--clock']) == 0
    out = capsys.readouterr().out
    run = out.split('would run: ')[1].split()
    assert run[:4] == ['ros2', 'bag', 'play', str(bag)]
    played = run[run.index('--topics') + 1:run.index('--remap')]
    assert played == ['/sensing/lidar/vlp32/velodyne_points', '/tf']
    assert run[-2:] == ['/tf:=/replay/tf_recorded', '--clock']
    assert play.main(['--dry-run', '--computed', str(bag), '--clock']) == 0
    assert capsys.readouterr().out.strip().endswith(f'ros2 bag play {bag} --clock')
