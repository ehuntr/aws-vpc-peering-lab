#!/usr/bin/env bash
# EWB VPC Peering Lab - automated build / test / cleanup (AWS CLI v2)
#
# Usage:
#   export STUDENT=YourName            # no spaces
#   export AWS_REGION=ap-south-1       # optional, default ap-south-1
#   ./ewb_vpc_peering_lab.sh network   # Phases 1-4: VPCs, subnets, IGW, routes, SGs, key, instances
#   ./ewb_vpc_peering_lab.sh baseline  # Pre-peering test (expected: ping FAILS)
#   ./ewb_vpc_peering_lab.sh peer      # Peering + accept + routes on all 3 route tables
#   ./ewb_vpc_peering_lab.sh verify    # Tests 02-05 (pings, SSH to App-B, no public IP)
#   ./ewb_vpc_peering_lab.sh failtest  # Controlled failure: remove ICMP rule, then restore
#   ./ewb_vpc_peering_lab.sh inventory # Print all resource IDs / routes / SG rules
#   ./ewb_vpc_peering_lab.sh updateip  # Refresh your /32 in the bastion SG if your IP changed
#   ./ewb_vpc_peering_lab.sh cleanup   # Delete everything created by this script
#
# All output is saved in ./evidence/ - use it (plus console screenshots) in your report.

set -euo pipefail

REGION="${AWS_REGION:-ap-south-1}"
export AWS_DEFAULT_REGION="$REGION"
STUDENT="${STUDENT:-YourName}"; STUDENT="${STUDENT// /-}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
KEY_NAME="ewb-lab"
KEY_FILE="$HOME/.ssh/ewb-lab.pem"
STATE="./.ewb-state.env"
EVID="./evidence"
SSH_CFG="./ewb_ssh_config"
mkdir -p "$EVID"
touch "$STATE"
# shellcheck disable=SC1090
source "$STATE"

save() { echo "$1=$2" >> "$STATE"; eval "$1=$2"; }
tags() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=Project,Value=EWB-VPC-Peering},{Key=Student,Value=$STUDENT}]"; }
say()  { echo -e "\n=== $* ==="; }
ssh_run() { local h=$1; shift; ssh -F "$SSH_CFG" -o ConnectTimeout=15 "$h" "$@"; }
myip() { curl -s https://checkip.amazonaws.com | tr -d '[:space:]'; }

# ---------------------------------------------------------------- network
cmd_network() {
  say "Phase 1: VPC A"
  AZ=$(aws ec2 describe-availability-zones --query 'AvailabilityZones[0].ZoneName' --output text)
  save AZ "$AZ"
  save VPC_A "$(aws ec2 create-vpc --cidr-block 10.10.0.0/16 --tag-specifications "$(tags vpc ewb-vpc-a)" --query Vpc.VpcId --output text)"
  save SUB_A_PUB "$(aws ec2 create-subnet --vpc-id "$VPC_A" --cidr-block 10.10.1.0/24 --availability-zone "$AZ" --tag-specifications "$(tags subnet ewb-a-public)" --query Subnet.SubnetId --output text)"
  save SUB_A_PRIV "$(aws ec2 create-subnet --vpc-id "$VPC_A" --cidr-block 10.10.2.0/24 --availability-zone "$AZ" --tag-specifications "$(tags subnet ewb-a-private)" --query Subnet.SubnetId --output text)"
  save IGW "$(aws ec2 create-internet-gateway --tag-specifications "$(tags internet-gateway ewb-igw-a)" --query InternetGateway.InternetGatewayId --output text)"
  aws ec2 attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_A"

  save RT_A_PUB "$(aws ec2 create-route-table --vpc-id "$VPC_A" --tag-specifications "$(tags route-table ewb-rt-a-public)" --query RouteTable.RouteTableId --output text)"
  aws ec2 associate-route-table --route-table-id "$RT_A_PUB" --subnet-id "$SUB_A_PUB" >/dev/null
  aws ec2 create-route --route-table-id "$RT_A_PUB" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW" >/dev/null

  save RT_A_PRIV "$(aws ec2 create-route-table --vpc-id "$VPC_A" --tag-specifications "$(tags route-table ewb-rt-a-private)" --query RouteTable.RouteTableId --output text)"
  aws ec2 associate-route-table --route-table-id "$RT_A_PRIV" --subnet-id "$SUB_A_PRIV" >/dev/null

  say "Phase 2: VPC B (no internet gateway)"
  save VPC_B "$(aws ec2 create-vpc --cidr-block 10.20.0.0/16 --tag-specifications "$(tags vpc ewb-vpc-b)" --query Vpc.VpcId --output text)"
  save SUB_B_PRIV "$(aws ec2 create-subnet --vpc-id "$VPC_B" --cidr-block 10.20.1.0/24 --availability-zone "$AZ" --tag-specifications "$(tags subnet ewb-b-private)" --query Subnet.SubnetId --output text)"
  save RT_B_PRIV "$(aws ec2 create-route-table --vpc-id "$VPC_B" --tag-specifications "$(tags route-table ewb-rt-b-private)" --query RouteTable.RouteTableId --output text)"
  aws ec2 associate-route-table --route-table-id "$RT_B_PRIV" --subnet-id "$SUB_B_PRIV" >/dev/null

  say "Phase 3: Security groups"
  MYIP=$(myip)
  save SG_BASTION "$(aws ec2 create-security-group --group-name ewb-sg-bastion --description "EWB bastion" --vpc-id "$VPC_A" --tag-specifications "$(tags security-group ewb-sg-bastion)" --query GroupId --output text)"
  save SG_APP_A   "$(aws ec2 create-security-group --group-name ewb-sg-app-a --description "EWB App A" --vpc-id "$VPC_A" --tag-specifications "$(tags security-group ewb-sg-app-a)" --query GroupId --output text)"
  save SG_APP_B   "$(aws ec2 create-security-group --group-name ewb-sg-app-b --description "EWB App B" --vpc-id "$VPC_B" --tag-specifications "$(tags security-group ewb-sg-app-b)" --query GroupId --output text)"

  aws ec2 authorize-security-group-ingress --group-id "$SG_BASTION" --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$MYIP/32,Description=my-ip-ssh}]" >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$SG_APP_A" --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=10.10.1.10/32,Description=bastion-ssh}]" >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$SG_APP_A" --ip-permissions "IpProtocol=icmp,FromPort=8,ToPort=0,IpRanges=[{CidrIp=10.20.1.10/32,Description=app-b-echo}]" >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$SG_APP_B" --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=10.10.1.10/32,Description=bastion-ssh}]" >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$SG_APP_B" --ip-permissions "IpProtocol=icmp,FromPort=8,ToPort=0,IpRanges=[{CidrIp=10.10.2.10/32,Description=app-a-echo}]" >/dev/null

  say "Phase 4: Key pair and instances"
  if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
    mkdir -p "$HOME/.ssh"
    aws ec2 create-key-pair --key-name "$KEY_NAME" --key-type rsa --query KeyMaterial --output text > "$KEY_FILE"
    chmod 400 "$KEY_FILE"
    echo "Created key pair $KEY_NAME -> $KEY_FILE"
  else
    echo "Key pair $KEY_NAME already exists in AWS; make sure $KEY_FILE is its private key."
  fi

  AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text)
  save AMI "$AMI"

  launch() { # name subnet ip sg public(true|false)
    aws ec2 run-instances --image-id "$AMI" --instance-type "$INSTANCE_TYPE" --key-name "$KEY_NAME" \
      --network-interfaces "DeviceIndex=0,SubnetId=$2,PrivateIpAddress=$3,Groups=$4,AssociatePublicIpAddress=$5" \
      --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=8,VolumeType=gp3,DeleteOnTermination=true}" \
      --tag-specifications "$(tags instance "$1")" "$(tags volume "$1")" \
      --query 'Instances[0].InstanceId' --output text
  }
  save I_BASTION "$(launch ewb-bastion "$SUB_A_PUB"  10.10.1.10 "$SG_BASTION" true)"
  save I_APP_A   "$(launch ewb-app-a   "$SUB_A_PRIV" 10.10.2.10 "$SG_APP_A"   false)"
  save I_APP_B   "$(launch ewb-app-b   "$SUB_B_PRIV" 10.20.1.10 "$SG_APP_B"   false)"

  echo "Waiting for status checks (2-3 minutes)..."
  aws ec2 wait instance-status-ok --instance-ids "$I_BASTION" "$I_APP_A" "$I_APP_B"

  BASTION_IP=$(aws ec2 describe-instances --instance-ids "$I_BASTION" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  save BASTION_IP "$BASTION_IP"
  write_ssh_config
  say "Done. Checkpoints 01 and 02: run './ewb_vpc_peering_lab.sh inventory' and take console screenshots."
}

write_ssh_config() {
  cat > "$SSH_CFG" <<EOF
Host *
    User ec2-user
    IdentityFile $KEY_FILE
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    UserKnownHostsFile ./ewb_known_hosts

Host ewb-bastion
    HostName $BASTION_IP

Host ewb-app-a
    HostName 10.10.2.10
    ProxyJump ewb-bastion

Host ewb-app-b
    HostName 10.20.1.10
    ProxyJump ewb-bastion
EOF
  echo "SSH config written to $SSH_CFG (use: ssh -F $SSH_CFG ewb-app-a)"
}

# ---------------------------------------------------------------- baseline
cmd_baseline() {
  say "TEST 01 - Baseline (before peering): expect NO replies"
  { ssh_run ewb-app-a 'hostname; hostname -I; ping -c 4 -W 2 10.20.1.10' || echo ">> Ping failed as expected (no peering yet)"; } 2>&1 | tee "$EVID/01_baseline.txt"
}

# ---------------------------------------------------------------- peering
cmd_peer() {
  say "Phase 6: Peering"
  save PCX "$(aws ec2 create-vpc-peering-connection --vpc-id "$VPC_A" --peer-vpc-id "$VPC_B" --tag-specifications "$(tags vpc-peering-connection ewb-a-b-peer)" --query VpcPeeringConnection.VpcPeeringConnectionId --output text)"
  sleep 3
  aws ec2 accept-vpc-peering-connection --vpc-peering-connection-id "$PCX" >/dev/null
  for _ in {1..30}; do
    st=$(aws ec2 describe-vpc-peering-connections --vpc-peering-connection-ids "$PCX" --query 'VpcPeeringConnections[0].Status.Code' --output text)
    [[ "$st" == "active" ]] && break; sleep 5
  done
  echo "Peering $PCX status: $st"
  [[ "$st" == "active" ]] || { echo "Peering did not become active"; exit 1; }

  say "Phase 7: Routes on both sides"
  aws ec2 create-route --route-table-id "$RT_A_PRIV" --destination-cidr-block 10.20.0.0/16 --vpc-peering-connection-id "$PCX" >/dev/null
  aws ec2 create-route --route-table-id "$RT_B_PRIV" --destination-cidr-block 10.10.0.0/16 --vpc-peering-connection-id "$PCX" >/dev/null
  aws ec2 create-route --route-table-id "$RT_A_PUB"  --destination-cidr-block 10.20.0.0/16 --vpc-peering-connection-id "$PCX" >/dev/null
  echo "Routes added. Checkpoints 03 and 04: screenshot the peering connection and all three route tables."
}

# ---------------------------------------------------------------- verify
cmd_verify() {
  say "TEST 02 - Forward path (App-A -> App-B)"
  ssh_run ewb-app-a 'hostname; hostname -I; ping -c 4 10.20.1.10' 2>&1 | tee "$EVID/02_forward.txt"
  say "TEST 03 - Reverse path (App-B -> App-A)"
  ssh_run ewb-app-b 'hostname; hostname -I; ping -c 4 10.10.2.10' 2>&1 | tee "$EVID/03_reverse.txt"
  say "TEST 04 - Private SSH to App-B through the bastion"
  { echo '$ ssh ewb-app-b "hostname; hostname -I"'; ssh_run ewb-app-b 'hostname; hostname -I'; } 2>&1 | tee "$EVID/04_ssh_app_b.txt"
  say "TEST 05 - Isolation (public IPv4 must be None)"
  aws ec2 describe-instances --instance-ids "$I_APP_A" "$I_APP_B" \
    --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceId,PrivateIpAddress,PublicIpAddress]' \
    --output table 2>&1 | tee "$EVID/05_isolation.txt"
}

# ---------------------------------------------------------------- controlled failure
cmd_failtest() {
  RULE="IpProtocol=icmp,FromPort=8,ToPort=0,IpRanges=[{CidrIp=10.10.2.10/32,Description=app-a-echo}]"
  {
    say "Before: ping works"
    ssh_run ewb-app-a 'ping -c 4 10.20.1.10' || true
    say "Removing ONLY the ICMP echo rule from ewb-sg-app-b"
    aws ec2 revoke-security-group-ingress --group-id "$SG_APP_B" --ip-permissions "$RULE" >/dev/null
    sleep 5
    say "During failure: expect 100% packet loss"
    ssh_run ewb-app-a 'ping -c 4 -W 2 10.20.1.10' || echo ">> Ping failed as expected (rule removed)"
    say "Restoring the exact rule"
    aws ec2 authorize-security-group-ingress --group-id "$SG_APP_B" --ip-permissions "$RULE" >/dev/null
    sleep 5
    say "After recovery: replies resume"
    ssh_run ewb-app-a 'ping -c 4 10.20.1.10'
  } 2>&1 | tee "$EVID/06_controlled_failure.txt"
}

# ---------------------------------------------------------------- inventory
cmd_inventory() {
  {
    say "Resource IDs"
    grep -v '^AMI=' "$STATE" | sort -u
    say "Route tables"
    aws ec2 describe-route-tables --route-table-ids "$RT_A_PUB" "$RT_A_PRIV" "$RT_B_PRIV" \
      --query 'RouteTables[].[Tags[?Key==`Name`]|[0].Value,RouteTableId,Associations[0].SubnetId,Routes[].[DestinationCidrBlock,GatewayId||VpcPeeringConnectionId]]' --output json
    say "Security group rules"
    aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$SG_BASTION,$SG_APP_A,$SG_APP_B" \
      --query 'SecurityGroupRules[?IsEgress==`false`].[GroupId,IpProtocol,FromPort,ToPort,CidrIpv4]' --output table
    say "Peering"
    [[ -n "${PCX:-}" ]] && aws ec2 describe-vpc-peering-connections --vpc-peering-connection-ids "$PCX" \
      --query 'VpcPeeringConnections[0].[VpcPeeringConnectionId,Status.Code,RequesterVpcInfo.VpcId,RequesterVpcInfo.CidrBlock,AccepterVpcInfo.VpcId,AccepterVpcInfo.CidrBlock]' --output table || true
  } 2>&1 | tee "$EVID/inventory.txt"
}

# ---------------------------------------------------------------- update ip
cmd_updateip() {
  NEW=$(myip)
  OLD=$(aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$SG_BASTION" \
        --query 'SecurityGroupRules[?IsEgress==`false`].CidrIpv4|[0]' --output text)
  aws ec2 revoke-security-group-ingress --group-id "$SG_BASTION" --protocol tcp --port 22 --cidr "$OLD" >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$SG_BASTION" --protocol tcp --port 22 --cidr "$NEW/32" >/dev/null
  echo "Bastion SSH source updated: $OLD -> $NEW/32"
}

# ---------------------------------------------------------------- cleanup
cmd_cleanup() {
  say "Cleanup - saving inventory first"
  cmd_inventory || true
  read -r -p "Delete ALL lab resources recorded in $STATE? (yes/no) " ans
  [[ "$ans" == "yes" ]] || { echo "Aborted."; exit 0; }

  say "1. Terminate instances"
  aws ec2 terminate-instances --instance-ids "${I_BASTION:-}" "${I_APP_A:-}" "${I_APP_B:-}" >/dev/null 2>&1 || true
  aws ec2 wait instance-terminated --instance-ids "${I_BASTION:-}" "${I_APP_A:-}" "${I_APP_B:-}" 2>/dev/null || true

  say "2. Peering routes and connection"
  [[ -n "${RT_A_PRIV:-}" ]] && aws ec2 delete-route --route-table-id "$RT_A_PRIV" --destination-cidr-block 10.20.0.0/16 2>/dev/null || true
  [[ -n "${RT_A_PUB:-}"  ]] && aws ec2 delete-route --route-table-id "$RT_A_PUB"  --destination-cidr-block 10.20.0.0/16 2>/dev/null || true
  [[ -n "${RT_B_PRIV:-}" ]] && aws ec2 delete-route --route-table-id "$RT_B_PRIV" --destination-cidr-block 10.10.0.0/16 2>/dev/null || true
  [[ -n "${PCX:-}" ]] && aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id "$PCX" 2>/dev/null || true

  say "3. Security groups"
  for sg in "${SG_BASTION:-}" "${SG_APP_A:-}" "${SG_APP_B:-}"; do
    [[ -z "$sg" ]] && continue
    for _ in {1..12}; do aws ec2 delete-security-group --group-id "$sg" 2>/dev/null && break; sleep 10; done
  done

  say "4. Route tables and subnets"
  for rt in "${RT_A_PUB:-}" "${RT_A_PRIV:-}" "${RT_B_PRIV:-}"; do
    [[ -z "$rt" ]] && continue
    for assoc in $(aws ec2 describe-route-tables --route-table-ids "$rt" --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' --output text); do
      aws ec2 disassociate-route-table --association-id "$assoc"
    done
    aws ec2 delete-route-table --route-table-id "$rt" 2>/dev/null || true
  done
  for s in "${SUB_A_PUB:-}" "${SUB_A_PRIV:-}" "${SUB_B_PRIV:-}"; do
    [[ -n "$s" ]] && aws ec2 delete-subnet --subnet-id "$s" 2>/dev/null || true
  done

  say "5. Internet gateway"
  [[ -n "${IGW:-}" ]] && { aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_A" 2>/dev/null || true
                           aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" 2>/dev/null || true; }

  say "6. VPCs"
  for v in "${VPC_A:-}" "${VPC_B:-}"; do [[ -n "$v" ]] && aws ec2 delete-vpc --vpc-id "$v" 2>/dev/null || true; done

  say "7. Key pair"
  aws ec2 delete-key-pair --key-name "$KEY_NAME" 2>/dev/null || true
  rm -f "$KEY_FILE"

  say "8. Verify nothing is left (filtered by project tag)"
  {
    aws ec2 describe-vpcs --filters Name=tag:Project,Values=EWB-VPC-Peering --query 'Vpcs[].VpcId' --output text
    aws ec2 describe-instances --filters Name=tag:Project,Values=EWB-VPC-Peering Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text
    aws ec2 describe-volumes --filters Name=tag:Project,Values=EWB-VPC-Peering --query 'Volumes[].VolumeId' --output text
    echo "(empty lines above = nothing remaining)"
  } 2>&1 | tee "$EVID/07_cleanup.txt"
  mv "$STATE" "$STATE.cleaned.$(date +%s)"
}

case "${1:-}" in
  network)   cmd_network ;;
  baseline)  cmd_baseline ;;
  peer)      cmd_peer ;;
  verify)    cmd_verify ;;
  failtest)  cmd_failtest ;;
  inventory) cmd_inventory ;;
  updateip)  cmd_updateip ;;
  cleanup)   cmd_cleanup ;;
  *) sed -n '2,17p' "$0" ;;
esac
