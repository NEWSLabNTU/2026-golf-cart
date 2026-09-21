// Copyright 2026 Golf Cart Team
// Licensed under the Apache License, Version 2.0

#include "golfcart_domain_bridge/config.hpp"

#include <yaml-cpp/yaml.h>

#include <fstream>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace golfcart_domain_bridge
{

namespace
{

[[noreturn]] void bad(const std::string & where, const std::string & what)
{
  throw std::runtime_error("topics.yaml: " + where + ": " + what);
}

TopicSpec parse_topic(const YAML::Node & n, const std::string & where)
{
  if (!n.IsMap()) {
    bad(where, "entry is not a map");
  }
  TopicSpec t;
  if (!n["topic"] || !n["topic"].IsScalar()) {
    bad(where, "missing `topic`");
  }
  t.topic = n["topic"].as<std::string>();
  if (t.topic.empty() || t.topic[0] != '/') {
    bad(where, "`topic` must be absolute (start with /): " + t.topic);
  }
  if (!n["type"] || !n["type"].IsScalar()) {
    bad(t.topic, "missing `type` (pkg/msg/Type)");
  }
  t.type = n["type"].as<std::string>();
  // Two slashes, three non-empty parts. rclcpp would reject anything else
  // later with a message that names the library it could not dlopen, not
  // the entry that asked for it.
  {
    std::size_t a = t.type.find('/');
    std::size_t b = (a == std::string::npos) ? a : t.type.find('/', a + 1);
    if (a == std::string::npos || b == std::string::npos || a == 0 || b == a + 1 ||
      b + 1 >= t.type.size() || t.type.find('/', b + 1) != std::string::npos)
    {
      bad(t.topic, "`type` must be pkg/msg/Type: " + t.type);
    }
  }
  if (n["reliability"]) {
    const auto s = n["reliability"].as<std::string>();
    if (s == "reliable") {
      t.reliability = Reliability::Reliable;
    } else if (s == "best_effort") {
      t.reliability = Reliability::BestEffort;
    } else {
      bad(t.topic, "`reliability` must be reliable or best_effort: " + s);
    }
  }
  if (n["durability"]) {
    const auto s = n["durability"].as<std::string>();
    if (s == "transient_local") {
      t.durability = Durability::TransientLocal;
    } else if (s == "volatile") {
      t.durability = Durability::Volatile;
    } else {
      bad(t.topic, "`durability` must be volatile or transient_local: " + s);
    }
  }
  if (n["depth"]) {
    const auto d = n["depth"].as<long long>();
    if (d < 1) {
      bad(t.topic, "`depth` must be >= 1");
    }
    t.depth = static_cast<std::size_t>(d);
  }
  if (n["max_hz"]) {
    t.max_hz = n["max_hz"].as<double>();
    if (t.max_hz < 0.0) {
      bad(t.topic, "`max_hz` must be >= 0 (0 = unthrottled)");
    }
  }
  return t;
}

std::vector<TopicSpec> parse_list(const YAML::Node & root, const std::string & key)
{
  std::vector<TopicSpec> out;
  const YAML::Node n = root[key];
  if (!n || n.IsNull()) {
    return out;  // absent or `key:` with nothing under it: an empty direction
  }
  if (!n.IsSequence()) {
    bad(key, "must be a list");
  }
  for (std::size_t i = 0; i < n.size(); ++i) {
    out.push_back(parse_topic(n[i], key + "[" + std::to_string(i) + "]"));
  }
  return out;
}

void refuse_duplicates(const std::vector<TopicSpec> & list, const std::string & key)
{
  std::set<std::string> seen;
  for (const auto & t : list) {
    if (!seen.insert(t.topic).second) {
      bad(key, "topic listed twice: " + t.topic);
    }
  }
}

}  // namespace

LinkConfig parse_link_config(const std::string & yaml_text)
{
  YAML::Node root;
  try {
    root = YAML::Load(yaml_text);
  } catch (const YAML::Exception & e) {
    throw std::runtime_error(std::string("topics.yaml: not valid YAML: ") + e.what());
  }
  if (!root.IsMap()) {
    bad("top level", "must be a map with orin_to_master / master_to_orin");
  }
  LinkConfig cfg;
  cfg.orin_to_master = parse_list(root, "orin_to_master");
  cfg.master_to_orin = parse_list(root, "master_to_orin");
  refuse_duplicates(cfg.orin_to_master, "orin_to_master");
  refuse_duplicates(cfg.master_to_orin, "master_to_orin");

  // The loop check. A topic bridged A->link->B and also B->link->A is
  // re-published into the domain it came from, picked up again by the
  // outbound subscription, and sent back, forever, at whatever rate the link
  // allows. /diagnostics and /tf_static are the ones that tempt this.
  std::set<std::string> o2m;
  for (const auto & t : cfg.orin_to_master) {
    o2m.insert(t.topic);
  }
  for (const auto & t : cfg.master_to_orin) {
    if (o2m.count(t.topic)) {
      bad(t.topic, "listed in BOTH directions; that is an echo loop across the link");
    }
  }
  return cfg;
}

LinkConfig load_link_config(const std::string & path)
{
  std::ifstream in(path);
  if (!in) {
    throw std::runtime_error("topics.yaml: cannot read " + path);
  }
  std::stringstream ss;
  ss << in.rdbuf();
  return parse_link_config(ss.str());
}

HostPlan for_role(const LinkConfig & cfg, const std::string & role)
{
  HostPlan p;
  if (role == "master") {
    p.outbound = cfg.master_to_orin;
    p.inbound = cfg.orin_to_master;
  } else if (role == "orin") {
    p.outbound = cfg.orin_to_master;
    p.inbound = cfg.master_to_orin;
  } else {
    throw std::runtime_error("role must be master or orin, got: " + role);
  }
  return p;
}

const char * to_string(Reliability r)
{
  return r == Reliability::Reliable ? "reliable" : "best_effort";
}

const char * to_string(Durability d)
{
  return d == Durability::TransientLocal ? "transient_local" : "volatile";
}

}  // namespace golfcart_domain_bridge
