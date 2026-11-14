#!/usr/bin/env python3
"""Local Docker acceptance test; never contacts AWS. Cleans up only its own containers/network."""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import secrets
import socket
import ssl
import subprocess
import tempfile
import time
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("bootstrap", ROOT / "modules/ec2/runtime/bootstrap.py")
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True, timeout=180, **kwargs).stdout.strip()


def wait_until(predicate, timeout=180):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if predicate():
                return
        except (subprocess.SubprocessError, OSError, ValueError):
            pass
        time.sleep(3)
    raise RuntimeError("Timed out waiting for cluster condition")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", required=True, help="Cached digest-pinned RabbitMQ 4.3 image")
    args = parser.parse_args()
    if "@sha256:" not in args.image:
        parser.error("Pin the test image by digest")
    prefix = "rabbitmq-smoke-" + uuid.uuid4().hex[:8]
    names = {k: f"rabbit@{k}.rmq.test" for k in "abc"}
    containers = []
    password = secrets.token_urlsafe(32)
    salt = secrets.token_bytes(4)
    password_hash = base64.b64encode(salt + hashlib.sha256(salt + password.encode()).digest()).decode()
    definitions = {"users": [{"name": "smoke", "password_hash": password_hash, "hashing_algorithm": "rabbit_password_hashing_sha256", "tags": ["administrator"]}],
                   "vhosts": [{"name": "/"}], "permissions": [{"user": "smoke", "vhost": "/", "configure": ".*", "write": ".*", "read": ".*"}]}
    bootstrap.validate_definitions(definitions)
    with tempfile.TemporaryDirectory(prefix=prefix) as directory:
        folder = Path(directory)
        os.chmod(folder, 0o755)
        run("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-subj", "/CN=localhost",
            "-addext", "subjectAltName=DNS:localhost", "-keyout", str(folder / "key.pem"), "-out", str(folder / "cert.pem"))
        context = ssl.create_default_context(cafile=str(folder / "cert.pem"))
        run("docker", "network", "create", prefix)
        try:
            for node in "abc":
                base = folder / node
                for part in ["etc/tls", "data", "logs"]:
                    path = base / part
                    path.mkdir(parents=True, exist_ok=True)
                for dest, source in [("ca.pem", "cert.pem"), ("cert.pem", "cert.pem"), ("key.pem", "key.pem")]:
                    (base / "etc/tls" / dest).write_bytes((folder / source).read_bytes())
                config = {"cluster": "smoke", "node_names": names, "plaintext": True, "enable_tls": True,
                          "management": True, "require_mtls": False, "allow_transient": False}
                config["discovery_nodes"] = [names["a"]] if node == "a" else [names[node], names["a"]]
                (base / "etc/rabbitmq.conf").write_text(bootstrap.rabbit_config(config))
                (base / "etc/enabled_plugins").write_text("[rabbitmq_management,rabbitmq_prometheus,rabbitmq_federation,rabbitmq_federation_management].\n")
                (base / "etc/definitions.json").write_text(json.dumps(definitions))
                (base / "data/.erlang.cookie").write_text("SmokeTestOnlyCookie0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ\n")
                for path in [base, *base.rglob("*")]:
                    os.chown(path, 999, 999)
                    os.chmod(path, 0o750 if path.is_dir() else 0o400)
                if node == "b":
                    # Exercise the production join probe: read-only CLI container, retained cookie.
                    probe = bootstrap.peer_probe_command(args.image, names["a"], network=prefix, data=base / "data")
                    run(*probe)
                    absent = bootstrap.peer_probe_command(args.image, names["c"], network=prefix, data=base / "data")
                    if subprocess.run(absent, capture_output=True, timeout=60).returncode == 0:
                        raise RuntimeError("Peer probe reported a stopped node as running")
                    print("PASS: follower join probe detects the running seed and rejects an absent peer", flush=True)
                container = prefix + "-" + node
                containers.append(container)
                run("docker", "run", "-d", "--pull=never", "--name", container, "--network", prefix, "--network-alias", f"{node}.rmq.test",
                    "--user", "999:999", "--cap-drop=ALL", "--security-opt=no-new-privileges", "--read-only", "--tmpfs", "/tmp:rw,noexec,nosuid,size=256m", "--tmpfs", "/run",
                    "--ulimit", "nofile=131072:131072",
                    "-e", f"RABBITMQ_NODENAME={names[node]}", "-e", "RABBITMQ_USE_LONGNAME=true", "-e", "RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS=+S 2:2", "-e", "RABBITMQ_CTL_ERL_ARGS=+S 1:1",
                    "-e", "RABBITMQ_MNESIA_BASE=/var/lib/rabbitmq/mnesia",
                    "-p", "127.0.0.1::5671", "-p", "127.0.0.1::15671",
                    "-v", f"{base / 'etc'}:/etc/rabbitmq:ro", "-v", f"{base / 'data'}:/var/lib/rabbitmq", "-v", f"{base / 'logs'}:/var/log/rabbitmq", args.image)
                if node == "a":
                    wait_until(lambda: (run("docker", "exec", container, "rabbitmq-diagnostics", "-q", "check_running"), True)[1])
            def cluster_count(container):
                data = json.loads(run("docker", "exec", container, "rabbitmq-diagnostics", "-q", "cluster_status", "--formatter", "json"))
                return len(data["running_nodes"])
            wait_until(lambda: all(cluster_count(c) == 3 for c in containers))
            print("PASS: all three nodes formed one cluster", flush=True)
            for container in containers:
                ports = json.loads(run("docker", "inspect", container))[0]["NetworkSettings"]["Ports"]
                amqp_port = int(ports["5671/tcp"][0]["HostPort"])
                with context.wrap_socket(socket.create_connection(("127.0.0.1", amqp_port), timeout=10), server_hostname="localhost") as connection:
                    connection.sendall(b"AMQP\x00\x00\x09\x01")
                    assert connection.recv(7)[0] == 1, "Expected AMQP 0-9-1 connection.start"
                ui_port = int(ports["15671/tcp"][0]["HostPort"])
                request = urllib.request.Request(f"https://localhost:{ui_port}/api/overview")
                request.add_header("Authorization", "Basic " + base64.b64encode(f"smoke:{password}".encode()).decode())
                with urllib.request.urlopen(request, context=context, timeout=10) as response:
                    assert json.load(response)["rabbitmq_version"].startswith("4.3.")
                with urllib.request.urlopen(f"https://localhost:{ui_port}/", context=context, timeout=10) as response:
                    assert response.status == 200
            print("PASS: verified TLS, AMQP 0-9-1 and authenticated HTTPS UI on every node", flush=True)
            run("docker", "stop", "--time", "30", containers[2])
            wait_until(lambda: all(cluster_count(c) == 2 for c in containers[:2]))
            print("PASS: surviving nodes retain a two-node majority", flush=True)
            run("docker", "start", containers[2])
            wait_until(lambda: all(cluster_count(c) == 3 for c in containers))
            print("PASS: restarted node rejoins using retained data", flush=True)
        except Exception:
            for container in containers:
                output = subprocess.run(["docker", "logs", container], text=True, capture_output=True)
                lines = (output.stdout + output.stderr).splitlines()
                print(container, "\n".join(lines[:120] + lines[-80:]))
            raise
        finally:
            for container in containers:
                subprocess.run(["docker", "rm", "-f", container], check=False, capture_output=True)
            subprocess.run(["docker", "network", "rm", prefix], check=False, capture_output=True)


if __name__ == "__main__":
    main()
