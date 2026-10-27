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

from pathlib import Path

import pytest

load_config = pytest.importorskip('reflective_pose_core.config').load_config


SCENARIO_ROOT = (
    Path(__file__).parents[1]
    / 'config'
    / 'localization'
    / 'reflective_pose'
    / 'scenarios'
)


@pytest.mark.parametrize(
    ('scenario', 'runtime_centre_height'),
    [('basement', 1.3), ('sim', 1.0)],
)
def test_runtime_scenario_detector_configs_load(scenario, runtime_centre_height):
    config = load_config(str(SCENARIO_ROOT / scenario / 'detector.yaml'))

    assert config.detector.runtime.board_centre_height == pytest.approx(
        runtime_centre_height
    )
    assert config.detector.map.aabb.minimum == (None, None, None)
    assert config.detector.map.aabb.maximum == (None, None, None)


def test_falcon_map_detector_config_loads_with_its_effective_aabb():
    config = load_config(
        str(SCENARIO_ROOT / 'basement' / 'falcon_map.yaml')
    )

    assert config.detector.map.board_centre_height == pytest.approx(1.0)
    assert config.detector.map.aabb.minimum == (-20.0, -20.0, 0.5)
    assert config.detector.map.aabb.maximum == (20.0, 20.0, 1.1)


POLICY_ROOT = SCENARIO_ROOT.parent


def _policy(name):
    yaml = pytest.importorskip('yaml')
    with open(POLICY_ROOT / name) as f:
        return yaml.safe_load(f)['/**']['ros__parameters']


def test_vehicle_policy_waits_for_the_stack_to_take_a_pose():
    policy = _policy('board_pose_initializer.param.yaml')

    assert policy['require_velocity'] is True
    assert policy['stopped_for'] >= 3.0
    assert policy['ready_pointcloud_topic'] == (
        '/localization/util/downsample/pointcloud'
    )


def test_no_velocity_policy_differs_only_in_require_velocity():
    vehicle = _policy('board_pose_initializer.param.yaml')
    replay = _policy('board_pose_initializer.no_velocity.param.yaml')

    assert replay['require_velocity'] is False
    assert {k: v for k, v in replay.items() if k != 'require_velocity'} == {
        k: v for k, v in vehicle.items() if k != 'require_velocity'
    }
