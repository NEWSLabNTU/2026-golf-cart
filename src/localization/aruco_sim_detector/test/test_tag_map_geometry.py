# Copyright 2026 NEWSLab, National Taiwan University
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

"""Geometry checks on the tag maps, including the generated one.

A tag map is four corner points per board and nothing else, so every property
that matters -- that a board is a square of the right size, that it is planar,
that the pairs really face each other -- is implicit and unreadable. A wrong
corner produces a map that loads, detects, and quietly localizes to the wrong
place.

The facing-pair rule is the one worth defending in a test. Initialization needs
two boards inside a narrow view-angle window at the same moment with different
normals; boards staggered along one side never manage it, and the bench fixture
failed to cold-start for a whole run before that was understood. See the header
of bench_tag_map.yaml.
"""

import math
from pathlib import Path

import pytest
import yaml

CONFIG = Path(__file__).resolve().parents[1] / 'config'
MAPS = sorted(CONFIG.glob('*tag_map.yaml'))


def load(path):
    return yaml.safe_load(path.read_text())


def centre_of(corners):
    return [sum(corner[i] for corner in corners) / 4 for i in range(3)]


def normal_of(corners):
    top_left, top_right, bottom_right, _ = corners
    across = [top_right[i] - top_left[i] for i in range(3)]
    down = [bottom_right[i] - top_right[i] for i in range(3)]
    normal = [
        across[1] * down[2] - across[2] * down[1],
        across[2] * down[0] - across[0] * down[2],
        across[0] * down[1] - across[1] * down[0],
    ]
    length = math.sqrt(sum(component * component for component in normal))
    return [component / length for component in normal]


@pytest.mark.parametrize('path', MAPS, ids=lambda p: p.stem)
def test_every_board_is_a_square_of_the_declared_size(path):
    data = load(path)
    size = data['defaults']['marker_size']
    for tag in data['tags']:
        corners = tag['corners']
        assert len(corners) == 4, f"tag {tag['id']} has {len(corners)} corners"
        edges = [
            math.dist(corners[0], corners[1]),
            math.dist(corners[1], corners[2]),
            math.dist(corners[2], corners[3]),
            math.dist(corners[3], corners[0]),
        ]
        for edge in edges:
            assert edge == pytest.approx(size, abs=2e-3), (
                f"tag {tag['id']}: edge {edge:.4f} m against a declared {size} m"
            )


@pytest.mark.parametrize('path', MAPS, ids=lambda p: p.stem)
def test_every_board_is_planar(path):
    """The diagonals of a planar rectangle meet at its centre."""
    for tag in load(path)['tags']:
        corners = tag['corners']
        first = [(corners[0][i] + corners[2][i]) / 2 for i in range(3)]
        second = [(corners[1][i] + corners[3][i]) / 2 for i in range(3)]
        assert math.dist(first, second) == pytest.approx(0.0, abs=2e-3), (
            f"tag {tag['id']} is not a planar rectangle"
        )


@pytest.mark.parametrize('path', MAPS, ids=lambda p: p.stem)
def test_ids_are_unique(path):
    identifiers = [tag['id'] for tag in load(path)['tags']]
    assert len(identifiers) == len(set(identifiers))


@pytest.mark.parametrize('path', MAPS, ids=lambda p: p.stem)
def test_boards_come_in_facing_pairs(path):
    """Every board has a partner across the lane with an opposed normal.

    Both maps use the same convention: a board with id 1xx is paired with 2xx.
    A map that fails this can still detect and track, and will not cold-start,
    which is a far more expensive thing to discover from a log.
    """
    tags = {tag['id']: tag['corners'] for tag in load(path)['tags']}
    pairs = [(i, i + 100) for i in tags if i < 200 and i + 100 in tags]
    assert pairs, f'{path.name} has no 1xx/2xx pairs'

    for left, right in pairs:
        a, b = normal_of(tags[left]), normal_of(tags[right])
        opposition = sum(a[i] * b[i] for i in range(3))
        assert opposition < -0.98, (
            f'tags {left} and {right} are meant to face each other, '
            f'normals dot to {opposition:.3f}'
        )

        separation = math.dist(centre_of(tags[left])[:2], centre_of(tags[right])[:2])
        assert separation > 1.0, (
            f'tags {left} and {right} are {separation:.2f} m apart, too close to '
            'give the spread initialization needs'
        )
