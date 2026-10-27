# Copyright 2026 Golf Cart Team
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""
The 1 Hz AD API heartbeat leaves outlast their publish period in every graph.

/autoware/localization/state, /autoware/planning/routing/state and
/adapi/mrm_request/delegate are published once a second by the /adapi nodes.
With the aggregator's 1.0 s default timeout a late publish reads STALE for a
tick, its subtree goes ERROR and the MRM handler brakes the cart (Phase 8 L6).
Our copies give them 3.0 / 3.0 / 5.0 s; every graph the launch can select must
reach those copies and not upstream's originals.
"""

from pathlib import Path
import re

import pytest
import yaml

PKG = Path(__file__).parents[1]
DIAG = PKG / 'config' / 'system' / 'diagnostics'
LAUNCH = PKG / 'launch' / 'golfcart_autoware.launch.xml'
PUBLISH_PERIOD = 1.0
UPSTREAM_DIAG = 'config/system/diagnostics'

# leaf path -> (file it is defined in, the timeout it must carry)
HEARTBEATS = {
    'autoware-main.yaml': {'/adapi/mrm_request/delegate': 5.0},
    'autoware-main-aruco.yaml': {'/adapi/mrm_request/delegate': 5.0},
    'localization.yaml': {'/autoware/localization/state': 3.0},
    'localization-aruco.yaml': {'/autoware/localization/state': 3.0},
    'planning.yaml': {'/autoware/planning/routing/state': 3.0},
}


def _load(path):
    return yaml.safe_load(path.read_text()) or {}


def _resolve(path, here):
    """Resolve a graph `files:` entry; None for a file outside this package."""
    if path.startswith('$(dirname)/'):
        return here.parent / path[len('$(dirname)/'):]
    assert path.startswith('$(find-pkg-share autoware_launch)/'), path
    return None


def _reached(graph):
    """Return every file a graph reaches: local Paths, and upstream base names."""
    local, upstream = [], []
    stack = [graph]
    while stack:
        f = stack.pop()
        local.append(f)
        for entry in _load(f).get('files', []):
            target = _resolve(entry['path'], f)
            if target is None:
                upstream.append(entry['path'].rsplit('/', 1)[1])
            else:
                assert target.is_file(), f'{f.name} includes missing {target}'
                stack.append(target)
    return local, upstream


def _units(graph):
    units = {}
    for f in _reached(graph)[0]:
        for u in _load(f).get('units', []):
            units[u['path']] = u
    return units


def _launch_graphs():
    """Return the graph files golfcart_autoware.launch.xml can select."""
    text = LAUNCH.read_text()
    names = re.findall(
        r'find-pkg-share golfcart_launch\)/config/system/diagnostics/([\w.-]+\.yaml)',
        text)
    assert names, 'no golfcart_launch graph found in the launch'
    assert 'find-pkg-share autoware_launch)/config/system/diagnostics' not in text, \
        'the launch still selects an upstream graph'
    return sorted(set(names))


def test_launch_selects_all_four_variants():
    assert _launch_graphs() == sorted([
        'autoware-main.yaml', 'autoware-main-no-perception.yaml',
        'autoware-main-aruco.yaml', 'autoware-main-aruco-no-perception.yaml'])


@pytest.mark.parametrize('name,leaves', sorted(HEARTBEATS.items()))
def test_copies_pin_the_heartbeat_timeouts(name, leaves):
    units = {u['path']: u for u in _load(DIAG / name)['units']}
    for path, timeout in leaves.items():
        unit = units[path]
        assert unit['type'] == 'diag'
        assert unit.get('timeout') == timeout, f'{path} in {name}'
        assert timeout >= 2 * PUBLISH_PERIOD


@pytest.mark.parametrize('graph', _launch_graphs())
def test_every_variant_reaches_the_copies(graph):
    local, upstream = _reached(DIAG / graph)
    assert 'localization.yaml' not in upstream and 'planning.yaml' not in upstream
    assert 'autoware-main.yaml' not in upstream
    names = {f.name for f in local}
    assert 'planning.yaml' in names
    assert names & {'localization.yaml', 'localization-aruco.yaml'}
    units = _units(DIAG / graph)
    assert units['/autoware/localization/state'].get('timeout') == 3.0
    assert units['/autoware/planning/routing/state'].get('timeout') == 3.0
    assert units['/adapi/mrm_request/delegate'].get('timeout') == 5.0


def _upstream(name):
    share = pytest.importorskip('ament_index_python.packages')
    try:
        root = share.get_package_share_directory('autoware_launch')
    except share.PackageNotFoundError:
        pytest.skip('autoware_launch is not installed')
    return Path(root) / UPSTREAM_DIAG / name


def _strip_timeouts(units):
    return [{k: v for k, v in u.items() if k != 'timeout'} for u in units]


@pytest.mark.parametrize('name', ['autoware-main.yaml', 'localization.yaml', 'planning.yaml'])
def test_copies_differ_from_upstream_only_by_timeout(name):
    ours, theirs = _load(DIAG / name), _load(_upstream(name))
    assert _strip_timeouts(ours['units']) == theirs['units'], f'{name} drifted from upstream'
    ours_files = [Path(f['path']).name for f in ours.get('files', [])]
    theirs_files = [Path(f['path']).name for f in theirs.get('files', [])]
    assert ours_files == theirs_files


def test_aruco_graph_matches_main_but_for_localization():
    main, aruco = _load(DIAG / 'autoware-main.yaml'), _load(DIAG / 'autoware-main-aruco.yaml')
    assert aruco['units'] == main['units']
    swap = {'localization.yaml': 'localization-aruco.yaml'}
    assert [swap.get(Path(f['path']).name, Path(f['path']).name) for f in main['files']] \
        == [Path(f['path']).name for f in aruco['files']]
    assert [f['path'] for f in aruco['files'] if 'aruco' not in f['path']] \
        == [f['path'] for f in main['files'] if 'localization' not in f['path']]
