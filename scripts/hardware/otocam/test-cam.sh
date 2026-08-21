#!/usr/bin/env bash
parallel -j3 <<EOF
gst-launch-1.0 v4l2src device=/dev/v4l/by-path/platform-tegra-capture-vi-video-index12 ! video/x-raw,format=UYVY,width=1920,height=1280,framerate=30/1 ! fpsdisplaysink
gst-launch-1.0 v4l2src device=/dev/v4l/by-path/platform-tegra-capture-vi-video-index0 ! video/x-raw,format=UYVY,width=1920,height=1280,framerate=30/1 ! fpsdisplaysink
gst-launch-1.0 v4l2src device=/dev/v4l/by-path/platform-tegra-capture-vi-video-index10 ! video/x-raw,format=UYVY,width=1920,height=1280,framerate=30/1 ! fpsdisplaysink
EOF

