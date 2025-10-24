#!/usr/bin/env bash
set -euo pipefail

# ===== [0] 기본 정보 =====
POD_CIDR="20.96.0.0/12"
MASTER_IP="$(hostname -I | awk '{print $1}')"   # 필요 시 고정 IP로 교체
MASTER_HOST="k8s-master"
CTR_RPM="containerd.io-1.6.21-3.1.el8"
K8S_VER_RPM="1.27.2-150500.1.1.x86_64"          # yum에서 쓰는 표기

echo "==> Master IP: ${MASTER_IP}"
hostnamectl set-hostname "${MASTER_HOST}"

# ===== [1] 기본 세팅 =====
echo "==> 타임존/시간 동기화"
timedatectl set-timezone Asia/Seoul || true
timedatectl set-ntp true || true
(chronyc makestep || true) 2>/dev/null || true
yum install -y chrony && systemctl enable --now chronyd || true

echo "==> 스왑 비활성화"
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

echo "==> 방화벽 비활성화"
systemctl stop firewalld || true
systemctl disable firewalld || true

echo "==> hosts 등록"
if ! grep -q "${MASTER_IP} ${MASTER_HOST}" /etc/hosts; then
  echo "${MASTER_IP} ${MASTER_HOST}" >> /etc/hosts
fi

echo "==> tc 경고 방지"
yum install -y yum-utils iproute-tc

# ===== [2] 커널 모듈/네트워킹 =====
echo "==> 커널 모듈 및 sysctl"
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# ===== [3] containerd 설치 =====
echo "==> Docker CE repo 추가"
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

echo "==> containerd 설치"
yum install -y ${CTR_RPM}
systemctl daemon-reload
systemctl enable --now containerd

echo "==> containerd systemd cgroup"
containerd config default > /etc/containerd/config.toml
sed -i 's/ SystemdCgroup = false/ SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd

# ===== [4] Kubernetes 1.27 repo & 설치 =====
echo "==> k8s 1.27 repo"
cat <<'EOF' | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.27/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.27/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

echo "==> SELinux permissive"
setenforce 0 || true
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

echo "==> kubelet/kubeadm/kubectl 설치"
yum install -y \
  kubelet-${K8S_VER_RPM} \
  kubeadm-${K8S_VER_RPM} \
  kubectl-${K8S_VER_RPM} \
  --disableexcludes=kubernetes

systemctl enable --now kubelet

# ===== [5] kubeadm init =====
echo "==> kubeadm init"
kubeadm init \
  --pod-network-cidr="${POD_CIDR}" \
  --apiserver-advertise-address "${MASTER_IP}"

echo "==> admin kubeconfig 세팅"
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown "$(id -u):$(id -g)" $HOME/.kube/config

# ===== [6] Calico 설치 (너의 레포 사용) =====
echo "==> Calico 설치"
kubectl create -f https://raw.githubusercontent.com/jaewoo-rain/kubernetes/main/ground/k8s-1.27/calico-3.26.4/calico.yaml
kubectl create -f https://raw.githubusercontent.com/jaewoo-rain/kubernetes/main/ground/k8s-1.27/calico-3.26.4/calico-custom.yaml

# ===== [7] master 스케줄 허용 (단일노드용) =====
kubectl taint nodes "${MASTER_HOST}" node-role.kubernetes.io/control-plane- || true

# ===== [8] 편의기능 =====
echo "==> kubectl 자동완성"
echo 'source <(kubectl completion bash)' >> ~/.bashrc
echo 'alias k=kubectl' >> ~/.bashrc
echo 'complete -o default -F __start_kubectl k' >> ~/.bashrc

echo "✅ Rocky Linux 단일 노드 K8s 1.27 설치 완료!"
kubectl get nodes -o wide
