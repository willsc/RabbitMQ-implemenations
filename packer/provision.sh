#!/usr/bin/env bash
set -euo pipefail
umask 077
# shellcheck source=/dev/null
source /etc/os-release
test "$ID" = ubuntu
test "$VERSION_ID" = 26.04
test "$(dpkg --print-architecture)" = amd64
cloud-init status --wait
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends docker.io python3-boto3 ca-certificates curl openssl chrony
systemctl enable --now docker
docker pull "$RABBITMQ_IMAGE"
test "$(docker run --rm --entrypoint id "$RABBITMQ_IMAGE" -u rabbitmq)" = 999
docker run --rm --entrypoint sh "$RABBITMQ_IMAGE" -c 'test "$RABBITMQ_VERSION" != ""; case "$RABBITMQ_VERSION" in 4.3.*) exit 0;; *) exit 1;; esac'
test "$(docker image inspect --format '{{.Architecture}}' "$RABBITMQ_IMAGE")" = amd64
install -d -m 0750 /etc/rabbitmq-estate
printf '%s\n' "$RABBITMQ_IMAGE" > /etc/rabbitmq-estate/image
# Package URLs must be HTTPS, and checksums come from independently reviewed artifacts.
[[ "$CW_URL" == https://* && "$SSM_URL" == https://* ]]
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "$CW_URL" -o /tmp/cloudwatch.deb
printf '%s  %s\n' "$CW_SHA" /tmp/cloudwatch.deb | sha256sum --check --status
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "$SSM_URL" -o /tmp/ssm.deb
printf '%s  %s\n' "$SSM_SHA" /tmp/ssm.deb | sha256sum --check --status
# Ubuntu may ship SSM as a snap. Keep exactly one agent installation.
if command -v snap >/dev/null && snap list amazon-ssm-agent >/dev/null 2>&1; then
  snap remove amazon-ssm-agent
fi
dpkg -i /tmp/cloudwatch.deb /tmp/ssm.deb
systemctl enable amazon-ssm-agent
cat > /etc/chrony/sources.d/aws.sources <<'TIME'
server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4
TIME
systemctl restart chrony
python3 -c 'import boto3'
test -x /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl
test -x /usr/bin/amazon-ssm-agent
# No RabbitMQ data, TLS keys, users or cookies are ever baked into the image.
apt-get clean
cloud-init clean --logs --machine-id
