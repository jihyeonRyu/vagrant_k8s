# k3d GPU Kubernetes Cluster

k3d(k3s in Docker)를 사용하여 GPU 멀티노드 클러스터를 구성합니다.
**기존 k3s 클러스터와 충돌 없이 공존**할 수 있습니다.

## 특징

- **기존 k3s 유지**: 베어메탈 k3s와 별도로 동작
- **IOMMU 불필요**: BIOS 설정 변경 없이 사용 가능
- **k3s 기반**: 이미 k3s를 사용 중이라면 친숙함
- **노드별 GPU 격리**: 각 Worker 노드가 다른 GPU를 인식
- **빠른 시작**: 1분 이내 클러스터 생성

## 아키텍처

```
┌──────────────────────────────────────────────────────────────┐
│                      Physical Host                            │
│                                                               │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │                  기존 k3s (베어메탈)                      │ │
│  │                  h100test04 (단일 노드)                   │ │
│  │                  context: default                        │ │
│  └─────────────────────────────────────────────────────────┘ │
│                                                               │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │                  k3d 클러스터 (Docker)                    │ │
│  │                  context: k3d-gpu-cluster                │ │
│  │                                                          │ │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐               │ │
│  │  │  Server  │  │  Agent 0 │  │  Agent 1 │               │ │
│  │  │(container)│ │(container)│ │(container)│               │ │
│  │  │          │  │GPU 0,1,2,3│ │GPU 4,5,6,7│               │ │
│  │  └──────────┘  └──────────┘  └──────────┘               │ │
│  └─────────────────────────────────────────────────────────┘ │
│                                                               │
│              ┌─────────────────────────────────┐             │
│              │     Host의 8 GPUs (H100 등)      │             │
│              └─────────────────────────────────┘             │
└──────────────────────────────────────────────────────────────┘
```

## 사전 요구사항

### 1. 기존 환경 (이미 있을 것)

```bash
# NVIDIA 드라이버 확인
nvidia-smi

# Docker 확인
docker --version

# NVIDIA Container Toolkit 확인
docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi
```

### 2. k3d 설치

```bash
# k3d 설치
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

# 확인
k3d version
```

## 사용 방법

### 클러스터 생성

```bash
cd k3d/

# 기본: 2 Worker x 4 GPU
./setup.sh

# 커스텀: 4 Worker x 2 GPU
./setup.sh 4 2

# 클러스터 이름 지정
CLUSTER_NAME=my-cluster ./setup.sh 2 4
```

### Context 전환

```bash
# k3d 클러스터 사용
kubectl config use-context k3d-gpu-cluster

# 기존 k3s 클러스터로 복귀
kubectl config use-context default

# 현재 context 확인
kubectl config current-context

# 모든 context 목록
kubectl config get-contexts
```

### 클러스터 확인

```bash
# 노드 확인
kubectl get nodes

# GPU 라벨 확인
kubectl get nodes -L gpu-worker,gpu-ids

# GPU 리소스 확인
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
k3d cluster delete gpu-cluster
```

## 파일 구조

```
k3d/
├── setup.sh                  # 클러스터 생성 스크립트
├── teardown.sh               # 클러스터 삭제 스크립트
├── k3d-config-generated.yaml # 자동 생성된 설정 (setup.sh 실행 시)
└── README.md                 # 이 파일
```

## 기존 k3s vs k3d 클러스터 비교

| 항목 | 기존 k3s (베어메탈) | k3d (Docker) |
|------|-------------------|--------------|
| 위치 | 호스트에서 직접 실행 | Docker 컨테이너 |
| 노드 수 | 1 (h100test04) | 3+ (server + agents) |
| GPU 접근 | 전체 8 GPU | 노드별 격리 가능 |
| API 포트 | 6443 | 6550 |
| context | default | k3d-gpu-cluster |
| 용도 | 실제 워크로드 | 멀티노드 테스트 |

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

### 클러스터 이름 및 포트 변경

```bash
CLUSTER_NAME=my-gpu-cluster ./setup.sh
```

## 문제 해결

### k3d 클러스터가 생성되지 않음

```bash
# Docker 상태 확인
docker ps

# k3d 클러스터 목록
k3d cluster list

# 로그 확인
docker logs k3d-gpu-cluster-server-0
```

### GPU가 인식되지 않음

```bash
# 호스트에서 GPU 확인
nvidia-smi

# k3d 컨테이너에서 GPU 확인
docker exec k3d-gpu-cluster-agent-0 nvidia-smi

# Device Plugin 상태 확인
kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds
kubectl logs -n kube-system -l name=nvidia-device-plugin-ds
```

### Context 전환이 안 됨

```bash
# kubeconfig 다시 병합
k3d kubeconfig merge gpu-cluster --kubeconfig-switch-context

# 또는 직접 설정
export KUBECONFIG=~/.kube/config:$(k3d kubeconfig write gpu-cluster)
kubectl config use-context k3d-gpu-cluster
```

## 참고 자료

- [k3d Documentation](https://k3d.io/)
- [k3s Documentation](https://docs.k3s.io/)
- [NVIDIA Device Plugin](https://github.com/NVIDIA/k8s-device-plugin)
