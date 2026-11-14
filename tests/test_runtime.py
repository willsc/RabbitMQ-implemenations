import base64
import copy
import gzip
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bootstrap = load("bootstrap", ROOT / "modules/ec2/runtime/bootstrap.py")
health = load("health", ROOT / "modules/ec2/runtime/health.py")
prepare = load("prepare_definitions", ROOT / "scripts/prepare_definitions.py")

NAMES = {k: f"rabbit@{k}.rmq.prod.internal" for k in "abc"}


def node_config(**overrides):
    config = {"cluster": "prod-rabbit", "node_key": "b", "node_name": NAMES["b"], "node_names": NAMES,
              "plaintext": False, "enable_tls": True, "management": False, "require_mtls": False, "allow_transient": False}
    config.update(overrides)
    return config


class DefinitionsSecurity(unittest.TestCase):
    def setUp(self):
        self.definitions = {"users": [{"name": "admin", "password_hash": "opaque-test-hash", "tags": ["administrator"]}]}

    def test_valid_hashed_administrator(self):
        bootstrap.validate_definitions(self.definitions)

    def test_guest_and_clear_passwords_rejected(self):
        for change in [{"name": "guest"}, {"password": "never-allowed"}, {"password_hash": ""}]:
            definitions = copy.deepcopy(self.definitions)
            definitions["users"][0].update(change)
            with self.assertRaises(ValueError):
                bootstrap.validate_definitions(definitions)

    def test_mirroring_and_lazy_policies_rejected(self):
        for key in ["ha-mode", "ha-sync-mode", "queue-mode", "queue-master-locator"]:
            self.definitions["policies"] = [{"definition": {key: "legacy"}}]
            with self.assertRaises(ValueError):
                bootstrap.validate_definitions(self.definitions)

    def test_transient_queue_requires_opt_in(self):
        self.definitions["queues"] = [{"name": "legacy", "durable": False}]
        with self.assertRaises(ValueError):
            bootstrap.validate_definitions(self.definitions)
        bootstrap.validate_definitions(self.definitions, allow_transient=True)

    def test_federation_enforces_tls_chain_and_hostname(self):
        uris = [
            "amqp://upstream:5672/",
            "amqps://upstream:5671/?verify=verify_none&server_name_indication=upstream",
            "amqps://upstream:5671/?verify=verify_peer&server_name_indication=elsewhere",
            "amqps://upstream:5671/?verify=verify_peer&server_name_indication=upstream&cacertfile=/untrusted.pem",
        ]
        for uri in uris:
            self.definitions["parameters"] = [{"component": "federation-upstream", "value": {"uri": uri}}]
            with self.assertRaises(ValueError):
                bootstrap.validate_definitions(self.definitions)
        self.definitions["parameters"][0]["value"]["uri"] = "amqps://upstream:5671/%2f?verify=verify_peer&server_name_indication=upstream"
        bootstrap.validate_definitions(self.definitions)


class Availability(unittest.TestCase):
    def test_only_expected_majority_can_be_ready(self):
        expected = ["rabbit@a", "rabbit@b", "rabbit@c"]
        self.assertTrue(health.cluster_ready({"running_nodes": expected[:2], "partitions": {}}, expected, expected[0]))
        for status in [
            {"running_nodes": expected[:1]},
            {"running_nodes": ["rabbit@b", "rabbit@c"]},
            {"running_nodes": ["rabbit@a", "rabbit@foreign"]},
            {"running_nodes": expected, "partitions": {"rabbit@a": ["rabbit@c"]}},
        ]:
            self.assertFalse(health.cluster_ready(status, expected, expected[0]))



class BrokerConfiguration(unittest.TestCase):
    def test_tls_only_default(self):
        text = bootstrap.rabbit_config(node_config())
        self.assertIn("listeners.tcp = none", text)
        self.assertIn("listeners.ssl.default = 5671", text)
        self.assertIn("ssl_options.fail_if_no_peer_cert = false", text)
        self.assertIn("management.tcp.ip = 127.0.0.1", text)
        self.assertNotIn("management.ssl", text)

    def test_management_tls_never_sets_listener_ip(self):
        # Regression: management.ssl.ip is copied into ssl_opts and crashes broker boot (badarg).
        text = bootstrap.rabbit_config(node_config(management=True))
        self.assertIn("management.ssl.port = 15671", text)
        self.assertNotIn("management.ssl.ip", text)

    def test_private_plaintext_without_tls(self):
        text = bootstrap.rabbit_config(node_config(enable_tls=False, plaintext=True))
        self.assertIn("listeners.ssl = none", text)
        self.assertIn("listeners.tcp.default = 5672", text)
        self.assertNotIn("ssl_options.", text)

    def test_mtls_and_migration_flags(self):
        text = bootstrap.rabbit_config(node_config(require_mtls=True, allow_transient=True))
        self.assertIn("ssl_options.fail_if_no_peer_cert = true", text)
        self.assertIn("deprecated_features.permit.transient_nonexcl_queues = true", text)

    def test_discovery_nodes_override_full_membership(self):
        text = bootstrap.rabbit_config(node_config(discovery_nodes=[NAMES["b"], NAMES["a"]]))
        self.assertIn(f"cluster_formation.classic_config.nodes.2 = {NAMES['a']}", text)
        self.assertNotIn(NAMES["c"], text)
        full = bootstrap.rabbit_config(node_config())
        self.assertIn(f"cluster_formation.classic_config.nodes.3 = {NAMES['c']}", full)


class ClusterJoin(unittest.TestCase):
    def join(self, node_key, peer):
        written = {}
        with mock.patch.object(bootstrap, "DATA", Path(tempfile.mkdtemp())), \
                mock.patch.object(bootstrap, "image_reference", return_value="img@sha256:" + "0" * 64), \
                mock.patch.object(bootstrap, "running_peer", return_value=peer), \
                mock.patch.object(bootstrap, "write", side_effect=lambda path, content, **_: written.update({str(path): content})), \
                mock.patch.object(bootstrap.time, "sleep"):
            bootstrap.wait_for_peer(node_config(node_key=node_key, node_name=NAMES[node_key]))
        return written["/etc/rabbitmq/rabbitmq.conf"]

    def test_seed_forms_cluster_only_when_no_peer_runs(self):
        text = self.join("a", None)
        self.assertIn(f"cluster_formation.classic_config.nodes.1 = {NAMES['a']}", text)
        self.assertNotIn("nodes.2", text)

    def test_rebuilt_seed_joins_existing_cluster(self):
        text = self.join("a", NAMES["b"])
        self.assertIn(f"cluster_formation.classic_config.nodes.2 = {NAMES['b']}", text)

    def test_follower_never_forms_its_own_cluster(self):
        with self.assertRaises(RuntimeError):
            self.join("c", None)
        self.assertIn(NAMES["a"], self.join("c", NAMES["a"]))

    def test_existing_data_is_never_rejoined(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "mnesia" / "node").mkdir(parents=True)
            with mock.patch.object(bootstrap, "DATA", Path(directory)), mock.patch.object(bootstrap, "write") as write:
                bootstrap.wait_for_peer(node_config())
            write.assert_not_called()


class CertificateExpiry(unittest.TestCase):
    def test_days_remaining_parsed_from_openssl(self):
        with tempfile.TemporaryDirectory() as directory:
            cert, key = Path(directory) / "cert.pem", Path(directory) / "key.pem"
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "30", "-subj", "/CN=test",
                            "-keyout", str(key), "-out", str(cert)], check=True, capture_output=True)
            self.assertAlmostEqual(health.certificate_days(cert), 30, delta=0.1)

    def test_unreadable_certificate_raises(self):
        with self.assertRaises(subprocess.CalledProcessError):
            health.certificate_days(Path("/nonexistent/cert.pem"))


class UserData(unittest.TestCase):
    def test_rendered_user_data_fits_ec2_limit(self):
        # EC2 limits user data to 16 KiB before base64; Terraform gzips it (base64gzip).
        template = (ROOT / "modules/ec2/templates/cloud-init.sh.tftpl").read_text()
        long = "x" * 63
        config = {"region": "ap-southeast-1", "cluster": "x" * 20, "node_key": "a", "node_name": f"rabbit@a.{long}",
                  "node_names": {k: f"rabbit@{k}.{long}" for k in "abc"}, "volume_id": "vol-" + "0" * 17,
                  "secret_arn": "arn:aws:secretsmanager:ap-southeast-1:123456789012:secret:" + "x" * 256,
                  "definitions": {"bucket": "x" * 63, "key": "x" * 512, "version_id": "x" * 64, "sha256": "0" * 64},
                  "tls_names": [long, long], "enable_tls": True, "management": True, "tls_material": True,
                  "plaintext": True, "require_mtls": True, "allow_transient": True, "log_group": "/rabbitmq/" + "x" * 20}
        rendered = template.replace("${config}", base64.b64encode(json.dumps(config).encode()).decode())
        for name, path in [("runtime", "bootstrap.py"), ("health", "health.py")]:
            rendered = rendered.replace("${%s}" % name, base64.b64encode((ROOT / "modules/ec2/runtime" / path).read_bytes()).decode())
        self.assertNotIn("${", rendered)
        self.assertLess(len(gzip.compress(rendered.encode(), 6)), 16384 - 2048, "keep 2 KiB headroom under the EC2 limit")


class DefinitionsMigration(unittest.TestCase):
    def export(self):
        return {
            "rabbit_version": "3.13.7",
            "users": [{"name": "guest", "password_hash": "x", "tags": ["administrator"]},
                      {"name": "ops", "password_hash": "opaque", "tags": ["administrator"]}],
            "permissions": [{"user": "guest", "vhost": "/"}, {"user": "ops", "vhost": "/"}],
            "policies": [{"name": "ha", "definition": {"ha-mode": "all", "ha-sync-mode": "automatic"}},
                         {"name": "ttl", "definition": {"ha-mode": "all", "message-ttl": 60000}}],
            "queues": [{"name": "orders", "vhost": "/", "durable": True, "arguments": {"x-queue-mode": "lazy", "x-queue-version": 1}},
                       {"name": "scratch", "vhost": "/", "durable": False, "auto_delete": False, "arguments": {}}],
            "bindings": [{"vhost": "/", "destination": "scratch", "destination_type": "queue"},
                         {"vhost": "/", "destination": "orders", "destination_type": "queue"}],
            "global_parameters": [{"name": "cluster_name", "value": "old"}, {"name": "keep", "value": 1}],
        }

    def test_transform_produces_importable_definitions(self):
        source = self.export()
        output, counts = prepare.transform(source, drop_transient=True)
        self.assertEqual(source["users"][0]["name"], "guest", "input must not be mutated")
        self.assertEqual([p["name"] for p in output["policies"]], ["ttl"])
        self.assertEqual(output["policies"][0]["definition"], {"message-ttl": 60000})
        self.assertEqual([q["name"] for q in output["queues"]], ["orders"])
        self.assertEqual(output["queues"][0]["arguments"], {})
        self.assertEqual([b["destination"] for b in output["bindings"]], ["orders"])
        self.assertEqual([u["name"] for u in output["users"]], ["ops"])
        self.assertEqual([p["user"] for p in output["permissions"]], ["ops"])
        self.assertEqual(output["global_parameters"], [{"name": "keep", "value": 1}])
        self.assertNotIn("rabbit_version", output)
        self.assertEqual(counts, {"policy_keys_removed": 3, "empty_policies_removed": 1, "queues_removed": 1, "bindings_removed": 1})
        bootstrap.validate_definitions(output)

    def test_transient_queues_kept_without_flag_still_need_opt_in(self):
        output, _ = prepare.transform(self.export())
        with self.assertRaises(ValueError):
            bootstrap.validate_definitions(output)
        bootstrap.validate_definitions(output, allow_transient=True)


if __name__ == "__main__":
    unittest.main()
