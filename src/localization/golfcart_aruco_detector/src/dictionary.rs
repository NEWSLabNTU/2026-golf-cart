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

//! The predefined ArUco dictionaries, and their OpenCV equivalents.

use anyhow::{bail, Result};
use opencv::{aruco, core::Ptr};
use serde::{Deserialize, Serialize};

/// Every dictionary is listed once, with its name and its OpenCV constant, so
/// the string form and the OpenCV form cannot drift apart.
macro_rules! dictionaries {
    ($($variant:ident),+ $(,)?) => {
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
        #[allow(non_camel_case_types)]
        pub enum ArucoDictionary {
            $($variant),+
        }

        impl ArucoDictionary {
            pub fn as_str(self) -> &'static str {
                match self {
                    $(Self::$variant => stringify!($variant)),+
                }
            }

            pub fn opencv_name(self) -> aruco::PREDEFINED_DICTIONARY_NAME {
                use aruco::PREDEFINED_DICTIONARY_NAME as P;
                match self {
                    $(Self::$variant => P::$variant),+
                }
            }

            pub const ALL: &'static [Self] = &[$(Self::$variant),+];
        }
    };
}

dictionaries! {
    DICT_4X4_50, DICT_4X4_100, DICT_4X4_250, DICT_4X4_1000,
    DICT_5X5_50, DICT_5X5_100, DICT_5X5_250, DICT_5X5_1000,
    DICT_6X6_50, DICT_6X6_100, DICT_6X6_250, DICT_6X6_1000,
    DICT_7X7_50, DICT_7X7_100, DICT_7X7_250, DICT_7X7_1000,
    DICT_ARUCO_ORIGINAL,
    DICT_APRILTAG_16h5, DICT_APRILTAG_25h9, DICT_APRILTAG_36h10, DICT_APRILTAG_36h11,
}

impl ArucoDictionary {
    pub fn to_opencv(self) -> Result<Ptr<aruco::Dictionary>> {
        Ok(aruco::get_predefined_dictionary(self.opencv_name())?)
    }
}

impl std::str::FromStr for ArucoDictionary {
    type Err = anyhow::Error;

    fn from_str(s: &str) -> Result<Self> {
        match Self::ALL.iter().find(|d| d.as_str() == s) {
            Some(&dictionary) => Ok(dictionary),
            None => bail!(
                "unknown ArUco dictionary {s:?}; expected one of: {}",
                Self::ALL
                    .iter()
                    .map(|d| d.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
        }
    }
}

impl std::fmt::Display for ArucoDictionary {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::str::FromStr as _;

    #[test]
    fn every_dictionary_round_trips_through_its_name() {
        for &dictionary in ArucoDictionary::ALL {
            let parsed = ArucoDictionary::from_str(dictionary.as_str()).unwrap();
            assert_eq!(parsed, dictionary);
        }
    }

    #[test]
    fn an_unknown_dictionary_lists_the_valid_ones() {
        let error = ArucoDictionary::from_str("DICT_5X5").unwrap_err().to_string();
        assert!(error.contains("DICT_5X5_1000"), "{error}");
    }
}
