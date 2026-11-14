# Migration audit and cutover

Complete this audit before choosing a module and again before production cutover. Its findings decide whether clients can move unchanged, which module settings are needed, and which application changes must ship first. Treat every export below as **secret**: definitions contain password hashes and federation URIs contain credentials.

## 1. Inventory the current broker

Run against the existing RabbitMQ 3.x cluster, per virtual host where relevant:

```sh
rabbitmqctl export_definitions /secure/path/definitions-export.json
rabbitmqctl list_connections name user vhost peer_host ssl protocol --formatter json > connections.json
rabbitmqctl list_queues -p VHOST name type durable auto_delete exclusive arguments policy consumers messages --formatter json > queues-VHOST.json
rabbitmqctl list_policies -p VHOST --formatter json > policies-VHOST.json
rabbitmqctl federation_status --formatter json > federation.json
```

Record, with owners for each finding:

| Area | Question to answer |
|---|---|
| Connections | Total at peak (starting figure: 874). How many use TLS (`ssl=true`)? Which source networks are public vs RFC1918? (Starting figure: 264 public plaintext.) |
| Clients | Library and version per application; whether automatic connection **and topology** recovery are enabled; heartbeat setting. |
| Queues | Count by `type`, `durable`, `auto_delete`, `exclusive`. Any `x-queue-mode`, `x-queue-master-locator`, `x-queue-version`, stream queues? |
| Policies | Any `ha-*`, `queue-mode` or `queue-master-locator` keys (removed in RabbitMQ 4). |
| Federation | Every upstream, which side is downstream, exchanges/queues federated, `max-hops`, credentials used. |
| Throughput | Peak publish/deliver rates and message sizes per vhost (starting figure: 83 MB/s outbound). |

## 2. TLS

| Client category | EC2 module | Amazon MQ module |
|---|---|---|
| Public, plaintext AMQP | Must move to AMQPS. Use `tls_public=true` with an explicit `tls_client_cidrs` allowlist. Public 5672 is impossible. | Must move to AMQPS **and** gain private connectivity (VPN, Transit Gateway or peering); the broker is private and this module creates no network path. |
| Private, plaintext AMQP | Temporary: `plaintext_client_cidrs` (RFC1918 only) on a separate internal NLB. Plan its removal. | Not available. Move to AMQPS before cutover. |
| TLS clients | Connect to `tls_dns.name` on 5671. Certificate in the bootstrap secret must cover that name. | Connect to the AWS endpoint hostname from `amqps_endpoints`. A CNAME does not make AWS's certificate valid for your name. |

For each TLS client verify: TLS 1.2 or 1.3, SNI sent, hostname verification **enabled**, CA bundle contains the issuing CA. `require_client_certificate=true` (EC2 only) additionally requires a client certificate. Test from the client's real network path, not from inside the VPC.

## 3. Queue declarations

RabbitMQ 4 changes what clients may declare. Test each application against the imported topology in staging: a redeclaration whose arguments differ from the existing queue fails with channel error `406 PRECONDITION_FAILED`.

- **Classic mirrored queues no longer exist.** `ha-*` keys are stripped by [prepare_definitions.py](../scripts/prepare_definitions.py) and rejected by the EC2 bootstrap. Classic queues on RabbitMQ 4 are **not replicated**. Messages that must survive a node loss need durable **quorum** queues. A queue's type is immutable, so changing type means a new queue (new name, or delete and redeclare during cutover).
- **Transient non-exclusive queues** (`durable=false`, `exclusive=false`) are deprecated and disabled by default in 4.3. EC2: `allow_transient_nonexclusive_queues=true` permits them temporarily. Amazon MQ 4.3 rejects them with no override. Fix: make per-connection queues `exclusive`, or make shared queues durable.
- **Default queue type.** EC2 sets `default_queue_type = classic`. Amazon MQ 4 defaults to **quorum**. Quorum queues cannot be exclusive, non-durable or auto-delete. Clients relying on those semantics must declare `x-queue-type=classic` explicitly. Quorum queues do not support global QoS (`basic.qos` with `global=true`); Amazon MQ 4.3 rejects it.
- **Obsolete arguments** `x-queue-mode`, `x-queue-master-locator` and `x-queue-version=1` are removed from definitions by the preparation script. Remove them from client declarations as well, or verify the broker accepts the redeclaration.
- **Streams** are outside this estate's supported topology (EC2 validator rejects them; Amazon MQ 4.3 does not support them).

## 4. Definitions pipeline

Prepare once, review, then publish per target.

```sh
python3 scripts/prepare_definitions.py definitions-export.json prepared.json
# Optional: remove transient/auto-delete queues and their bindings (clients must recreate them)
python3 scripts/prepare_definitions.py definitions-export.json prepared.json --drop-client-queues
```

The script prints counts of removed policy keys, empty policies, queues and bindings, and refuses to overwrite an existing destination. Review the diff by hand. Requirements enforced by the EC2 bootstrap (and sensible for Amazon MQ):

- At least one user tagged `administrator`; every user has a `password_hash`; no plaintext `password`; no `guest` user.
- No obsolete policy keys or queue arguments; no streams; durable queues unless the transient opt-in is set.
- Federation upstream URIs use `amqps` on 5671 with `verify=verify_peer` and `server_name_indication` equal to the URI hostname (see section 5).

To add a user, generate a hash with `rabbitmqctl hash_password` on a trusted host and include `hashing_algorithm` alongside `password_hash`.

**EC2.** Publish to a versioned, KMS-encrypted, public-access-blocked bucket and pass the exact version and checksum to the module:

```sh
sha256sum prepared.json
aws s3api put-object --bucket BUCKET --key rabbitmq/definitions.json --body prepared.json \
  --server-side-encryption aws:kms --ssekms-key-id KEY_ARN --query VersionId --output text
```

Set `definitions = { bucket, key, version_id, sha256 }`. Each node downloads that exact version, verifies the SHA-256, validates it and imports it on boot. For changing definitions later, see [operations](operations.md#change-definitions-or-the-bootstrap-secret).

**Amazon MQ.** Import through the management API from a host with private connectivity:

```sh
python3 scripts/import_definitions.py --endpoint "$(terraform output -json management_urls | jq -r '.[0]')" \
  --username bootstrap-admin --definitions prepared-amazon-mq.json
```

Remove users that clash with the bootstrap administrator, keep AWS-managed operator policies, and rewrite federation URIs for Amazon MQ (no EC2 certificate file paths; see the [module README](../modules/amazon-mq/README.md#definitions-federation-and-compatibility)). Import is additive and may be partial on error; inspect the broker afterwards.

## 5. Federation direction

Federation is **pull-based**. The *downstream* holds the upstream definition and opens the link; messages flow from upstream to downstream. Network rules therefore follow the link: downstream egress and upstream ingress.

| New cluster's role | EC2 module | Amazon MQ module |
|---|---|---|
| Downstream (pulls from TKY/LDN) | Add each upstream CIDR to `federation_egress` (5671 only). The upstream must admit the node IPs (or NAT IPs). | Supply approved `resource_share_arns` (VPC Lattice via RAM); use the `shared_resources` DNS names in URIs. |
| Upstream (TKY/LDN pull from it) | Add their source ranges to `tls_client_cidrs`; they connect to `tls_dns.name`. | Add their ranges to `client_cidrs` and provide private routing to the broker. |

- Use one dedicated, least-privilege federation user per link on the upstream.
- For bidirectional exchange federation set `max-hops` to 1 (or federate distinct exchanges) to prevent message loops.
- EC2 URI template (all three file paths must be the managed bundle, or omitted):

  ```text
  amqps://fed-user:SECRET@tky-rabbit.example.com:5671/%2f?verify=verify_peer&server_name_indication=tky-rabbit.example.com&cacertfile=/etc/rabbitmq/tls/ca.pem&certfile=/etc/rabbitmq/tls/cert.pem&keyfile=/etc/rabbitmq/tls/key.pem
  ```

  The node presents the bootstrap certificate as its client certificate. If an upstream requires mTLS, issue it with client-auth extended key usage, and include each upstream's CA in `ca_certificate_pem`.
- After import, `rabbitmqctl federation_status` must show every link `running`.

## 6. Cutover sequence

1. **Rehearse** the whole sequence in staging, including rollback, with production-like clients and message rates.
2. **Deploy** production, import definitions, and complete the [acceptance checklist](operations.md#acceptance-before-production).
3. **Bridge**: temporarily federate the relevant exchanges (and queues, for work queues) from the old cluster (upstream) into the new one (downstream), so messages published on either side reach consumers on the new side.
4. **Move consumers** to the new cluster, application by application. Watch queue depth on both sides.
5. **Move publishers.** Confirm old-cluster publish rates fall to zero.
6. **Drain** remaining messages from old queues (consumers or a dynamic shovel), then remove the temporary federation.
7. **Close migration paths**: set `plaintext_client_cidrs = []`, roll the nodes to remove the 5672 listener, and set `allow_transient_nonexclusive_queues = false` once no client needs it.
8. **Decommission** the old cluster after an agreed soak period.

**Rollback** until step 8: move clients back in reverse order. Messages published to the new cluster during rollback need reverse federation or a shovel back to the old one. Federation does not preserve ordering across the bridge; applications that depend on strict ordering must move publishers and consumers for a queue together.
