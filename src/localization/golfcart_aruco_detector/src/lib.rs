// Copyright 2026 Golf Cart Team
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//! ArUco marker detection for indoor localization.
//!
//! Images in, rectified corners and per-marker candidate poses out. This crate
//! knows nothing about the map, TF, or the vehicle — it reports what a camera
//! saw and how confident it is, and `golfcart_aruco_localizer` turns that into
//! a vehicle pose.
//!
//! Vendored from LCTK and merged into one package. What was dropped, and why,
//! is in `docs/roadmaps/3-indoor-d5-detector.md`.

pub mod detector;
pub mod dictionary;
pub mod marker_pnp;
pub mod params;
pub mod render;

pub use detector::{scale_intrinsics, BoardGeometry, Detector, MarkerDetection, NUM_CORNERS};
pub use dictionary::ArucoDictionary;
pub use marker_pnp::{marker_local_corners, solve_marker_pose, MarkerPose};
pub use params::{
    AdaptiveThreshParams, CandidateFilterParams, CornerRefinement, CornerRefinementParams,
    DetectorParams,
};
