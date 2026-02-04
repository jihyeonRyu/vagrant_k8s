#!/usr/bin/env bash
#
# worker-gpu.sh - Worker 노드를 클러스터에 조인
#
# 이 스크립트는 GPU Worker 노드에서 실행됩니다.
#

set -e

NODE=$1
NETWORK_PREFIX="192.168.122"
NODE_HOST_IP="${NETWORK_PREFIX}.$((20+$NODE))"

if [[ -z "$NODE" ]]; then
    echo "Usage: $0 <NODE_NUMBER>"
    exit 1
fi

echo "=========================================="
echo "Worker Node ${NODE} 클러스터 조인"
echo "=========================================="
echo "Node IP: ${NODE_HOST_IP}"
echo ""

# ============================================
# 클러스터 조인
# ============================================
echo "[1/3] 클러스터에 조인..."

# kubeadm-init.out에서 조인 명령어 추출 및 실행
JOIN_CMD=$(grep -A 2 "kubeadm join" /vagrant/kubeadm-init.out | \
           sed -e 's/^[ \t]*//' | \
           tr '\n' ' ' | \
           sed -e 's/ \\ / /g')

if [[ -z "$JOIN_CMD" ]]; then
    echo "Error: 조인 명령어를 찾을 수 없습니다."
    echo "/vagrant/kubeadm-init.out 파일을 확인하세요."
    exit 1
fi

echo "실행: $JOIN_CMD"
eval "$JOIN_CMD"

# ============================================
# kubelet 설정
# ============================================
echo "[2/3] kubelet 설정..."
systemctl daemon-reload
cat > /etc/default/kubelet <<EOF
KUBELET_EXTRA_ARGS=--node-ip=${NODE_HOST_IP} --cgroup-driver=systemd
EOF
systemctl restart kubelet

# ============================================
# kubeconfig 설정
# ============================================
echo "[3/3] kubeconfig 설정..."
cp /vagrant/admin.conf /etc/kubernetes/admin.conf
chmod 644 /etc/kubernetes/admin.conf

# vagrant 사용자용 kubeconfig
mkdir -p /home/vagrant/.kube
cp /etc/kubernetes/admin.conf /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube

echo ""
echo "=========================================="
echo "Worker Node ${NODE} 조인 완료!"
echo "=========================================="

# GPU 확인
if lspci | grep -qi nvidia; then
    echo ""
    echo "감지된 GPU:"
    lspci | grep -i nvidia
    echo ""
    echo "nvidia-smi 출력 (드라이버 로드 후):"
    nvidia-smi 2>/dev/null || echo "  (드라이버가 아직 로드되지 않음 - 재부팅 필요할 수 있음)"
fi
b