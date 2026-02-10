#!/usr/bin/env bash
#
# control-plane-gpu.sh - Kubernetes Control Plane 초기화
#
# 이 스크립트는 GPU 클러스터의 Control Plane 노드에서 실행됩니다.
#

set -e

POD_CIDR=$1
API_ADV_ADDRESS=$2

if [[ -z "$POD_CIDR" ]] || [[ -z "$API_ADV_ADDRESS" ]]; then
    echo "Usage: $0 <POD_CIDR> <API_ADVERTISE_ADDRESS>"
    exit 1
fi

echo "=========================================="
echo "Control Plane 초기화"
echo "=========================================="
echo "POD_CIDR: ${POD_CIDR}"
echo "API_ADV_ADDRESS: ${API_ADV_ADDRESS}"
echo ""

# ============================================
# 미리 정의된 부트스트랩 토큰 (Worker 조인용)
# ============================================
BOOTSTRAP_TOKEN="abcdef.0123456789abcdef"

# ============================================
# kubeadm 초기화
# ============================================
echo "[1/4] kubeadm init 실행..."
kubeadm init \
    --pod-network-cidr "$POD_CIDR" \
    --apiserver-advertise-address "$API_ADV_ADDRESS" \
    --token "$BOOTSTRAP_TOKEN" \
    --token-ttl 0

# ============================================
# kubelet 설정
# ============================================
echo "[2/4] kubelet 설정..."
systemctl daemon-reload
cat > /etc/default/kubelet <<EOF
KUBELET_EXTRA_ARGS=--node-ip=${API_ADV_ADDRESS} --cgroup-driver=systemd
EOF
systemctl restart kubelet

# ============================================
# kubeconfig 설정
# ============================================
echo "[3/4] kubeconfig 설정..."

# vagrant 사용자용
mkdir -p /home/vagrant/.kube
cp -i /etc/kubernetes/admin.conf /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube

# root 사용자용
mkdir -p /root/.kube
cp -i /etc/kubernetes/admin.conf /root/.kube/config

# 호스트에서 사용할 kubeconfig 복사
cp /etc/kubernetes/admin.conf /vagrant/admin.conf
chmod 644 /vagrant/admin.conf

# ============================================
# Calico CNI 설치
# ============================================
echo "[4/4] Calico CNI 설치..."

# Tigera Operator 설치
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/tigera-operator.yaml

# Calico 커스텀 리소스 설정
wget -q https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/custom-resources.yaml

# POD_CIDR에 맞게 수정
sed -i "s~cidr: 192\.168\.0\.0/16~cidr: ${POD_CIDR}~g" custom-resources.yaml

# Vagrant 환경용: vxlanMode를 Always로 변경
sed -i "s~vxlanMode: CrossSubnet~vxlanMode: Always~g" custom-resources.yaml

sed -i "s~encapsulation: VXLANCrossSubnet~encapsulation: VXLAN~g" custom-resources.yaml  # 추가!


kubectl create -f custom-resources.yaml
rm -f custom-resources.yaml

# ============================================
# NFS 서버 설정 (모델 캐시 공유용)
# ============================================
echo "[5/5] NFS 서버 설정..."

apt-get install -y nfs-kernel-server

# NFS export 디렉토리 생성
mkdir -p /srv/nfs/k8s
chown nobody:nogroup /srv/nfs/k8s
chmod 777 /srv/nfs/k8s

# Worker 대역에 NFS export
NETWORK_PREFIX="192.168.122"
grep -q "/srv/nfs/k8s" /etc/exports 2>/dev/null || \
  echo "/srv/nfs/k8s ${NETWORK_PREFIX}.0/24(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports

exportfs -ra
systemctl enable nfs-kernel-server
systemctl restart nfs-kernel-server

echo "  NFS export 설정 완료: /srv/nfs/k8s"

echo ""
echo "=========================================="
echo "Control Plane 초기화 완료!"
echo "=========================================="
echo ""
echo "Worker 노드가 자동으로 조인됩니다."
echo "사용 토큰: ${BOOTSTRAP_TOKEN}"
echo "호스트에서 사용할 kubeconfig: ./admin.conf"
