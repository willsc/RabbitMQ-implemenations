#!/usr/bin/env python3
"""Explicit, offline RabbitMQ 3.x definitions migration. Never reads broker credentials."""
import argparse
import json
import os
from pathlib import Path

REMOVED_POLICY_KEYS = {"ha-mode", "ha-params", "ha-sync-mode", "ha-promote-on-shutdown", "ha-promote-on-failure", "queue-master-locator", "queue-mode"}


def transform(definitions, drop_transient=False):
    counts = {"policy_keys_removed": 0, "empty_policies_removed": 0, "queues_removed": 0, "bindings_removed": 0}
    # Copy input to avoid mutating a caller's original export.
    definitions = json.loads(json.dumps(definitions))
    for section in ["policies", "operator_policies"]:
        policies = []
        for policy in definitions.get(section, []):
            old = policy.get("definition", {})
            policy["definition"] = {k: v for k, v in old.items() if k not in REMOVED_POLICY_KEYS}
            counts["policy_keys_removed"] += len(old) - len(policy["definition"])
            if policy["definition"]:
                policies.append(policy)
            else:
                counts["empty_policies_removed"] += 1
        if section in definitions:
            definitions[section] = policies
    removed_queues = set()
    queues = []
    for queue in definitions.get("queues", []):
        if drop_transient and (not queue.get("durable", False) or queue.get("auto_delete", False)):
            removed_queues.add((queue["vhost"], queue["name"]))
            continue
        arguments = queue.get("arguments", {})
        for key in ["x-queue-mode", "x-queue-master-locator"]:
            arguments.pop(key, None)
        if arguments.get("x-queue-version") == 1:
            arguments.pop("x-queue-version")
        queues.append(queue)
    definitions["queues"] = queues
    counts["queues_removed"] = len(removed_queues)
    bindings = definitions.get("bindings", [])
    definitions["bindings"] = [b for b in bindings if not (b.get("destination_type") == "queue" and (b["vhost"], b["destination"]) in removed_queues)]
    counts["bindings_removed"] = len(bindings) - len(definitions["bindings"])
    definitions["users"] = [u for u in definitions.get("users", []) if u.get("name") != "guest"]
    for section in ["permissions", "topic_permissions"]:
        if section in definitions:
            definitions[section] = [p for p in definitions[section] if p.get("user") != "guest"]
    # Node identities and upstream cluster names belong to the old cluster.
    definitions.pop("rabbit_version", None)
    definitions.pop("rabbitmq_version", None)
    definitions["global_parameters"] = [p for p in definitions.get("global_parameters", []) if p.get("name") not in {"cluster_name", "internal_cluster_id"}]
    return definitions, counts


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--drop-client-queues", action="store_true", help="Remove transient AND auto-delete queues and their bindings; clients must recreate them")
    args = parser.parse_args()
    output, counts = transform(json.loads(args.source.read_text()), args.drop_client_queues)
    # Exclusive creation prevents accidental overwrite of the original export.
    fd = os.open(args.destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(output, stream, indent=2)
        stream.write("\n")
    print(json.dumps(counts, sort_keys=True))


if __name__ == "__main__":
    main()
