#!/usr/bin/env bash

set -Eeuo pipefail

AWS_CLI_BIN="${AWS_CLI_BIN:-/usr/local/bin/aws}"
AWS_PROFILE="${AWS_PROFILE:-gafari-devops}"
AWS_REGION="${AWS_REGION:-ca-central-1}"
PROJECT_NAME="${PROJECT_NAME:-nodejs-aws-jenkins}"

EXECUTE=false

if [[ "${1:-}" == "--execute" ]]; then
  EXECUTE=true
elif [[ -n "${1:-}" ]]; then
  echo "Usage:"
  echo "  $0             # discovery only"
  echo "  $0 --execute   # delete discovered resources"
  exit 1
fi

if [[ ! -x "${AWS_CLI_BIN}" ]]; then
  echo "ERROR: AWS CLI was not found at ${AWS_CLI_BIN}."
  exit 1
fi

aws_cli() {
  "${AWS_CLI_BIN}" \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    "$@"
}

run_delete() {
  if [[ "${EXECUTE}" == "true" ]]; then
    "$@"
  else
    printf '[DRY RUN] '
    printf '%q ' "$@"
    printf '\n'
  fi
}

echo "===================================================="
echo "AWS project resource cleanup"
echo "===================================================="
echo "Profile: ${AWS_PROFILE}"
echo "Region:  ${AWS_REGION}"
echo "Project: ${PROJECT_NAME}"
echo "Execute: ${EXECUTE}"
echo

echo "Validating AWS identity..."
aws_cli sts get-caller-identity

echo
echo "Discovering VPCs tagged Project=${PROJECT_NAME}..."

mapfile -t VPC_IDS < <(
  aws_cli ec2 describe-vpcs \
    --filters \
      "Name=tag:Project,Values=${PROJECT_NAME}" \
    --query 'Vpcs[?IsDefault==`false`].VpcId' \
    --output text |
  tr '\t' '\n' |
  sed '/^$/d'
)

if [[ "${#VPC_IDS[@]}" -eq 0 ]]; then
  echo "No non-default VPCs were found with the project tag."
else
  printf 'Found VPC: %s\n' "${VPC_IDS[@]}"
fi

echo
echo "Discovering project EC2 instances..."

mapfile -t INSTANCE_IDS < <(
  aws_cli ec2 describe-instances \
    --filters \
      "Name=tag:Project,Values=${PROJECT_NAME}" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text |
  tr '\t' '\n' |
  sed '/^$/d'
)

if [[ "${#INSTANCE_IDS[@]}" -gt 0 ]]; then
  printf 'Found instance: %s\n' "${INSTANCE_IDS[@]}"
else
  echo "No active project instances found."
fi

echo
echo "Discovering matching EC2 key pairs..."

mapfile -t KEY_NAMES < <(
  aws_cli ec2 describe-key-pairs \
    --filters \
      "Name=key-name,Values=${PROJECT_NAME}-key,${PROJECT_NAME}-key-*" \
    --query 'KeyPairs[].KeyName' \
    --output text |
  tr '\t' '\n' |
  sed '/^$/d'
)

if [[ "${#KEY_NAMES[@]}" -gt 0 ]]; then
  printf 'Found key pair: %s\n' "${KEY_NAMES[@]}"
else
  echo "No matching EC2 key pairs found."
fi

if [[ "${EXECUTE}" != "true" ]]; then
  echo
  echo "===================================================="
  echo "DRY RUN ONLY"
  echo "===================================================="
  echo "No AWS resources were deleted."
  echo
  echo "Review the discovered resource IDs carefully."
  echo "To perform deletion, run:"
  echo
  echo "  $0 --execute"
  echo
  exit 0
fi

echo
echo "===================================================="
echo "DESTRUCTIVE MODE"
echo "===================================================="
echo
echo "The script will delete resources tagged:"
echo
echo "  Project=${PROJECT_NAME}"
echo
echo "from:"
echo
echo "  Account profile: ${AWS_PROFILE}"
echo "  Region:          ${AWS_REGION}"
echo
read -r -p "Type DELETE ${PROJECT_NAME} to continue: " confirmation

if [[ "${confirmation}" != "DELETE ${PROJECT_NAME}" ]]; then
  echo "Cleanup cancelled."
  exit 0
fi

# --------------------------------------------------
# 1. Terminate EC2 instances first
# --------------------------------------------------

if [[ "${#INSTANCE_IDS[@]}" -gt 0 ]]; then
  echo
  echo "Terminating project EC2 instances..."

  aws_cli ec2 terminate-instances \
    --instance-ids "${INSTANCE_IDS[@]}"

  echo "Waiting for instances to terminate..."

  aws_cli ec2 wait instance-terminated \
    --instance-ids "${INSTANCE_IDS[@]}"

  echo "Instances terminated."
fi

# --------------------------------------------------
# 2. Remove resources inside each project VPC
# --------------------------------------------------

for VPC_ID in "${VPC_IDS[@]}"; do
  echo
  echo "----------------------------------------------------"
  echo "Cleaning VPC: ${VPC_ID}"
  echo "----------------------------------------------------"

  IS_DEFAULT="$(
    aws_cli ec2 describe-vpcs \
      --vpc-ids "${VPC_ID}" \
      --query 'Vpcs[0].IsDefault' \
      --output text
  )"

  if [[ "${IS_DEFAULT}" == "True" || "${IS_DEFAULT}" == "true" ]]; then
    echo "ERROR: Refusing to delete default VPC ${VPC_ID}."
    continue
  fi

  # -----------------------------------------------
  # Delete available NAT gateways, if any
  # -----------------------------------------------

  mapfile -t NAT_GATEWAY_IDS < <(
    aws_cli ec2 describe-nat-gateways \
      --filter \
        "Name=vpc-id,Values=${VPC_ID}" \
        "Name=state,Values=pending,available,failed" \
      --query 'NatGateways[].NatGatewayId' \
      --output text |
    tr '\t' '\n' |
    sed '/^$/d'
  )

  for NAT_GATEWAY_ID in "${NAT_GATEWAY_IDS[@]}"; do
    echo "Deleting NAT gateway: ${NAT_GATEWAY_ID}"

    aws_cli ec2 delete-nat-gateway \
      --nat-gateway-id "${NAT_GATEWAY_ID}"
  done

  if [[ "${#NAT_GATEWAY_IDS[@]}" -gt 0 ]]; then
    echo "Waiting for NAT gateways to be deleted..."

    for NAT_GATEWAY_ID in "${NAT_GATEWAY_IDS[@]}"; do
      aws_cli ec2 wait nat-gateway-deleted \
        --nat-gateway-ids "${NAT_GATEWAY_ID}" || true
    done
  fi

  # -----------------------------------------------
  # Delete VPC endpoints, if any
  # -----------------------------------------------

  mapfile -t VPC_ENDPOINT_IDS < <(
    aws_cli ec2 describe-vpc-endpoints \
      --filters \
        "Name=vpc-id,Values=${VPC_ID}" \
      --query 'VpcEndpoints[].VpcEndpointId' \
      --output text |
    tr '\t' '\n' |
    sed '/^$/d'
  )

  if [[ "${#VPC_ENDPOINT_IDS[@]}" -gt 0 ]]; then
    echo "Deleting VPC endpoints:"
    printf '  %s\n' "${VPC_ENDPOINT_IDS[@]}"

    aws_cli ec2 delete-vpc-endpoints \
      --vpc-endpoint-ids "${VPC_ENDPOINT_IDS[@]}"
  fi

  # -----------------------------------------------
  # Delete custom network interfaces, if any
  # -----------------------------------------------

  mapfile -t NETWORK_INTERFACE_IDS < <(
    aws_cli ec2 describe-network-interfaces \
      --filters \
        "Name=vpc-id,Values=${VPC_ID}" \
        "Name=status,Values=available" \
      --query 'NetworkInterfaces[].NetworkInterfaceId' \
      --output text |
    tr '\t' '\n' |
    sed '/^$/d'
  )

  for NETWORK_INTERFACE_ID in "${NETWORK_INTERFACE_IDS[@]}"; do
    echo "Deleting available network interface: ${NETWORK_INTERFACE_ID}"

    aws_cli ec2 delete-network-interface \
      --network-interface-id "${NETWORK_INTERFACE_ID}" || true
  done

  # -----------------------------------------------
  # Disassociate and delete non-main route tables
  # -----------------------------------------------

  mapfile -t ROUTE_TABLE_IDS < <(
    aws_cli ec2 describe-route-tables \
      --filters \
        "Name=vpc-id,Values=${VPC_ID}" \
      --query \
        'RouteTables[?Associations[?Main==`true`]|length(@)==`0`].RouteTableId' \
      --output text |
    tr '\t' '\n' |
    sed '/^$/d'
  )

  for ROUTE_TABLE_ID in "${ROUTE_TABLE_IDS[@]}"; do
    echo "Processing route table: ${ROUTE_TABLE_ID}"

    mapfile -t ASSOCIATION_IDS < <(
      aws_cli ec2 describe-route-tables \
        --route-table-ids "${ROUTE_TABLE_ID}" \
        --query \
          'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' \
        --output text |
      tr '\t' '\n' |
      sed '/^$/d'
    )

    for ASSOCIATION_ID in "${ASSOCIATION_IDS[@]}"; do
      echo "Disassociating route table association: ${ASSOCIATION_ID}"

      aws_cli ec2 disassociate-route-table \
        --association-id "${ASSOCIATION_ID}" || true
    done

    echo "Deleting route table: ${ROUTE_TABLE_ID}"

    aws_cli ec2 delete-route-table \
      --route-table-id "${ROUTE_TABLE_ID}" || true
  done

  # -----------------------------------------------
  # Detach and delete internet gateways
  # -----------------------------------------------

  mapfile -t INTERNET_GATEWAY_IDS < <(
    aws_cli ec2 describe-internet-gateways \
      --filters \
        "Name=attachment.vpc-id,Values=${VPC_ID}" \
      --query 'InternetGateways[].InternetGatewayId' \
      --output text |
    tr '\t' '\n' |
    sed '/^$/d'
  )

  for INTERNET_GATEWAY_ID in "${INTERNET_GATEWAY_IDS[@]}"; do
    echo "Detaching internet gateway: ${INTERNET_GATEWAY_ID}"

    aws_cli ec2 detach-internet-gateway \
      --internet-gateway-id "${INTERNET_GATEWAY_ID}" \
      --vpc-id "${VPC_ID}" || true

    echo "Deleting internet gateway: ${INTERNET_GATEWAY_ID}"

    aws_cli ec2 delete-internet-gateway \
      --internet-gateway-id "${INTERNET_GATEWAY_ID}" || true
  done

  # -----------------------------------------------
  # Delete subnets
  # -----------------------------------------------

  mapfile -t SUBNET_IDS < <(
    aws_cli ec2 describe-subnets \
      --filters \
        "Name=vpc-id,Values=${VPC_ID}" \
      --query 'Subnets[].SubnetId' \
      --output text |
    tr '\t' '\n' |
    sed '/^$/d'
  )

  for SUBNET_ID in "${SUBNET_IDS[@]}"; do
    echo "Deleting subnet: ${SUBNET_ID}"

    aws_cli ec2 delete-subnet \
      --subnet-id "${SUBNET_ID}" || true
  done

  # -----------------------------------------------
  # Delete non-default security groups
  # -----------------------------------------------

  mapfile -t SECURITY_GROUP_IDS < <(
    aws_cli ec2 describe-security-groups \
      --filters \
        "Name=vpc-id,Values=${VPC_ID}" \
      --query \
        'SecurityGroups[?GroupName!=`default`].GroupId' \
      --output text |
    tr '\t' '\n' |
    sed '/^$/d'
  )

  for SECURITY_GROUP_ID in "${SECURITY_GROUP_IDS[@]}"; do
    echo "Deleting security group: ${SECURITY_GROUP_ID}"

    aws_cli ec2 delete-security-group \
      --group-id "${SECURITY_GROUP_ID}" || true
  done

  # -----------------------------------------------
  # Delete non-default network ACLs
  # -----------------------------------------------

  mapfile -t NETWORK_ACL_IDS < <(
    aws_cli ec2 describe-network-acls \
      --filters \
        "Name=vpc-id,Values=${VPC_ID}" \
      --query \
        'NetworkAcls[?IsDefault==`false`].NetworkAclId' \
      --output text |
    tr '\t' '\n' |
    sed '/^$/d'
  )

  for NETWORK_ACL_ID in "${NETWORK_ACL_IDS[@]}"; do
    echo "Deleting custom network ACL: ${NETWORK_ACL_ID}"

    aws_cli ec2 delete-network-acl \
      --network-acl-id "${NETWORK_ACL_ID}" || true
  done

  # -----------------------------------------------
  # Delete the VPC
  # -----------------------------------------------

  echo "Deleting VPC: ${VPC_ID}"

  if aws_cli ec2 delete-vpc \
    --vpc-id "${VPC_ID}"; then
    echo "Deleted VPC: ${VPC_ID}"
  else
    echo
    echo "WARNING: VPC ${VPC_ID} still has a dependency."
    echo "Run the dependency inspection commands from the troubleshooting section."
  fi
done

# --------------------------------------------------
# 3. Delete matching AWS key pairs
# --------------------------------------------------

for KEY_NAME in "${KEY_NAMES[@]}"; do
  echo "Deleting AWS EC2 key pair: ${KEY_NAME}"

  aws_cli ec2 delete-key-pair \
    --key-name "${KEY_NAME}" || true
done

echo
echo "===================================================="
echo "Cleanup attempt completed"
echo "===================================================="
echo
echo "Run the script again without --execute to verify:"
echo
echo "  $0"
echo
echo "Local PEM files were not deleted."