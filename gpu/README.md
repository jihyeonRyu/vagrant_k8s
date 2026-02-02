# GPU Kubernetes Cluster with PCI Passthrough

물리 서버의 NVIDIA GPU를 PCI Passthrough 방식으로 VM에 할당하여 멀티노드 GPU Kubernetes 클러스터를 구성합니다.

## 아키텍처

```
┌─────────────────────────────────────────────────────────────┐
│                      Physical Host                          │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                   VFIO Driver                        │   │
│  │    GPU 0-3 ──────────┐    ┌────────── GPU 4-7       │   │
│  └─────────────────────────────────────────────────────┘   │
│                          │    │                             │
│           ┌──────────────┘    └──────────────┐             │
│           ▼                                   ▼             │
│  ┌─────────────────┐                 ┌─────────────────┐   │
│  │  Worker 1 VM    │                 │  Worker 2 VM    │   │
│  │  (4 GPUs)       │                 │  (4 GPUs)       │   │
│  └────────┬────────┘                 └────────┬────────┘   │
│           │                                   │             │
│           └─────────────┬─────────────────────┘             │
│                         │                                   │
│                 ┌───────┴───────┐                          │
│                 │ Control Plane │                          │
│                 │      VM       │                          │
│                 └───────────────┘                          │
└─────────────────────────────────────────────────────────────┘
```

## 사전 요구사항

### 1. 호스트 시스템

- Ubuntu 22.04 이상 (권장)
- NVIDIA GPU (테스트됨: A100, H100, RTX 시리즈)
- 최소 64GB RAM (Worker VM당 32GB 권장)
- IOMMU 지원 CPU (Intel VT-d 또는 AMD-Vi)

### 2. IOMMU 활성화

**1회성 설정으로, 재부팅이 필요합니다.**

```bash
# /etc/default/grub 편집
sudo vim /etc/default/grub

# Intel CPU의 경우:
GRUB_CMDLINE_LINUX="intel_iommu=on iommu=pt"

# AMD CPU의 경우:
GRUB_CMDLINE_LINUX="amd_iommu=on iommu=pt"

# GRUB 업데이트 및 재부팅
sudo update-grub
sudo reboot
```

재부팅 후 확인:
```bash
dmesg | grep -i iommu
# "IOMMU enabled" 메시지 확인
```

### 3. 필수 소프트웨어 설치

```bash
# libvirt 및 QEMU/KVM 설치
sudo apt update
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils

# Vagrant 설치
wget https://releases.hashicorp.com/vagrant/2.4.1/vagrant_2.4.1-1_amd64.deb
sudo dpkg -i vagrant_2.4.1-1_amd64.deb

# vagrant-libvirt 플러그인 설치
sudo apt install -y libvirt-dev
vagrant plugin install vagrant-libvirt
```

## 파일 구조

```
gpu/
├── Vagrantfile          # libvirt + PCI passthrough 설정
├── gpu-config.yaml      # GPU PCI 주소 및 할당 설정
├── bind-vfio.sh         # GPU를 VFIO에 바인딩 (테스트 전)
├── unbind-vfio.sh       # GPU를 nvidia로 복원 (테스트 후)
├── common-gpu.sh        # K8s + NVIDIA 드라이버 + Container Toolkit
├── control-plane-gpu.sh # Control Plane 초기화
├── worker-gpu.sh        # Worker 클러스터 조인
├── setup-gpu-operator.sh# GPU Operator Helm 배포
└── README.md            # 이 파일
```

## 사용 방법

### Step 1: GPU 설정 파일 편집

먼저 시스템의 GPU PCI 주소를 확인합니다:

```bash
lspci | grep -i nvidia
# 예시 출력:
# 41:00.0 3D controller: NVIDIA Corporation ...
# 41:00.1 Audio device: NVIDIA Corporation ...
# 42:00.0 3D controller: NVIDIA Corporation ...
# ...

lspci -nn | grep -i nvidia
# 벤더:디바이스 ID 확인 (예: [10de:2330])
```

`gpu-config.yaml` 파일을 편집하여 PCI 주소를 설정합니다:

```bash
vim gpu-config.yaml
```

### Step 2: GPU를 VFIO에 바인딩

테스트를 시작하기 전에 GPU를 VFIO 드라이버에 바인딩합니다.

> ⚠️ **주의**: 이 단계 이후 호스트에서 GPU를 사용할 수 없습니다!

```bash
sudo ./bind-vfio.sh
```

### Step 3: 클러스터 생성

```bash
vagrant up
```

프로비저닝은 약 10-15분 소요됩니다:
1. Control Plane VM 생성 및 K8s 초기화
2. Worker VM 생성 (GPU Passthrough 포함)
3. 각 Worker가 클러스터에 조인
4. GPU Operator 설치

### Step 4: 클러스터 접속 및 확인

```bash
# kubeconfig 설정
export KUBECONFIG=$(pwd)/admin.conf

# 노드 확인
kubectl get nodes

# GPU 리소스 확인
kubectl describe node gpu-worker-1 | grep nvidia

# GPU Operator 상태 확인
kubectl get pods -n gpu-operator
```

### Step 5: GPU 테스트

```bash
# 단순 GPU 테스트
kubectl run gpu-test --rm -it --restart=Never \
  --image=nvidia/cuda:12.0-base \
  --limits=nvidia.com/gpu=1 \
  -- nvidia-smi

# 멀티 GPU 테스트
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: multi-gpu-test
spec:
  containers:
  - name: cuda
    image: nvidia/cuda:12.0-base
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 4
  restartPolicy: Never
EOF
kubectl logs -f multi-gpu-test
```

### Step 6: 클러스터 삭제 및 GPU 복원

```bash
# 클러스터 삭제
vagrant destroy -f

# GPU를 호스트로 복원
sudo ./unbind-vfio.sh

# GPU 확인
nvidia-smi
```

## 설정 커스터마이징

### Worker 수 및 GPU 할당 변경

`gpu-config.yaml` 에서 `worker_gpu_assignment`를 수정합니다:

```yaml
# 3개 Worker에 각각 2, 3, 3개 GPU 할당
worker_gpu_assignment:
  worker-1: [0, 1]
  worker-2: [2, 3, 4]
  worker-3: [5, 6, 7]
```

### VM 리소스 조정

```yaml
vm_resources:
  control_plane:
    memory: 8192   # 8GB
    cpus: 4
  worker:
    memory: 65536  # 64GB
    cpus: 16
```

## 문제 해결

### IOMMU 그룹 문제

GPU가 다른 디바이스와 같은 IOMMU 그룹에 있으면 passthrough가 실패할 수 있습니다:

```bash
# IOMMU 그룹 확인
for d in /sys/kernel/iommu_groups/*/devices/*; do
  n=$(basename $d)
  g=$(basename $(dirname $(dirname $d)))
  echo "Group $g: $n"
done | sort -t: -k1 -n | grep -i nvidia
```

### VM에서 GPU가 인식되지 않음

1. VFIO 바인딩 확인:
   ```bash
   ls -la /sys/bus/pci/drivers/vfio-pci/
   ```

2. VM 내부에서 PCI 디바이스 확인:
   ```bash
   vagrant ssh gpu-worker-1
   lspci | grep -i nvidia
   ```

### 드라이버 로드 실패

VM 재부팅 후 드라이버가 로드되지 않으면:
```bash
vagrant ssh gpu-worker-1
sudo modprobe nvidia
nvidia-smi
```

## 참고 자료

- [NVIDIA GPU Operator Documentation](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/)
- [Vagrant-libvirt Plugin](https://github.com/vagrant-libvirt/vagrant-libvirt)
- [VFIO PCI Passthrough Guide](https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF)
