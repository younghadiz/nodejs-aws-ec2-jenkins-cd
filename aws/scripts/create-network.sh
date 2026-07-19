#!/usr/bin/env bash

set -Eeuo pipefail

AWS_CLI_BIN="${AWS_CLI_BIN:-/usr/local/bin/aws}"

if [[ ! -x "${AWS_CLI_BIN}" ]]; then
  echo "ERROR: AWS CLI was not found at ${AWS_CLI_BIN}."
  echo "Install AWS CLI v2 or set AWS_CLI_BIN to the correct executable."
  exit 1
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env.infrastructure"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} does not exist."
  echo "Create it from .env.infrastructure.example."
  exit 1
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

required_variables=(
  AWS_PROFILE
  AWS_REGION
  PROJECT_NAME
  VPC_CIDR
  SUBNET_CIDR
  AVAILABILITY_ZONE
  SSH_CIDR
  APP_PORT
)

for variable in "${required_variables[@]}"; do
  if [[ -z "${!variable:-}" ]]; then
    echo "ERROR: ${variable} is not set."
    exit 1
  fi
done

aws_cli() {
  "${AWS_CLI_BIN}" \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    "$@"
}

save_variable() {
  local key="$1"
  local value="$2"

  if grep -q "^${key}=" "${ENV_FILE}"; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "${ENV_FILE}"
    rm -f "${ENV_FILE}.bak"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${ENV_FILE}"
  fi
}

echo "Validating AWS identity..."
aws_cli sts get-caller-identity >/dev/null

echo "Creating VPC..."
VPC_ID="$(
  aws_cli ec2 create-vpc \
    --cidr-block "${VPC_CIDR}" \
    --tag-specifications \
      "ResourceType=vpc,Tags=[{Key=Name,Value=${PROJECT_NAME}-vpc},{Key=Project,Value=${PROJECT_NAME}},{Key=ManagedBy,Value=AWS-CLI}]" \
    --query 'Vpc.VpcId' \
    --output text
)"

save_variable VPC_ID "${VPC_ID}"

echo "VPC created: ${VPC_ID}"

echo "Enabling DNS support and DNS hostnames..."
aws_cli ec2 modify-vpc-attribute \
  --vpc-id "${VPC_ID}" \
  --enable-dns-support '{"Value":true}'

aws_cli ec2 modify-vpc-attribute \
  --vpc-id "${VPC_ID}" \
  --enable-dns-hostnames '{"Value":true}'

echo "Creating public subnet..."
SUBNET_ID="$(
  aws_cli ec2 create-subnet \
    --vpc-id "${VPC_ID}" \
    --cidr-block "${SUBNET_CIDR}" \
    --availability-zone "${AVAILABILITY_ZONE}" \
    --tag-specifications \
      "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-public-subnet},{Key=Project,Value=${PROJECT_NAME}},{Key=Tier,Value=Public}]" \
    --query 'Subnet.SubnetId' \
    --output text
)"

save_variable SUBNET_ID "${SUBNET_ID}"

echo "Subnet created: ${SUBNET_ID}"

echo "Enabling automatic public IPv4 assignment..."
aws_cli ec2 modify-subnet-attribute \
  --subnet-id "${SUBNET_ID}" \
  --map-public-ip-on-launch

echo "Creating internet gateway..."
INTERNET_GATEWAY_ID="$(
  aws_cli ec2 create-internet-gateway \
    --tag-specifications \
      "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PROJECT_NAME}-igw},{Key=Project,Value=${PROJECT_NAME}}]" \
    --query 'InternetGateway.InternetGatewayId' \
    --output text
)"

save_variable INTERNET_GATEWAY_ID "${INTERNET_GATEWAY_ID}"

echo "Attaching internet gateway..."
aws_cli ec2 attach-internet-gateway \
  --vpc-id "${VPC_ID}" \
  --internet-gateway-id "${INTERNET_GATEWAY_ID}"

echo "Creating route table..."
ROUTE_TABLE_ID="$(
  aws_cli ec2 create-route-table \
    --vpc-id "${VPC_ID}" \
    --tag-specifications \
      "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_NAME}-public-rt},{Key=Project,Value=${PROJECT_NAME}}]" \
    --query 'RouteTable.RouteTableId' \
    --output text
)"

save_variable ROUTE_TABLE_ID "${ROUTE_TABLE_ID}"

echo "Creating default internet route..."
aws_cli ec2 create-route \
  --route-table-id "${ROUTE_TABLE_ID}" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "${INTERNET_GATEWAY_ID}"

echo "Associating route table with public subnet..."
ROUTE_TABLE_ASSOCIATION_ID="$(
  aws_cli ec2 associate-route-table \
    --subnet-id "${SUBNET_ID}" \
    --route-table-id "${ROUTE_TABLE_ID}" \
    --query 'AssociationId' \
    --output text
)"

save_variable \
  ROUTE_TABLE_ASSOCIATION_ID \
  "${ROUTE_TABLE_ASSOCIATION_ID}"

echo "Creating security group..."
SECURITY_GROUP_ID="$(
  aws_cli ec2 create-security-group \
    --group-name "${PROJECT_NAME}-sg" \
    --description "Security group for the Node.js Jenkins EC2 deployment" \
    --vpc-id "${VPC_ID}" \
    --tag-specifications \
      "ResourceType=security-group,Tags=[{Key=Name,Value=${PROJECT_NAME}-sg},{Key=Project,Value=${PROJECT_NAME}}]" \
    --query 'GroupId' \
    --output text
)"

save_variable SECURITY_GROUP_ID "${SECURITY_GROUP_ID}"

echo "Allowing SSH from ${SSH_CIDR}..."
aws_cli ec2 authorize-security-group-ingress \
  --group-id "${SECURITY_GROUP_ID}" \
  --ip-permissions \
    "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${SSH_CIDR},Description='Trusted administration IP'}]"

echo
echo "Network creation completed successfully."
echo "VPC:              ${VPC_ID}"
echo "Subnet:           ${SUBNET_ID}"
echo "Internet gateway: ${INTERNET_GATEWAY_ID}"
echo "Route table:      ${ROUTE_TABLE_ID}"
echo "Security group:   ${SECURITY_GROUP_ID}"
echo
echo "Port ${APP_PORT} remains closed until Exercise 8."