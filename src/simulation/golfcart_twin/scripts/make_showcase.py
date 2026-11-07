#!/usr/bin/env python3
"""Showcase scenarios on route 1 (Phase 10): what an OpenSCENARIO script adds to the twin.

    python3 make_showcase.py [--check]

Writes scenarios/showcase_<name>.xosc. Each is route 1 (config/routes.yaml: from the west,
left at the T in front of 學新館, north), with:

- pedestrian: a pedestrian steps off the east kerb of the north road when the cart nears and
  crosses in front of it. Passes at the goal; fails if the cart touches the pedestrian or
  comes within 1 m of it in its path (the cart must stop for it: perception).
- lead_vehicle: a car pulls out ahead of the cart and drives the same way at 1.5 m/s, past the
  goal and on (route 3's way). The cart follows behind it. Fails on contact.
- traffic: background traffic: a car coming the other way (route 2's way: down the north road,
  right at the T, west), a parked car on the west road's far side, two pedestrians walking
  along the north road. Fails on contact.

The cart is this package's catalog entry, driven by its own Autoware; NPCs are driven by
SSv2 (their bodies are the Isaac world server's CARLA catalogue, chosen by size).
"""
import sys
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from make_scenarios import MAX_SPEED, PKG  # noqa: E402

ROUTES = yaml.safe_load((PKG / "config" / "routes.yaml").read_text())["routes"]
R1, R2, R3 = ROUTES["1"], ROUTES["2"], ROUTES["3"]
Z = 12.0  # the junction's elevation, near enough for the NPCs' WorldPositions (SSv2 snaps to lanes)


def wp(x, y, z=Z, h=0.0):
    return f'<WorldPosition x="{x}" y="{y}" z="{z}" h="{h}" p="0" r="0" />'


def pose(p):
    return wp(p["x"], p["y"], p["z"], p["yaw"])


def condition_reach(name, entity, position, tol):
    return f"""<Condition name="{name}" delay="0" conditionEdge="none"><ByEntityCondition>
            <TriggeringEntities triggeringEntitiesRule="any"><EntityRef entityRef="{entity}" /></TriggeringEntities>
            <EntityCondition><ReachPositionCondition tolerance="{tol}"><Position>{position}</Position></ReachPositionCondition></EntityCondition>
          </ByEntityCondition></Condition>"""


def fail_on_contact(npc):
    return f"""<Event name="contact_{npc}" priority="parallel">
              <Action name="fail_contact_{npc}"><UserDefinedAction><CustomCommandAction type="exitFailure" /></UserDefinedAction></Action>
              <StartTrigger><ConditionGroup><Condition name="ego_touches_{npc}" delay="0" conditionEdge="none"><ByEntityCondition>
                <TriggeringEntities triggeringEntitiesRule="any"><EntityRef entityRef="ego" /></TriggeringEntities>
                <EntityCondition><CollisionCondition><EntityRef entityRef="{npc}" /></CollisionCondition></EntityCondition>
              </ByEntityCondition></Condition></ConditionGroup></StartTrigger>
            </Event>"""


def car(name, length=4.5, width=1.8, height=1.5):
    return f"""<ScenarioObject name="{name}">
      <Vehicle name="{name}" vehicleCategory="car">
        <BoundingBox><Center x="1.4" y="0.0" z="{height / 2}" /><Dimensions width="{width}" height="{height}" length="{length}" /></BoundingBox>
        <Performance maxSpeed="10" maxAcceleration="3.0" maxDeceleration="5.0" />
        <Axles>
          <FrontAxle maxSteering="0.6" wheelDiameter="0.6" trackWidth="1.5" positionX="2.7" positionZ="0.3" />
          <RearAxle maxSteering="0.0" wheelDiameter="0.6" trackWidth="1.5" positionX="0.0" positionZ="0.3" />
        </Axles>
        <Properties />
      </Vehicle>
      <ObjectController><Controller name=""><Properties /></Controller></ObjectController>
    </ScenarioObject>"""


def walker(name, model="walker.pedestrian.0001"):
    # name: a CARLA walker blueprint, so Isaac's world server dresses it as that walker
    return f"""<ScenarioObject name="{name}">
      <Pedestrian model="unspecified" mass="70.0" name="{model}" pedestrianCategory="pedestrian">
        <BoundingBox><Center x="0.0" y="0.0" z="0.9" /><Dimensions width="0.6" length="0.6" height="1.8" /></BoundingBox>
        <Properties />
      </Pedestrian>
      <!-- isBlind: it walks its path whatever is in the way (SSv2's entities otherwise see
           around and stop for what is ahead, the cart included) -->
      <ObjectController><Controller name=""><Properties><Property name="isBlind" value="true" /></Properties></Controller></ObjectController>
    </ScenarioObject>"""


def teleport(entity, position):
    return f"""<Private entityRef="{entity}"><PrivateAction><TeleportAction><Position>{position}</Position></TeleportAction></PrivateAction></Private>"""


def speed_action(speed):
    return f"""<PrivateAction><LongitudinalAction><SpeedAction>
                  <SpeedActionDynamics dynamicsShape="step" value="0" dynamicsDimension="time" />
                  <SpeedActionTarget><AbsoluteTargetSpeed value="{speed}" /></SpeedActionTarget>
                </SpeedAction></LongitudinalAction></PrivateAction>"""


def drive(entity, speed, goal):
    """Two actions (an Action holds one PrivateAction): the speed, then the destination."""
    return [speed_action(speed),
            f"""<PrivateAction><RoutingAction><AcquirePositionAction><Position>{goal}</Position></AcquirePositionAction></RoutingAction></PrivateAction>"""]


def walk(name, vertices):
    vs = "".join(f'<Vertex time="{t}"><Position>{wp(x, y, Z, h)}</Position></Vertex>' for t, x, y, h in vertices)
    return f"""<PrivateAction><RoutingAction><FollowTrajectoryAction initialDistanceOffset="0">
                  <TimeReference><Timing domainAbsoluteRelative="relative" offset="0" scale="1" /></TimeReference>
                  <TrajectoryFollowingMode followingMode="position" />
                  <TrajectoryRef><Trajectory name="{name}_path" closed="false"><ParameterDeclarations />
                    <Shape><Polyline>{vs}</Polyline></Shape>
                  </Trajectory></TrajectoryRef>
                </FollowTrajectoryAction></RoutingAction></PrivateAction>"""


def walk_at(name, speed, points):
    """Walk the points at `speed` (m/s), untimed: a timed trajectory started late by a trigger
    never moved here (its vertex times are counted from the interpreter's clock)."""
    vs = "".join(f'<Vertex><Position>{wp(x, y, Z, h)}</Position></Vertex>' for x, y, h in points)
    return [speed_action(speed), f"""<PrivateAction><RoutingAction><FollowTrajectoryAction initialDistanceOffset="0">
                  <TimeReference><None /></TimeReference>
                  <TrajectoryFollowingMode followingMode="position" />
                  <TrajectoryRef><Trajectory name="{name}_path" closed="false"><ParameterDeclarations />
                    <Shape><Polyline>{vs}</Polyline></Shape>
                  </Trajectory></TrajectoryRef>
                </FollowTrajectoryAction></RoutingAction></PrivateAction>"""]


def after(name, event_ref, delay):
    return f"""<Condition name="{name}" delay="{delay}" conditionEdge="none"><ByValueCondition>
            <StoryboardElementStateCondition storyboardElementType="event" storyboardElementRef="{event_ref}" state="completeState" />
          </ByValueCondition></Condition>"""


def group(name, actors, events):
    refs = "".join(f'<EntityRef entityRef="{a}" />' for a in actors)
    return f"""<ManeuverGroup maximumExecutionCount="1" name="{name}">
          <Actors selectTriggeringEntities="false">{refs}</Actors>
          <Maneuver name="{name}_m">{"".join(events)}</Maneuver>
        </ManeuverGroup>"""


def event(name, actions, conditions):
    actions = [actions] if isinstance(actions, str) else actions
    acts = "".join(f'<Action name="{name}_a{i}">{a}</Action>' for i, a in enumerate(actions))
    return f"""<Event name="{name}" priority="parallel">
            {acts}
            <StartTrigger><ConditionGroup>{conditions}</ConditionGroup></StartTrigger>
          </Event>"""


AT_START = """<Condition name="at_start" delay="0" conditionEdge="none"><ByValueCondition><SimulationTimeCondition value="0" rule="greaterThan" /></ByValueCondition></Condition>"""


def scenario(name, description, entities, init, groups, contacts, timeout=240):
    s, g = R1["start"], R1["goal"]
    ego_events = [
        event("success", '<UserDefinedAction><CustomCommandAction type="exitSuccess" /></UserDefinedAction>',
              condition_reach("reach_goal", "ego", pose(g), 2.0)),
        event("timeout", '<UserDefinedAction><CustomCommandAction type="exitFailure" /></UserDefinedAction>',
              f'<Condition name="too_long" delay="0" conditionEdge="none"><ByValueCondition><SimulationTimeCondition value="{timeout}" rule="greaterThan" /></ByValueCondition></Condition>'),
    ] + [fail_on_contact(n) for n in contacts]
    return f"""<?xml version="1.0"?>
<!-- Generated by golfcart_twin scripts/make_showcase.py: do not edit. -->
<OpenSCENARIO>
  <FileHeader author="golfcart_twin" date="2026-11-08T00:00:00+00:00" description="NTU twin, route 1 showcase, {name}: {description}" revMajor="1" revMinor="2" />
  <ParameterDeclarations />
  <CatalogLocations>
    <VehicleCatalog><Directory path="$(find-pkg-share golfcart_twin)/catalogs" /></VehicleCatalog>
  </CatalogLocations>
  <RoadNetwork><LogicFile filepath="$(env TWIN_MAP)" /></RoadNetwork>
  <Entities>
    <ScenarioObject name="ego">
      <CatalogReference catalogName="vehicles" entryName="newslab_golfcart">
        <ParameterAssignments>
          <ParameterAssignment parameterRef="maxSpeed" value="{MAX_SPEED}" />
          <ParameterAssignment parameterRef="maxAcceleration" value="3.0" />
          <ParameterAssignment parameterRef="maxDeceleration" value="6.0" />
          <ParameterAssignment parameterRef="maxSteering" value="0.52" />
        </ParameterAssignments>
      </CatalogReference>
      <ObjectController><Controller name="Autoware"><Properties>
        <Property name="maxJerk" value="1.5" /><Property name="minJerk" value="-1.5" />
      </Properties></Controller></ObjectController>
    </ScenarioObject>
    {"".join(entities)}
  </Entities>
  <Storyboard>
    <Init><Actions>
      <Private entityRef="ego">
        <PrivateAction><TeleportAction><Position>{pose(s)}</Position></TeleportAction></PrivateAction>
        <PrivateAction><RoutingAction><AcquirePositionAction><Position>{pose(g)}</Position></AcquirePositionAction></RoutingAction></PrivateAction>
      </Private>
      {"".join(init)}
    </Actions></Init>
    <Story name="showcase_{name}">
      <Act name="act">
        {group("ego_checks", ["ego"], ego_events)}
        {"".join(groups)}
        <StartTrigger><ConditionGroup>{AT_START}</ConditionGroup></StartTrigger>
      </Act>
    </Story>
    <StopTrigger />
  </Storyboard>
</OpenSCENARIO>
"""


def pedestrian():
    # The north road's lanes: northbound x ~53021.7 (the cart's), southbound x ~53017.2.
    y, h = 67880.0, 3.1416  # crossing westward
    clearance = event(
        "pedestrian_clearance",
        '<UserDefinedAction><CustomCommandAction type="exitFailure" /></UserDefinedAction>',
        """<Condition name="walker_in_path" delay="0" conditionEdge="none"><ByEntityCondition>
            <TriggeringEntities triggeringEntitiesRule="any"><EntityRef entityRef="ego" /></TriggeringEntities>
            <EntityCondition><RelativeDistanceCondition entityRef="walker" freespace="true" relativeDistanceType="lateral" coordinateSystem="entity" rule="lessThan" value="0.3" /></EntityCondition>
          </ByEntityCondition></Condition>
          <Condition name="cart_within_1m" delay="0" conditionEdge="none"><ByEntityCondition>
            <TriggeringEntities triggeringEntitiesRule="any"><EntityRef entityRef="ego" /></TriggeringEntities>
            <EntityCondition><RelativeDistanceCondition entityRef="walker" freespace="true" relativeDistanceType="longitudinal" coordinateSystem="entity" rule="lessThan" value="1.0" /></EntityCondition>
          </ByEntityCondition></Condition>""")
    # It steps off the kerb when the cart is 20 m away (straight line), walking straight west
    # (SSv2's WalkStraightAction: a timed trajectory started by a trigger never moved here, and
    # SSv2 has no untimed one); it stops in the cart's lane, stands there 5 s, then walks on
    # across. The cart has to stop for it.
    walk_straight = '<UserDefinedAction><CustomCommandAction type="WalkStraightAction()" /></UserDefinedAction>'
    step_in = event("step_in", [walk_straight, speed_action(0.8)],
                    """<Condition name="cart_within_20m" delay="0" conditionEdge="none"><ByEntityCondition>
            <TriggeringEntities triggeringEntitiesRule="any"><EntityRef entityRef="ego" /></TriggeringEntities>
            <EntityCondition><RelativeDistanceCondition entityRef="walker" freespace="false" relativeDistanceType="euclidianDistance" coordinateSystem="entity" rule="lessThan" value="20.0" /></EntityCondition>
          </ByEntityCondition></Condition>""")
    stop_in_lane = event("stop_in_lane", speed_action(0.0),
                         condition_reach("in_cart_lane", "walker", wp(53021.5, y, Z, h), 0.15))
    walk_on = event("walk_on", speed_action(0.8), after("stood_5s", "stop_in_lane", 5))
    halt = event("halt", speed_action(0.0), after("across", "walk_on", 12))
    return scenario(
        "pedestrian",
        "a pedestrian crosses the north road in front of the cart; the cart must stop for it.",
        [walker("walker", "walker.pedestrian.0001")],
        [teleport("walker", wp(53026.5, y, Z, h))],
        [group("crossing", ["walker"], [step_in, stop_in_lane, walk_on, halt]),
         group("walker_checks", ["ego"], [clearance])],
        ["walker"])


def lead_vehicle():
    s3 = R3["goal"]
    go = event("lead_drives", drive("lead", 1.5, pose(s3)), AT_START)
    return scenario(
        "lead_vehicle",
        "a car drives ahead of the cart at 1.5 m/s, the same way and on; the cart follows it.",
        [car("lead")],
        [teleport("lead", wp(52996.0, 67848.6, 11.9, 0.0204))],
        [group("lead", ["lead"], [go])],
        ["lead"])


def traffic():
    s2, g2 = R2["start"], R2["goal"]
    oncoming = event("oncoming_drives", drive("oncoming", 2.5, pose(g2)),
                     """<Condition name="cart_within_45m" delay="0" conditionEdge="none"><ByEntityCondition>
            <TriggeringEntities triggeringEntitiesRule="any"><EntityRef entityRef="ego" /></TriggeringEntities>
            <EntityCondition><RelativeDistanceCondition entityRef="oncoming" freespace="false" relativeDistanceType="euclidianDistance" coordinateSystem="entity" rule="lessThan" value="45.0" /></EntityCondition>
          </ByEntityCondition></Condition>""")
    straight = '<UserDefinedAction><CustomCommandAction type="WalkStraightAction()" /></UserDefinedAction>'
    walk_north = event("stroll_a", [straight, speed_action(0.9)], AT_START)
    walk_south = event("stroll_b", [straight, speed_action(0.8)], AT_START)
    return scenario(
        "traffic",
        "background traffic: an oncoming car, a parked car, two pedestrians walking along the north road.",
        [car("oncoming"), car("parked"), walker("stroller_a", "walker.pedestrian.0005"),
         walker("stroller_b", "walker.pedestrian.0012")],
        [teleport("oncoming", pose(s2)),
         teleport("parked", wp(52990.0, 67845.0, 11.9, 3.1212)),
         teleport("stroller_a", wp(53025.5, 67870.0, Z, 1.5708)),
         teleport("stroller_b", wp(53013.5, 67905.0, Z, -1.5708))],
        [group("oncoming", ["oncoming"], [oncoming]), group("stroller_a", ["stroller_a"], [walk_north]), group("stroller_b", ["stroller_b"], [walk_south])],
        ["oncoming", "parked", "stroller_a", "stroller_b"])


SCHEMA = "openscenario/openscenario_validator/schema/OpenSCENARIO-1.3.xsd"


def validate(text, name):
    """Against SSv2's OpenSCENARIO 1.3 schema (its preprocessor refuses an invalid file),
    when xmllint and scenario-world-bridge's SSv2 checkout ($TWIN_SWB) are at hand."""
    import os
    import shutil
    import subprocess
    import tempfile

    xsd = Path(os.environ.get("TWIN_SWB", Path.home() / "repos/carla-scenario-bridge")) / "src/scenario_simulator_v2" / SCHEMA
    if not shutil.which("xmllint") or not xsd.is_file():
        return
    with tempfile.NamedTemporaryFile("w", suffix=".xosc") as f:
        f.write(text)
        f.flush()
        r = subprocess.run(["xmllint", "--noout", "--schema", str(xsd), f.name], capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"{name}: not valid OpenSCENARIO 1.3:\n{r.stderr}")


def main():
    check = "--check" in sys.argv[1:]
    stale = []
    for name, make in (("pedestrian", pedestrian), ("lead_vehicle", lead_vehicle), ("traffic", traffic)):
        out = PKG / "scenarios" / f"showcase_{name}.xosc"
        text = make()
        validate(text, out.name)
        if out.is_file() and out.read_text() == text:
            continue
        if check:
            stale.append(out)
            continue
        out.write_text(text)
        print(f"wrote {out}")
    for p in stale:
        print(f"stale: {p}", file=sys.stderr)
    return 1 if stale else 0


if __name__ == "__main__":
    sys.exit(main())
