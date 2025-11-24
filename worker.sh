#!/usr/bin/env bash
set -euo pipefail

#############################################
# Ubuntu K8s Worker 초기화 스크립트
# - kubeadm + containerd
# - 마스터에 join 까지 자동 수행
#
# 사용 예시:
#   MASTER_IP=192.168.0.2 \
#   NODE_HOST=k8s-worker1 \
#   JOIN_COMMAND="kubeadm join 192.168.0.2:6443 --token ... --discovery-token-ca-cert-hash sha256:..." \
#   bash worker.sh
#############################################

# ===== [0] 기본 변수 =====
MASTER_IP="${MASTER_IP:-}"                     # 마스터 노드의 IP (예: 192.168.0.2)
NODE_HOST="${NODE_HOST:-k8s-worker}"           # 워커 노드 호스트명
JOIN_COMMAND="${JOIN_COMMAND:-}"               # kubeadm join ... 전체 문자열

echo "==> [CONFIG] Master IP    : ${MASTER_IP:-<EMPTY>}"
echo "==> [CONFIG] Node Hostname: ${NODE_HOST}"
echo "==> [CONFIG] Join Command : ${JOIN_COMMAND:-<EMPTY>}"

if [[ -z "${MASTER_IP}" ]]; then
  echo "ERROR: MASTER_IP 환경 변수가 비어 있습니다."
  echo "예) MASTER_IP=192.168.0.2 NODE_HOST=k8s-worker1 JOIN_COMMAND=\"kubeadm join ...\" bash worker.sh"
  exit 1
fi

if [[ -z "${JOIN_COMMAND}" ]]; then
  echo "ERROR: JOIN_COMMAND 환경 변수가 비어 있습니다."
  echo "마스터 노드에서 다음 명령으로 join 커맨드를 얻을 수 있습니다:"
  echo "  kubeadm token create --print-join-command"
  exit 1
fi

# 이미 kubeadm으로 초기화된 워커인지 확인 (중복 join 방지)
if [[ -f /etc/kubernetes/kubelet.conf ]]; then
  echo "ERROR: /etc/kubernetes/kubelet.conf 가 존재합니다."
  echo "이미 kubeadm으로 초기화된 노드로 보입니다."
  echo "정말 새로 join 하려면 먼저 아래를 실행하세요:"
  echo "  sudo kubeadm reset -f"
  echo "  sudo rm -rf /etc/cni/net.d"
  exit 1
fi

# ===== [1] 호스트명 및 기본 세팅 =====
echo "==> 호스트명 설정: ${NODE_HOST}"
sudo hostnamectl set-hostname "${NODE_HOST}"

echo "==> 시간/타임존/필수 패키지 설치"
sudo timedatectl set-timezone Asia/Seoul || true

sudo apt-get update -y
sudo apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  software-properties-common

echo "==> 스왑 비활성화"
sudo swapoff -a
sudo sed -ri '/\sswap\s/s/^/#/' /etc/fstab

echo "==> UFW(있다면) 비활성화"
if systemctl is-enabled --quiet ufw; then
  sudo systemctl stop ufw || true
  sudo systemctl disable ufw || true
fi

echo "==> /etc/hosts에 마스터 IP/호스트 추가 (참고용)"
if ! grep -q "${MASTER_IP}" /etc/hosts; then
  echo "${MASTER_IP} k8s-master" | sudo tee -a /etc/hosts
fi

# ===== [2] 커널 모듈 & sysctl =====
echo "==> 커널 모듈 (overlay, br_netfilter) 및 sysctl 설정"
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system

# ===== [3-A] containerd 설치 (없을 경우 자동 설치) =====
echo "==> containerd 설치 여부 확인"
if ! command -v containerd &>/dev/null; then
  echo "==> containerd가 없어 자동 설치 진행"

  sudo apt-get update -y

  # Docker 공식 레포 추가
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  # Ubuntu 버전 정보 로드
  . /etc/os-release

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  sudo apt-get update -y
  sudo apt-get install -y containerd.io

  echo "==> containerd 설치 완료"
else
  echo "==> containerd 이미 설치됨"
fi

# ===== [3-B] containerd SystemdCgroup 설정 보정 =====
echo "==> containerd SystemdCgroup 설정 보정"
if [ ! -f /etc/containerd/config.toml ]; then
  echo "  -> /etc/containerd/config.toml 이 없어 기본 설정 생성"
  sudo mkdir -p /etc/containerd
  containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
fi

sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml || true

sudo systemctl daemon-reload
sudo systemctl enable --now containerd || true
sudo systemctl restart containerd || true

# ===== [4] Kubernetes repo & 설치 (v1.28) =====
echo "==> Kubernetes apt repo 추가 (pkgs.k8s.io / v1.28)"
sudo mkdir -p /etc/apt/keyrings

# 이전 키/리스트가 있다면 제거 (없어도 에러 무시)
sudo rm -f /etc/apt/sources.list.d/kubernetes*.list /etc/apt/keyrings/kubernetes-*.gpg || true

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

echo "==> kubelet / kubeadm / kubectl 설치"
sudo apt-get update -y
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

sudo systemctl enable --now kubelet

# ===== [5] kubeadm join =====
echo "==> kubeadm join 실행 (마스터에 워커 노드 등록)"
echo "JOIN_COMMAND: ${JOIN_COMMAND}"
sudo ${JOIN_COMMAND}

echo "✅ Ubuntu K8s Worker 설치 및 마스터 조인 완료!"
echo "마스터 노드에서 다음 명령으로 워커 상태를 확인할 수 있습니다:"
echo "  kubectl get nodes -o wide"
