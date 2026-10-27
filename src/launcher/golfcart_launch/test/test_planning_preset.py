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
The slow_indoor planning preset says what it changes, and changes nothing else.

Three things can drift without any launch failing:

- our copy of tier4_planning_component.launch.xml, after an Autoware upgrade;
- a parameter file copy, which would silently carry a stale upstream value;
- a module switch in the preset whose name upstream no longer declares, which
  ROS 2 launch drops without a word, so the module stays on.

Each is pinned here against the installed autoware_launch.
"""

import difflib
from pathlib import Path
import re

import pytest
import yaml

PKG = Path(__file__).parents[1]
COPY = PKG / 'launch' / 'components' / 'tier4_planning_component.launch.xml'
PRESETS = PKG / 'config' / 'planning' / 'preset'
SLOW = PKG / 'config' / 'planning' / 'slow_indoor'

UPSTREAM_COMPONENT = 'launch/components/tier4_planning_component.launch.xml'
UPSTREAM_PRESET = 'config/planning/preset/default_preset.yaml'
MOTION = ('config/planning/scenario_planning/lane_driving/motion_planning/'
          'motion_velocity_planner/')
BEHAVIOR = ('config/planning/scenario_planning/lane_driving/behavior_planning/'
            'behavior_path_planner/')

# Module switches: the whole decision, so that a change here is a reviewed one.
SWITCHES = {
    'launch_static_obstacle_avoidance': 'false',
    'launch_lane_change_right_module': 'false',
    'launch_lane_change_left_module': 'false',
    'launch_avoidance_by_lane_change_module': 'false',
    'launch_crosswalk_module': 'false',
    'launch_walkway_module': 'false',
    'launch_traffic_light_module': 'false',
    'launch_virtual_traffic_light_module': 'false',
    'launch_intersection_module': 'false',
    'launch_blind_spot_module': 'false',
    'launch_detection_area_module': 'false',
    'launch_no_stopping_area_module': 'false',
}

# Parameter file copies: (upstream relative path, copy, {leaf: (old, new)}).
PARAM_COPIES = [
    ('config/planning/scenario_planning/common/common.param.yaml',
     SLOW / 'common.param.yaml',
     {'max_vel': (4.17, 1.5)}),
    (MOTION + 'obstacle_stop.param.yaml',
     SLOW / 'obstacle_stop.param.yaml',
     {'obstacle_stop.stop_planning.stop_margin': (5.0, 2.0),
      'obstacle_stop.stop_planning.terminal_stop_margin': (3.0, 1.5),
      'obstacle_stop.stop_planning.min_behavior_stop_margin': (3.0, 1.5)}),
    (BEHAVIOR + 'drivable_area_expansion.param.yaml',
     SLOW / 'drivable_area_expansion.param.yaml',
     {'dynamic_expansion.ego.extra_width': (0.0, 0.1)}),
    (BEHAVIOR + 'start_planner/start_planner.param.yaml',
     SLOW / 'start_planner.param.yaml',
     {'start_planner.enable_back': (True, False),
      'start_planner.freespace_planner.enable_freespace_planner': (True, False)}),
    (BEHAVIOR + 'goal_planner/goal_planner.param.yaml',
     SLOW / 'goal_planner.param.yaml',
     {'goal_planner.pull_over.parallel_parking.backward.enable_arc_backward_parking':
          (True, False),
      'goal_planner.pull_over.freespace_parking.enable_freespace_parking': (True, False)}),
    (MOTION + 'road_user_stop.param.yaml',
     SLOW / 'road_user_stop.param.yaml',
     {'road_user_stop.stop_planning.longitudinal_margin.default_margin': (5.0, 2.0),
      'road_user_stop.stop_planning.longitudinal_margin.terminal_margin': (3.0, 1.5),
      'road_user_stop.stop_planning.longitudinal_margin.minimum_margin': (3.0, 1.5)}),
]

PATH_ARGS = {
    'golfcart_common_param_path': 'common.param.yaml',
    'golfcart_obstacle_stop_param_path': 'obstacle_stop.param.yaml',
    'golfcart_road_user_stop_param_path': 'road_user_stop.param.yaml',
    'golfcart_drivable_area_expansion_param_path': 'drivable_area_expansion.param.yaml',
    'golfcart_start_planner_param_path': 'start_planner.param.yaml',
    'golfcart_goal_planner_param_path': 'goal_planner.param.yaml',
}


def _upstream(relative):
    share = pytest.importorskip('ament_index_python.packages')
    try:
        root = share.get_package_share_directory('autoware_launch')
    except share.PackageNotFoundError:
        pytest.skip('autoware_launch is not installed')
    return Path(root) / relative


def _xml_lines(path):
    text = re.sub(r'<!--.*?-->', '', path.read_text(), flags=re.DOTALL)
    return [line.rstrip() for line in text.splitlines() if line.strip()]


def _leaves(node, prefix=''):
    if isinstance(node, dict):
        out = {}
        for key, value in node.items():
            out.update(_leaves(value, f'{prefix}.{key}' if prefix else str(key)))
        return out
    return {prefix: node}


def _params(path):
    return _leaves(yaml.safe_load(path.read_text())['/**']['ros__parameters'])


def _preset_args(path):
    entries = yaml.safe_load(path.read_text())['launch']
    return {e['arg']['name']: e['arg']['default'] for e in entries if 'arg' in e}


def test_component_copy_differs_from_upstream_only_in_marked_lines():
    diff = list(difflib.unified_diff(
        _xml_lines(_upstream(UPSTREAM_COMPONENT)), _xml_lines(COPY), lineterm='', n=0))
    added = [d[1:] for d in diff if d.startswith('+') and not d.startswith('+++')]
    removed = [d[1:] for d in diff if d.startswith('-') and not d.startswith('---')]

    assert [a for a in added if not re.search(r'golfcart_', a)] == []
    assert len(removed) == 7, removed
    assert any('find-pkg-share autoware_launch)/config/planning/preset/' in r
               for r in removed)
    # The six values the golfcart_ path arguments replace, and only those.
    for name in ('common_param_path', 'obstacle_stop_module_param_path',
                 'road_user_stop_module_param_path',
                 'drivable_area_expansion_param_path',
                 'goal_planner_module_param_path', 'start_planner_module_param_path'):
        assert any(f'{name}" value="$(var golfcart_' in a for a in added), name


def test_component_copy_defaults_paths_to_upstream_files():
    text = COPY.read_text()
    for arg, filename in PATH_ARGS.items():
        match = re.search(rf'<arg name="{arg}" default="([^"]+)"/>', text)
        assert match, arg
        default = match.group(1)
        assert default.startswith('$(find-pkg-share autoware_launch)/'), default
        assert default.endswith('/' + filename)


def test_default_preset_is_upstream_default():
    entries = yaml.safe_load((PRESETS / 'default_preset.yaml').read_text())['launch']
    assert entries == [{'include': {'file': '$(find-pkg-share autoware_launch)/'
                                            + UPSTREAM_PRESET}}]


def test_slow_indoor_switches_are_exactly_the_decided_ones():
    args = _preset_args(PRESETS / 'slow_indoor_preset.yaml')
    switches = {k: v for k, v in args.items() if k not in PATH_ARGS}
    assert switches == SWITCHES


def test_slow_indoor_switch_names_exist_upstream():
    # A misspelt name is a new, unread launch argument: no error, module on.
    upstream = _preset_args(_upstream(UPSTREAM_PRESET))
    assert sorted(set(SWITCHES) - set(upstream)) == []
    # And none of them is already off upstream, or the line says nothing.
    assert {k: upstream[k] for k in SWITCHES} == {k: 'true' for k in SWITCHES}


def test_slow_indoor_ends_with_the_default_preset():
    entries = yaml.safe_load((PRESETS / 'slow_indoor_preset.yaml').read_text())['launch']
    assert entries[-1] == {'include': {
        'file': '$(find-pkg-share golfcart_launch)/config/planning/preset/default_preset.yaml'}}


def test_slow_indoor_path_args_name_its_copies():
    args = _preset_args(PRESETS / 'slow_indoor_preset.yaml')
    for arg, filename in PATH_ARGS.items():
        assert args[arg] == ('$(find-pkg-share golfcart_launch)/config/planning/'
                             'slow_indoor/' + filename)
        assert (SLOW / filename).is_file()
    assert sorted(p.name for p in SLOW.iterdir()) == sorted(PATH_ARGS.values())


@pytest.mark.parametrize(('relative', 'copy', 'changes'), PARAM_COPIES,
                         ids=[c[1].name for c in PARAM_COPIES])
def test_param_copy_differs_from_upstream_only_in_listed_values(relative, copy, changes):
    upstream, ours = _params(_upstream(relative)), _params(copy)
    assert sorted(ours) == sorted(upstream), 'keys added or removed'
    differing = {k: (upstream[k], ours[k]) for k in upstream if upstream[k] != ours[k]}
    assert differing == changes


def test_stop_margins_keep_upstream_ordering():
    # terminal_stop_margin "cannot exceed stop margin" (upstream's comment).
    stop = _params(SLOW / 'obstacle_stop.param.yaml')
    pre = 'obstacle_stop.stop_planning.'
    assert stop[pre + 'terminal_stop_margin'] <= stop[pre + 'stop_margin']
    assert stop[pre + 'min_behavior_stop_margin'] <= stop[pre + 'stop_margin']
    road = _params(SLOW / 'road_user_stop.param.yaml')
    pre = 'road_user_stop.stop_planning.longitudinal_margin.'
    assert road[pre + 'terminal_margin'] <= road[pre + 'default_margin']
    assert road[pre + 'minimum_margin'] <= road[pre + 'default_margin']
    # One margin for both modules: which one stops the cart must not move the stop.
    assert road[pre + 'default_margin'] == stop['obstacle_stop.stop_planning.stop_margin']
