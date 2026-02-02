# Kind GPU Kubernetes Cluster

Kind(Kubernetes in Docker)를 사용하여 GPU 멀티노드 클러스터를 구성합니다.

## 특징

- **IOMMU 불필요**: BIOS/UEFI 설정 변경 없이 사용 가능
- **VM 오버헤드 없음**: Docker 컨테이너 기반으로 빠른 시작
- **노드별 GPU 격리**: 각 Worker 노드가 다른 GPU를 인식
- **간편한 설정**: 스크립트로 자동 구성

## 아키텍처

```
┌──────────────────────────────────────────────────────────────┐
│                      Physical Host                            │
│         Docker + NVIDIA Container Toolkit 설치됨              │
│                                                               │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐        │
│  │ Control Plane│  │   Worker 1   │  │   Worker 2   │        │
│  │  (container) │  │  (container) │  │  (container) │        │
│  │              │  │              │  │              │        │
│  │   No GPU     │  │ GPU 0,1,2,3  │  │ GPU 4,5,6,7  │        │
│  └──────────────┘  └──────────────┘  └──────────────┘        │
│                           │                 │                 │
│                           ▼                 ▼                 │
│              ┌─────────────────────────────────────┐         │
│              │     Host의 8 GPUs (물리 디바이스)    │         │
│              │  NVIDIA_VISIBLE_DEVICES로 격리      │         │
│              └─────────────────────────────────────┘         │
└──────────────────────────────────────────────────────────────┘
```

## 사전 요구사항

### 1. NVIDIA 드라이버

호스트에 NVIDIA 드라이버가 설치되어 있어야 합니다:

```bash
nvidia-smi
```

### 2. Docker

```bash
# Docker 설치 확인
docker --version

# Docker 서비스 실행 확인
sudo systemctl status docker
```

### 3. NVIDIA Container Toolkit

```bash
# 저장소 설정
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

# 설치
sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit

# Docker 런타임 설정
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# 확인
docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi
```

### 4. Kind

```bash
# Go를 사용하는 경우
go install sigs.k8s.io/kind@latest

# 또는 바이너리 직접 다운로드
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.22.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

# 확인
kind version
```

### 5. kubectl

```bash
# 이미 설치되어 있지 않다면
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/

# 확인
kubectl version --client
```

## 사용 방법

### 클러스터 생성

```bash
# 기본: 2 Worker x 4 GPU
./setup.sh

# 커스텀: 4 Worker x 2 GPU
./setup.sh 4 2

# 환경변수로 클러스터 이름 지정
CLUSTER_NAME=my-gpu-cluster ./setup.sh 2 4
```

### 클러스터 확인

```bash
# 노드 확인
kubectl get nodes

# GPU 라벨 확인
kubectl get nodes -L gpu-worker,gpu-ids

# GPU 리소스 확인 (Device Plugin 배포 후)
kubectl describe nodes | grep nvidia.com/gpu
```

### GPU 테스트

```bash
# 단일 GPU 테스트
kubectl run gpu-test --rm -it --restart=Never \
  --image=nvidia/cuda:12.0-base \
  --limits=nvidia.com/gpu=1 \
  -- nvidia-smi

# 특정 Worker에서 실행
kubectl run gpu-test --rm -it --restart=Never \
  --image=nvidia/cuda:12.0-base \
  --limits=nvidia.com/gpu=1 \
  --overrides='{"spec":{"nodeSelector":{"gpu-worker":"1"}}}' \
  -- nvidia-smi

# 멀티 GPU Pod
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: multi-gpu-test
spec:
  containers:
  - name: cuda
    image: nvidia/cuda:12.0-base
    command: ["nvidia-smi", "-L"]
    resources:
      limits:
        nvidia.com/gpu: 4
  restartPolicy: Never
  nodeSelector:
    gpu-worker: "1"
EOF

kubectl logs -f multi-gpu-test
kubectl delete pod multi-gpu-test
```

### 클러스터 삭제

```bash
./teardown.sh

# 또는 직접
kind delete cluster --name gpu-cluster
```

## 파일 구조

```
kind/
├── setup.sh              # 클러스터 생성 스크립트
├── teardown.sh           # 클러스터 삭제 스크립트
├── kind-config.yaml      # 기본 Kind 설정 (참고용)
├── kind-config-generated.yaml  # 자동 생성된 설정 (setup.sh 실행 시)
└── README.md             # 이 파일
```

## 설정 커스터마이징

### Worker 수 및 GPU 할당

```bash
# 환경변수 또는 인자로 설정
./setup.sh <WORKER_COUNT> <GPU_PER_WORKER>

# 예시
./setup.sh 2 4    # 2 Worker x 4 GPU = 8 GPU 필요
./setup.sh 4 2    # 4 Worker x 2 GPU = 8 GPU 필요
./setup.sh 8 1    # 8 Worker x 1 GPU = 8 GPU 필요
```

### 클러스터 이름 변경

```bash
CLUSTER_NAME=my-cluster ./setup.sh
```

## GPU Operator vs Device Plugin

이 설정은 **NVIDIA Device Plugin**을 사용합니다:

| 구분 | Device Plugin | GPU Operator |
|------|--------------|--------------|
| 설치 | 단순 (DaemonSet 1개) | 복잡 (여러 컴포넌트) |
| 기능 | GPU 스케줄링만 | 드라이버, 모니터링 등 포함 |
| 적합성 | 테스트/개발 환경 | 프로덕션 환경 |

GPU Operator가 필요하면:

```bash
# Helm 설치
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# GPU Operator 설치
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update

helm install gpu-operator nvidia/gpu-operator \
    --namespace gpu-operator --create-namespace \
    --set driver.enabled=false \
    --set toolkit.enabled=false
```

## 문제 해결

### GPU가 인식되지 않음

```bash
# 호스트에서 GPU 확인
nvidia-smi

# Docker에서 GPU 확인
docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi

# Kind 노드에서 환경변수 확인
docker exec gpu-cluster-worker cat /etc/environment
```

### Device Plugin이 시작되지 않음

```bash
# Pod 상태 확인
kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds

# 로그 확인
kubectl logs -n kube-system -l name=nvidia-device-plugin-ds
```

### 노드에 GPU 리소스가 표시되지 않음

```bash
# Device Plugin 재시작
kubectl rollout restart daemonset nvidia-device-plugin-ds -n kube-system

# 또는 노드 다시 확인 (몇 분 후)
kubectl describe node gpu-cluster-worker | grep nvidia
```

## Vagrant GPU (PCI Passthrough)와 비교

| 항목 | Kind + GPU | Vagrant + PCI Passthrough |
|------|-----------|---------------------------|
| IOMMU 필요 | ❌ | ✅ |
| BIOS 변경 | ❌ | ✅ |
| 진짜 VM | ❌ (컨테이너) | ✅ |
| GPU 격리 수준 | 논리적 (환경변수) | 물리적 (VFIO) |
| 설정 복잡도 | 낮음 | 높음 |
| 시작 시간 | 빠름 (< 1분) | 느림 (10-15분) |
| 프로덕션 유사성 | 낮음 | 높음 |

**Kind를 선택하는 경우:**
- BIOS 설정을 변경할 수 없음
- 빠른 테스트 환경이 필요
- 분산 학습 기본 테스트

**Vagrant PCI Passthrough를 선택하는 경우:**
- 프로덕션 환경과 유사한 테스트 필요
- 완전한 GPU 격리가 필요
- IOMMU 설정이 가능

## 참고 자료

- [Kind Documentation](https://kind.sigs.k8s.io/)
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/)
- [NVIDIA Device Plugin](https://github.com/NVIDIA/k8s-device-plugin)
