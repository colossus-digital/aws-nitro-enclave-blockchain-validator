#!/usr/bin/env bash
#  Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
#  SPDX-License-Identifier: MIT-0
set -e
set +x

output=${1}
my_command=${2}

if [ -z $my_command ]; then
  echo "No command supplied. Usage: ./execute_command.sh output.json \"command(s) to execute\""
  exit 1
fi

# instance id
stack_name=$(jq -r '. |= keys | .[0]' output.json)
asg_name=$(jq -r '."'${stack_name}'".ASGGroupName' "${output}")
web3signer_init_flag_param_name=$(jq -r '."'${stack_name}'"."Web3SignerInitFlagParamName"' "${output}")

instance_ids=$(./scripts/get_asg_instances.sh ${asg_name} | tr "\n" " ")

command_id=$(aws ssm send-command --document-name "AWS-RunShellScript" --instance-ids ${instance_ids} --parameters 'commands=['"$my_command"']' | jq -r '.Command.CommandId')

instance_ids_nl=$(echo ${instance_ids} | tr "\n " " ")
for instance_id in ${instance_ids_nl}; do
  status=$(aws ssm list-command-invocations --instance-id ${instance_id} --command-id ${command_id} --details | jq -r '.CommandInvocations[0].CommandPlugins[0].Output')
  echo "${instance_id}:"
  echo ${status}
done
