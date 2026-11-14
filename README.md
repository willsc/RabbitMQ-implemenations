# RabbitMQ on AWS

Two independent Terraform modules for this AMQP **0-9-1** estate:

| | [EC2](modules/ec2) | [Amazon MQ](modules/amazon-mq) |
|---|---|---|
| Engine | Digest-pinned RabbitMQ 4.4 with matching Erlang | AWS-supported RabbitMQ 4.3 by default |
| Hosts | Three Ubuntu **26.04** EC2 instances, one per AZ | AWS-managed `CLUSTER_MULTI_AZ`, three nodes |
| Initial sizing | `r5n.2xlarge` per node | `mq.m7g.2xlarge` per node; benchmark independently |
| TLS | Native RabbitMQ TLS on 5671, enabled by default; optional for private-only deployments | Mandatory AMQPS on 5671 |
| Plain AMQP | Optional 5672 through a separate internal NLB, RFC1918 sources only | Unavailable |
| Management UI | Optional private HTTPS endpoint; SSM tunnel always available | Native private HTTPS UI |
| Federation | Enabled; TKY/LDN definitions and TLS destination allowlists | AWS federation plugin; optional existing VPC Lattice/RAM private resource shares |
| Storage | Separate encrypted, retained gp3 EBS volume per node | Service-managed encrypted storage with customer KMS key |
| Shared filesystem | None | None provisioned by this module |

These modules provision into an existing VPC. They do not deploy Artemis, EFS, Kubernetes or Amazon MQ for ActiveMQ. The Ubuntu requirement applies to EC2; AWS controls Amazon MQ's operating system.

## Start here

1. Read [the EC2 guide](modules/ec2/README.md) or [the Amazon MQ guide](modules/amazon-mq/README.md).
2. Complete the [migration audit](docs/migration.md), particularly TLS, queue declarations and federation direction.
3. For EC2, bake your approved Ubuntu 26.04 AMI using [Packer](packer/README.md).
4. Copy the relevant [example](examples), replace its input placeholders, and configure an encrypted remote Terraform backend with locking. Commit the root module's provider lock file; do not commit secrets, tfvars, state or plans.
5. Run `terraform init`, `terraform validate`, and `terraform plan`. Review the plan before applying it to a staging account. Follow the [acceptance checklist](docs/operations.md#acceptance-before-production).
6. Run day-2 changes (AMI rolls, resizes, certificate and definitions changes, node rebuilds) through the [operations runbooks](docs/operations.md).

Terraform >=1.9 and AWS provider >=6.54,<7 are supported. Local validation uses the committed provider lock files. The verification script checks formatting, the Packer template, the Python runtime unit tests, both modules (`terraform test` with a mocked provider) and both examples. It needs no AWS credentials and creates no AWS resources.

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

## Availability and migration constraints

Three nodes make the broker service and cluster metadata tolerant of a single node/AZ failure. **RabbitMQ 4 classic queues are not replicated.** Transient messages can be lost during failures, and clients must recover connections, channels, subscriptions, exclusive/auto-delete queues and bindings. Use durable quorum queues where message replication is required; that is a separate application design decision.

RabbitMQ 4.3 and later require a metadata majority. Non-durable, non-exclusive queues are disabled by default on self-managed RabbitMQ and can be enabled temporarily with the EC2 module's explicit migration flag. Amazon MQ 4.3 does not offer that compatibility escape. Its default queue type is quorum, so clients using temporary queues must explicitly request compatible classic/exclusive semantics. [RabbitMQ 4.3 release notes](https://github.com/rabbitmq/rabbitmq-server/releases/tag/v4.3.0), [RabbitMQ 4.4 release notes](https://github.com/rabbitmq/rabbitmq-server/releases/tag/v4.4.0), [Amazon MQ 4.3 changes](https://docs.aws.amazon.com/amazon-mq/latest/developer-guide/rabbitmq-43.html), [Amazon MQ 4.2 changes](https://docs.aws.amazon.com/amazon-mq/latest/developer-guide/rabbitmq-42.html).

The older claim that private Amazon MQ brokers cannot participate as private federation upstreams is no longer a blanket limitation. AWS now provides private outbound connectivity through VPC Lattice, RAM and PrivateLink. The managed module accepts existing `resource_share_arns`; your network team must supply the reachable resource gateways/configurations and permitted shares. See [AWS private networking](https://docs.aws.amazon.com/amazon-mq/latest/developer-guide/private-networking.html).

## Capacity and cost

874 connections and 83 MB/s outbound are starting workload measurements, not a completed sizing exercise. 83 MB/s is approximately 664 Mbit/s before protocol overhead, federation and cross-node traffic. Test the whole workload with one node unavailable, realistic messages, TLS and federation enabled. Many queues can generate more inter-node traffic than the client egress figure suggests.

Budget for three instances/brokers, per-node disks, one to three EC2 NLBs (AMQPS, temporary AMQP, optional UI), NLB processing, cross-AZ/region traffic, NAT or VPC endpoints, logs, metrics and KMS. At a sustained 83 MB/s, aggregate outbound traffic is roughly 215 TB per 30 days; billable transfer depends on destinations. No ActiveMQ/m5.large cost estimate carries over.

The EC2 design runs a cached, immutable container on each Ubuntu host to package RabbitMQ and Erlang together. It is managed by systemd and uses host networking. The bake supports the 4.4 release series; review support dates and add/test later series before their adoption. Do not silently move a production image tag to a new series: existing 4.3 clusters move to 4.4 through the [series upgrade runbook](docs/operations.md#upgrade-the-rabbitmq-release-series-ec2), and a node cannot be downgraded afterwards.
