# One detected ArUco marker.
#
# Corners are already mapped into the RECTIFIED image frame by the detector, so
# a consumer running PnP on them must pass ZERO distortion. Re-applying the
# distortion coefficients here double-corrects; that mistake has been measured
# at tens of pixels of displacement, and because the error is radius-dependent
# it corrupts wide-field-of-view observations worst.

# Marker ID within the configured dictionary.
uint32 id

# Corner pixel coordinates in the rectified image frame, flattened as
#   [u_tl, v_tl, u_tr, v_tr, u_br, v_br, u_bl, v_bl]
# Order is OpenCV's: top-left, top-right, bottom-right, bottom-left, as seen by
# a viewer facing the front of the marker.
float64[8] corners_rectified

# The two SOLVEPNP_IPPE_SQUARE solutions, expressed in the camera OPTICAL frame
# (z forward, x right, y down). A planar target is genuinely two-valued; both
# solutions are carried so the consumer can resolve the flip using information
# this node does not have, such as agreement across several markers.
#
# pose_1 is the solution with the LOWER reprojection error.
geometry_msgs/Pose pose_1
geometry_msgs/Pose pose_2

# Reprojection errors of the two solutions, in pixels, same order.
# Invariant: reprojection_error_1 <= reprojection_error_2.
#
# The ambiguity metric is the ratio
#     reprojection_error_1 / reprojection_error_2      in (0, 1]
# Near 0 means the best solution is clearly better and the pose is trustworthy.
# Near 1 means the two solutions fit the corners equally well and the marker's
# orientation cannot be resolved from this observation alone.
float64 reprojection_error_1
float64 reprojection_error_2
