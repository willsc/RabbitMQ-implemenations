#!/usr/bin/env python3
"""Fail-closed bootstrap. Secret values are never included in logs or process arguments."""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
from urllib.parse import parse_qs, urlsplit

CONFIG = Path("/etc/rabbitmq-estate/config.json")
ETC = Path("/etc/rabbitmq")
DATA = Path("/srv/rabbitmq/data")
UID = 999


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=60, **kwargs).stdout.strip()


def write(path, content, mode=0o400, owner=UID):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + ".new")
    temporary.write_text(content)
    os.chmod(temporary, mode)
    os.chown(temporary, owner, owner)
    temporary.replace(path)


def validate_definitions(definitions, allow_transient=False):
    if not isinstance(definitions, dict):
        raise ValueError("Definitions must be a JSON object")
    users = definitions.get("users", [])
    if not users or any(u.get("name") == "guest" or "password" in u or not u.get("password_hash") for u in users):
        raise ValueError("Definitions require hashed users, no guest and no plaintext passwords")
    if not any("administrator" in u.get("tags", []) for u in users):
        raise ValueError("Definitions require an administrator")
    removed = {"ha-mode", "ha-params", "ha-sync-mode", "ha-promote-on-shutdown", "ha-promote-on-failure", "queue-master-locator", "queue-mode"}
    for policy in definitions.get("policies", []) + definitions.get("operator_policies", []):
        if removed.intersection(policy.get("definition", {})):
            raise ValueError("Definitions contain obsolete RabbitMQ 3.x policy keys")
    for queue in definitions.get("queues", []):
        if not queue.get("durable", False) and not allow_transient:
            raise ValueError("Imported transient queues require explicit migration compatibility")
        if queue.get("arguments", {}).get("x-queue-type") == "stream":
            raise ValueError("Streams are outside this AMQP 0-9-1 estate's supported topology")
        if {"x-queue-mode", "x-queue-master-locator"}.intersection(queue.get("arguments", {})):
            raise ValueError("Remove obsolete queue arguments before import")
    for parameter in definitions.get("parameters", []):
        if parameter.get("component") != "federation-upstream":
            continue
        uris = parameter["value"].get("uri", [])
        uris = [uris] if isinstance(uris, str) else uris
        if not uris:
            raise ValueError("Federation upstream requires at least one URI")
        for uri in uris:
            parsed = urlsplit(uri)
            query = parse_qs(parsed.query)
            if (parsed.scheme != "amqps" or not parsed.hostname or parsed.port not in (None, 5671)
                    or query.get("verify") != ["verify_peer"]
                    or query.get("server_name_indication") != [parsed.hostname]):
                raise ValueError("Federation requires AMQPS 5671, verify_peer and matching SNI")
            # Use only the managed files; prohibit URI overrides that weaken trust.
            for key, expected in {"cacertfile": "/etc/rabbitmq/tls/ca.pem", "certfile": "/etc/rabbitmq/tls/cert.pem", "keyfile": "/etc/rabbitmq/tls/key.pem"}.items():
                if query.get(key, [expected]) != [expected]:
                    raise ValueError("Federation TLS paths must use the managed certificate bundle")


def mount_data(volume_id):
    serial = volume_id.replace("-", "")
    device = None
    for _ in range(120):
        tree = json.loads(run("lsblk", "--json", "--paths", "--output", "NAME,SERIAL,TYPE"))
        device = next((d["name"] for d in tree["blockdevices"] if (d.get("serial") or "").strip() == serial and d["type"] == "disk"), None)
        if device:
            break
        time.sleep(5)
    if not device:
        raise RuntimeError("Expected EBS data volume is not attached")
    mount = Path("/srv/rabbitmq")
    mount.mkdir(mode=0o750, exist_ok=True)
    if subprocess.run(["mountpoint", "-q", str(mount)], check=False).returncode != 0:
        signatures = run("wipefs", "--noheadings", "--output", "TYPE", device).splitlines()
        if not signatures:
            run("mkfs.ext4", "-L", "rabbitmq-data", device)
        elif signatures != ["ext4"]:
            raise RuntimeError("Refusing to format an existing non-ext4 data volume")
        run("mount", "-o", "noatime,nodev,nosuid", device, str(mount))
        # Online grow after an EBS size increase; a no-op when the filesystem already fills the
        # volume. Growing is optional, so a failure is reported but never blocks broker start.
        if subprocess.run(["resize2fs", device], check=False, capture_output=True, timeout=600).returncode != 0:
            print("Data filesystem grow failed; run resize2fs manually", file=sys.stderr)
    mounted = run("findmnt", "--noheadings", "--output", "SOURCE", "--target", str(mount))
    if os.path.realpath(mounted) != os.path.realpath(device):
        raise RuntimeError("Unexpected filesystem mounted at RabbitMQ data directory")
    DATA.mkdir(mode=0o750, exist_ok=True)
    os.chown(DATA, UID, UID)


def image_reference():
    image = Path("/etc/rabbitmq-estate/image").read_text().strip()
    if not re.fullmatch(r"[a-zA-Z0-9./:_-]+@sha256:[a-f0-9]{64}", image):
        raise ValueError("RabbitMQ image must be pinned by digest")
    run("docker", "image", "inspect", image)
    return image


SEED_PROBE_ROUNDS = 3
FOLLOWER_PROBE_ROUNDS = 60


def peer_probe_command(image, peer, network="host", data=DATA):
    """Read-only CLI container that authenticates to a peer with the retained cookie."""
    return ["docker", "run", "--rm", "--pull=never", "--network", network, "--user", "999:999",
            "--cap-drop=ALL", "--security-opt=no-new-privileges", "--read-only", "--tmpfs", "/tmp",
            "-v", f"{data}:/var/lib/rabbitmq:ro", image,
            "rabbitmq-diagnostics", "--longnames", "--timeout", "10", "-n", peer, "check_running"]


def running_peer(config, image):
    for key, peer in sorted(config["node_names"].items()):
        if key == config["node_key"]:
            continue
        try:
            run(*peer_probe_command(image, peer))
            return peer
        except (subprocess.SubprocessError, OSError):
            pass
    return None


def wait_for_peer(config):
    # Existing node data is never reset. RabbitMQ's own recovery handles reboots.
    if (DATA / "mnesia").exists() and any((DATA / "mnesia").iterdir()):
        return
    image = image_reference()
    # Every blank node prefers joining a running peer. This includes the seed: a rebuilt
    # node a with an empty volume must join b/c rather than found a second cluster.
    seed = config["node_key"] == "a"
    for _ in range(SEED_PROBE_ROUNDS if seed else FOLLOWER_PROBE_ROUNDS):
        peer = running_peer(config, image)
        if peer:
            config["discovery_nodes"] = [config["node_name"], peer]
            write(ETC / "rabbitmq.conf", rabbit_config(config))
            return
        time.sleep(5)
    if seed:
        # Only the designated seed may create the first cluster, and only when no peer runs.
        config["discovery_nodes"] = [config["node_name"]]
        write(ETC / "rabbitmq.conf", rabbit_config(config))
        return
    raise RuntimeError("No running peer; refusing to create an independent follower cluster")


def rabbit_config(config):
    peers = "\n".join(f"cluster_formation.classic_config.nodes.{i} = {node}" for i, node in enumerate(config.get("discovery_nodes", config["node_names"].values()), 1))
    tls = f"""listeners.ssl.default = 5671
ssl_options.cacertfile = /etc/rabbitmq/tls/ca.pem
ssl_options.certfile = /etc/rabbitmq/tls/cert.pem
ssl_options.keyfile = /etc/rabbitmq/tls/key.pem
ssl_options.verify = verify_peer
ssl_options.fail_if_no_peer_cert = {str(config['require_mtls']).lower()}
ssl_options.versions.1 = tlsv1.3
ssl_options.versions.2 = tlsv1.2
""" if config["enable_tls"] else "listeners.ssl = none"
    # Do not set management.ssl.ip: it is copied into ssl_opts as a string and the
    # TLS listener then fails with badarg, aborting broker boot. The default binds all
    # interfaces; the node security group admits 15671 only from the UI NLB.
    management_tls = """management.ssl.port = 15671
management.ssl.cacertfile = /etc/rabbitmq/tls/ca.pem
management.ssl.certfile = /etc/rabbitmq/tls/cert.pem
management.ssl.keyfile = /etc/rabbitmq/tls/key.pem
management.ssl.versions.1 = tlsv1.3
management.ssl.versions.2 = tlsv1.2
""" if config["management"] else ""
    return f"""cluster_name = {config['cluster']}
{'listeners.tcp.default = 5672' if config['plaintext'] else 'listeners.tcp = none'}
{tls}
{management_tls}
cluster_formation.peer_discovery_backend = classic_config
cluster_formation.discovery_retry_limit = 60
cluster_formation.discovery_retry_interval = 1000
{peers}
definitions.import_backend = local_filesystem
definitions.local.path = /etc/rabbitmq/definitions.json
definitions.skip_if_unchanged = true
default_queue_type = classic
deprecated_features.permit.transient_nonexcl_queues = {str(config['allow_transient']).lower()}
management.tcp.ip = 127.0.0.1
management.tcp.port = 15672
prometheus.tcp.port = 15692
vm_memory_high_watermark.relative = 0.6
disk_free_limit.absolute = 5GB
heartbeat = 60
max_channels_per_connection = 2047
tcp_listen_options.backlog = 4096
log.console = true
log.file = /var/log/rabbitmq/rabbit.log
log.file.rotation.size = 104857600
log.file.rotation.count = 5
"""


def configure(config):
    import boto3
    from botocore.config import Config
    session = boto3.Session(region_name=config["region"])
    api_config = Config(retries={"mode": "standard", "max_attempts": 10}, connect_timeout=5, read_timeout=30)
    mount_data(config["volume_id"])
    image = image_reference()
    secret = json.loads(session.client("secretsmanager", config=api_config).get_secret_value(SecretId=config["secret_arn"])["SecretString"])
    cookie = secret["erlang_cookie"]
    if not re.fullmatch(r"[A-Za-z0-9]{32,255}", cookie):
        raise ValueError("Cookie must contain 32-255 alphanumeric characters")
    cookie_file = DATA / ".erlang.cookie"
    if cookie_file.exists() and cookie_file.read_text().strip() != cookie:
        raise ValueError("Cookie differs from retained node identity; coordinated rotation is required")
    for path in [ETC, ETC / "tls", Path("/var/log/rabbitmq")]:
        path.mkdir(mode=0o750, parents=True, exist_ok=True)
        os.chown(path, UID, UID)
    write(cookie_file, cookie + "\n")
    if config["tls_material"]:
        for filename, key in [("ca.pem", "ca_certificate_pem"), ("cert.pem", "certificate_pem"), ("key.pem", "private_key_pem")]:
            write(ETC / "tls" / filename, secret[key])
        cert = str(ETC / "tls/cert.pem")
        key = str(ETC / "tls/key.pem")
        run("openssl", "x509", "-in", cert, "-noout", "-checkend", "86400")
        for name in config["tls_names"]:
            run("openssl", "verify", "-verify_hostname", name, "-CAfile", str(ETC / "tls/ca.pem"), "-untrusted", cert, cert)
        run("openssl", "verify", "-CAfile", str(ETC / "tls/ca.pem"), "-untrusted", cert, cert)
        if run("openssl", "x509", "-in", cert, "-pubkey", "-noout") != run("openssl", "pkey", "-in", key, "-pubout"):
            raise ValueError("Certificate and key do not match")
    obj = config["definitions"]
    raw = session.client("s3", config=api_config).get_object(Bucket=obj["bucket"], Key=obj["key"], VersionId=obj["version_id"])["Body"].read()
    if hashlib.sha256(raw).hexdigest() != obj["sha256"]:
        raise ValueError("Definitions checksum mismatch")
    definitions = json.loads(raw)
    validate_definitions(definitions, config["allow_transient"])
    write(ETC / "definitions.json", json.dumps(definitions))
    settings = rabbit_config(config)
    write(ETC / "rabbitmq.conf", settings)
    write(ETC / "enabled_plugins", "[rabbitmq_management,rabbitmq_prometheus,rabbitmq_federation,rabbitmq_federation_management].\n")
    if config["tls_material"]:
        write(ETC / "advanced.config", '[{amqp_client,[{ssl_options,[{cacertfile,"/etc/rabbitmq/tls/ca.pem"},{certfile,"/etc/rabbitmq/tls/cert.pem"},{keyfile,"/etc/rabbitmq/tls/key.pem"},{verify,verify_peer}]}]}].\n')
    command = ["/usr/bin/docker", "run", "--rm", "--pull=never", "--name", "rabbitmq", "--network", "host",
               "--user", "999:999", "--cap-drop=ALL", "--security-opt=no-new-privileges", "--read-only",
               "--tmpfs", "/tmp:rw,noexec,nosuid,size=256m", "--tmpfs", "/run:rw,nosuid,size=16m",
               "--ulimit", "nofile=131072:131072", "--log-driver=journald", "--stop-timeout", "120",
               "-e", f"RABBITMQ_NODENAME={config['node_name']}", "-e", "RABBITMQ_USE_LONGNAME=true",
               "-e", "RABBITMQ_MNESIA_BASE=/var/lib/rabbitmq/mnesia",
               "-v", f"{DATA}:/var/lib/rabbitmq", "-v", "/etc/rabbitmq:/etc/rabbitmq:ro",
               "-v", "/var/log/rabbitmq:/var/log/rabbitmq", image]
    write("/opt/rabbitmq-estate/start-broker", "#!/bin/sh\nexec " + shlex.join(command) + "\n", mode=0o700, owner=0)
    # Broker logs are 0750 uid 999 and cloud-init output is root-only; the agent must read both.
    agent_config = {"agent": {"region": config["region"], "run_as_user": "root"}, "logs": {"logs_collected": {"files": {"collect_list": [
        {"file_path": "/var/log/rabbitmq/rabbit.log", "log_group_name": config["log_group"], "log_stream_name": config["node_key"] + "/rabbitmq"},
        {"file_path": "/var/log/cloud-init-output.log", "log_group_name": config["log_group"], "log_stream_name": config["node_key"] + "/bootstrap"}
    ]}}}}
    write("/etc/rabbitmq-estate/cloudwatch.json", json.dumps(agent_config), owner=0)
    run("/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl", "-a", "fetch-config", "-m", "ec2", "-c", "file:/etc/rabbitmq-estate/cloudwatch.json", "-s")


if __name__ == "__main__":
    try:
        configuration = json.loads(CONFIG.read_text())
        if sys.argv[1:] == ["--wait-for-peer"]:
            wait_for_peer(configuration)
        else:
            configure(configuration)
    except Exception as error:
        # boto/subprocess exceptions can contain secrets. Emit the type only.
        print(f"RabbitMQ bootstrap failed ({type(error).__name__}); inspect prerequisites without logging secret data", file=sys.stderr)
        sys.exit(1)
