#!/usr/bin/env python3
"""Cached readiness: no Erlang VM is started by individual NLB health requests."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import ssl
import subprocess
import threading
import time

STATE = {"ready": False, "updated": 0.0}
CERTIFICATE = Path("/etc/rabbitmq/tls/cert.pem")


def cluster_ready(status, expected, local):
    running = set(status.get("running_nodes", []))
    partitions = status.get("partitions", {})
    return local in running and len(running) >= 2 and running.issubset(set(expected)) and not partitions


def diagnostic(*args):
    result = subprocess.run(["docker", "exec", "--user", "999:999", "rabbitmq", "rabbitmq-diagnostics", "-q", "--timeout", "8", *args],
                            check=True, capture_output=True, text=True, timeout=12)
    return result.stdout


def certificate_days(path=CERTIFICATE, now=None):
    """Days until the leaf certificate expires; negative once expired."""
    result = subprocess.run(["openssl", "x509", "-in", str(path), "-noout", "-enddate"],
                            capture_output=True, text=True, check=True, timeout=5)
    expires = ssl.cert_time_to_seconds(result.stdout.strip().split("=", 1)[1])
    return (expires - (time.time() if now is None else now)) / 86400


def probe(config):
    import boto3
    from botocore.config import Config
    cloudwatch = boto3.client("cloudwatch", region_name=config["region"], config=Config(connect_timeout=3, read_timeout=5, retries={"max_attempts": 2}))
    dimensions = [{"Name": "Cluster", "Value": config["cluster"]}, {"Name": "Node", "Value": config["node_key"]}]
    while True:
        try:
            diagnostic("check_running")
            diagnostic("check_local_alarms")
            status = json.loads(diagnostic("cluster_status", "--formatter", "json"))
            ready = cluster_ready(status, config["node_names"].values(), config["node_name"])
        except (subprocess.SubprocessError, ValueError, KeyError, OSError):
            ready = False
        # Certificate expiry is measured independently of broker state, so a stopped
        # broker cannot masquerade as an expiring certificate (and vice versa).
        days = None
        if config["tls_material"]:
            try:
                days = certificate_days()
            except (subprocess.SubprocessError, ValueError, IndexError, OSError):
                days = None  # Unreadable certificate: metric goes missing, alarm treats as breaching.
            ready = ready and days is not None and days > 0
        STATE.update(ready=ready, updated=time.monotonic())
        metrics = [{"MetricName": "Ready", "Value": int(ready), "Unit": "Count", "Dimensions": dimensions}]
        if days is not None:
            metrics.append({"MetricName": "CertificateDaysRemaining", "Value": days, "Unit": "None", "Dimensions": dimensions})
        try:
            cloudwatch.put_metric_data(Namespace="RabbitMQ/EC2", MetricData=metrics)
        except Exception:
            print("CloudWatch metric publication failed", flush=True)
        time.sleep(15)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        ready = STATE["ready"] and time.monotonic() - STATE["updated"] < 60
        self.send_response(200 if self.path == "/ready" and ready else 503)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"ready\n" if ready else b"unavailable\n")

    def log_message(self, *_args):
        pass


if __name__ == "__main__":
    config = json.loads(Path("/etc/rabbitmq-estate/config.json").read_text())
    threading.Thread(target=probe, args=(config,), daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
