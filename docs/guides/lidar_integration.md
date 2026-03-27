# LiDAR Integration Guide

This guide covers LiDAR sensor integration for Golf Cart.

## Supported LiDAR Models

| Model            | Type     | Configuration         |
|------------------|----------|-----------------------|
| Velodyne VLP-32C | Spinning | `lidar_model:=vlp32c` |

Configuration location: `src/param/autoware_individual_params/individual_params/config/default/golfcart_sensor_kit/`

## TensorRT Model Compilation

### First Run Behavior

On first launch, TensorRT compiles ONNX models to CUDA engines:
- Duration: 10-30 minutes
- Cache location: `./data/` directory

Key models:
- `lidar_centerpoint/pts_voxel_encoder_centerpoint_tiny.engine`
- `lidar_centerpoint/pts_backbone_neck_head_centerpoint_tiny.engine`

### LiDAR-Only Perception

For faster startup, configure in `golfcart.launch.yaml`:
```yaml
perception_mode: "lidar"
use_traffic_light_recognition: "false"
use_detection_by_tracker: "false"
use_image_segmentation_based_filter: "false"
```
