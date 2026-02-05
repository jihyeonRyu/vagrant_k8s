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
CONTROL_PLANE_IP="${NETWORK_PREFIX}.10"

# 미리 정의된 부트스트랩 토큰 (Control Plane과 동일)
BOOTSTRAP_TOKEN="abcdef.0123456789abcdef"

if [[ -z "$NODE" ]]; then
    echo "Usage: $0 <NODE_NUMBER>"
    exit 1
fi

echo "=========================================="
echo "Worker Node ${NODE} 클러스터 조인"
echo "=========================================="
echo "Node IP: ${NODE_HOST_IP}"
echo "Control Plane IP: ${CONTROL_PLANE_IP}"
echo ""

# ============================================
# Control Plane API 서버 대기
# ============================================
echo "[1/4] Control Plane API 서버 대기 중..."

MAX_WAIT=300  # 최대 5분 대기
WAITED=0
while ! nc -z "$CONTROL_PLANE_IP" 6443 2>/dev/null; do
    if [[ $WAITED -ge $MAX_WAIT ]]; then
        echo "Error: Control Plane API 서버에 연결할 수 없습니다 (${MAX_WAIT}초 초과)"
        exit 1
    fi
    echo "  대기 중... (${WAITED}/${MAX_WAIT}초)"
    sleep 10
    WAITED=$((WAITED + 10))
done
echo "✓ Control Plane API 서버 연결 가능"

# API 서버가 완전히 준비될 때까지 추가 대기
echo "  API 서버 완전 준비 대기 중..."
sleep 30

# ============================================
# 클러스터 조인
# ============================================
echo "[2/4] 클러스터에 조인..."

# 미리 정의된 토큰으로 조인 (CA 검증 스킵 - 테스트 환경용)
kubeadm join "${CONTROL_PLANE_IP}:6443" \
    --token "$BOOTSTRAP_TOKEN" \
    --discovery-token-unsafe-skip-ca-verification

# ============================================
# kubelet 설정
# ============================================
echo "[3/4] kubelet 설정..."
systemctl daemon-reload
cat > /etc/default/kubelet <<EOF
KUBELET_EXTRA_ARGS=--node-ip=${NODE_HOST_IP} --cgroup-driver=systemd
EOF
systemctl restart kubelet

# ============================================
# kubeconfig 설정 (kubectl 사용을 위해)
# ============================================
echo "[4/4] kubeconfig 설정..."

# /vagrant에서 admin.conf 복사 (rsync로 동기화된 파일)
if [[ -f /vagrant/admin.conf ]]; then
    mkdir -p /home/vagrant/.kube
    cp /vagrant/admin.conf /home/vagrant/.kube/config
    chown -R vagrant:vagrant /home/vagrant/.kube
    
    mkdir -p /root/.kube
    cp /vagrant/admin.conf /root/.kube/config
    echo "✓ kubeconfig 설정 완료"
else
    echo "Warning: admin.conf를 찾을 수 없습니다."
    echo "  Control Plane에서 복사하세요: vagrant ssh gpu-control-plane -c 'cat /etc/kubernetes/admin.conf'"
fi

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