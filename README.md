# Kubernetes Cluster Tools

로컬 Kubernetes 클러스터 구성 도구 모음입니다.

## 구성 옵션

| 디렉토리 | 방식 | GPU | IOMMU 필요 | 설명 |
|----------|------|-----|-----------|------|
| `/` (루트) | Vagrant + VirtualBox | ❌ | ❌ | 일반 K8s 테스트용 |
| `/gpu` | Vagrant + libvirt | ✅ | ✅ | GPU PCI Passthrough (프로덕션 유사) |
| `/kind` | Kind (Docker) | ✅ | ❌ | GPU 멀티노드 (간편 설정) |
| `/k3d` | k3d (k3s in Docker) | ✅ | ❌ | 기존 k3s와 공존 ⭐ **추천**

---

## 기본 클러스터 (VirtualBox)

GPU 없이 Kubernetes를 테스트하기 위한 기본 구성입니다.

### 사전 요구사항

- [Vagrant](https://developer.hashicorp.com/vagrant/downloads)
- [VirtualBox](https://www.virtualbox.org/wiki/Downloads)

### 사용 방법

```bash
# 클러스터 생성
vagrant up

# Control Plane 접속
vagrant ssh kube-control-plane

# Worker 노드 접속
vagrant ssh kube-worker-1

# 클러스터 삭제
vagrant destroy -f
```

### 구성

- **Control Plane**: 1대 (192.168.56.10)
- **Worker**: 2대 (192.168.56.21, 192.168.56.22)
- **CNI**: Calico
- **K8s Version**: 1.32.x

---

## GPU 클러스터 (libvirt + PCI Passthrough)

물리 서버의 NVIDIA GPU를 VM에 PCI Passthrough 방식으로 할당하여 멀티노드 GPU 클러스터를 구성합니다.

### 사전 요구사항

- IOMMU 지원 CPU (Intel VT-d 또는 AMD-Vi)
- NVIDIA GPU

### 사전 설치

**1. BIOS/UEFI에서 IOMMU 활성화** (1회 설정)

시스템 재부팅 후 BIOS 설정에서 다음 옵션을 활성화:
- Intel CPU: `VT-d` (Intel Virtualization Technology for Directed I/O)
- AMD CPU: `AMD-Vi` 또는 `IOMMU`

**2. 커널 파라미터 설정** (1회 설정, 재부팅 필요)

```bash
# /etc/default/grub 편집
sudo vim /etc/default/grub

# GRUB_CMDLINE_LINUX 라인에 추가:
#   Intel: GRUB_CMDLINE_LINUX="intel_iommu=on iommu=pt"
#   AMD:   GRUB_CMDLINE_LINUX="amd_iommu=on iommu=pt"

sudo update-grub && sudo reboot

# 재부팅 후 IOMMU 활성화 확인
dmesg | grep -i iommu
# "IOMMU enabled" 또는 "AMD-Vi" 메시지가 보여야 함
```

**3. libvirt 및 QEMU/KVM 설치**

```bash
sudo apt update
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils
```

**4. Vagrant 설치** (아직 없다면)

```bash
wget https://releases.hashicorp.com/vagrant/2.4.1/vagrant_2.4.1-1_amd64.deb
sudo dpkg -i vagrant_2.4.1-1_amd64.deb
```

**5. vagrant-libvirt 플러그인 설치**

```bash
sudo apt install -y libvirt-dev
vagrant plugin install vagrant-libvirt
```

### 사용 방법

```bash
cd gpu/

# 1. GPU PCI 주소 확인 및 설정
lspci | grep -i nvidia
vim gpu-config.yaml

# 2. GPU를 VFIO에 바인딩 (호스트에서 GPU 사용 불가)
sudo ./bind-vfio.sh

# 3. 클러스터 생성
vagrant up

# 4. 테스트
export KUBECONFIG=./admin.conf
kubectl get nodes
kubectl describe node gpu-worker-1 | grep nvidia

# 5. 클러스터 삭제
vagrant destroy -f

# 6. GPU를 호스트로 복원
sudo ./unbind-vfio.sh
```

자세한 내용은 [gpu/README.md](gpu/README.md)를 참조하세요.

---

## Kind GPU 클러스터 (Docker) ⭐ 추천

Docker 컨테이너 기반의 Kind로 GPU 멀티노드 클러스터를 구성합니다.
**IOMMU/BIOS 설정 변경 없이** 사용 가능합니다.

### 사전 요구사항

- Docker
- NVIDIA 드라이버
- NVIDIA Container Toolkit
- Kind, kubectl

### 사용 방법

```bash
cd kind/

# 클러스터 생성 (2 Worker x 4 GPU)
./setup.sh

# 또는 커스텀 설정 (4 Worker x 2 GPU)
./setup.sh 4 2

# 노드 확인
kubectl get nodes -L gpu-worker,gpu-ids

# GPU 테스트
kubectl run gpu-test --rm -it --restart=Never \
  --image=nvidia/cuda:12.0-base \
  --limits=nvidia.com/gpu=1 \
  -- nvidia-smi

# 클러스터 삭제
./teardown.sh
```

자세한 내용은 [kind/README.md](kind/README.md)를 참조하세요.

---

## k3d GPU 클러스터 ⭐ **추천**

k3d(k3s in Docker)로 GPU 멀티노드 클러스터를 구성합니다.
**기존 k3s 클러스터와 충돌 없이 공존**할 수 있습니다.

### 장점

- 이미 k3s를 사용 중이라면 가장 자연스러운 선택
- 기존 k3s 단일 노드를 유지하면서 멀티노드 테스트 가능
- context 전환으로 두 환경 간 쉽게 이동

### 사전 요구사항

- Docker
- NVIDIA 드라이버 + Container Toolkit
- k3d (`curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash`)

### 사용 방법

```bash
cd k3d/

# 클러스터 생성 (2 Worker x 4 GPU)
./setup.sh

# 또는 커스텀 설정 (4 Worker x 2 GPU)
./setup.sh 4 2

# 노드 확인
kubectl get nodes -L gpu-worker,gpu-ids

# 기존 k3s로 전환
kubectl config use-context default

# k3d 클러스터로 전환
kubectl config use-context k3d-gpu-cluster

# 클러스터 삭제
./teardown.sh
```

자세한 내용은 [k3d/README.md](k3d/README.md)를 참조하세요.

---

## 파일 구조

```
vagrant_k8s/
├── Vagrantfile              # VirtualBox 기본 클러스터
├── common.sh                # K8s 공통 설정 스크립트
├── control-plane.sh         # Control Plane 초기화
├── worker.sh                # Worker 조인
├── setup.sh                 # 추가 설정
├── admin.conf               # kubeconfig (생성 후)
│
├── k3d/                     # k3d GPU 클러스터 ⭐ 추천
│   ├── setup.sh             # 클러스터 생성 (기존 k3s와 공존)
│   ├── teardown.sh          # 클러스터 삭제
│   └── README.md
│
├── kind/                    # Kind GPU 클러스터
│   ├── setup.sh             # 클러스터 생성
│   ├── teardown.sh          # 클러스터 삭제
│   ├── kind-config.yaml     # Kind 설정
│   └── README.md
│
└── gpu/                     # GPU 클러스터 (libvirt + PCI Passthrough)
    ├── Vagrantfile          # libvirt + PCI passthrough
    ├── gpu-config.yaml      # GPU PCI 주소 설정
    ├── bind-vfio.sh         # GPU -> VFIO 바인딩
    ├── unbind-vfio.sh       # GPU -> nvidia 복원
    ├── common-gpu.sh        # K8s + NVIDIA 드라이버
    ├── control-plane-gpu.sh
    ├── worker-gpu.sh
    ├── setup-gpu-operator.sh
    └── README.md
```

## 라이선스

MIT
