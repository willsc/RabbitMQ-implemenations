#!/usr/bin/env bash
# Offline verification. Creates no AWS resources and needs no AWS credentials.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== formatting"
terraform fmt -check -recursive
packer fmt -check packer

echo "== shell and Python syntax"
bash -n packer/provision.sh
bash -n scripts/verify.sh
bash -n modules/ec2/templates/cloud-init.sh.tftpl
python3 -m py_compile modules/ec2/runtime/*.py scripts/*.py

echo "== Packer template"
packer validate -syntax-only packer

echo "== Python unit tests"
python3 -m unittest discover -s tests -v

echo "== Terraform modules"
for module in ec2 amazon-mq; do
  terraform -chdir="modules/$module" init -backend=false -input=false -lockfile=readonly -no-color >/dev/null
  terraform -chdir="modules/$module" validate -no-color
  terraform -chdir="modules/$module" test -no-color
done

echo "== Terraform examples"
for example in ec2 amazon-mq; do
  terraform -chdir="examples/$example" init -backend=false -input=false -lockfile=readonly -no-color >/dev/null
  terraform -chdir="examples/$example" validate -no-color
done

echo "All offline checks passed."
