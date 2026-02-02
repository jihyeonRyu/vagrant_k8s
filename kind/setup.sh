#!/usr/bin/env bash
#
# setup.sh - Kind GPU 클러스터 생성
#
# 각 Worker 노드에 다른 GPU를 할당하여 멀티노드 GPU 클러스터를 구성합니다.
#
# 사용법: ./setup.sh [WORKER_COUNT] [GPU_PER_WORKER]
#   예: ./setup.sh 2 4    # 2개 Worker, 각 4 GPU
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-gpu-cluster}"
WORKER_COUNT="${1:-2}"
GPU_PER_WORKER="${2:-4}"

echo "=========================================="
echo "Kind GPU 클러스터 생성"
echo "=========================================="
echo "클러스터 이름: ${CLUSTER_NAME}"
echo "Worker 수: ${WORKER_COUNT}"
echo "Worker당 GPU: ${GPU_PER_WORKER}"
echo ""

# ============================================
# 사전 요구사항 확인
# ============================================
echo "[1/6] 사전 요구사항 확인..."

# Docker 확인
if ! command -v docker &> /dev/null; then
    echo "Error: Docker가 설치되어 있지 않습니다."
    exit 1
fi
echo "  ✓ Docker: $(docker --version | cut -d' ' -f3)"

# Kind 확인
if ! command -v kind &> /dev/null; then
    echo "Error: Kind가 설치되어 있지 않습니다."
    echo "설치: go install sigs.k8s.io/kind@latest"
    echo "또는: brew install kind"
    exit 1
fi
echo "  ✓ Kind: $(kind version | cut -d' ' -f2)"

# kubectl 확인
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl이 설치되어 있지 않습니다."
    exit 1
fi
echo "  ✓ kubectl: $(kubectl version --client -o yaml | grep gitVersion | cut -d':' -f2 | tr -d ' ')"

# NVIDIA 드라이버 확인
if ! command -v nvidia-smi &> /dev/null; then
    echo "Error: NVIDIA 드라이버가 설치되어 있지 않습니다."
    exit 1
fi
echo "  ✓ NVIDIA Driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"

# GPU 수 확인
TOTAL_GPUS=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
REQUIRED_GPUS=$((WORKER_COUNT * GPU_PER_WORKER))
echo "  ✓ 총 GPU: ${TOTAL_GPUS}개"

if [[ "$REQUIRED_GPUS" -gt "$TOTAL_GPUS" ]]; then
    echo "Error: GPU가 부족합니다. 필요: ${REQUIRED_GPUS}, 보유: ${TOTAL_GPUS}"
    exit 1
fi

# NVIDIA Container Toolkit 확인
if ! docker info 2>/dev/null | grep -q "nvidia"; then
    echo "Warning: NVIDIA Container Toolkit이 Docker 기본 런타임으로 설정되지 않았습니다."
    echo "GPU 컨테이너 테스트 중..."
fi

if ! docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi &> /dev/null; then
    echo "Error: Docker에서 GPU를 사용할 수 없습니다."
    echo "NVIDIA Container Toolkit을 설치하세요."
    exit 1
fi
echo "  ✓ NVIDIA Container Toolkit: 작동 확인"

# ============================================
# 기존 클러스터 확인
# ============================================
echo ""
echo "[2/6] 기존 클러스터 확인..."

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "Warning: 클러스터 '${CLUSTER_NAME}'가 이미 존재합니다."
    echo "삭제하고 다시 생성하시겠습니까? [y/N]"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        kind delete cluster --name "${CLUSTER_NAME}"
    else
        echo "취소되었습니다."
        exit 0
    fi
fi

# ============================================
# Kind 설정 파일 동적 생성
# ============================================
echo ""
echo "[3/6] Kind 설정 생성 중..."

CONFIG_FILE="${SCRIPT_DIR}/kind-config-generated.yaml"

cat > "$CONFIG_FILE" << 'HEADER'
# 자동 생성된 Kind 설정 파일
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4

nodes:
  # Control Plane
  - role: control-plane

HEADER

# Worker 노드 추가
GPU_INDEX=0
for ((i=1; i<=WORKER_COUNT; i++)); do
    START_GPU=$GPU_INDEX
    END_GPU=$((GPU_INDEX + GPU_PER_WORKER - 1))
    
    # GPU 인덱스 목록 생성 (예: "0,1,2,3")
    GPU_LIST=""
    for ((g=START_GPU; g<=END_GPU; g++)); do
        if [[ -n "$GPU_LIST" ]]; then
            GPU_LIST="${GPU_LIST},"
        fi
        GPU_LIST="${GPU_LIST}${g}"
    done
    
    cat >> "$CONFIG_FILE" << EOF
  # Worker ${i}: GPU ${GPU_LIST}
  - role: worker
    labels:
      gpu-worker: "${i}"
      gpu-ids: "${GPU_LIST}"

EOF
    
    GPU_INDEX=$((GPU_INDEX + GPU_PER_WORKER))
done

# 네트워킹 설정 추가
cat >> "$CONFIG_FILE" << 'FOOTER'
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
FOOTER

echo "  설정 파일 생성: ${CONFIG_FILE}"

# ============================================
# Kind 클러스터 생성
# ============================================
echo ""
echo "[4/6] Kind 클러스터 생성 중..."

kind create cluster --config "$CONFIG_FILE" --name "${CLUSTER_NAME}"

# kubeconfig 설정
kubectl cluster-info --context "kind-${CLUSTER_NAME}"

# ============================================
# Worker 노드에 GPU 접근 설정
# ============================================
echo ""
echo "[5/6] Worker 노드에 GPU 접근 설정 중..."

GPU_INDEX=0
for ((i=1; i<=WORKER_COUNT; i++)); do
    CONTAINER_NAME="${CLUSTER_NAME}-worker"
    if [[ "$WORKER_COUNT" -gt 1 ]]; then
        CONTAINER_NAME="${CLUSTER_NAME}-worker${i}"
    fi
    
    # GPU 인덱스 목록 생성
    START_GPU=$GPU_INDEX
    END_GPU=$((GPU_INDEX + GPU_PER_WORKER - 1))
    GPU_LIST=""
    for ((g=START_GPU; g<=END_GPU; g++)); do
        if [[ -n "$GPU_LIST" ]]; then
            GPU_LIST="${GPU_LIST},"
        fi
        GPU_LIST="${GPU_LIST}${g}"
    done
    
    echo "  Worker ${i} (${CONTAINER_NAME}): GPU ${GPU_LIST} 설정..."
    
    # 컨테이너에 NVIDIA 환경변수 설정
    # Kind 노드 컨테이너 내부에 환경변수 파일 생성
    docker exec "${CONTAINER_NAME}" bash -c "
        echo 'NVIDIA_VISIBLE_DEVICES=${GPU_LIST}' >> /etc/environment
        echo 'NVIDIA_DRIVER_CAPABILITIES=compute,utility' >> /etc/environment
    "
    
    # /dev/nvidia* 디바이스 마운트를 위해 컨테이너 설정 업데이트
    # (Kind는 privileged 모드로 실행되므로 디바이스 접근 가능)
    
    GPU_INDEX=$((GPU_INDEX + GPU_PER_WORKER))
done

# ============================================
# NVIDIA Device Plugin 설치
# ============================================
echo ""
echo "[6/6] NVIDIA Device Plugin 설치 중..."

# NVIDIA Device Plugin DaemonSet 배포
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.5/nvidia-device-plugin.yml

echo ""
echo "Device Plugin이 Ready 상태가 될 때까지 대기 중..."
sleep 10

kubectl wait --for=condition=ready pod -l name=nvidia-device-plugin-ds -n kube-system --timeout=120s 2>/dev/null || true

# ============================================
# 완료
# ============================================
echo ""
echo "=========================================="
echo "Kind GPU 클러스터 생성 완료!"
echo "=========================================="
echo ""
echo "클러스터 정보:"
kubectl get nodes -o wide
echo ""
echo "GPU 노드 확인:"
kubectl get nodes -L gpu-worker,gpu-ids
echo ""
echo "kubeconfig:"
echo "  export KUBECONFIG=\$(kind get kubeconfig-path --name=${CLUSTER_NAME})"
echo "  또는"
echo "  kubectl cluster-info --context kind-${CLUSTER_NAME}"
echo ""
echo "GPU 테스트:"
echo "  kubectl run gpu-test --rm -it --restart=Never \\"
echo "    --image=nvidia/cuda:12.0-base \\"
echo "    --limits=nvidia.com/gpu=1 \\"
echo "    -- nvidia-smi"
echo ""
echo "클러스터 삭제:"
echo "  ./teardown.sh"
