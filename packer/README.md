# Ubuntu 26.04 RabbitMQ AMI

The Terraform EC2 module consumes a **baked Ubuntu Server 26.04 amd64 AMI**, not a raw OS image. This template uses your approved `source_ami`; it does not silently select a latest image. The build refuses a different OS release or architecture.

It installs Docker, Python/boto3, OpenSSL, chrony and checksum-verified SSM/CloudWatch agents. It caches a RabbitMQ 4.3 image **by digest**, checks the container architecture and UID, and writes the image reference into `/etc/rabbitmq-estate/image`. RabbitMQ's image supplies its compatible Erlang release. No cookie, application credentials, TLS keys or broker data are baked into the AMI.

Copy `build.pkrvars.hcl.example` to an untracked `.pkrvars.hcl` file and supply approved artifacts. AWS agent packages must be amd64 .debs compatible with Ubuntu 26.04; verify the package signatures/checksums through your artifact approval process. Use versioned URLs and the expected hashes. A mutable download cannot silently change the accepted bytes.

```sh
packer init packer
packer validate -var-file=packer/build.pkrvars.hcl packer
packer build -var-file=packer/build.pkrvars.hcl packer
```

The runner needs EC2 image-building permissions, the encryption key, SSH access to a private builder subnet, and outbound access for Ubuntu repositories and the approved artifacts/image registry. Packer creates a temporary build-only SSH security group scoped to `builder_cidr`; production brokers have no SSH ingress. Use a dedicated build role and no application secrets. Do not run `packer build` against production without reviewing the AWS resources it will create.

After the build, scan the OS and container, boot-test the AMI in staging using the EC2 module, verify SSM/logs after reboot, and promote the AMI ID. Preserve the manifest, source AMI ID, package inventory, image digest and scan report. Re-bake for Ubuntu, Docker, AWS-agent and RabbitMQ fixes; production boot never updates packages opportunistically. The supplied provisioning script validates the 4.3 series; later series need a reviewed compatibility change and the same acceptance tests.

The current template's host-package installation takes Ubuntu security updates at bake time. The final AMI and cached broker digest are immutable; this is not a claim that rebuilding from the same inputs yields byte-identical OS packages forever. Use an approved APT snapshot/mirror if that is required.
