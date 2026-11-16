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

The two files under launch/components/ are copies of Autoware 2.1.0's,
changed only to carry use_lidar_rule_detector down to the lidar object
recognition launch and let it leave the clustering detector out. Anything else
that differs is drift: an upgrade that was not re-copied, or an edit that does
not belong in a copy.
"""

import difflib
from pathlib import Path
import re

import pytest

LAUNCH = Path(__file__).parents[1] / 'launch' / 'components'

COPIES = [
    ('autoware_launch', 'launch/components/component_perception.launch.xml',
     LAUNCH / 'tier4_perception_component.launch.xml'),
    ('autoware_perception_launch',
     'launch/object_recognition/object_recognition_lidar.launch.xml',
     LAUNCH / 'perception' / 'object_recognition_lidar.launch.xml'),
]

OURS = re.compile(r'golfcart_launch|use_lidar_rule_detector')
REPLACED = re.compile(
    r'find-pkg-share autoware_perception_launch\)/launch/'
    r'object_recognition/object_recognition_lidar\.launch\.xml'
    r'|<group>$'
    r'|<group if="\$\(var use_object_filter\)">'
    r'|name="input/detection03/channel" value="lidar_clustering"/>')


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


def test_rule_detector_switch_gates_the_detector_filter_and_channel():
    text = (LAUNCH / 'perception' / 'object_recognition_lidar.launch.xml').read_text()
    assert ('<group if="$(var use_lidar_rule_detector)">\n'
            '      <!-- Lidar rule-based detectors-->') in text
    assert "'$(var use_lidar_rule_detector)' == 'true'" in text
    assert ('<let name="input/detection03/channel" value="none" '
            'unless="$(var use_lidar_rule_detector)"/>') in text
    # The DNN detector stays unconditional.
    dnn = text.index('lidar_dnn_detector.launch.xml')
    assert text.rfind('<group>', 0, dnn) > text.rfind('<group if=', 0, dnn)


def test_component_hands_the_switch_to_our_copy():
    text = (LAUNCH / 'tier4_perception_component.launch.xml').read_text()
    assert ('find-pkg-share golfcart_launch)/launch/components/perception/'
            'object_recognition_lidar.launch.xml') in text
    assert '<arg name="use_lidar_rule_detector" value="$(var use_lidar_rule_detector)"/>' in text
