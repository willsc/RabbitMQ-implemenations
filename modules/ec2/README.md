# RabbitMQ EC2 module

Three fixed identities (`a`, `b`, `c`) across three AZs. Retained ENIs, private Route 53 node names and independent encrypted EBS data volumes let a replacement host keep its broker identity. There is no ASG that can replace multiple stateful members unexpectedly. EC2 status alarms alert operators; recovery/replacement is deliberate, one node at a time.

## Inputs and prerequisites

See [variables.tf](variables.tf) for all types, descriptions, validations and defaults, and [the runnable example](../../examples/ec2).

Required for the default TLS deployment:

- `name`, `vpc_id`, `nodes`: exactly three private subnets in different AZs and three baked AMI IDs. AMIs must be owned by an allowed account, x86_64, and carry `RabbitMQOS=ubuntu-26.04` and `RabbitMQAMIContract=1`. A raw Ubuntu AMI must first pass through the [Packer build](../../packer). An optional per-node `instance_type` overrides the module-wide size, so you can resize one node at a time. Changing the module-wide `instance_type` stops and starts all three nodes together.
- `private_zone_name`: a dedicated, non-overlapping private namespace created in this VPC. Never reuse a node's name for another independent cluster.
- `tls_dns`, `tls_subnet_ids`, `tls_client_cidrs`: client name, existing hosted zone, three NLB subnets and explicit client IPv4 allowlists. Set `tls_public=true` and supply public NLB subnets only for internet clients. Public node addresses are never assigned.
- `kms_key_arn`: customer key allowed by your EC2 deployment role and EBS key policy.
- `bootstrap_secret_arn`: an existing Secrets Manager secret, fetched with the instance role. The module never reads its value into Terraform state or user data.
- `definitions`: a versioned S3 object (`bucket`, `key`, `version_id`, `sha256`). Enable bucket versioning, encryption and public-access blocking. Grant any necessary bucket/key cross-account permissions separately. The instance role can read any version of that one key. Each node pins and verifies its own version and checksum, so an un-rolled node still reboots cleanly after the input changes.
- `secret_kms_key_arns`: CMKs for the secret and object, if customer-managed. IAM decrypt access is constrained to those keys through S3/Secrets Manager.

The VPC must enable DNS support and hostnames. Provide routes/NACLs and either NAT or private endpoints for Secrets Manager, S3, CloudWatch Logs/metrics and SSM/SSM Messages. The module opens outbound HTTPS only (configurable destination CIDRs), plus the two Erlang peer ports, AWS time sync, and explicit federation destinations. AmazonProvidedDNS is used. It does not create a VPC, NAT gateways, VPNs, Transit Gateways, endpoints or cross-region routing. TLS NLB public subnets need Internet Gateway routes; subnet public-IP flags alone cannot prove routing correctness.

## TLS and the UI

TLS on 5671 terminates at RabbitMQ, with TLS 1.2/1.3, so the NLB cannot downgrade it. Clients must validate the CA and DNS hostname. `require_client_certificate=true` additionally requires a trusted client certificate; RabbitMQ user authentication still applies.

`plaintext_client_cidrs=["10.20.0.0/16"]` enables 5672 on a separate internal NLB. Set it to `[]` to remove network access; roll the nodes afterwards to remove their listener. The module rejects public CIDRs and supernets extending beyond RFC1918.

For a private-only installation without AMQP TLS, set:

```hcl
enable_tls            = false
tls_public            = false
tls_dns               = null
tls_subnet_ids        = []
tls_client_cidrs      = []
plaintext_client_cidrs = ["10.20.0.0/16"]
```

Passwords on that private AMQP path are unencrypted. The default remains TLS. TLS is mandatory for federation links configured through this module.

Enable the UI with `management_dns={zone_id="...",name="rabbit-ui.example.com"}` and `management_client_cidrs=["10.20.5.0/24"]`. The UI's internal NLB forwards HTTPS 443 to RabbitMQ HTTPS 15671; its certificate must cover the UI hostname. The DNS zone may be a centrally managed private zone. Access it through your VPN/private network. Application CIDRs do not automatically receive UI access. Outputs include `management_url`, broker endpoints and node IDs.

Without those UI inputs, use SSM with no inbound management ports:

```sh
aws ssm start-session --target i-REPLACE \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["15672"],"localPortNumber":["15672"]}'
```

Open `http://localhost:15672` through this encrypted SSM session. The HTTP management listener binds only to the host's loopback interface. Sign in with a user imported in the definitions; the default `guest` account is prohibited.

## Runtime secret

Create the secret through your approved secret-management workflow, outside Terraform:

```json
{
  "erlang_cookie": "REPLACE_WITH_32_OR_MORE_RANDOM_ALPHANUMERIC_CHARACTERS",
  "ca_certificate_pem": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----\n",
  "certificate_pem": "-----BEGIN CERTIFICATE-----\n...leaf-and-intermediates...\n-----END CERTIFICATE-----\n",
  "private_key_pem": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n"
}
```

Only `erlang_cookie` is required when AMQP TLS, HTTPS UI and federation are all disabled. Otherwise the full bundle is required. Include all CA roots needed for clients and TKY/LDN in the CA bundle. The same cert/key are used for the listeners and outgoing federation TLS; issue a certificate with suitable server/client extended key usage if upstreams require mTLS. It must cover every enabled client-facing hostname. The bootstrap checks trust, expiry, names and key matching, and rejects a changed cookie on an existing data volume.

Secret material is owned by container UID 999, with restrictive permissions, on encrypted disks. Host root/SSM administrators and the broker process can access it. AWS instance credentials and IAM policies are attached only to the host. Erlang distribution is cookie-authenticated but **not TLS-encrypted**; security groups confine 4369/25672 to the node group. Use a reviewed inter-node TLS extension if your internal threat model requires it.

Definitions must include at least one administrator with a password hash, application users/permissions, vhosts and the intended durable topology. Never store a plaintext user password. Federation URIs are secrets even though user password hashes are not plaintext passwords. Imports run on boot and can reapply definitions; align changes and rotations with the versioned source. See [migration](../../docs/migration.md).

## Operations and lifecycle

Cloud-init installs no packages and downloads no container images. It mounts only the expected EBS volume, creates ext4 only if no filesystem signature exists, fetches secrets/definitions and starts systemd services. Every node with an empty data volume first probes its peers and joins a running one. Only `a` may seed a new cluster, and only when no peer is running, so a rebuilt `a` cannot start a second, independent cluster. Existing metadata is never reset. The data filesystem grows at boot after an EBS size increase. A first boot requires AWS APIs, DNS and a working seed. An unrecoverable bootstrap failure requires operator repair and `systemctl restart rabbitmq-bootstrap rabbitmq`; readiness alarms report it.

The health endpoint caches diagnostic checks and reports ready only with a running local broker, no local resource alarm, and at least two expected running peers. CloudWatch receives readiness and certificate-expiry metrics. EC2 status and NLB capacity alarms are included. Prometheus is enabled on 15692, accessible only from `monitoring_cidrs`; use it for per-queue depth, federation state, connections, publish/ack rates and host capacity alerting. NLBs can fail open when every target is unhealthy; readiness checks are not a security barrier.

The data volumes have `prevent_destroy=true`. Normal `terraform destroy` is deliberately blocked until that guard is consciously removed from a reviewed module copy. NLB deletion protection and per-node EC2 termination protection also default on. Snapshots are not an automatic guarantee of consistent cluster metadata: follow the [operations guide](../../docs/operations.md#backup-and-restore).

**User data changes are staged, not automatically applied to existing nodes.** `ignore_changes=[user_data_base64]` avoids an ordinary shared template edit stopping/replacing all three brokers. New instances receive the latest template. Use the [one-node procedure](../../docs/operations.md#replace-or-update-one-node) to apply template, definitions reference, secret ARN or listener changes. Changing network rules takes effect immediately. Do not rely on `terraform apply` alone to roll broker configuration.
