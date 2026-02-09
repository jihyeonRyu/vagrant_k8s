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

## 사전 요구사항 (중요!)

GPU PCI Passthrough를 위해서는 **BIOS 설정**과 **커널 파라미터** 설정이 모두 필요합니다.

### 1. BIOS 설정 (관리자 권한 필요)

서버 BIOS에서 다음 두 가지를 **모두** 활성화해야 합니다:

| 설정 | 용도 | 확인 방법 |
|------|------|----------|
| **VT-x** (Intel Virtualization Technology) | VM 실행 | `ls /dev/kvm` 존재 여부 |
| **VT-d** (Intel VT for Directed I/O) | GPU 패스스루 | `ls /sys/kernel/iommu_groups/ \| wc -l` > 0 |

> **주의**: VT-x와 VT-d는 별개 설정입니다. VT-x만으로는 GPU 패스스루가 불가능합니다.

### 2. 커널 파라미터 설정

**1회성 설정으로, 재부팅이 필요합니다.**

```bash
# /etc/default/grub 편집
sudo vim /etc/default/grub

# Intel CPU의 경우 - GRUB_CMDLINE_LINUX 또는 GRUB_CMDLINE_LINUX_DEFAULT에 추가:
intel_iommu=on iommu=pt

# AMD CPU의 경우:
amd_iommu=on iommu=pt

# 예시 (RHEL/CentOS):
GRUB_CMDLINE_LINUX_DEFAULT="intel_iommu=on iommu=pt"

# GRUB 업데이트
# Ubuntu/Debian:
sudo update-grub

# RHEL/CentOS (EFI):
sudo grub2-mkconfig -o /boot/efi/EFI/redhat/grub.cfg

# RHEL/CentOS (Legacy BIOS):
sudo grub2-mkconfig -o /boot/grub2/grub.cfg

# 재부팅
sudo reboot
```

### 3. 설정 확인 (재부팅 후)

```bash
# 1. VT-x 확인 (KVM 사용 가능)
ls /dev/kvm
# /dev/kvm 파일이 존재해야 함

# 2. VT-d/IOMMU 확인 (GPU 패스스루 가능)
ls /sys/kernel/iommu_groups/ | wc -l
# 0보다 커야 함 (정상: 수십~수백 개)

# 3. 커널 파라미터 확인
cat /proc/cmdline | grep -E "intel_iommu|amd_iommu"
# intel_iommu=on 또는 amd_iommu=on 이 보여야 함
```

**문제 해결:**
- `/dev/kvm` 없음 → BIOS에서 VT-x 활성화 필요
- IOMMU 그룹 0개 → BIOS에서 VT-d 활성화 필요
- 커널 파라미터 없음 → `/etc/default/grub` 수정 후 재부팅

### 4. 호스트 시스템 요구사항

- RHEL 9 / Ubuntu 22.04 이상
- NVIDIA GPU (테스트됨: H100 SXM5, A100)
- 최소 128GB RAM (Worker VM당 64GB 권장)
- IOMMU 지원 CPU (Intel VT-d 또는 AMD-Vi)

### 5. 필수 소프트웨어 설치

```bash
# libvirt 및 QEMU/KVM 설치
sudo apt update
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils

# sudo dnf install -y qemu-kvm libvirt virt-install
# sudo systemctl enable --now libvirtd

# Vagrant 설치
wget https://releases.hashicorp.com/vagrant/2.4.1/vagrant_2.4.1-1_amd64.deb
sudo dpkg -i vagrant_2.4.1-1_amd64.deb

# newgrp libvirt
# 맞는 버전 다운로드
# curl -LO https://dl.rockylinux.org/vault/rocky/9.2/CRB/x86_64/os/Packages/l/libvirt-devel-9.0.0-10.3.el9_2.x86_64.rpm

# 파일 크기 확인 (약 200KB)
# ls -la libvirt-devel-*.rpm

# 설치
# sudo rpm -ivh --nodeps libvirt-devel-9.0.0-10.3.el9_2.x86_64.rpm

# vagrant-libvirt 플러그인 설치
# vagrant plugin install vagrant-libvirt

# vagrant-libvirt 플러그인 설치
sudo apt install -y libvirt-dev
vagrant plugin install vagrant-libvirt

# KVM 모듈 로드
sudo modprobe kvm
sudo modprobe kvm_intel

# /dev/kvm 확인
ls -la /dev/kvm

# CPU 가상화 플래그 확인
grep -E "vmx" /proc/cpuinfo | head -1

sudo virsh net-destroy default
sudo virsh net-undefine default
sudo virsh net-list --all

# 1. vfio-pci 모듈 로드 확인
lsmod | grep vfio

# 2. 없으면 로드
sudo modprobe vfio-pci

ls /sys/kernel/iommu_groups/ | wc -l
# 0보다 커야 정상

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

### Step 2: GPU 사용 서비스 중지

VFIO 바인딩 전에 GPU를 사용하는 모든 프로세스를 중지해야 합니다.

```bash
# 1. NVIDIA 관련 서비스 중지
sudo systemctl stop containerd
sudo systemctl stop nvidia-fabricmanager
sudo systemctl stop nvidia-persistenced

# 2. GPU 사용 프로세스 확인 (0이어야 함)
sudo lsof /dev/nvidia* 2>/dev/null | wc -l

# 3. 프로세스가 남아있으면 강제 종료
sudo lsof /dev/nvidia* 2>/dev/null | awk 'NR>1 {print $2}' | sort -u | xargs -r sudo kill -9
```

### Step 3: GPU를 VFIO에 바인딩

GPU를 VFIO 드라이버에 바인딩합니다.

> ⚠️ **주의**: 이 단계 이후 호스트에서 GPU를 사용할 수 없습니다!

```bash
sudo ./bind-vfio.sh

# 바인딩 확인 (vfio-pci가 보여야 함)
lspci -nnk -d 10de: | grep -E "(3D controller|driver)"
```

### Step 4: 클러스터 생성

```bash
vagrant up


# on host-side (if turned-off)
sudo systemctl start containerd nvidia-fabricmanager
```

프로비저닝은 약 10-15분 소요됩니다:
1. Control Plane VM 생성 및 K8s 초기화
2. Worker VM 생성 (GPU Passthrough 포함)
3. 각 Worker가 클러스터에 조인
4. GPU Operator 설치

### Step 5: 클러스터 접속 및 확인

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

### Step 6: GPU 테스트

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

### Step 7: 클러스터 삭제 및 GPU 복원

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


## Issue Handling
```

# gpu usage check 
# sudo lsof /dev/nvidia* 2>/dev/null | wc -l

# process check
sudo lsof /dev/nvidia*
ps -p <pid> -o pid,comm,args


sudo systemctl stop singularity.dcgm-exporter.service
kubectl delete daemonset nvidia-device-plugin-daemonset -n kube-system
sudo systemctl stop containerd nvidia-fabricmanager nvidia-persistenced

# 모든 GPU가 물리적으로 존재하는지 확인
lspci | grep -i nvidia | grep "3D controller"

########### At the end #############
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.5/nvidia-device-plugin.yml

vagrant destroy -f
sudo ./unbind-vfio.sh
sudo systemctl start containerd nvidia-fabricmanager nvidia-persistenced

```


## GPU Pod Test
```bash

kubectl run cuda-test3 --rm -i --restart=Never \
  --image=nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.1 \
  --overrides='{
    "spec": {
      "runtimeClassName": "nvidia",
      "tolerations": [{"key": "nvidia.com/gpu", "operator": "Exists", "effect": "NoSchedule"}],
      "containers": [{
        "name": "cuda-test3",
        "image": "nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.1",
        "command": ["python3", "-c", "import torch; print(\"CUDA:\", torch.cuda.is_available()); print(\"Devices:\", torch.cuda.device_count()); print(\"SUCCESS\" if torch.cuda.is_available() else \"FAILED\")"],
        "resources": {"limits": {"nvidia.com/gpu": "1"}},
        "env": [{"name": "NVIDIA_VISIBLE_DEVICES", "value": "all"}, {"name": "NVIDIA_DRIVER_CAPABILITIES", "value": "all"}]
      }]
    }
  }' \
  -n dynamo-system


# gpu-worker
# VM 호스트에서 직접 CUDA 테스트 (컨테이너 X)
python3 -c "import ctypes; lib = ctypes.CDLL('libcuda.so.1'); print('cuInit:', lib.cuInit(0))"
```