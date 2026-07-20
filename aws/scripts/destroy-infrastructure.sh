#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly ENV_FILE="${PROJECT_ROOT}/.env.infrastructure"

declare -a SUCCEEDED_RESOURCES=()
declare -a SKIPPED_RESOURCES=()
declare -a FAILED_RESOURCES=()

log() {
  printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

info() {
  printf '%s\n' "$*"
}

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

error() {
  printf 'ERROR: %s\n' "$*" >&2
}

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

resource_exists() {
  local resource_type="$1"
  local resource_id="$2"

  case "${resource_type}" in
    instance)
      aws_cli ec2 describe-instances \
        --instance-ids "${resource_id}" \
        --query 'Reservations[0].Instances[0].InstanceId' \
        --output text \
        >/dev/null 2>&1
      ;;

    security-group)
      aws_cli ec2 describe-security-groups \
        --group-ids "${resource_id}" \
        --query 'SecurityGroups[0].GroupId' \
        --output text \
        >/dev/null 2>&1
      ;;

    route-table)
      aws_cli ec2 describe-route-tables \
        --route-table-ids "${resource_id}" \
        --query 'RouteTables[0].RouteTableId' \
        --output text \
        >/dev/null 2>&1
      ;;

    internet-gateway)
      aws_cli ec2 describe-internet-gateways \
        --internet-gateway-ids "${resource_id}" \
        --query 'InternetGateways[0].InternetGatewayId' \
        --output text \
        >/dev/null 2>&1
      ;;

    subnet)
      aws_cli ec2 describe-subnets \
        --subnet-ids "${resource_id}" \
        --query 'Subnets[0].SubnetId' \
        --output text \
        >/dev/null 2>&1
      ;;

    vpc)
      aws_cli ec2 describe-vpcs \
        --vpc-ids "${resource_id}" \
        --query 'Vpcs[0].VpcId' \
        --output text \
        >/dev/null 2>&1
      ;;

    key-pair)
      aws_cli ec2 describe-key-pairs \
        --key-names "${resource_id}" \
        --query 'KeyPairs[0].KeyName' \
        --output text \
        >/dev/null 2>&1
      ;;

    *)
      error "Unsupported resource type: ${resource_type}"
      return 1
      ;;
  esac
}

record_success() {
  SUCCEEDED_RESOURCES+=("$1")
}

record_skip() {
  SKIPPED_RESOURCES+=("$1")
}

record_failure() {
  FAILED_RESOURCES+=("$1")
}

validate_environment() {
  require_command aws

  if [[ ! -f "${ENV_FILE}" ]]; then
    error "Infrastructure environment file does not exist:"
    error "${ENV_FILE}"
    exit 1
  fi

  # shellcheck disable=SC1090
  source "${ENV_FILE}"

  local required_variables=(
    AWS_PROFILE
    AWS_REGION
    PROJECT_NAME
    VPC_ID
  )

  local validation_failed=false
  local variable_name

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

  local account_id
  local caller_arn

  account_id="$(
    aws_cli sts get-caller-identity \
      --query 'Account' \
      --output text
  )"

  caller_arn="$(
    aws_cli sts get-caller-identity \
      --query 'Arn' \
      --output text
  )"

  info "AWS profile: ${AWS_PROFILE}"
  info "AWS region:  ${AWS_REGION}"
  info "AWS account: ${account_id}"
  info "Caller ARN:  ${caller_arn}"

  if [[ -n "${AWS_ACCOUNT_ID:-}" && "${account_id}" != "${AWS_ACCOUNT_ID}" ]]; then
    error "AWS account mismatch."
    error "Expected: ${AWS_ACCOUNT_ID}"
    error "Actual:   ${account_id}"
    exit 1
  fi
}

verify_vpc_ownership() {
  log "Verifying target VPC"

  if ! resource_exists vpc "${VPC_ID}"; then
    warn "VPC ${VPC_ID} no longer exists."
    return
  fi

  local vpc_name

  vpc_name="$(
    aws_cli ec2 describe-vpcs \
      --vpc-ids "${VPC_ID}" \
      --query \
        'Vpcs[0].Tags[?Key==`Name`].Value | [0]' \
      --output text
  )"

  info "VPC ID:   ${VPC_ID}"
  info "VPC name: ${vpc_name}"

  if [[ -n "${vpc_name}" &&
        "${vpc_name}" != "None" &&
        "${vpc_name}" != *"${PROJECT_NAME}"* ]]; then
    error "The VPC Name tag does not appear to match the project."
    error "Project:  ${PROJECT_NAME}"
    error "VPC name: ${vpc_name}"
    exit 1
  fi
}

display_destruction_plan() {
  log "Destruction plan"

  cat <<EOF
Project:                    ${PROJECT_NAME}
AWS profile:                ${AWS_PROFILE}
AWS region:                 ${AWS_REGION}
EC2 instance:               ${INSTANCE_ID:-not recorded}
AWS key pair:               ${KEY_NAME:-not recorded}
Security group:             ${SECURITY_GROUP_ID:-not recorded}
Route table association:    ${ROUTE_TABLE_ASSOCIATION_ID:-not recorded}
Route table:                ${ROUTE_TABLE_ID:-not recorded}
Internet Gateway:           ${INTERNET_GATEWAY_ID:-not recorded}
Subnet:                     ${SUBNET_ID:-not recorded}
VPC:                        ${VPC_ID}
EOF
}

request_confirmation() {
  echo
  warn "This operation permanently deletes the listed AWS resources."
  warn "The EC2 instance and all data stored on its root volume may be lost."
  echo

  local expected_confirmation
  local confirmation

  expected_confirmation="DELETE ${PROJECT_NAME}"

  read -r -p "Type '${expected_confirmation}' to continue: " confirmation

  if [[ "${confirmation}" != "${expected_confirmation}" ]]; then
    info "Infrastructure cleanup cancelled."
    exit 0
  fi
}

terminate_instance() {
  if [[ -z "${INSTANCE_ID:-}" ]]; then
    record_skip "EC2 instance: no instance ID recorded"
    return
  fi

  log "Terminating EC2 instance ${INSTANCE_ID}"

  if ! resource_exists instance "${INSTANCE_ID}"; then
    warn "EC2 instance ${INSTANCE_ID} does not exist or is already terminated."
    record_skip "EC2 instance ${INSTANCE_ID}"
    return
  fi

  local instance_state

  instance_state="$(
    aws_cli ec2 describe-instances \
      --instance-ids "${INSTANCE_ID}" \
      --query 'Reservations[0].Instances[0].State.Name' \
      --output text
  )"

  if [[ "${instance_state}" == "terminated" ]]; then
    record_skip "EC2 instance ${INSTANCE_ID}: already terminated"
    return
  fi

  if ! aws_cli ec2 terminate-instances \
    --instance-ids "${INSTANCE_ID}" \
    >/dev/null; then
    error "Failed to request termination for ${INSTANCE_ID}."
    record_failure "EC2 instance ${INSTANCE_ID}"
    return 1
  fi

  info "Waiting for EC2 instance termination..."

  if ! aws_cli ec2 wait instance-terminated \
    --instance-ids "${INSTANCE_ID}"; then
    error "EC2 instance did not reach the terminated state."
    record_failure "EC2 instance ${INSTANCE_ID}"
    return 1
  fi

  record_success "EC2 instance ${INSTANCE_ID}"
}

wait_for_network_interfaces() {
  if [[ -z "${VPC_ID:-}" ]]; then
    return
  fi

  log "Waiting for EC2-managed network interfaces to be released"

  local attempt
  local interface_count

  for attempt in {1..30}; do
    interface_count="$(
      aws_cli ec2 describe-network-interfaces \
        --filters \
          "Name=vpc-id,Values=${VPC_ID}" \
          "Name=status,Values=in-use" \
        --query 'length(NetworkInterfaces)' \
        --output text
    )"

    if [[ "${interface_count}" == "0" ]]; then
      info "No in-use network interfaces remain."
      return
    fi

    info "Attempt ${attempt}/30: ${interface_count} interface(s) still in use."
    sleep 5
  done

  warn "Some network interfaces are still in use."
  warn "Later deletion steps may fail until AWS releases them."
}

delete_key_pair() {
  if [[ -z "${KEY_NAME:-}" ]]; then
    record_skip "AWS key pair: no key name recorded"
    return
  fi

  log "Deleting AWS key pair ${KEY_NAME}"

  if ! resource_exists key-pair "${KEY_NAME}"; then
    record_skip "AWS key pair ${KEY_NAME}: already absent"
    return
  fi

  if aws_cli ec2 delete-key-pair \
    --key-name "${KEY_NAME}"; then
    record_success "AWS key pair ${KEY_NAME}"
  else
    error "Failed to delete AWS key pair ${KEY_NAME}."
    record_failure "AWS key pair ${KEY_NAME}"
  fi
}

delete_security_group() {
  if [[ -z "${SECURITY_GROUP_ID:-}" ]]; then
    record_skip "Security group: no ID recorded"
    return
  fi

  log "Deleting security group ${SECURITY_GROUP_ID}"

  if ! resource_exists security-group "${SECURITY_GROUP_ID}"; then
    record_skip "Security group ${SECURITY_GROUP_ID}: already absent"
    return
  fi

  if aws_cli ec2 delete-security-group \
    --group-id "${SECURITY_GROUP_ID}"; then
    record_success "Security group ${SECURITY_GROUP_ID}"
  else
    error "Failed to delete security group ${SECURITY_GROUP_ID}."
    record_failure "Security group ${SECURITY_GROUP_ID}"
  fi
}

disassociate_route_table() {
  if [[ -z "${ROUTE_TABLE_ASSOCIATION_ID:-}" ]]; then
    record_skip "Route table association: no ID recorded"
    return
  fi

  log "Disassociating route table association ${ROUTE_TABLE_ASSOCIATION_ID}"

  if aws_cli ec2 disassociate-route-table \
    --association-id "${ROUTE_TABLE_ASSOCIATION_ID}" \
    >/dev/null 2>&1; then
    record_success "Route table association ${ROUTE_TABLE_ASSOCIATION_ID}"
  else
    warn "Route table association may already be absent."
    record_skip "Route table association ${ROUTE_TABLE_ASSOCIATION_ID}"
  fi
}

delete_route_table() {
  if [[ -z "${ROUTE_TABLE_ID:-}" ]]; then
    record_skip "Route table: no ID recorded"
    return
  fi

  log "Deleting route table ${ROUTE_TABLE_ID}"

  if ! resource_exists route-table "${ROUTE_TABLE_ID}"; then
    record_skip "Route table ${ROUTE_TABLE_ID}: already absent"
    return
  fi

  local is_main_route_table

  is_main_route_table="$(
    aws_cli ec2 describe-route-tables \
      --route-table-ids "${ROUTE_TABLE_ID}" \
      --query \
        'length(RouteTables[0].Associations[?Main==`true`])' \
      --output text
  )"

  if [[ "${is_main_route_table}" != "0" ]]; then
    warn "Route table ${ROUTE_TABLE_ID} is the VPC main route table."
    warn "AWS deletes the main route table automatically with the VPC."
    record_skip "Route table ${ROUTE_TABLE_ID}: main route table"
    return
  fi

  aws_cli ec2 delete-route \
    --route-table-id "${ROUTE_TABLE_ID}" \
    --destination-cidr-block "0.0.0.0/0" \
    >/dev/null 2>&1 || true

  if aws_cli ec2 delete-route-table \
    --route-table-id "${ROUTE_TABLE_ID}"; then
    record_success "Route table ${ROUTE_TABLE_ID}"
  else
    error "Failed to delete route table ${ROUTE_TABLE_ID}."
    record_failure "Route table ${ROUTE_TABLE_ID}"
  fi
}

delete_internet_gateway() {
  if [[ -z "${INTERNET_GATEWAY_ID:-}" ]]; then
    record_skip "Internet Gateway: no ID recorded"
    return
  fi

  log "Deleting Internet Gateway ${INTERNET_GATEWAY_ID}"

  if ! resource_exists internet-gateway "${INTERNET_GATEWAY_ID}"; then
    record_skip "Internet Gateway ${INTERNET_GATEWAY_ID}: already absent"
    return
  fi

  local attached_vpc

  attached_vpc="$(
    aws_cli ec2 describe-internet-gateways \
      --internet-gateway-ids "${INTERNET_GATEWAY_ID}" \
      --query 'InternetGateways[0].Attachments[0].VpcId' \
      --output text
  )"

  if [[ -n "${attached_vpc}" && "${attached_vpc}" != "None" ]]; then
    info "Detaching Internet Gateway from VPC ${attached_vpc}..."

    if ! aws_cli ec2 detach-internet-gateway \
      --internet-gateway-id "${INTERNET_GATEWAY_ID}" \
      --vpc-id "${attached_vpc}"; then
      error "Failed to detach Internet Gateway ${INTERNET_GATEWAY_ID}."
      record_failure "Internet Gateway ${INTERNET_GATEWAY_ID}"
      return
    fi
  fi

  if aws_cli ec2 delete-internet-gateway \
    --internet-gateway-id "${INTERNET_GATEWAY_ID}"; then
    record_success "Internet Gateway ${INTERNET_GATEWAY_ID}"
  else
    error "Failed to delete Internet Gateway ${INTERNET_GATEWAY_ID}."
    record_failure "Internet Gateway ${INTERNET_GATEWAY_ID}"
  fi
}

delete_subnet() {
  if [[ -z "${SUBNET_ID:-}" ]]; then
    record_skip "Subnet: no ID recorded"
    return
  fi

  log "Deleting subnet ${SUBNET_ID}"

  if ! resource_exists subnet "${SUBNET_ID}"; then
    record_skip "Subnet ${SUBNET_ID}: already absent"
    return
  fi

  if aws_cli ec2 delete-subnet \
    --subnet-id "${SUBNET_ID}"; then
    record_success "Subnet ${SUBNET_ID}"
  else
    error "Failed to delete subnet ${SUBNET_ID}."
    record_failure "Subnet ${SUBNET_ID}"
  fi
}

delete_vpc() {
  if [[ -z "${VPC_ID:-}" ]]; then
    record_skip "VPC: no ID recorded"
    return
  fi

  log "Deleting VPC ${VPC_ID}"

  if ! resource_exists vpc "${VPC_ID}"; then
    record_skip "VPC ${VPC_ID}: already absent"
    return
  fi

  if aws_cli ec2 delete-vpc \
    --vpc-id "${VPC_ID}"; then
    record_success "VPC ${VPC_ID}"
  else
    error "Failed to delete VPC ${VPC_ID}."
    error "Check for remaining ENIs, subnets, security groups, endpoints, or gateways."
    record_failure "VPC ${VPC_ID}"
  fi
}

print_results() {
  log "Infrastructure cleanup summary"

  if (( ${#SUCCEEDED_RESOURCES[@]} > 0 )); then
    echo
    echo "Deleted successfully:"

    local resource

    for resource in "${SUCCEEDED_RESOURCES[@]}"; do
      printf '  - %s\n' "${resource}"
    done
  fi

  if (( ${#SKIPPED_RESOURCES[@]} > 0 )); then
    echo
    echo "Skipped or already absent:"

    local resource

    for resource in "${SKIPPED_RESOURCES[@]}"; do
      printf '  - %s\n' "${resource}"
    done
  fi

  if (( ${#FAILED_RESOURCES[@]} > 0 )); then
    echo
    echo "Failed to delete:"

    local resource

    for resource in "${FAILED_RESOURCES[@]}"; do
      printf '  - %s\n' "${resource}"
    done
  fi
}

handle_local_files() {
  if [[ -n "${KEY_FILE:-}" && -f "${KEY_FILE}" ]]; then
    echo
    echo "The local private key was not deleted:"
    echo "${KEY_FILE}"
    echo
    echo "Delete it manually only after confirming it is no longer needed:"
    printf "rm -f '%s'\n" "${KEY_FILE}"
  fi

  if (( ${#FAILED_RESOURCES[@]} == 0 )); then
    echo
    echo "AWS cleanup completed without recorded deletion failures."
    echo
    echo "The infrastructure environment file remains available at:"
    echo "${ENV_FILE}"
    echo
    echo "Remove it after confirming the AWS resources are gone:"
    printf "rm -f '%s'\n" "${ENV_FILE}"
  else
    warn "Do not delete ${ENV_FILE} yet."
    warn "It contains resource IDs needed to troubleshoot remaining resources."
  fi
}

main() {
  validate_environment
  verify_aws_identity
  verify_vpc_ownership
  display_destruction_plan
  request_confirmation

  terminate_instance
  wait_for_network_interfaces
  delete_key_pair
  delete_security_group
  disassociate_route_table
  delete_route_table
  delete_internet_gateway
  delete_subnet
  delete_vpc

  print_results
  handle_local_files

  if (( ${#FAILED_RESOURCES[@]} > 0 )); then
    error "Infrastructure cleanup completed with one or more failures."
    exit 1
  fi

  log "Infrastructure cleanup completed successfully"
}

main "$@"