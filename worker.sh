#!/usr/bin/env bash
set -euo pipefail

###########################################################
# Ubuntu K8s Worker 초기화 스크립트 (템플릿)
#
# [사용 방법]
# 1) 마스터에서 join 명령 가져오기:
#      kubeadm token create --print-join-command
#
# 2) 워커 노드에서:
#      MASTER_IP=192.168.0.10 \
#      NODE_HOST=k8s-worker1 \
#      JOIN_COMMAND="kubeadm join 192.168.0.10:6443 --token xxx --discovery-token-ca-cert-hash sha256:yyyy" \
#      bash worker.sh
#
#  - MASTER_IP   : 마스터 노드 IP (마스터 API 서버/hosts 등록용)
#  - NODE_HOST   : (선택) 이 워커 노드의 hostname (기본: 변경 안 함)
#  - JOIN_COMMAND: 마스터에서 복사한 kubeadm join 명령 전체
###########################################################

MASTER_IP="${MASTER_IP:-}"
MASTER_HOST="${MASTER_HOST:-k8s-master}"   # 마스터 호스트명 (hosts에 등록용)
NODE_HOST="${NODE_HOST:-}"                 # 워커 노드 hostname (옵션)
JOIN_COMMAND="${JOIN_COMMAND:-}"

echo "==> [CONFIG] Master IP   : ${MASTER_IP:-<EMPTY>}"
echo "==> [CONFIG] Master Host : ${MASTER_HOST}"
echo "==> [CONFIG] Node Host   : ${NODE_HOST:-<KEEP_CURRENT>}"

if [[ -z "${MASTER_IP}" ]]; then
  echo "ERROR: MASTER_IP 환경 변수가 비어 있습니다."
  echo "예) MASTER_IP=192.168.0.10 NODE_HOST=k8s-worker1 JOIN_COMMAND=\"...\" bash worker.sh"
  exit 1
fi

if [[ -z "${JOIN_COMMAND}" ]]; then
  echo "ERROR: JOIN_COMMAND 환경 변수가 비어 있습니다."
  echo "마스터에서 아래 명령으로 join 명령을 얻은 뒤 그대로 넣어주세요:"
  echo "  kubeadm token create --print-join-command"
  echo
  echo "예) JOIN_COMMAND=\"kubeadm join 192.168.0.10:6443 --token xxx --discovery-token-ca-cert-hash sha256:yyyy\""
  exit 1
fi

# ===== [1] hostname 및 기본 세팅 =====
if [[ -n "${NODE_HOST}" ]]; then
  echo "==> 호스트명 설정: ${NODE_HOST}"
  sudo hostnamectl set-hostname "${NODE_HOST}"
else
  echo "==> 호스트명은 변경하지 않고 유지합니다."
fi

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

echo "==> /etc/hosts에 마스터 IP/호스트 추가"
if ! grep -q "${MASTER_IP} ${MASTER_HOST}" /etc/hosts; then
  echo "${MASTER_IP} ${MASTER_HOST}" | sudo tee -a /etc/hosts
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

# ===== [3] containerd SystemdCgroup 설정 =====
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

# ===== [4] Kubernetes repo & kubelet/kubeadm 설치 =====
echo "==> Kubernetes apt repo 추가 (pkgs.k8s.io / v1.28)"
sudo mkdir -p /etc/apt/keyrings

sudo rm -f /etc/apt/sources.list.d/kubernetes*.list /etc/apt/keyrings/kubernetes-*.gpg || true

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

echo "==> kubelet / kubeadm 설치"
sudo apt-get update -y
sudo apt-get install -y kubelet kubeadm
sudo apt-mark hold kubelet kubeadm

sudo systemctl enable --now kubelet

# ===== [5] 마스터에 join =====
echo "==> kubeadm join 실행"
echo "JOIN_COMMAND: ${JOIN_COMMAND}"
# JOIN_COMMAND 예: "kubeadm join 192.168.0.10:6443 --token xxx --discovery-token-ca-cert-hash sha256:yyyy"
# sudo로 실행
eval "sudo ${JOIN_COMMAND}"

echo "✅ Worker 노드가 마스터에 성공적으로 join 되었을 가능성이 높습니다!"
echo "마스터에서 다음 명령으로 확인하세요:"
echo "  kubectl get nodes -o wide"
