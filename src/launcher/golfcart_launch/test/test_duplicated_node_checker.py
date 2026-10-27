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

"""A second `ros2 bag record` must not block autonomous mode."""

from pathlib import Path

import yaml

PKG = Path(__file__).parents[1]
PARAM = (
    PKG / 'config' / 'system' / 'duplicated_node_checker'
    / 'duplicated_node_checker.param.yaml'
)
UPSTREAM = Path(
    '/opt/autoware/1.5.0/share/autoware_launch/config/system/'
    'duplicated_node_checker/duplicated_node_checker.param.yaml'
)


def _params(path):
    return yaml.safe_load(path.read_text())['/**']['ros__parameters']


def test_recorder_is_ignored():
    assert '/rosbag2_recorder' in _params(PARAM)['nodes_to_ignore']


def test_copy_keeps_upstream_values():
    if not UPSTREAM.exists():
        return
    ours, theirs = _params(PARAM), _params(UPSTREAM)
    assert set(theirs['nodes_to_ignore']) <= set(ours['nodes_to_ignore'])
    for key, value in theirs.items():
        if key != 'nodes_to_ignore':
            assert ours[key] == value, key


def test_system_component_loads_the_copy():
    launch = (
        PKG / 'launch' / 'components' / 'tier4_system_component.launch.xml'
    ).read_text()
    assert (
        '$(find-pkg-share golfcart_launch)/config/system/'
        'duplicated_node_checker/duplicated_node_checker.param.yaml'
    ) in launch
