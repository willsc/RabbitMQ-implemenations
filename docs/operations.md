# Operations

Runbooks for the [EC2 module](../modules/ec2/README.md) and the [Amazon MQ module](../modules/amazon-mq/README.md). Commands use the example root module address `module.rabbitmq`; adjust for yours. Change one node at a time and never start a step while any broker alarm is firing.

## First deployment (EC2)

1. Create the KMS keys and key policies (EBS, secret, definitions object, optional logs).
2. Create the bootstrap secret (format in the [module README](../modules/ec2/README.md#runtime-secret)).
3. Publish the definitions object ([migration, section 4](migration.md#4-definitions-pipeline)).
4. Bake and boot-test the AMI ([Packer](../packer/README.md)).
5. `terraform plan`, review, `terraform apply`.

On first boot node `a` probes `b`/`c` for about a minute, finds none running, and seeds the cluster. `b` and `c` wait for a running peer and join it. Readiness alarms fire until at least two nodes are clustered; that is expected for the first few minutes.

## Accessing a node

No inbound administration ports exist. Use SSM:

```sh
aws ssm start-session --target i-REPLACE
sudo docker exec rabbitmq rabbitmq-diagnostics cluster_status
sudo docker exec rabbitmq rabbitmq-diagnostics status | grep -i maintenance
curl -s localhost:8080/ready
sudo journalctl -u rabbitmq-bootstrap -u rabbitmq -u rabbitmq-health --since -1h
```

Bootstrap failures are logged by exception type only (never values). They are also shipped to CloudWatch Logs as `<node>/bootstrap`.

## Health signals

| Alarm | Module | Meaning |
|---|---|---|
| `<name>-<node>-not-ready` | EC2 | Readiness probe failing or not reporting: broker down, local resource alarm, fewer than two expected nodes running, a partition, or an unreadable/expired certificate. |
| `<name>-<node>-ec2-status` | EC2 | EC2 instance/system status check failed. Recovery is a deliberate [node replacement](#replace-or-update-one-node), not automatic. |
| `<name>-<listener>-capacity` | EC2 | NLB has fewer than three healthy targets: failure tolerance is reduced. |
| `<name>-<node>-certificate-expiry` | EC2 | Under 21 days left, or the certificate cannot be read. Rotate (below). |
| `<name>-memory` | Amazon MQ | Cluster-aggregate memory above the threshold. One node can be higher; also watch per-node metrics. |
| `<name>-node-disk` | Amazon MQ | The node with the least free disk is below the threshold. |

Use Prometheus on 15692 (EC2, `monitoring_cidrs` only) for queue depth, unacknowledged messages, federation link state, connection counts and per-node memory and disk. RabbitMQ blocks publishers when a node exceeds its memory watermark (EC2: 60 % of RAM) or drops below its disk limit (EC2: 5 GB).

## Replace or update one node

Use this for anything that only reaches a node through new user data or a stop/start:

- AMI changes (`nodes.X.ami_id`)
- template or runtime script changes
- changes to the definitions reference or secret ARN
- listener changes (`enable_tls`, `plaintext_client_cidrs` emptied, management UI)
- resizes (`nodes.X.instance_type`)

Security group, NLB and alarm changes take effect on apply without touching nodes.

**Never change the module-wide `instance_type` directly.** That stops and starts all three nodes together. Set `nodes.a.instance_type`, roll `a`, then `b`, then `c`. After that, set `instance_type` to the new value and remove the overrides; the plan should show no changes.

Pre-checks, all must pass:

```sh
# On any node: three running nodes, no partitions
sudo docker exec rabbitmq rabbitmq-diagnostics cluster_status
# On the node you are about to take out
sudo docker exec rabbitmq rabbitmq-queues check_if_node_is_quorum_critical
```

Steps for node `X`:

1. **Remove from load balancers.** For each ARN in the `target_group_arns` output:
   `aws elbv2 deregister-targets --target-group-arn ARN --targets Id=INSTANCE_ID`, then
   `aws elbv2 wait target-deregistered --target-group-arn ARN --targets Id=INSTANCE_ID`.
2. **Drain** on the node: `sudo docker exec rabbitmq rabbitmq-upgrade drain`. This closes client connections and moves quorum queue leaders elsewhere.
3. **Replacement only:** set `nodes.X.termination_protection = false` and apply. The plan must change only that attribute.
4. **Apply the change.** Either edit `nodes.X` (AMI or instance type), or for template-only changes run
   `terraform apply -replace='module.rabbitmq.aws_instance.node["X"]'`.
   The plan must replace or update exactly one `aws_instance` and recreate only its volume and target-group attachments. `aws_ebs_volume.data["X"]`, `aws_network_interface.node["X"]` and the Route 53 records must be unchanged. If the plan shows anything else, stop.
5. **Verify** the node rejoined with its retained data and identity:
   - its `not-ready` alarm returns to OK
   - `cluster_status` shows three running nodes
   - `rabbitmq-diagnostics status` reports `Is under maintenance?: false`. A restart normally clears maintenance mode; if not, run `rabbitmq-upgrade revive`, which is a no-op on a node that is not draining.
   - all target groups show the node healthy. A replacement registers the new instance automatically. After a stop/start (resize), re-register it with `aws elbv2 register-targets`.
6. **Restore** `termination_protection = true` and apply.
7. Wait until `check_if_node_is_quorum_critical` passes on the next node, then repeat for it.

## Upgrade the RabbitMQ release series (EC2)

A move to a new minor series, such as 4.3 to 4.4, is a normal AMI roll with extra gates. The [Docker acceptance test](validation.md#docker-acceptance-scriptssmoke_clusterpy) has proved this exact sequence from 4.3.7 to 4.4.0; prove it again in staging with production-like definitions and clients.

**It is one-way.** Once a 4.4 node writes classic-queue message store files in its new v2 format, that node cannot go back to 4.3. Rollback means restoring the node's data volume from a snapshot taken before the roll, so take one per node first.

1. Read the [release notes](https://github.com/rabbitmq/rabbitmq-server/releases/tag/v4.4.0) and confirm the breaking changes do not affect your clients. For 4.4.0: the `GET /api/auth/hash_password/{password}` endpoint is now `POST /api/auth/hash_password`; OAuth 2 discovery is validated more strictly; and the AMQP 1.0 / `x-basic-*` headers written by 3.13 and earlier nodes are no longer parsed.
2. Bake and boot-test a new AMI with the 4.4 image ([Packer](../packer/README.md)).
3. On any node, enable every feature flag of the **current** series, then confirm none remain disabled:
   ```sh
   sudo docker exec rabbitmq rabbitmqctl enable_feature_flag all
   sudo docker exec rabbitmq rabbitmqctl list_feature_flags name state stability
   ```
   RabbitMQ supports a rolling upgrade to the next series only when every stable feature flag is already enabled.
4. Snapshot each node's data volume (`aws ec2 create-snapshot --volume-id VOLUME_ID`) and wait for the snapshots to complete.
5. [Roll the nodes](#replace-or-update-one-node) to the new AMI (`nodes.X.ami_id`) one at a time: `a`, `b`, then `c`. Finish promptly: a mixed-version cluster is supported only while the upgrade is in progress, so do not change definitions, policies or topology until it is done.
6. After all three nodes run 4.4, enable the new series' feature flags with `enable_feature_flag all`, then check that `list_feature_flags` shows every stable flag `enabled`.

## Change definitions or the bootstrap secret

**Definitions.** Upload a new object version, update the `definitions` input (`version_id`, `sha256`) and apply. The instance role may read any version of that one key, so un-rolled nodes still reboot cleanly with their pinned version. Then [roll every node](#replace-or-update-one-node) promptly. Each node imports its own file at boot. A node still holding an older file re-imports it when it restarts, which can revert changed values such as password hashes or policies (import is additive and never deletes). For an urgent change, also import immediately through the API with [import_definitions.py](../scripts/import_definitions.py) (management UI or an SSM tunnel), and still complete the roll.

**Certificate and key** (same secret, new content). Update the secret value, then node by node: deregister and drain (steps 1–2 above), run `sudo systemctl restart rabbitmq-bootstrap`, verify (step 5), and re-register the targets. Restarting the bootstrap re-fetches the secret, re-validates names, expiry and key match, and also restarts `rabbitmq` (it `Requires=` the bootstrap). The certificate-expiry metric updates within a minute.

**Secret ARN.** Prefer rotating the content of the same secret. Changing `bootstrap_secret_arn` grants only the new ARN as soon as you apply, so any un-rolled node that reboots fails bootstrap. If the ARN must change, roll all three nodes immediately after the apply.

**Erlang cookie.** This needs a coordinated full-cluster outage, because every node must share the cookie and the bootstrap refuses a cookie that differs from the retained one.

1. Stop clients.
2. Run `sudo systemctl stop rabbitmq` on all three nodes.
3. Update `erlang_cookie` in the secret.
4. On each node, run `sudo rm /srv/rabbitmq/data/.erlang.cookie`.
5. Run `sudo systemctl restart rabbitmq-bootstrap` on all three nodes within a few minutes of each other.

## Storage

- **Grow** by increasing `data_volume` (`size`, `iops`, `throughput`). EBS modifies volumes online, at most once per six hours per volume. The filesystem grows at the next bootstrap run, or immediately with `sudo resize2fs "$(findmnt -no SOURCE /srv/rabbitmq)"`.
- **Shrinking is not possible**; build a new cluster instead.

## Backup and restore

- **Topology and configuration**: the versioned definitions object is authoritative. Additionally schedule `rabbitmqctl export_definitions` through SSM and store it encrypted. It contains hashes and federation credentials.
- **Messages are not backed up.** Quorum queues replicate across nodes; classic queues do not.
- **EBS snapshots** (none are created by the module) are crash-consistent per volume and not consistent across nodes. Never restore a single node's snapshot into a running cluster. Use them for forensics or for a whole-cluster restore from one point in time.

**Rebuild a node whose data volume is lost** (any node, including `a`):

1. On a surviving node: `sudo docker exec rabbitmq rabbitmqctl forget_cluster_node rabbit@X.PRIVATE_ZONE`.
2. After confirming the old volume is gone or snapshotted, run `terraform state rm 'module.rabbitmq.aws_ebs_volume.data["X"]'`. Then apply with `-replace='module.rabbitmq.aws_instance.node["X"]'`. The instance must be replaced in the same apply: its user data names the volume ID.
3. The blank node probes its peers, joins the running cluster and keeps its name.
4. Restore quorum queue replicas: `sudo docker exec rabbitmq rabbitmq-queues grow rabbit@X.PRIVATE_ZONE all`. Classic queue contents that lived on that node are lost.

**Loss of two or more nodes' data** is a disaster recovery. Build a fresh cluster (new volumes for all nodes) and re-import definitions. Messages are lost.

## Amazon MQ operations

- `apply_immediately=false`: configuration, engine and instance type changes are pending until the weekly UTC maintenance window or `aws mq reboot-broker`. Clients must reconnect during maintenance.
- Users, passwords, permissions and federation parameters are managed through the RabbitMQ API, not Terraform. Do not change `admin_username`/`admin_password` in Terraform (see the module README).
- AWS creates the general log group (`/aws/amazonmq/broker/<broker-id>/general`). Apply your retention and KMS policy to it after creation.

## Decommissioning

1. Move all clients away and confirm zero connections.
2. Set `nlb_deletion_protection = false` and `termination_protection = false` on every node (EC2), then apply.
3. Snapshot data volumes if retention requires it.
4. Remove `prevent_destroy` in a reviewed copy of the module and destroy. The same applies to the Amazon MQ broker.

## Acceptance before production

Complete in a staging account with the production module configuration, and record the evidence.

Both modules:

- [ ] `terraform plan` after apply shows no changes.
- [ ] TLS clients connect from their real networks with hostname verification enabled; a wrong-hostname connection fails.
- [ ] Denied paths fail: AMQP from a non-allowlisted CIDR, plaintext from a public address, UI from an application CIDR.
- [ ] Definitions imported: vhosts, users, permissions, policies; `guest` absent; administrators log in.
- [ ] Federation links show `running` in both directions where configured; a test message crosses each link.
- [ ] Alarms reach the on-call SNS topic (trigger one deliberately).
- [ ] Load test at peak connections (874+) and throughput (83 MB/s+), with real message sizes, TLS and federation enabled, **with one node unavailable**.
- [ ] Every client application recovers connections, channels, consumers and declared topology after a node failure.

EC2 module:

- [ ] The baked AMI boots; SSM sessions work; broker and bootstrap logs arrive in CloudWatch Logs.
- [ ] All three nodes are `Ready`; each target group shows three healthy targets.
- [ ] Stop one instance: the cluster stays writable, alarms fire, clients reconnect; start it: it rejoins.
- [ ] Rehearse [replace or update one node](#replace-or-update-one-node) on every node, including `a`.
- [ ] Rehearse certificate rotation; the `CertificateDaysRemaining` metric reflects the new certificate.
- [ ] Reboot a node mid-roll with a changed `definitions` input: it boots with its pinned version.
- [ ] Prometheus scrapes 15692 from `monitoring_cidrs` only.

Amazon MQ module:

- [ ] Engine 4.3 and `mq.m7g` size are available in the region (`aws mq describe-broker-instance-options`).
- [ ] `memory` and `node-disk` alarms are in state OK (not INSUFFICIENT_DATA) once the broker is running.
- [ ] Private federation resource associations in `shared_resources` are active.
- [ ] A maintenance-window reboot is observed and clients recover.
