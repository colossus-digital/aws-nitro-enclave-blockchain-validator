#!/usr/bin/env bash
#  Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
#  SPDX-License-Identifier: MIT-0
set -e
set +x

output=${1}
instance_to_restart=${2}

# instance id
stack_name=$(jq -r '. |= keys | .[0]' output.json)
asg_name=$(jq -r '."'${stack_name}'".ASGGroupName' "${output}")
web3signer_init_flag_param_name=$(jq -r '."'${stack_name}'"."Web3SignerInitFlagParamName"' "${output}")

instance_ids=$(./scripts/get_asg_instances.sh ${asg_name} | tr "\n" " ")
read -r instance_1 instance_2 <<< "$instance_ids"
echo "Instances: $instance_1,$instance_2"

if [[ -z "$instance_to_restart" || "$instance_to_restart" == "1" ]]; then
  echo "Restart nitro-signing-server.service on instance: $instance_1"
  restart_instance_1=$(aws ssm send-command --document-name "AWS-RunShellScript" --instance-ids ${instance_1} --parameters 'commands=["sudo systemctl restart nitro-signing-server.service"]' | jq -r '.Command.CommandId')
fi

if [[ -z "$instance_to_restart" || "$instance_to_restart" == "2" ]]; then
  echo "Restart nitro-signing-server.service on instance: $instance_2"
  restart_instance_2=$(aws ssm send-command --document-name "AWS-RunShellScript" --instance-ids ${instance_2} --parameters 'commands=["sudo systemctl restart nitro-signing-server.service"]' | jq -r '.Command.CommandId')
fi

echo "Done."
