// Copyright 2026 Golf Cart Team
// Licensed under the Apache License, Version 2.0

#ifndef GOLFCART_DOMAIN_BRIDGE__CONFIG_HPP_
#define GOLFCART_DOMAIN_BRIDGE__CONFIG_HPP_

#include <cstddef>
#include <string>
#include <vector>

namespace golfcart_domain_bridge
{

enum class Reliability { BestEffort, Reliable };
enum class Durability { Volatile, TransientLocal };

struct TopicSpec
{
  std::string topic;
  std::string type;  // pkg/msg/Type
  Reliability reliability{Reliability::BestEffort};
  Durability durability{Durability::Volatile};
  std::size_t depth{10};
  double max_hz{0.0};  // 0 = forward every sample
};

// A service that crosses the link. The direction is that of the REQUEST: a
// service under master_to_orin has its callers on the master and its server
// on the orin.
struct ServiceSpec
{
  std::string service;
  std::string type;  // pkg/srv/Type
};

// The two directions as the FILE names them. Which one a given host publishes
// into the link is decided by its role, see for_role().
struct LinkConfig
{
  std::vector<TopicSpec> orin_to_master;
  std::vector<TopicSpec> master_to_orin;
  std::vector<ServiceSpec> services_orin_to_master;
  std::vector<ServiceSpec> services_master_to_orin;
};

// What one host's bridge does: outbound goes internal -> link, inbound goes
// link -> internal. For services that is the direction of the request:
// outbound services are offered here and answered on the far host, inbound
// services are offered on the link and answered here.
struct HostPlan
{
  std::vector<TopicSpec> outbound;
  std::vector<TopicSpec> inbound;
  std::vector<ServiceSpec> services_outbound;
  std::vector<ServiceSpec> services_inbound;
};

// Throws std::runtime_error with a message naming the offending entry on any
// malformed field, and on a topic that appears in both directions: that would
// be an echo loop across the link, and nothing downstream would notice. A
// service in both directions is refused for the same reason: each bridge would
// offer it, and a request could chase itself back and forth.
LinkConfig parse_link_config(const std::string & yaml_text);
LinkConfig load_link_config(const std::string & path);

// role is "master" or "orin"; anything else throws.
HostPlan for_role(const LinkConfig & cfg, const std::string & role);

const char * to_string(Reliability r);
const char * to_string(Durability d);

}  // namespace golfcart_domain_bridge

#endif  // GOLFCART_DOMAIN_BRIDGE__CONFIG_HPP_
