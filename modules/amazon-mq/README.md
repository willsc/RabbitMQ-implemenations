# Amazon MQ for RabbitMQ module

Creates one AWS-managed `RabbitMQ` broker with `CLUSTER_MULTI_AZ` (three nodes), three private subnets in three AZs, customer KMS encryption, general logging, a scheduled maintenance window, automatic minor upgrades, CloudWatch alarms and explicit client/UI allowlists. No EC2 AMI is supplied to this module.

See [variables.tf](variables.tf) and [the runnable example](../../examples/amazon-mq). The default engine is `4.3` and the default size is `mq.m7g.2xlarge`. Verify regional offerings and quotas before applying:

```sh
aws mq describe-broker-instance-options \
  --engine-type RABBITMQ --host-instance-type mq.m7g.2xlarge
```

`engine_version` accepts `4.2` or `4.3`; AWS controls the patch release. Automatic upgrades are enabled and changes wait for the configured UTC maintenance window. Plan application reconnects for maintenance. Neither this module nor Amazon MQ provides plaintext 5672. All clients, including the 264 currently connecting publicly without TLS, must move to TLS and have private connectivity before using this deployment. The module intentionally provisions a private broker.

`client_cidrs` and/or `client_security_group_ids` open only 5671. `management_cidrs` allow the HTTPS UI/API ports 443/15671; empty means no UI network ingress is granted. Use VPN/private routes to reach the returned `console_urls`. Use the returned AWS `amqps_endpoints` directly; a CNAME alone does not make AWS's certificate valid for your custom hostname. Terraform filters AMQPS endpoints so a newer Prometheus endpoint is not mistaken for a broker endpoint.

`admin_password` is sensitive, but **the AWS Terraform provider stores it in state**. Inject it from your CI secret store and encrypt/lock/restrict the remote backend. The module creates no `random_password` or secret-version resource and does not claim to avoid this provider limitation. AWS supports only one bootstrap administrator at broker creation. Subsequent users, password rotations, permissions and federation parameters are managed through the RabbitMQ API. Do not edit Terraform's bootstrap user/password to rotate it: the provider can require broker replacement, which this module's `prevent_destroy=true` guard blocks. Keep bootstrap inputs stable and perform runtime rotation through your approved credential workflow.

AWS provisions CloudWatch log groups through its service-linked role. Apply your account's log retention/KMS policy to these service-owned groups after creation; this module does not race AWS to create a group with the same name. Two alarms are included. Broker-dimension RabbitMQ metrics are the **sum** of the three nodes, so:

- `<name>-node-disk` uses a CloudWatch Metrics Insights query over the node-level series and fires when the **worst** node has less than `node_disk_free_alarm_gib` (default 10) free.
- `<name>-memory` is cluster-aggregate (`memory_alarm_percent`, default 70). One node can exceed its watermark, and block publishers, while the aggregate looks healthy.

Add per-node memory and per-queue alerting from the node-level CloudWatch metrics or the management API. Configure `alarm_action_arns` to deliver alarms to on-call SNS topics. Runbooks: [operations](../../docs/operations.md#amazon-mq-operations).

## Definitions, federation and compatibility

The managed service enables federation. Import reviewed definitions through the management API after broker provisioning, using [import_definitions.py](../../scripts/import_definitions.py) from a machine with private connectivity. This separate operation keeps application passwords and federation URIs out of Terraform configuration/state. It is not run implicitly during a Terraform apply.

For TKY/LDN private upstreams, supply `resource_share_arns` for approved RAM shares containing VPC Lattice resource configurations. The network must provide a resource gateway in supported AZs, reachable upstream IP/DNS destinations on 5671, appropriate gateway and upstream security groups, and AWS RAM permissions. The resources are external prerequisites, not silently created public proxies. Inspect `shared_resources` until associations are active and use the returned DNS names with the appropriate expected TLS server name. Keep hostname verification enabled; private connectivity does not replace certificate trust. Associations may require the next broker reboot/maintenance window. See [AWS private networking](https://docs.aws.amazon.com/amazon-mq/latest/developer-guide/private-networking.html).

The EC2 definitions validator requires SNI equal to the upstream hostname. Amazon MQ private resource DNS names may differ from the upstream certificate's hostname, so its reviewed federation URIs must follow AWS's private-network TLS instructions. Do not import the EC2 filesystem certificate paths into Amazon MQ; use its supported [AMQP client TLS settings](https://docs.aws.amazon.com/amazon-mq/latest/developer-guide/rabbitmq-amqp-client-ssl.html).

Amazon MQ 4 defaults to quorum queues. Existing transient/exclusive clients must explicitly request compatible classic queues and test declaration recovery. Amazon MQ 4.3 rejects transient non-exclusive queues and global QoS, and does not support streams. There is no module switch that bypasses those service restrictions. Preserve AWS-managed operator policies when importing application definitions. See [AWS RabbitMQ 4](https://docs.aws.amazon.com/amazon-mq/latest/developer-guide/rabbitmq-4.html) and [4.3 changes](https://docs.aws.amazon.com/amazon-mq/latest/developer-guide/rabbitmq-43.html).

`prevent_destroy=true` guards the broker. Network topology changes and bootstrap-user changes can force replacement; create a fresh broker and migrate clients instead of weakening the guard during routine changes. Deliberate decommissioning requires a reviewed module copy with the guard removed. Removing a module block from configuration also removes its lifecycle rules, so protect destructive plans in CI as well.
