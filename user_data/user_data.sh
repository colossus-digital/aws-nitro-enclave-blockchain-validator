#!/bin/bash
#  Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
#  SPDX-License-Identifier: MIT-0
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

set -x
set -e

echo "NITRO_ENCLAVE_DEBUG=${__NITRO_ENCLAVE_DEBUG__}" >>/etc/environment
echo "REGION=${__REGION__}" >>/etc/environment
echo "TLS_KEYS_TABLE_NAME=${__TLS_KEYS_TABLE_NAME__}" >>/etc/environment
echo "VALIDATOR_KEYS_TABLE_NAME=${__VALIDATOR_KEYS_TABLE_NAME__}" >>/etc/environment
echo "CF_STACK_NAME=${__CF_STACK_NAME__}" >>/etc/environment

yum update -y
amazon-linux-extras install docker
systemctl start docker
systemctl enable docker
amazon-linux-extras enable aws-nitro-enclaves-cli
yum install -y aws-nitro-enclaves-cli aws-nitro-enclaves-cli-devel htop git mod_ssl

sudo -H bash -c "pip3 install boto3"
sudo -H bash -c "pip3 install botocore"

usermod -aG docker ec2-user
usermod -aG ne ec2-user

ALLOCATOR_YAML=/etc/nitro_enclaves/allocator.yaml
MEM_KEY=memory_mib
CPU_KEY=cpu_count
DEFAULT_MEM=4096
DEFAULT_CPU=2

sed -r "s/^(\s*$MEM_KEY\s*:\s*).*/\1$DEFAULT_MEM/" -i "$ALLOCATOR_YAML"
sed -r "s/^(\s*$CPU_KEY\s*:\s*).*/\1$DEFAULT_CPU/" -i "$ALLOCATOR_YAML"

VSOCK_PROXY_YAML=/etc/nitro_enclaves/vsock-proxy.yaml
cat <<'EOF' >$VSOCK_PROXY_YAML
allowlist:
- {address: kms.${__REGION__}.amazonaws.com, port: 443}
- {address: kms-fips.${__REGION__}.amazonaws.com, port: 443}
EOF

sleep 20
systemctl start nitro-enclaves-allocator.service
systemctl enable nitro-enclaves-allocator.service

systemctl start nitro-enclaves-vsock-proxy.service
systemctl enable nitro-enclaves-vsock-proxy.service

cd /home/ec2-user
if [[ ! -d ./app/server ]]; then
  mkdir -p ./app/server

  cd ./app/server
  cat <<'EOF' >>build_signing_server_enclave.sh
#!/usr/bin/bash

set -x
set -e

account_id=$( aws sts get-caller-identity | jq -r '.Account' )
region=$( curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r '.region' )
aws ecr get-login-password --region $region | docker login --username AWS --password-stdin $account_id.dkr.ecr.$region.amazonaws.com
docker pull ${__SIGNING_SERVER_IMAGE_URI__}
docker pull ${__SIGNING_ENCLAVE_IMAGE_URI__}

nitro-cli build-enclave --docker-uri ${__SIGNING_ENCLAVE_IMAGE_URI__} --output-file signing_server.eif

EOF

  chmod +x build_signing_server_enclave.sh
  cd ../..
  chown -R ec2-user:ec2-user ./app

  sudo -H -u ec2-user bash -c "cd /home/ec2-user/app/server && ./build_signing_server_enclave.sh"
fi

if [[ ! -f /etc/systemd/system/nitro-signing-server.service ]]; then

  aws s3 cp ${__WATCHDOG_SYSTEMD_S3_URL__} /etc/systemd/system/nitro-signing-server.service
  aws s3 cp ${__WATCHDOG_S3_URL__} /home/ec2-user/app/watchdog.py

  chmod +x /home/ec2-user/app/watchdog.py

fi

# register signing service for autostart
systemctl enable nitro-signing-server.service

# autostart since that key config and key provisioning in Secrets Manager and KMS need to be finished first
init_flag=$(aws --region ${__REGION__} ssm get-parameter --name ${__WEB3SIGNER_INIT_FLAG_PARAM__} | jq -r '.Parameter.Value')

if [[ $init_flag == "true" ]]; then
  systemctl start nitro-signing-server.service
fi

# docker over system process manager
sudo docker run -d --restart unless-stopped --name http_server -p 8443:443 ${__SIGNING_SERVER_IMAGE_URI__}
