# All markers detected in one image, from one camera.
#
# Self-contained by design: the camera matrix used for rectification travels
# with the detections, so a recorded stream replays with no camera and no
# calibration file. Detections are small enough that a bag of them is a
# practical tuning artifact, where a bag of several 1920x1280 image streams is
# not.

# stamp    - the image CAPTURE time, not the time this message was built.
# frame_id - the camera OPTICAL frame (z forward, x right, y down), which is
#            what PnP results are expressed in. This is deliberately not the
#            camera body frame; composing an optical-frame pose through a body
#            frame rotates every observation by about 90 degrees.
std_msgs/Header header

# Row-major 3x3 camera matrix used to rectify the corners in this message.
float64[9] k

# Image dimensions the corners refer to, for sanity checks and field-of-view
# reasoning downstream.
uint32 image_width
uint32 image_height

ArucoDetection[] detections
