#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env.infrastructure"
KEY_DIRECTORY="${HOME}/.ssh/aws-training"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} does not exist."
  exit 1
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

required_variables=(
  AWS_PROFILE
  AWS_REGION
  PROJECT_NAME
  SUBNET_ID
  SECURITY_GROUP_ID
)

for variable in "${required_variables[@]}"; do
  if [[ -z "${!variable:-}" ]]; then
    echo "ERROR: ${variable} is not set."
    exit 1
  fi
done

aws_cli() {
  aws \
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

KEY_NAME="${PROJECT_NAME}-key"
KEY_FILE="${KEY_DIRECTORY}/${KEY_NAME}.pem"

mkdir -p "${KEY_DIRECTORY}"
chmod 700 "${KEY_DIRECTORY}"

if aws_cli ec2 describe-key-pairs \
  --key-names "${KEY_NAME}" >/dev/null 2>&1; then
  echo "ERROR: AWS key pair ${KEY_NAME} already exists."
  echo "Use the existing private key or choose another key name."
  exit 1
fi

if [[ -e "${KEY_FILE}" ]]; then
  echo "ERROR: Local key file already exists: ${KEY_FILE}"
  exit 1
fi

echo "Creating EC2 key pair..."
aws_cli ec2 create-key-pair \
  --key-name "${KEY_NAME}" \
  --key-type ed25519 \
  --key-format pem \
  --query 'KeyMaterial' \
  --output text > "${KEY_FILE}"

chmod 400 "${KEY_FILE}"

save_variable KEY_NAME "${KEY_NAME}"
save_variable KEY_FILE "${KEY_FILE}"

echo "Resolving latest Amazon Linux 2023 AMI..."
AMI_ID="$(
  aws_cli ssm get-parameter \
    --name \
      /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query 'Parameter.Value' \
    --output text
)"

save_variable AMI_ID "${AMI_ID}"

echo "AMI: ${AMI_ID}"

echo "Launching EC2 instance..."
INSTANCE_ID="$(
  aws_cli ec2 run-instances \
    --image-id "${AMI_ID}" \
    --instance-type "t3.micro" \
    --count 1 \
    --key-name "${KEY_NAME}" \
    --security-group-ids "${SECURITY_GROUP_ID}" \
    --subnet-id "${SUBNET_ID}" \
    --associate-public-ip-address \
    --metadata-options \
      "HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=1" \
    --block-device-mappings \
      "DeviceName=/dev/xvda,Ebs={VolumeSize=12,VolumeType=gp3,DeleteOnTermination=true,Encrypted=true}" \
    --tag-specifications \
      "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_NAME}-ec2},{Key=Project,Value=${PROJECT_NAME}},{Key=Environment,Value=Production-Lab}]" \
      "ResourceType=volume,Tags=[{Key=Name,Value=${PROJECT_NAME}-root-volume},{Key=Project,Value=${PROJECT_NAME}}]" \
    --query 'Instances[0].InstanceId' \
    --output text
)"

save_variable INSTANCE_ID "${INSTANCE_ID}"

echo "Waiting for ${INSTANCE_ID} to enter running state..."
aws_cli ec2 wait instance-running \
  --instance-ids "${INSTANCE_ID}"

echo "Waiting for EC2 status checks..."
aws_cli ec2 wait instance-status-ok \
  --instance-ids "${INSTANCE_ID}"

INSTANCE_PUBLIC_IP="$(
  aws_cli ec2 describe-instances \
    --instance-ids "${INSTANCE_ID}" \
    --query \
      'Reservations[0].Instances[0].PublicIpAddress' \
    --output text
)"

save_variable INSTANCE_PUBLIC_IP "${INSTANCE_PUBLIC_IP}"

echo
echo "EC2 creation completed."
echo "Instance ID: ${INSTANCE_ID}"
echo "Public IP:  ${INSTANCE_PUBLIC_IP}"
echo "Key file:   ${KEY_FILE}"
echo
echo "Connect with:"
echo "ssh -i '${KEY_FILE}' ec2-user@${INSTANCE_PUBLIC_IP}"