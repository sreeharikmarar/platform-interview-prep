FROM ubuntu:22.04

ARG TARGETARCH

# Avoid interactive prompts during package install
ENV DEBIAN_FRONTEND=noninteractive

# Install all tools needed for topics 01-04
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Kernel / namespace tools
    util-linux \
    iproute2 \
    iptables \
    iputils-ping \
    strace \
    libcap2-bin \
    procps \
    conntrack \
    kmod \
    # Container runtimes
    runc \
    containerd \
    busybox-static \
    # Docker CLI (no daemon — talks to host Docker via socket mount)
    docker.io \
    # General utilities
    python3 \
    jq \
    curl \
    file \
    vim-tiny \
    less \
    cgroup-tools \
    net-tools \
  && rm -rf /var/lib/apt/lists/*

# Install crictl (multi-arch)
RUN CRICTL_VERSION="v1.28.0" && \
    curl -sSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${TARGETARCH}.tar.gz" \
      | tar -xz -C /usr/local/bin/ && \
    chmod +x /usr/local/bin/crictl

# Configure crictl to use containerd
RUN mkdir -p /etc && printf '%s\n' \
    'runtime-endpoint: unix:///run/containerd/containerd.sock' \
    'image-endpoint: unix:///run/containerd/containerd.sock' \
    'timeout: 10' \
    'debug: false' \
    > /etc/crictl.yaml

# Copy lab directories
COPY weeks/week-00-linux-containers-and-cloud-networking/01-linux-processes-signals-and-filesystem/lab/ /labs/01/
COPY weeks/week-00-linux-containers-and-cloud-networking/02-cgroups-and-namespaces/lab/ /labs/02/
COPY weeks/week-00-linux-containers-and-cloud-networking/03-container-internals-oci-and-runtimes/lab/ /labs/03/
COPY weeks/week-00-linux-containers-and-cloud-networking/04-container-networking-cni-and-pod-model/lab/ /labs/04/

# Make lab scripts executable
RUN find /labs -name '*.sh' -exec chmod +x {} +

# Install entrypoint
COPY weeks/week-00-linux-containers-and-cloud-networking/lab-entrypoint.sh /usr/local/bin/lab-entrypoint.sh
RUN chmod +x /usr/local/bin/lab-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/lab-entrypoint.sh"]
CMD ["/bin/bash"]
