# vim: filetype=dockerfile

ARG FLAVOR=${TARGETARCH}
ARG ROCMVERSION=6.3.3
ARG JETPACK5VERSION=r35.4.1
ARG JETPACK6VERSION=r36.4.0
ARG CMAKEVERSION=3.27.6  # Последняя стабильная версия
ARG GOVERSION=1.22.0     # Последняя стабильная версия Go

FROM --platform=linux/amd64 rocm/dev-almalinux-8:${ROCMVERSION}-complete AS base-amd64
RUN yum install -y yum-utils \
    && yum-config-manager --add-repo https://dl.rockylinux.org/vault/rocky/8.5/AppStream/\$basearch/os/ \
    && rpm --import https://dl.rockylinux.org/pub/rocky/RPM-GPG-KEY-Rocky-8 \
    && dnf install -y yum-utils ccache gcc-toolset-10-gcc gcc-toolset-10-gcc-c++ --nodocs \
    && yum-config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel8/x86_64/cuda-rhel8.repo \
    && dnf clean all
ENV PATH=/opt/rh/gcc-toolset-10/root/usr/bin:$PATH

FROM --platform=linux/arm64 almalinux:8 AS base-arm64
RUN yum install -y yum-utils epel-release \
    && dnf install -y clang ccache --nodocs \
    && yum-config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel8/sbsa/cuda-rhel8.repo \
    && dnf clean all
ENV CC=clang CXX=clang++

FROM base-${TARGETARCH} AS base
ARG CMAKEVERSION
RUN wget -q https://github.com/Kitware/CMake/releases/download/v${CMAKEVERSION}/cmake-${CMAKEVERSION}-linux-$(uname -m).tar.gz -O cmake.tar.gz \
    && tar xzf cmake.tar.gz -C /usr/local --strip-components 1 \
    && rm -f cmake.tar.gz
COPY CMakeLists.txt CMakePresets.json .
COPY ml/backend/ggml/ggml ml/backend/ggml/ggml
ENV LDFLAGS=-s

FROM base AS cpu
RUN dnf install -y gcc-toolset-11-gcc gcc-toolset-11-gcc-c++ --nodocs && dnf clean all
ENV PATH=/opt/rh/gcc-toolset-11/root/usr/bin:$PATH
RUN cmake --preset 'CPU' \
    && cmake --build --parallel --preset 'CPU' \
    && cmake --install build --component CPU --strip

FROM base AS cuda-11
ARG CUDA11VERSION=11.8
RUN dnf install -y cuda-toolkit-${CUDA11VERSION//./-} --nodocs && dnf clean all
ENV PATH=/usr/local/cuda-11/bin:$PATH
RUN cmake --preset 'CUDA 11' \
    && cmake --build --parallel --preset 'CUDA 11' \
    && cmake --install build --component CUDA --strip

FROM base AS cuda-12
ARG CUDA12VERSION=12.4
RUN dnf install -y cuda-toolkit-${CUDA12VERSION//./-} --nodocs && dnf clean all
ENV PATH=/usr/local/cuda-12/bin:$PATH
RUN cmake --preset 'CUDA 12' \
    && cmake --build --parallel --preset 'CUDA 12' \
    && cmake --install build --component CUDA --strip

FROM base AS rocm-6
ENV PATH=/opt/rocm/hcc/bin:/opt/rocm/hip/bin:/opt/rocm/bin:/opt/rocm/hcc/bin:$PATH
RUN cmake --preset 'ROCm 6' \
    && cmake --build --parallel --preset 'ROCm 6' \
    && cmake --install build --component HIP --strip

FROM --platform=linux/arm64 nvcr.io/nvidia/l4t-jetpack:${JETPACK5VERSION} AS jetpack-5
ARG CMAKEVERSION
RUN apt-get update && apt-get install -y wget ccache \
    && wget -q https://github.com/Kitware/CMake/releases/download/v${CMAKEVERSION}/cmake-${CMAKEVERSION}-linux-$(uname -m).tar.gz -O cmake.tar.gz \
    && tar xzf cmake.tar.gz -C /usr/local --strip-components 1 \
    && rm -f cmake.tar.gz
COPY CMakeLists.txt CMakePresets.json .
COPY ml/backend/ggml/ggml ml/backend/ggml/ggml
RUN cmake --preset 'JetPack 5' \
    && cmake --build --parallel --preset 'JetPack 5' \
    && cmake --install build --component CUDA --strip

FROM --platform=linux/arm64 nvcr.io/nvidia/l4t-jetpack:${JETPACK6VERSION} AS jetpack-6
ARG CMAKEVERSION
RUN apt-get update && apt-get install -y wget ccache \
    && wget -q https://github.com/Kitware/CMake/releases/download/v${CMAKEVERSION}/cmake-${CMAKEVERSION}-linux-$(uname -m).tar.gz -O cmake.tar.gz \
    && tar xzf cmake.tar.gz -C /usr/local --strip-components 1 \
    && rm -f cmake.tar.gz
COPY CMakeLists.txt CMakePresets.json .
COPY ml/backend/ggml/ggml ml/backend/ggml/ggml
RUN cmake --preset 'JetPack 6' \
    && cmake --build --parallel --preset 'JetPack 6' \
    && cmake --install build --component CUDA --strip

FROM base AS build
ARG GOVERSION
RUN if [ "$(uname -m)" = "x86_64" ]; then GOARCH=amd64; else GOARCH=$(uname -m); fi \
    && wget -q https://go.dev/dl/go${GOVERSION}.linux-${GOARCH}.tar.gz -O go.tar.gz \
    && tar xzf go.tar.gz -C /usr/local \
    && rm -f go.tar.gz
ENV PATH=/usr/local/go/bin:$PATH
WORKDIR /go/src/github.com/ollama/ollama
COPY . .
ARG GOFLAGS="'-ldflags=-w -s'"
ENV CGO_ENABLED=1
RUN go build -trimpath -buildmode=pie -o /bin/ollama .

FROM scratch AS amd64
COPY --from=cuda-11 dist/lib/ollama/cuda_v11 /lib/ollama/cuda_v11
COPY --from=cuda-12 dist/lib/ollama/cuda_v12 /lib/ollama/cuda_v12

FROM scratch AS arm64
COPY --from=cuda-11 dist/lib/ollama/cuda_v11 /lib/ollama/cuda_v11
COPY --from=cuda-12 dist/lib/ollama/cuda_v12 /lib/ollama/cuda_v12
COPY --from=jetpack-5 dist/lib/ollama/cuda_v11 lib/ollama/cuda_jetpack5
COPY --from=jetpack-6 dist/lib/ollama/cuda_v12 lib/ollama/cuda_jetpack6

FROM scratch AS rocm
COPY --from=rocm-6 dist/lib/ollama/rocm /lib/ollama/rocm

FROM ${FLAVOR} AS archive
COPY --from=cpu dist/lib/ollama /lib/ollama
COPY --from=build /bin/ollama /bin/ollama

FROM ubuntu:20.04
RUN apt-get update \
    && apt-get install -y ca-certificates \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
COPY --from=archive /bin /usr/bin
COPY --from=archive /lib/ollama /usr/lib/ollama
ENV OLLAMA_HOST=0.0.0.0:11434
EXPOSE 11434
ENTRYPOINT ["/bin/ollama"]
CMD ["serve"]
