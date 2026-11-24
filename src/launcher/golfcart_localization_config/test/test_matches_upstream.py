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
This package is upstream's autoware_localization_config with marked overrides.

Every file of the installed autoware_localization_config is here, with the
same keys, and the same values except the ones listed in OVERRIDES. Each of
those carries a `# {OVERRIDE: ...}` marker on its line, upstream's own
convention, so a diff against a new Autoware release shows ours at a glance.

Drift this catches: upstream adds a file or a required key (a node then aborts
at startup on our copy), or a value here changes without being declared.
"""

from pathlib import Path

import pytest
import yaml

OURS = Path(__file__).parents[1] / 'config'

NDT = 'ndt_scan_matcher/'
PRE = NDT + 'pointcloud_preprocessor/'
ROS = '/**.ros__parameters.'

# The whole list of our changes: {file: {leaf: (upstream, ours)}}.
OVERRIDES = {
    NDT + 'ndt_scan_matcher.param.yaml': {
        ROS + 'score_estimation.'
        'converged_param_nearest_voxel_transformation_likelihood': (2.3, 1.3),
    },
    PRE + 'crop_box_filter_measurement_range.param.yaml': {
        ROS + 'min_z': (-30.0, -1.0),
    },
    PRE + 'random_downsample_filter.param.yaml': {
        ROS + 'sample_num': (1500, 2000),
    },
    PRE + 'voxel_grid_filter.param.yaml': {
        ROS + 'voxel_size_x': (3.0, 0.5),
        ROS + 'voxel_size_y': (3.0, 0.5),
        ROS + 'voxel_size_z': (3.0, 0.5),
    },
}


def _upstream_root():
    share = pytest.importorskip('ament_index_python.packages')
    try:
        root = share.get_package_share_directory('autoware_localization_config')
    except share.PackageNotFoundError:
        pytest.skip('autoware_localization_config is not installed')
    return Path(root) / 'config'


def _files(root):
    return sorted(str(p.relative_to(root)) for p in root.rglob('*') if p.is_file())


def _leaves(node, prefix=''):
    if isinstance(node, dict):
        out = {}
        for key, value in node.items():
            out.update(_leaves(value, f'{prefix}.{key}' if prefix else str(key)))
        return out
    return {prefix: node}


def test_same_files():
    assert _files(OURS) == _files(_upstream_root())


@pytest.mark.parametrize('relative', _files(OURS))
def test_same_keys_and_values(relative):
    upstream = _leaves(yaml.safe_load((_upstream_root() / relative).read_text()))
    ours = _leaves(yaml.safe_load((OURS / relative).read_text()))
    assert sorted(ours) == sorted(upstream), 'key sets differ'
    declared = OVERRIDES.get(relative, {})
    for leaf, (old, new) in declared.items():
        assert upstream[leaf] == old, f'{leaf}: upstream moved to {upstream[leaf]!r}'
        assert ours[leaf] == new, f'{leaf}: ours is {ours[leaf]!r}'
    changed = {k for k in ours if ours[k] != upstream[k]}
    assert changed == set(declared), 'undeclared change'


@pytest.mark.parametrize('relative', sorted(OVERRIDES))
def test_overrides_are_marked(relative):
    text = (OURS / relative).read_text().splitlines()
    for leaf in OVERRIDES[relative]:
        key = leaf.rsplit('.', 1)[1] + ':'
        lines = [line for line in text if line.strip().startswith(key)]
        assert lines and all('{OVERRIDE' in line for line in lines), leaf
