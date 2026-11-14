# Validation evidence and limits

Last run: 2026-11-14. No AWS account was used; nothing on this page is evidence of AWS behaviour.

## Toolchain

| Tool | Version |
|---|---|
| Terraform | 1.15.5 |
| AWS provider (committed lock files) | 6.73.0 |
| Packer / amazon plugin | 1.15.0 / 1.8.4 |
| Python | 3.12 |
| Docker Engine | 29.1.3 |
| RabbitMQ image | `rabbitmq:4.3.7-management@sha256:8e913a7748f808be4ce117c3df11817935775bcd83934d4de92441a7e93e9899` |

## Offline checks: `bash scripts/verify.sh`

| Check | Result |
|---|---|
| `terraform fmt`, `packer fmt` | clean |
| `bash -n` (provisioner, verify script, cloud-init template); `py_compile` (runtime and scripts) | pass |
| `packer validate -syntax-only` (full `packer validate` with well-formed dummy variables also passed; a floating image tag is rejected) | pass |
| Python unit tests (`tests/test_runtime.py`) | 20 pass |
| `modules/ec2`: init (read-only lock file), validate, `terraform test` with mocked provider | 15 pass |
| `modules/amazon-mq`: init (read-only lock file), validate, `terraform test` with mocked provider | 7 pass |
| `examples/ec2`, `examples/amazon-mq`: init (read-only lock file), validate | pass |

The Python tests cover:

- definitions validation (guest, plaintext passwords, 3.x policy keys, transient queues, federation TLS rules)
- the 3.x definitions migration script
- rendered `rabbitmq.conf` for TLS, plaintext, management UI and mTLS
- the join logic: the seed forms a cluster only when no peer runs, a rebuilt seed joins, followers never self-form, existing data is never rejoined
- certificate-expiry parsing
- rendered user data staying at least 2 KiB under the 16 KiB EC2 limit with worst-case inputs

The Terraform tests plan against a mocked AWS provider. They prove variable validation, preconditions, resource counts and selected attribute values. They do not prove that AWS accepts the requests.

## Docker acceptance: `scripts/smoke_cluster.py`

Runs three containers from the pinned image with the module's rendered `rabbitmq.conf`, plugins, definitions import, read-only config mounts, UID 999, dropped capabilities and a read-only root filesystem. Result: **all five stages pass**.

1. The production peer-join probe (`peer_probe_command`, read-only container using the retained cookie) detects the running seed and reports an absent peer as not running.
2. Three nodes form one cluster.
3. On every node: TLS handshake with hostname verification, AMQP 0-9-1 `connection.start`, authenticated HTTPS management API reporting 4.3.x, and the UI page.
4. With one node stopped, the other two keep a running majority.
5. The stopped node restarts and rejoins using its retained data.

This test found a boot-blocking defect, now fixed with a regression test. The generated `management.ssl.ip = 0.0.0.0` was passed into the TLS options, and the 15671 listener failed with `badarg`. With the management UI enabled, every EC2 node would have failed to start.

Also observed on 4.3.7 (single node): a node drained with `rabbitmq-upgrade drain` leaves maintenance mode after a restart, and `rabbitmq-upgrade revive` on a node that is not draining exits 0. The [operations runbook](operations.md#replace-or-update-one-node) still checks the status explicitly.

## Not validated

Prove these in a staging account using the [acceptance checklist](operations.md#acceptance-before-production):

- Any real `terraform apply`: IAM, KMS key policies, Route 53, NLB security groups with client IP preservation, target health, cross-zone behaviour.
- The Packer build and an Ubuntu 26.04 boot: cloud-init, systemd units, Docker host networking, EBS NVMe discovery and formatting, the SSM and CloudWatch agents.
- The bootstrap's AWS calls (Secrets Manager, S3 versioned get, CloudWatch metrics) and the health service under `ProtectSystem=strict`.
- Amazon MQ: regional availability of RabbitMQ 4.3 and `mq.m7g` sizes, CMK encryption, VPC Lattice resource shares, the configuration keys, and the Metrics Insights disk alarm query.
- Federation to TKY/LDN, client compatibility, and capacity (874 connections, 83 MB/s) with one node unavailable.
