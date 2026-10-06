// Copyright 2026 Golf Cart Team
// Licensed under the Apache License, Version 2.0

#include <gtest/gtest.h>

#include <stdexcept>
#include <string>

#include "golfcart_domain_bridge/config.hpp"

using golfcart_domain_bridge::Durability;
using golfcart_domain_bridge::for_role;
using golfcart_domain_bridge::parse_link_config;
using golfcart_domain_bridge::Reliability;

namespace
{

const char * kGood = R"(
orin_to_master:
  - topic: /sensing/camera/zed/imu/data
    type: sensor_msgs/msg/Imu
  - topic: /tf_static
    type: tf2_msgs/msg/TFMessage
    reliability: reliable
    durability: transient_local
    depth: 50
master_to_orin:
  - topic: /clock
    type: rosgraph_msgs/msg/Clock
    max_hz: 5
)";

}  // namespace

TEST(Config, DefaultsAndOverrides)
{
  const auto cfg = parse_link_config(kGood);
  ASSERT_EQ(cfg.orin_to_master.size(), 2u);
  ASSERT_EQ(cfg.master_to_orin.size(), 1u);

  const auto & imu = cfg.orin_to_master[0];
  EXPECT_EQ(imu.reliability, Reliability::BestEffort);
  EXPECT_EQ(imu.durability, Durability::Volatile);
  EXPECT_EQ(imu.depth, 10u);
  EXPECT_EQ(imu.max_hz, 0.0);

  const auto & tf = cfg.orin_to_master[1];
  EXPECT_EQ(tf.reliability, Reliability::Reliable);
  EXPECT_EQ(tf.durability, Durability::TransientLocal);
  EXPECT_EQ(tf.depth, 50u);

  EXPECT_EQ(cfg.master_to_orin[0].max_hz, 5.0);
}

// The role mapping is the whole reason one file serves both hosts: what the
// orin sends out is exactly what the master takes in.
TEST(Config, RolesAreMirrors)
{
  const auto cfg = parse_link_config(kGood);
  const auto orin = for_role(cfg, "orin");
  const auto master = for_role(cfg, "master");
  ASSERT_EQ(orin.outbound.size(), master.inbound.size());
  for (size_t i = 0; i < orin.outbound.size(); ++i) {
    EXPECT_EQ(orin.outbound[i].topic, master.inbound[i].topic);
  }
  ASSERT_EQ(master.outbound.size(), orin.inbound.size());
  EXPECT_EQ(master.outbound[0].topic, "/clock");
  EXPECT_THROW(for_role(cfg, "laptop"), std::runtime_error);
}

TEST(Config, RefusesEchoLoop)
{
  const char * loop = R"(
orin_to_master:
  - {topic: /diagnostics, type: diagnostic_msgs/msg/DiagnosticArray}
master_to_orin:
  - {topic: /diagnostics, type: diagnostic_msgs/msg/DiagnosticArray}
)";
  EXPECT_THROW(parse_link_config(loop), std::runtime_error);
}

TEST(Config, RefusesDuplicateAndMalformed)
{
  EXPECT_THROW(
    parse_link_config(
      "orin_to_master:\n"
      "  - {topic: /a, type: std_msgs/msg/String}\n"
      "  - {topic: /a, type: std_msgs/msg/String}\n"),
    std::runtime_error);
  EXPECT_THROW(
    parse_link_config("orin_to_master:\n  - {topic: a, type: std_msgs/msg/String}\n"),
    std::runtime_error);
  EXPECT_THROW(
    parse_link_config("orin_to_master:\n  - {topic: /a, type: String}\n"),
    std::runtime_error);
  EXPECT_THROW(
    parse_link_config("orin_to_master:\n  - {topic: /a, type: std_msgs/msg/String, reliability: sometimes}\n"),
    std::runtime_error);
  EXPECT_THROW(
    parse_link_config("orin_to_master:\n  - {topic: /a, type: std_msgs/msg/String, depth: 0}\n"),
    std::runtime_error);
  EXPECT_THROW(parse_link_config("- not a map\n"), std::runtime_error);
}

TEST(Config, EmptyDirectionsAreFine)
{
  const auto cfg = parse_link_config("orin_to_master: []\nmaster_to_orin:\n");
  EXPECT_TRUE(cfg.orin_to_master.empty());
  EXPECT_TRUE(cfg.master_to_orin.empty());
}

// A service's direction is that of its requests, and the roles mirror it the
// same way topics do: the callers' host offers it outbound.
TEST(Config, ServicesFollowRequestDirection)
{
  const auto cfg = parse_link_config(R"(
orin_to_master: []
master_to_orin: []
services:
  master_to_orin:
    - service: /control/control_mode_request
      type: autoware_vehicle_msgs/srv/ControlModeCommand
)");
  ASSERT_EQ(cfg.services_master_to_orin.size(), 1u);
  EXPECT_EQ(cfg.services_master_to_orin[0].service, "/control/control_mode_request");
  EXPECT_TRUE(cfg.services_orin_to_master.empty());

  const auto master = for_role(cfg, "master");
  ASSERT_EQ(master.services_outbound.size(), 1u);
  EXPECT_TRUE(master.services_inbound.empty());
  const auto orin = for_role(cfg, "orin");
  ASSERT_EQ(orin.services_inbound.size(), 1u);
  EXPECT_TRUE(orin.services_outbound.empty());
}

TEST(Config, RefusesBadServices)
{
  // a msg type where a srv type belongs
  EXPECT_THROW(
    parse_link_config("services:\n  master_to_orin:\n"
                      "    - {service: /s, type: std_msgs/msg/String}\n"),
    std::runtime_error);
  // relative name
  EXPECT_THROW(
    parse_link_config("services:\n  master_to_orin:\n"
                      "    - {service: s, type: std_srvs/srv/Trigger}\n"),
    std::runtime_error);
  // both directions: each bridge would offer it
  EXPECT_THROW(
    parse_link_config("services:\n"
                      "  master_to_orin: [{service: /s, type: std_srvs/srv/Trigger}]\n"
                      "  orin_to_master: [{service: /s, type: std_srvs/srv/Trigger}]\n"),
    std::runtime_error);
  // listed twice in one direction
  EXPECT_THROW(
    parse_link_config("services:\n"
                      "  master_to_orin: [{service: /s, type: std_srvs/srv/Trigger},"
                      " {service: /s, type: std_srvs/srv/Trigger}]\n"),
    std::runtime_error);
  // services must be a map
  EXPECT_THROW(parse_link_config("services: [1, 2]\n"), std::runtime_error);
}

TEST(Config, NoServicesSectionIsFine)
{
  const auto cfg = parse_link_config("orin_to_master: []\n");
  EXPECT_TRUE(cfg.services_master_to_orin.empty());
  EXPECT_TRUE(cfg.services_orin_to_master.empty());
}

int main(int argc, char ** argv)
{
  ::testing::InitGoogleTest(&argc, argv);
  return RUN_ALL_TESTS();
}
