"""
Every place that holds the cart's steering limit holds the same one (Phase 8, M9).

The limit is the vehicle description's `max_steer_angle`: the MPC, the planners
and the lane tool read it from there. Three other places carry their own copy,
and each one has to be edited by hand when the limit changes:

    simulator    simulator_model.param.yaml `steer_lim`, the planning sim's
                 physical stop, so a sim run steers no further than the cart
    keyboard     `just vehicle manual-control`'s `max_steer_angle:=`
    interface    golfcart_vehicle_interface's `max_tire_angle_rad`, the last
                 clamp before the CAN frame (code default, unless the param
                 file sets it)

`scripts/map/centerline_to_lanelet.py` reads the description itself; it is
checked here so a future copy in it is caught too.

So changing the limit is a one-value change plus whatever this test names.

The two copies marked xfail disagreed with the description when this test was
written (2026-10-24), and are reported in Phase 9, not fixed here, because the
limit itself is undecided (Phase 9, decision 4). The marks are strict: once a
copy agrees, its xfail turns into a failure and the mark must be deleted.
"""

import importlib.util
import math
from pathlib import Path
import re

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[4]
VEHICLE = ROOT / 'src' / 'vehicle' / 'golfcart_vehicle_launch'
DESCRIPTION = VEHICLE / 'golfcart_vehicle_description' / 'config'
VEHICLE_INFO = DESCRIPTION / 'vehicle_info.param.yaml'
SIMULATOR_MODEL = DESCRIPTION / 'simulator_model.param.yaml'
VEHICLE_JUST = ROOT / 'just' / 'vehicle.just'
INTERFACE_PARAMS_RS = VEHICLE / 'golfcart_vehicle_interface' / 'src' / 'params.rs'
INTERFACE_PARAM_FILE = (VEHICLE / 'golfcart_vehicle_launch' / 'config'
                        / 'vehicle_interface.param.yaml')
LANE_TOOL = ROOT / 'scripts' / 'map' / 'centerline_to_lanelet.py'

# Ads_Vcu_Target_Tire_Angle is +-30 deg in the vendor DBC.
VCU_MAX_TIRE_ANGLE_RAD = math.radians(30.0)
# Agreement within a hundredth of a degree: the keyboard recipe and the code
# default are hand-typed decimals.
TOL_RAD = math.radians(0.01)


def _ros_params(path):
    return yaml.safe_load(path.read_text())['/**']['ros__parameters']


def vehicle_info():
    return float(_ros_params(VEHICLE_INFO)['max_steer_angle'])


def simulator():
    return float(_ros_params(SIMULATOR_MODEL)['steer_lim'])


def keyboard():
    text = VEHICLE_JUST.read_text()
    recipe = re.search(r'^manual-control\b.*?(?=^\S|\Z)', text, re.M | re.S)
    assert recipe, f'no manual-control recipe in {VEHICLE_JUST}'
    values = re.findall(r'max_steer_angle:=([-+0-9.eE]+)', recipe.group(0))
    assert len(values) == 1, (
        f'manual-control should pass max_steer_angle exactly once, found {values}')
    return float(values[0])


def interface():
    params = _ros_params(INTERFACE_PARAM_FILE)
    if 'max_tire_angle_rad' in params:
        return float(params['max_tire_angle_rad'])
    text = INTERFACE_PARAMS_RS.read_text()
    m = re.search(
        r'declare_parameter\("max_tire_angle_rad"\)(?:\s|//[^\n]*\n)*'
        r'\.default\(([-+0-9.eE]+)\)', text)
    assert m, f'no max_tire_angle_rad default found in {INTERFACE_PARAMS_RS}'
    return float(m.group(1))


def lane_tool():
    spec = importlib.util.spec_from_file_location('centerline_to_lanelet', LANE_TOOL)
    assert spec is not None and spec.loader is not None, LANE_TOOL
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    _, max_steer = module.vehicle_geometry()
    return float(max_steer)


def _known_disagreement(fn, why):
    return pytest.param(fn, id=fn.__name__,
                        marks=pytest.mark.xfail(strict=True, reason=why))


COPIES = [
    _known_disagreement(
        simulator,
        'steer_lim is 1.0, upstream default kept from the sample vehicle; '
        'the planning sim steers up to 57 deg (Phase 9, decision 4)'),
    _known_disagreement(
        keyboard,
        'manual-control still passes 0.349, the PWM cart value from before '
        '2026-10-05 (Phase 9, decision 4)'),
    pytest.param(interface, id='interface'),
    pytest.param(lane_tool, id='lane_tool'),
]


def test_description_limit_is_inside_the_vcu_range():
    limit = vehicle_info()
    assert 0.0 < limit <= VCU_MAX_TIRE_ANGLE_RAD, (
        f'max_steer_angle {limit} rad is outside (0, {VCU_MAX_TIRE_ANGLE_RAD:.4f}]')


@pytest.mark.parametrize('copy', COPIES)
def test_copy_agrees_with_the_vehicle_description(copy):
    want, got = vehicle_info(), copy()
    assert abs(got - want) <= TOL_RAD, (
        f'{copy.__name__} holds {got} rad ({math.degrees(got):.2f} deg), the vehicle '
        f'description {want} rad ({math.degrees(want):.2f} deg): {VEHICLE_INFO}')
