// Copyright 2026 Golf Cart Team
// Licensed under the Apache License, Version 2.0
//
// golfcart_domain_bridge - the one participant a host puts on the master/orin
// link.
//
// Two rclcpp contexts in one process: one in the internal domain (50 on the
// master, 60 on the orin; ROS_DOMAIN_ID, bound to lo by config/cyclonedds/<role>.xml) and one in the link domain (bound to the
// LAN interface). For every topic in config/link/topics.yaml a generic
// subscription in the source domain hands serialized bytes to a generic
// publisher in the other. No type is deserialized, so the bridge does not
// need to know anything about the message beyond the name of its type
// support library.
//
// Each context gets its own executor and thread. A single executor cannot
// spin nodes from two contexts, and a callback on the link side publishing
// into the internal side is an ordinary cross-thread publish, which rclcpp
// permits.
//
// Usage:
//   domain_bridge --role master|orin [--config topics.yaml]
//                 [--internal-domain 50] [--link-domain 10]
// Defaults come from the environment scripts/env.sh exports: GOLFCART_HOST,
// GOLFCART_LINK_TOPICS, GOLFCART_LINK_DOMAIN_ID. Anything after --ros-args is
// left to rclcpp, which is how play_launch's node remaps reach the nodes.

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "golfcart_domain_bridge/config.hpp"
#include "rclcpp/rclcpp.hpp"

namespace
{

using golfcart_domain_bridge::Durability;
using golfcart_domain_bridge::HostPlan;
using golfcart_domain_bridge::Reliability;
using golfcart_domain_bridge::TopicSpec;

struct Args
{
  std::string role;
  std::string config;
  std::size_t internal_domain{0};
  std::size_t link_domain{10};
};

std::string env_or(const char * name, const std::string & fallback)
{
  const char * v = std::getenv(name);
  return (v && *v) ? std::string(v) : fallback;
}

std::size_t parse_domain(const std::string & s, const char * what)
{
  if (s.empty() || s.find_first_not_of("0123456789") != std::string::npos) {
    throw std::runtime_error(std::string(what) + " must be a non-negative integer, got: " + s);
  }
  return static_cast<std::size_t>(std::stoul(s));
}

Args parse_args(int argc, char ** argv)
{
  Args a;
  a.role = env_or("GOLFCART_HOST", "");
  a.config = env_or("GOLFCART_LINK_TOPICS", "");
  a.internal_domain = parse_domain(env_or("ROS_DOMAIN_ID", "0"), "ROS_DOMAIN_ID");
  a.link_domain = parse_domain(env_or("GOLFCART_LINK_DOMAIN_ID", "10"), "GOLFCART_LINK_DOMAIN_ID");

  for (int i = 1; i < argc; ++i) {
    const std::string flag = argv[i];
    if (flag == "--ros-args") {
      break;  // rclcpp's, not ours
    }
    auto value = [&]() -> std::string {
        if (i + 1 >= argc) {
          throw std::runtime_error(flag + " needs a value");
        }
        return argv[++i];
      };
    if (flag == "--role") {
      a.role = value();
    } else if (flag == "--config") {
      a.config = value();
    } else if (flag == "--internal-domain") {
      a.internal_domain = parse_domain(value(), "--internal-domain");
    } else if (flag == "--link-domain") {
      a.link_domain = parse_domain(value(), "--link-domain");
    } else if (flag == "-h" || flag == "--help") {
      throw std::runtime_error(
              "usage: domain_bridge --role master|orin [--config topics.yaml] "
              "[--internal-domain N] [--link-domain M]");
    } else {
      throw std::runtime_error("unknown argument: " + flag);
    }
  }
  if (a.role.empty()) {
    throw std::runtime_error("--role (or GOLFCART_HOST) is required: master or orin");
  }
  if (a.config.empty()) {
    throw std::runtime_error("--config (or GOLFCART_LINK_TOPICS) is required");
  }
  if (a.internal_domain == a.link_domain) {
    throw std::runtime_error(
            "internal and link domain are both " + std::to_string(a.link_domain) +
            "; a bridge between a domain and itself is an echo loop");
  }
  return a;
}

rclcpp::QoS qos_of(const TopicSpec & t)
{
  rclcpp::QoS qos(rclcpp::KeepLast(t.depth));
  if (t.reliability == Reliability::Reliable) {
    qos.reliable();
  } else {
    qos.best_effort();
  }
  if (t.durability == Durability::TransientLocal) {
    qos.transient_local();
  } else {
    qos.durability_volatile();
  }
  return qos;
}

// One bridged topic: the subscription that feeds it, the publisher it feeds,
// and the counters `stats` prints.
struct Lane
{
  TopicSpec spec;
  std::string direction;  // "out" (internal -> link) or "in" (link -> internal)
  rclcpp::GenericPublisher::SharedPtr pub;
  rclcpp::GenericSubscription::SharedPtr sub;
  std::atomic<uint64_t> forwarded{0};
  std::atomic<uint64_t> throttled{0};
  std::atomic<uint64_t> bytes{0};  // serialized payload forwarded; the wire adds RTPS/UDP/IP
  std::chrono::steady_clock::time_point last_sent{};
  std::chrono::steady_clock::duration min_gap{};
};

// Build the lanes for one direction. Every failure is per topic: a type whose
// support library this host does not have is logged and skipped, so the IMU
// keeps flowing when a camera type is missing on the master.
void add_lanes(
  const std::vector<TopicSpec> & specs, const std::string & direction,
  const rclcpp::Node::SharedPtr & from, const rclcpp::Node::SharedPtr & to,
  std::vector<std::shared_ptr<Lane>> & lanes)
{
  for (const auto & spec : specs) {
    auto lane = std::make_shared<Lane>();
    lane->spec = spec;
    lane->direction = direction;
    if (spec.max_hz > 0.0) {
      lane->min_gap = std::chrono::duration_cast<std::chrono::steady_clock::duration>(
        std::chrono::duration<double>(1.0 / spec.max_hz));
    }
    const auto qos = qos_of(spec);
    try {
      lane->pub = to->create_generic_publisher(spec.topic, spec.type, qos);
      // Weak capture: the subscription outlives nothing here, but a callback
      // that keeps its own lane alive would make shutdown order circular.
      std::weak_ptr<Lane> weak = lane;
      lane->sub = from->create_generic_subscription(
        spec.topic, spec.type, qos,
        [weak](std::shared_ptr<rclcpp::SerializedMessage> msg) {
          auto l = weak.lock();
          if (!l) {
            return;
          }
          if (l->min_gap.count() > 0) {
            const auto now = std::chrono::steady_clock::now();
            if (now - l->last_sent < l->min_gap) {
              l->throttled.fetch_add(1, std::memory_order_relaxed);
              return;
            }
            l->last_sent = now;
          }
          l->pub->publish(*msg);
          l->forwarded.fetch_add(1, std::memory_order_relaxed);
          l->bytes.fetch_add(msg->size(), std::memory_order_relaxed);
        });
    } catch (const std::exception & e) {
      RCLCPP_ERROR(
        from->get_logger(), "%s %s (%s): NOT bridged: %s",
        direction.c_str(), spec.topic.c_str(), spec.type.c_str(), e.what());
      continue;
    }
    const std::string cap = spec.max_hz > 0.0 ? " max_hz=" + std::to_string(spec.max_hz) : "";
    RCLCPP_INFO(
      from->get_logger(), "%s %s (%s) %s %s depth=%zu%s",
      direction.c_str(), spec.topic.c_str(), spec.type.c_str(),
      to_string(spec.reliability), to_string(spec.durability), spec.depth, cap.c_str());
    lanes.push_back(lane);
  }
}

}  // namespace

int main(int argc, char ** argv)
{
  Args args;
  try {
    args = parse_args(argc, argv);
  } catch (const std::exception & e) {
    fprintf(stderr, "domain_bridge: %s\n", e.what());
    return 64;
  }

  HostPlan plan;
  try {
    plan = golfcart_domain_bridge::for_role(
      golfcart_domain_bridge::load_link_config(args.config), args.role);
  } catch (const std::exception & e) {
    fprintf(stderr, "domain_bridge: %s\n", e.what());
    return 65;
  }

  // Two contexts. rclcpp::init would create only the global one, in
  // ROS_DOMAIN_ID; these are explicit so each carries its own domain. The
  // signal handlers are what rclcpp::init would have installed: on SIGINT
  // every context with shutdown_on_signal (the default) is shut down, which
  // returns both spins below. play_launch stops nodes with SIGINT.
  rclcpp::install_signal_handlers();

  auto make_context = [&](std::size_t domain) {
      rclcpp::InitOptions opts;
      opts.set_domain_id(domain);
      auto ctx = std::make_shared<rclcpp::Context>();
      ctx->init(argc, argv, opts);
      return ctx;
    };
  auto internal_ctx = make_context(args.internal_domain);
  auto link_ctx = make_context(args.link_domain);

  auto make_node = [&](const rclcpp::Context::SharedPtr & ctx, const char * name) {
      rclcpp::NodeOptions opts;
      opts.context(ctx);
      return std::make_shared<rclcpp::Node>(name, opts);
    };
  // The two nodes can never meet, so the names only matter to a reader of
  // `ros2 node list`. Under play_launch both get the launch entry's
  // `__node:=` remap, because the contexts took argv and the nodes use global
  // arguments; standalone, the link-domain one says which end it is.
  auto internal_node = make_node(internal_ctx, "link_bridge");
  auto link_node = make_node(link_ctx, "link_bridge_far_end");

  RCLCPP_INFO(
    internal_node->get_logger(), "role=%s internal domain %zu <-> link domain %zu, %s",
    args.role.c_str(), args.internal_domain, args.link_domain, args.config.c_str());

  std::vector<std::shared_ptr<Lane>> lanes;
  add_lanes(plan.outbound, "out", internal_node, link_node, lanes);
  add_lanes(plan.inbound, "in", link_node, internal_node, lanes);
  if (lanes.empty()) {
    RCLCPP_WARN(
      internal_node->get_logger(),
      "no topic bridged in either direction; staying up so the link domain has a participant");
  }

  // Counters every 10 s on the internal side, where the rest of the stack's
  // logs are. This is what `just link status` and the simulation read.
  auto stats = internal_node->create_wall_timer(
    std::chrono::seconds(10), [&lanes, internal_node]() {
      for (const auto & l : lanes) {
        RCLCPP_INFO(
          internal_node->get_logger(), "%s %s forwarded=%lu throttled=%lu bytes=%lu",
          l->direction.c_str(), l->spec.topic.c_str(),
          static_cast<unsigned long>(l->forwarded.load(std::memory_order_relaxed)),
          static_cast<unsigned long>(l->throttled.load(std::memory_order_relaxed)),
          static_cast<unsigned long>(l->bytes.load(std::memory_order_relaxed)));
      }
    });

  rclcpp::ExecutorOptions internal_eo;
  internal_eo.context = internal_ctx;
  rclcpp::executors::SingleThreadedExecutor internal_exec(internal_eo);
  internal_exec.add_node(internal_node);

  rclcpp::ExecutorOptions link_eo;
  link_eo.context = link_ctx;
  rclcpp::executors::SingleThreadedExecutor link_exec(link_eo);
  link_exec.add_node(link_node);

  std::thread link_thread([&]() {link_exec.spin();});
  internal_exec.spin();

  // One side shut down (signal). Take the other with it, whichever it was.
  if (link_ctx->is_valid()) {
    link_ctx->shutdown("internal side stopped");
  }
  link_thread.join();
  if (internal_ctx->is_valid()) {
    internal_ctx->shutdown("link side stopped");
  }
  rclcpp::uninstall_signal_handlers();
  return 0;
}
