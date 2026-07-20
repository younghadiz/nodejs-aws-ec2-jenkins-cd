#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly ENV_FILE="${PROJECT_ROOT}/.env.infrastructure"

readonly APPLICATION_PORT="${APPLICATION_PORT:-3000}"
readonly HTTP_TIMEOUT_SECONDS="${HTTP_TIMEOUT_SECONDS:-10}"
readonly EXPECTED_HTTP_STATUS="${EXPECTED_HTTP_STATUS:-200}"

log() {
  printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

error() {
  printf '\nERROR: %s\n' "$*" >&2
}

cleanup() {
  local exit_code=$?

  if (( exit_code != 0 )); then
    error "Infrastructure verification failed with exit code ${exit_code}."
  fi
}

trap cleanup EXIT

require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    error "Required command is not installed: ${command_name}"
    exit 1
  fi
}

require_variable() {
  local variable_name="$1"

  if [[ -z "${!variable_name:-}" ]]; then
    error "Required variable is missing or empty: ${variable_name}"
    return 1
  fi
}

aws_cli() {
  aws \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    "$@"
}

validate_environment() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    error "Infrastructure environment file does not exist: ${ENV_FILE}"
    exit 1
  fi

  # shellcheck disable=SC1090
  source "${ENV_FILE}"

  local required_variables=(
    AWS_PROFILE
    AWS_REGION
    VPC_ID
    SUBNET_ID
    ROUTE_TABLE_ID
    SECURITY_GROUP_ID
    INSTANCE_ID
  )

  local validation_failed=false

  for variable_name in "${required_variables[@]}"; do
    if ! require_variable "${variable_name}"; then
      validation_failed=true
    fi
  done

  if [[ "${validation_failed}" == "true" ]]; then
    exit 1
  fi
}

verify_aws_identity() {
  log "Verifying AWS identity"

  aws_cli sts get-caller-identity \
    --query '{
      Account:Account,
      Arn:Arn,
      UserId:UserId
    }' \
    --output table
}

verify_vpc() {
  log "Verifying VPC"

  local vpc_state

  vpc_state="$(
    aws_cli ec2 describe-vpcs \
      --vpc-ids "${VPC_ID}" \
      --query 'Vpcs[0].State' \
      --output text
  )"

  if [[ "${vpc_state}" != "available" ]]; then
    error "VPC ${VPC_ID} is not available. Current state: ${vpc_state}"
    exit 1
  fi

  aws_cli ec2 describe-vpcs \
    --vpc-ids "${VPC_ID}" \
    --query 'Vpcs[0].{
      VpcId:VpcId,
      Cidr:CidrBlock,
      State:State,
      Default:IsDefault,
      DhcpOptionsId:DhcpOptionsId
    }' \
    --output table
}

verify_subnet() {
  log "Verifying subnet"

  local subnet_vpc_id
  local subnet_state

  subnet_vpc_id="$(
    aws_cli ec2 describe-subnets \
      --subnet-ids "${SUBNET_ID}" \
      --query 'Subnets[0].VpcId' \
      --output text
  )"

  subnet_state="$(
    aws_cli ec2 describe-subnets \
      --subnet-ids "${SUBNET_ID}" \
      --query 'Subnets[0].State' \
      --output text
  )"

  if [[ "${subnet_vpc_id}" != "${VPC_ID}" ]]; then
    error "Subnet ${SUBNET_ID} does not belong to VPC ${VPC_ID}."
    exit 1
  fi

  if [[ "${subnet_state}" != "available" ]]; then
    error "Subnet ${SUBNET_ID} is not available. Current state: ${subnet_state}"
    exit 1
  fi

  aws_cli ec2 describe-subnets \
    --subnet-ids "${SUBNET_ID}" \
    --query 'Subnets[0].{
      SubnetId:SubnetId,
      VpcId:VpcId,
      Cidr:CidrBlock,
      AvailabilityZone:AvailabilityZone,
      State:State,
      PublicIpOnLaunch:MapPublicIpOnLaunch,
      AvailableAddresses:AvailableIpAddressCount
    }' \
    --output table
}

verify_route_table() {
  log "Verifying route table"

  local route_table_vpc_id
  local internet_gateway_route

  route_table_vpc_id="$(
    aws_cli ec2 describe-route-tables \
      --route-table-ids "${ROUTE_TABLE_ID}" \
      --query 'RouteTables[0].VpcId' \
      --output text
  )"

  if [[ "${route_table_vpc_id}" != "${VPC_ID}" ]]; then
    error "Route table ${ROUTE_TABLE_ID} does not belong to VPC ${VPC_ID}."
    exit 1
  fi

  internet_gateway_route="$(
    aws_cli ec2 describe-route-tables \
      --route-table-ids "${ROUTE_TABLE_ID}" \
      --query \
        'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0` && starts_with(GatewayId, `igw-`)].GatewayId | [0]' \
      --output text
  )"

  if [[ -z "${internet_gateway_route}" || "${internet_gateway_route}" == "None" ]]; then
    error "Route table ${ROUTE_TABLE_ID} has no default route through an Internet Gateway."
    exit 1
  fi

  aws_cli ec2 describe-route-tables \
    --route-table-ids "${ROUTE_TABLE_ID}" \
    --query 'RouteTables[0].{
      RouteTableId:RouteTableId,
      VpcId:VpcId,
      Associations:Associations,
      Routes:Routes
    }' \
    --output json

  printf '\nInternet Gateway route: %s\n' "${internet_gateway_route}"
}

verify_internet_gateway() {
  log "Verifying Internet Gateway"

  local internet_gateway_id

  internet_gateway_id="$(
    aws_cli ec2 describe-route-tables \
      --route-table-ids "${ROUTE_TABLE_ID}" \
      --query \
        'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0` && starts_with(GatewayId, `igw-`)].GatewayId | [0]' \
      --output text
  )"

  aws_cli ec2 describe-internet-gateways \
    --internet-gateway-ids "${internet_gateway_id}" \
    --query 'InternetGateways[0].{
      InternetGatewayId:InternetGatewayId,
      Attachments:Attachments
    }' \
    --output json
}

verify_security_group() {
  log "Verifying security group"

  local security_group_vpc_id
  local application_rule_count
  local ssh_rule_count

  security_group_vpc_id="$(
    aws_cli ec2 describe-security-groups \
      --group-ids "${SECURITY_GROUP_ID}" \
      --query 'SecurityGroups[0].VpcId' \
      --output text
  )"

  if [[ "${security_group_vpc_id}" != "${VPC_ID}" ]]; then
    error "Security group ${SECURITY_GROUP_ID} does not belong to VPC ${VPC_ID}."
    exit 1
  fi

  application_rule_count="$(
    aws_cli ec2 describe-security-groups \
      --group-ids "${SECURITY_GROUP_ID}" \
      --query \
        "length(SecurityGroups[0].IpPermissions[?IpProtocol==\`tcp\` && FromPort==\`${APPLICATION_PORT}\` && ToPort==\`${APPLICATION_PORT}\`])" \
      --output text
  )"

  ssh_rule_count="$(
    aws_cli ec2 describe-security-groups \
      --group-ids "${SECURITY_GROUP_ID}" \
      --query \
        'length(SecurityGroups[0].IpPermissions[?IpProtocol==`tcp` && FromPort==`22` && ToPort==`22`])' \
      --output text
  )"

  if (( application_rule_count == 0 )); then
    error "Security group ${SECURITY_GROUP_ID} does not permit TCP port ${APPLICATION_PORT}."
    exit 1
  fi

  if (( ssh_rule_count == 0 )); then
    error "Security group ${SECURITY_GROUP_ID} does not contain an SSH port 22 rule."
    exit 1
  fi

  aws_cli ec2 describe-security-groups \
    --group-ids "${SECURITY_GROUP_ID}" \
    --query 'SecurityGroups[0].{
      GroupId:GroupId,
      GroupName:GroupName,
      VpcId:VpcId,
      InboundRules:IpPermissions,
      OutboundRules:IpPermissionsEgress
    }' \
    --output json
}

verify_network_acl() {
  log "Displaying subnet Network ACL"

  aws_cli ec2 describe-network-acls \
    --filters "Name=association.subnet-id,Values=${SUBNET_ID}" \
    --query 'NetworkAcls[].{
      NetworkAclId:NetworkAclId,
      Default:IsDefault,
      Entries:Entries
    }' \
    --output json
}

verify_instance() {
  log "Verifying EC2 instance"

  local instance_state
  local instance_vpc_id
  local instance_subnet_id
  local attached_security_groups

  instance_state="$(
    aws_cli ec2 describe-instances \
      --instance-ids "${INSTANCE_ID}" \
      --query 'Reservations[0].Instances[0].State.Name' \
      --output text
  )"

  instance_vpc_id="$(
    aws_cli ec2 describe-instances \
      --instance-ids "${INSTANCE_ID}" \
      --query 'Reservations[0].Instances[0].VpcId' \
      --output text
  )"

  instance_subnet_id="$(
    aws_cli ec2 describe-instances \
      --instance-ids "${INSTANCE_ID}" \
      --query 'Reservations[0].Instances[0].SubnetId' \
      --output text
  )"

  attached_security_groups="$(
    aws_cli ec2 describe-instances \
      --instance-ids "${INSTANCE_ID}" \
      --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' \
      --output text
  )"

  if [[ "${instance_state}" != "running" ]]; then
    error "EC2 instance ${INSTANCE_ID} is not running. Current state: ${instance_state}"
    exit 1
  fi

  if [[ "${instance_vpc_id}" != "${VPC_ID}" ]]; then
    error "EC2 instance ${INSTANCE_ID} is not in VPC ${VPC_ID}."
    exit 1
  fi

  if [[ "${instance_subnet_id}" != "${SUBNET_ID}" ]]; then
    error "EC2 instance ${INSTANCE_ID} is not in subnet ${SUBNET_ID}."
    exit 1
  fi

  if [[ " ${attached_security_groups} " != *" ${SECURITY_GROUP_ID} "* ]]; then
    error "Security group ${SECURITY_GROUP_ID} is not attached to EC2 instance ${INSTANCE_ID}."
    exit 1
  fi

  INSTANCE_PUBLIC_IP="$(
    aws_cli ec2 describe-instances \
      --instance-ids "${INSTANCE_ID}" \
      --query 'Reservations[0].Instances[0].PublicIpAddress' \
      --output text
  )"

  if [[ -z "${INSTANCE_PUBLIC_IP}" || "${INSTANCE_PUBLIC_IP}" == "None" ]]; then
    error "EC2 instance ${INSTANCE_ID} does not have a public IPv4 address."
    exit 1
  fi

  export INSTANCE_PUBLIC_IP

  aws_cli ec2 describe-instances \
    --instance-ids "${INSTANCE_ID}" \
    --query 'Reservations[0].Instances[0].{
      InstanceId:InstanceId,
      State:State.Name,
      PublicIp:PublicIpAddress,
      PrivateIp:PrivateIpAddress,
      InstanceType:InstanceType,
      AMI:ImageId,
      VpcId:VpcId,
      SubnetId:SubnetId,
      SecurityGroups:SecurityGroups,
      AvailabilityZone:Placement.AvailabilityZone,
      LaunchTime:LaunchTime
    }' \
    --output table
}

verify_instance_status_checks() {
  log "Verifying EC2 system and instance status checks"

  aws_cli ec2 wait instance-status-ok \
    --instance-ids "${INSTANCE_ID}"

  aws_cli ec2 describe-instance-status \
    --instance-ids "${INSTANCE_ID}" \
    --include-all-instances \
    --query 'InstanceStatuses[0].{
      InstanceState:InstanceState.Name,
      SystemStatus:SystemStatus.Status,
      InstanceStatus:InstanceStatus.Status
    }' \
    --output table
}

verify_application() {
  log "Verifying application HTTP response"

  local application_url
  local response_code

  application_url="http://${INSTANCE_PUBLIC_IP}:${APPLICATION_PORT}"

  response_code="$(
    curl \
      --silent \
      --show-error \
      --location \
      --output /dev/null \
      --write-out '%{http_code}' \
      --connect-timeout "${HTTP_TIMEOUT_SECONDS}" \
      --max-time "${HTTP_TIMEOUT_SECONDS}" \
      --retry 3 \
      --retry-delay 2 \
      --retry-connrefused \
      "${application_url}"
  )"

  printf 'Application URL: %s\n' "${application_url}"
  printf 'HTTP status:     %s\n' "${response_code}"

  if [[ "${response_code}" != "${EXPECTED_HTTP_STATUS}" ]]; then
    error \
      "Application returned HTTP ${response_code}; expected ${EXPECTED_HTTP_STATUS}."
    exit 1
  fi

  printf 'Application verification completed successfully.\n'
}

main() {
  require_command aws
  require_command curl

  validate_environment
  verify_aws_identity
  verify_vpc
  verify_subnet
  verify_route_table
  verify_internet_gateway
  verify_security_group
  verify_network_acl
  verify_instance
  verify_instance_status_checks
  verify_application

  log "Infrastructure verification completed successfully"
}

main "$@" 