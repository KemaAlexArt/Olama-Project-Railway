# vim: filetype=dockerfile

ARG FLAVOR=${TARGETARCH}
ARG ROCMVERSION=6.3.3
ARG JETPACK5VERSION=r35.4.1
ARG JETPACK6VERSION=r36.4.0
ARG CMAKEVERSION=3.27.6  # Последняя стабильная версия
ARG GOVERSION=1.22.0     # Исправлено с 1.23.4

FROM --platform=linux/amd64 rocm/dev-almalinux-8:${ROCMVERSION}-complete AS base-amd64
RUN yum install -y yum-utils \
    && yum-config-manager --add-repo https://dl.rockylinux.org/vault/rocky/8.5/AppStream/\$basearch/os/ \
    && rpm --import https://dl.rockylinux.org/pub/rocky/RPM-GPG-KEY-Rocky-8 \
    && dnf install -y yum-utils ccache gcc-toolset-10-gcc gcc-toolset-10-gcc-c++ \
    && yum-config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel8/x86_64/cuda-rhel8.repo \
    && dnf clean all
ENV PATH=/opt/rh/gcc-toolset-10/root/usr/bin:$PATH

FROM --platform=linux/arm64 almalinux:8 AS base-arm64
RUN yum install -y yum-utils epel-release \
    && dnf install -y clang ccache \
    && yum-config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel8/sbsa/cuda-rhel8.repo \
    && dnf clean all
ENV CC=clang CXX=clang++

FROM base-${TARGETARCH} AS base
RUN curl -fsSL --no-check-certificate https://github.com/Kitware/CMake/releases/download/v${CMAKEVERSION}/cmake-${CMAKEVERSION}-linux-$(uname -m).tar.gz | tar xz -C /usr/local --strip-components 1 \
    || (echo "Ошибка загрузки CMake! Проверьте версию." && exit 1)
COPY CMakeLists.txt CMakePresets.json .
COPY ml/backend/ggml/ggml ml/backend/ggml/ggml
ENV LDFLAGS=-s

FROM base AS cpu
RUN dnf install -y gcc-toolset-11-gcc gcc-toolset-11-gcc-c++ \
    && dnf clean all
ENV PATH=/opt/rh/gcc-toolset-11/root/usr/bin:$PATH
RUN cmake --preset 'CPU' \
    && cmake --build --parallel --preset 'CPU' \
    && cmake --install build --component CPU --strip --parallel 8

FROM base AS cuda-11
ARG CUDA11VERSION=11.8  # Исправлено с 11.3
RUN dnf install -y cuda-toolkit-${CUDA11VERSION//./-} \
    && dnf clean all
ENV PATH=/usr/local/cuda-11/bin:$PATH
RUN cmake --preset 'CUDA 11' \
    && cmake --build --parallel --preset 'CUDA 11' \
    && cmake --install build --component CUDA --strip --parallel 8

FROM base AS cuda-12
ARG CUDA12VERSION=12.4  # Исправлено с 12.8
RUN dnf install -y cuda-toolkit-${CUDA12VERSION//./-} \
    && dnf clean all
ENV PATH=/usr/local/cuda-12/bin:$PATH
RUN cmake --preset 'CUDA 12' \
    && cmake --build --parallel --preset 'CUDA 12' \
    && cmake --install build --component CUDA --strip --parallel 8

FROM base AS rocm-6
ENV PATH=/opt/rocm/hcc/bin:/opt/rocm/hip/bin:/opt/rocm/bin:/opt/rocm/hcc/bin:$PATH
RUN cmake --preset 'ROCm 6' \
    && cmake --build --parallel --preset 'ROCm 6' \
    && cmake --install build --component HIP --strip --parallel 8

FROM --platform=linux/arm64 nvcr.io/nvidia/l4t-jetpack:${JETPACK5VERSION} AS jetpack-5
RUN apt-get update && apt-get install -y curl ccache \
    && curl -fsSL --no-check-certificate https://github.com/Kitware/CMake/releases/download/v${CMAKEVERSION}/cmake-${CMAKEVERSION}-linux-$(uname -m).tar.gz | tar xz -C /usr/local --strip-components 1
COPY CMakeLists.txt CMakePresets.json .
COPY ml/backend/ggml/ggml ml/backend/ggml/ggml
RUN cmake --preset 'JetPack 5' \
    && cmake --build --parallel --preset 'JetPack 5' \
    && cmake --install build --component CUDA --strip --parallel 8

FROM --platform=linux/arm64 nvcr.io/nvidia/l4t-jetpack:${JETPACK6VERSION} AS jetpack-6
RUN apt-get update && apt-get install -y curl ccache \
    && curl -fsSL --no-check-certificate https://github.com/Kitware/CMake/releases/download/v${CMAKEVERSION}/cmake-${CMAKEVERSION}-linux-$(uname -m).tar.gz | tar xz -C /usr/local --strip-components 1
COPY CMakeLists.txt CMakePresets.json .
COPY ml/backend/ggml/ggml ml/backend/ggml/ggml
RUN cmake --preset 'JetPack 6' \
    && cmake --build --parallel --preset 'JetPack 6' \
    && cmake --install build --component CUDA --strip --parallel 8

FROM base AS build
RUN curl -fsSL --no-check-certificate https://golang.org/dl/go${GOVERSION}.linux-$(uname -m).tar.gz | tar xz -C /usr/local \
    || (echo "Ошибка загрузки Go! Проверьте версию." && exit 1)
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
