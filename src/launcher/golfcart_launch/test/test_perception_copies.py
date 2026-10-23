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
Our perception launch copies differ from upstream only where they say so.

The three files under launch/components/ are copies of Autoware 1.5.0's,
changed only to carry use_lidar_rule_detector down to the detection launch.
Anything else that differs is drift: an upgrade that was not re-copied, or an
edit that does not belong in a copy.
"""

import difflib
from pathlib import Path
import re

import pytest

LAUNCH = Path(__file__).parents[1] / 'launch' / 'components'

COPIES = [
    ('autoware_launch', 'launch/components/tier4_perception_component.launch.xml',
     LAUNCH / 'tier4_perception_component.launch.xml'),
    ('tier4_perception_launch', 'launch/perception.launch.xml',
     LAUNCH / 'perception' / 'perception.launch.xml'),
    ('tier4_perception_launch',
     'launch/object_recognition/detection/detection.launch.xml',
     LAUNCH / 'perception' / 'detection.launch.xml'),
]

# What a changed line may say: our own package in an include, or the switch.
OURS = re.compile(r'golfcart_launch|use_lidar_rule_detector')
# What a removed upstream line may be: the include we redirect, or the one
# hardcoded switch we replace.
REPLACED = re.compile(
    r'find-pkg-share tier4_perception_launch\)/launch/'
    r'(perception|object_recognition/detection/detection)\.launch\.xml'
    r'|switch/detector/lidar_rule" value="true"')


def _upstream(package, relative):
    share = pytest.importorskip('ament_index_python.packages')
    try:
        root = share.get_package_share_directory(package)
    except share.PackageNotFoundError:
        pytest.skip(f'{package} is not installed')
    return Path(root) / relative


def _lines(path):
    text = re.sub(r'<!--.*?-->', '', path.read_text(), flags=re.DOTALL)
    return [line.rstrip() for line in text.splitlines() if line.strip()]


@pytest.mark.parametrize(('package', 'relative', 'copy'), COPIES,
                         ids=[c[2].name for c in COPIES])
def test_copy_differs_from_upstream_only_in_marked_lines(package, relative, copy):
    diff = list(difflib.unified_diff(
        _lines(_upstream(package, relative)), _lines(copy), lineterm='', n=0))
    added = [d[1:] for d in diff if d.startswith('+') and not d.startswith('+++')]
    removed = [d[1:] for d in diff if d.startswith('-') and not d.startswith('---')]

    assert added, 'the copy is identical to upstream; include upstream instead'
    assert [a for a in added if not OURS.search(a)] == []
    assert [r for r in removed if not REPLACED.search(r)] == []


def test_lidar_mode_gates_only_the_clustering_detector():
    text = (LAUNCH / 'perception' / 'detection.launch.xml').read_text()
    lidar = re.search(
        r'==&quot;lidar&quot;\'\)">(.*?)</group>', text, flags=re.DOTALL).group(1)

    assert ('<let name="switch/detector/lidar_rule" '
            'value="$(var use_lidar_rule_detector)"/>') in lidar
    assert '<let name="switch/detector/lidar_dnn" value="true"/>' in lidar
