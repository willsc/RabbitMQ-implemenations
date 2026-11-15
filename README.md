# RabbitMQ on AWS

Two independent Terraform modules for this AMQP **0-9-1** estate:

| | [EC2](modules/ec2) | [Amazon MQ](modules/amazon-mq) |
|---|---|---|
| Engine | Digest-pinned RabbitMQ 4.4.0 with bundled Erlang/OTP 29 | AWS-managed RabbitMQ 4.3 by default (4.2 allowed) |
| Hosts | Three Ubuntu **26.04** EC2 instances, one per AZ | AWS-managed `CLUSTER_MULTI_AZ`, three nodes |
| Initial sizing | `r5n.2xlarge` per node | `mq.m7g.2xlarge` per node; benchmark independently |
| TLS | Native RabbitMQ TLS on 5671, enabled by default; optional for private-only deployments | Mandatory AMQPS on 5671 |
| Plain AMQP | Optional 5672 through a separate internal NLB, RFC1918 sources only | Unavailable |
| Management UI | Optional private HTTPS endpoint; SSM tunnel always available | Native private HTTPS UI |
| Federation | Enabled; TKY/LDN definitions and TLS destination allowlists | AWS federation plugin; optional existing VPC Lattice/RAM private resource shares |
| Storage | Separate encrypted, retained gp3 EBS volume per node | Service-managed encrypted storage with customer KMS key |
| Shared filesystem | None | None provisioned by this module |

These modules provision into an existing VPC. They do not deploy Artemis, EFS, Kubernetes or Amazon MQ for ActiveMQ. The Ubuntu requirement applies to EC2; AWS controls Amazon MQ's operating system.

## Versions

| Component | Supported | Pinned or tested |
|---|---|---|
| RabbitMQ (EC2) | 4.4 series, enforced by the Packer bake | `rabbitmq:4.4.0-management@sha256:753099a19b577c322117f793f864b3129cbba96d40317221a69d73976e3c843c` |
| Erlang/OTP (EC2) | Whatever the RabbitMQ image bundles | 29 |
| RabbitMQ (Amazon MQ) | `engine_version` 4.3 (default) or 4.2 | AWS selects and upgrades the patch release |
| Upgrade path (EC2) | Rolling, one series at a time ([runbook](docs/operations.md#upgrade-the-rabbitmq-release-series-ec2)) | 4.3.7 → 4.4.0 |
| Ubuntu (EC2 hosts) | 26.04 amd64 | Your approved base AMI |
| Terraform | >= 1.9.0, < 2.0.0 | 1.15.5 |
| AWS provider | >= 6.54, < 7.0 | 6.73.0 (committed lock files) |
| Packer / amazon plugin | >= 1.11.0 / >= 1.3.0, < 2.0.0 | 1.15.0 / 1.8.4 |
| Python, Docker Engine (local tests) | | 3.12, 29.1.3 |

[Validation evidence](docs/validation.md) records what was run against these versions.

## Start here

1. Read [the EC2 guide](modules/ec2/README.md) or [the Amazon MQ guide](modules/amazon-mq/README.md).
2. Complete the [migration audit](docs/migration.md), particularly TLS, queue declarations and federation direction.
3. For EC2, bake your approved Ubuntu 26.04 AMI using [Packer](packer/README.md).
4. Copy the relevant [example](examples), replace its input placeholders, and configure an encrypted remote Terraform backend with locking. Commit the root module's provider lock file; do not commit secrets, tfvars, state or plans.
5. Run `terraform init`, `terraform validate`, and `terraform plan`. Review the plan before applying it to a staging account. Follow the [acceptance checklist](docs/operations.md#acceptance-before-production).
6. Run day-2 changes (AMI rolls, resizes, certificate and definitions changes, node rebuilds) through the [operations runbooks](docs/operations.md).

Local validation uses the committed provider lock files. The verification script checks formatting, the Packer template, the Python runtime unit tests, both modules (`terraform test` with a mocked provider) and both examples. It needs no AWS credentials and creates no AWS resources.

```sh
bash scripts/verify.sh
```

The optional Docker acceptance test exercises real RabbitMQ clustering, TLS, the UI and node recovery. With `--upgrade-from`, it forms the cluster on the older image and rolls each node to `--image` first:

```sh
python3 scripts/smoke_cluster.py --image 'rabbitmq:4.4.0-management@sha256:753099a19b577c322117f793f864b3129cbba96d40317221a69d73976e3c843c'
python3 scripts/smoke_cluster.py --image 'rabbitmq:4.4.0-management@sha256:753099a19b577c322117f793f864b3129cbba96d40317221a69d73976e3c843c' \
  --upgrade-from 'rabbitmq:4.3.7-management@sha256:8e913a7748f808be4ce117c3df11817935775bcd83934d4de92441a7e93e9899'
```

See [validation evidence and limits](docs/validation.md). A passing local test is not proof of AWS routing, Ubuntu AMI boot, regional service support or 83 MB/s capacity.

## Deploy

Each directory under [examples](examples) is a root module. Keep one var file per environment and keep account-specific ones out of git (`terraform.tfvars` and `sandbox.tfvars` are ignored).

### Prerequisites

| | EC2 | Amazon MQ |
|---|---|---|
| Subnets | Three, one per AZ, public-IP auto-assignment off | Same |
| Private access to AWS APIs | NAT gateway or VPC endpoints (below) | Not needed |
| Image | AMI baked with [Packer](packer/README.md) | None |
| Secrets | Bootstrap secret ([format](modules/ec2/README.md#runtime-secret)) | Admin password, passed as `TF_VAR_admin_password` |
| Definitions | Versioned S3 object and its SHA-256 ([pipeline](docs/migration.md#4-definitions-pipeline)) | Imported through the API after creation |
| KMS | Key for the EBS volumes | Customer-managed key for broker storage |
| DNS | Existing hosted zone for `tls_dns` (and `management_dns`, if used) | None |

The EC2 order is in [first deployment](docs/operations.md#first-deployment-ec2).

**Default VPC subnets.** They assign public IPs on launch, and both modules reject them at plan time (`Use private node subnets…` / `…disable public IP assignment`). Turn the setting off on each subnet; it affects only instances launched afterwards:

```sh
aws ec2 modify-subnet-attribute --subnet-id subnet-REPLACE --no-map-public-ip-on-launch
```

**No NAT gateway.** EC2 nodes never get a public IP, so their first boot needs a private path to AWS APIs. Create an S3 gateway endpoint on the nodes' route table, plus interface endpoints for `secretsmanager`, `logs`, `monitoring`, `ssm`, `ssmmessages` and `ec2messages` with private DNS on and a security group allowing 443 from the VPC CIDR. Interface endpoints are billed hourly per endpoint per AZ, used or not. Amazon MQ needs none of this.

**No VPN.** Keep every endpoint private: `tls_public = false` and the VPC CIDR in `tls_client_cidrs` (EC2), or in `client_cidrs` and `management_cidrs` (Amazon MQ). From a workstation, reach EC2 nodes with [SSM port forwarding](modules/ec2/README.md#tls-and-the-ui). Amazon MQ needs a host inside the VPC to tunnel through.

**Packer without a VPN.** The template reaches the builder on its private IP and gives it no public address, so the runner needs private access to the build subnet, and the subnet needs outbound access to Ubuntu mirrors, Docker Hub and the agent download URLs. Outside production, a runner with no route into the VPC can build from a local copy of the template with `ssh_interface = "public_ip"` and `associate_public_ip_address = true`, in a subnet with an Internet Gateway route. The temporary SSH rule is still limited to `builder_cidr`.

### Apply

```sh
cd examples/ec2   # or examples/amazon-mq
export TF_VAR_admin_password='...'   # Amazon MQ only: from your secret store, never a var file
terraform init
terraform plan -var-file=<env>.tfvars -out=<env>.tfplan
terraform apply <env>.tfplan
```

Plan files and state contain the Amazon MQ admin password. `*.tfplan` and `*.tfstate` are git-ignored; use an encrypted, locked remote backend for anything shared.

- **EC2:** node `a` seeds the cluster and `b`/`c` join it. Readiness alarms fire for the first few minutes. Check the cluster with the [SSM commands](docs/operations.md#accessing-a-node).
- **Amazon MQ:** a three-node `mq.m7g.large` cluster in eu-west-1 had RabbitMQ running about 12 minutes after creation started. Import definitions afterwards ([migration, section 4](docs/migration.md#4-definitions-pipeline)).

## Destroy

Both modules set `prevent_destroy = true` on their stateful resources, the Amazon MQ broker and the EC2 data volumes, so a plain `terraform destroy` fails with `Instance cannot be destroyed`. That is deliberate. For production, complete [decommissioning](docs/operations.md#decommissioning) steps 1–3 first.

1. Wait for any running `apply` to finish. It holds the state lock, and AWS will not delete a broker that is still being created.
2. **EC2:** if `nlb_deletion_protection` or any `nodes.*.termination_protection` is `true`, set it to `false` and apply. Snapshot the data volumes if you need to keep them; destroy deletes them.
3. Lift the guard with a temporary override file in the module. Terraform merges only `prevent_destroy`; the module's preconditions and other lifecycle settings still apply. `*_override.tf` is git-ignored.

   ```sh
   # EC2
   cat > modules/ec2/destroy_override.tf <<'EOF'
   resource "aws_ebs_volume" "data" {
     lifecycle {
       prevent_destroy = false
     }
   }
   EOF

   # Amazon MQ
   cat > modules/amazon-mq/destroy_override.tf <<'EOF'
   resource "aws_mq_broker" "this" {
     lifecycle {
       prevent_destroy = false
     }
   }
   EOF
   ```

4. Destroy from the example directory with the var file you applied with. Amazon MQ still needs `TF_VAR_admin_password` set.

   ```sh
   terraform destroy -var-file=<env>.tfvars
   ```

5. **Delete the override file straight away:** `rm modules/*/destroy_override.tf`. While it exists, every plan from that checkout, production included, can destroy the broker or the data volumes.
6. Remove what Terraform did not create:
   - Amazon MQ: the log groups AWS created, `/aws/amazonmq/broker/<broker-id>/general` and `/connection`.
   - Prerequisites, if nothing else uses them: VPC endpoints and their security group, the AMI and its snapshot, secrets (`--force-delete-without-recovery` frees the name immediately), the definitions bucket (delete every object version first), the hosted zone and customer KMS keys (deletion waits 7–30 days). Turn subnet public-IP assignment back on only if something else needs it.

## Availability and migration constraints

Three nodes make the broker service and cluster metadata tolerant of a single node/AZ failure. **RabbitMQ 4 classic queues are not replicated.** Transient messages can be lost during failures, and clients must recover connections, channels, subscriptions, exclusive/auto-delete queues and bindings. Use durable quorum queues where message replication is required; that is a separate application design decision.

RabbitMQ 4.3 and later require a metadata majority. Non-durable, non-exclusive queues are disabled by default on self-managed RabbitMQ and can be enabled temporarily with the EC2 module's explicit migration flag. Amazon MQ 4.3 does not offer that compatibility escape. Its default queue type is quorum, so clients using temporary queues must explicitly request compatible classic/exclusive semantics. [RabbitMQ 4.3 release notes](https://github.com/rabbitmq/rabbitmq-server/releases/tag/v4.3.0), [RabbitMQ 4.4 release notes](https://github.com/rabbitmq/rabbitmq-server/releases/tag/v4.4.0), [Amazon MQ 4.3 changes](https://docs.aws.amazon.com/amazon-mq/latest/developer-guide/rabbitmq-43.html), [Amazon MQ 4.2 changes](https://docs.aws.amazon.com/amazon-mq/latest/developer-guide/rabbitmq-42.html).

The older claim that private Amazon MQ brokers cannot participate as private federation upstreams is no longer a blanket limitation. AWS now provides private outbound connectivity through VPC Lattice, RAM and PrivateLink. The managed module accepts existing `resource_share_arns`; your network team must supply the reachable resource gateways/configurations and permitted shares. See [AWS private networking](https://docs.aws.amazon.com/amazon-mq/latest/developer-guide/private-networking.html).

## Capacity and cost

874 connections and 83 MB/s outbound are starting workload measurements, not a completed sizing exercise. 83 MB/s is approximately 664 Mbit/s before protocol overhead, federation and cross-node traffic. Test the whole workload with one node unavailable, realistic messages, TLS and federation enabled. Many queues can generate more inter-node traffic than the client egress figure suggests.

Budget for three instances/brokers, per-node disks, one to three EC2 NLBs (AMQPS, temporary AMQP, optional UI), NLB processing, cross-AZ/region traffic, NAT or VPC endpoints, logs, metrics and KMS. At a sustained 83 MB/s, aggregate outbound traffic is roughly 215 TB per 30 days; billable transfer depends on destinations. No ActiveMQ/m5.large cost estimate carries over.

The EC2 design runs a cached, immutable container on each Ubuntu host to package RabbitMQ and Erlang together. It is managed by systemd and uses host networking. The bake supports the 4.4 release series; review support dates and add/test later series before their adoption. Do not silently move a production image tag to a new series: existing 4.3 clusters move to 4.4 through the [series upgrade runbook](docs/operations.md#upgrade-the-rabbitmq-release-series-ec2), and a node cannot be downgraded afterwards.
