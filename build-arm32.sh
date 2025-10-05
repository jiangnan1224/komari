#!/bin/bash

# 显示颜色输出
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 版本信息
VERSION=$(git describe --tags --always || echo "dev")
PLATFORM="linux/arm/v7"

# Docker Hub 配置
DOCKER_USERNAME=${DOCKER_USERNAME:-$(docker info 2>/dev/null | grep Username: | cut -d' ' -f2)}
if [ -z "$DOCKER_USERNAME" ]; then
    echo -e "${YELLOW}未检测到 Docker Hub 用户名，请通过以下方式之一设置：${NC}"
    echo "1. 导出环境变量：export DOCKER_USERNAME=你的用户名"
    echo "2. 运行脚本时指定：DOCKER_USERNAME=你的用户名 ./build-arm32.sh"
    exit 1
fi

IMAGE_NAME="${DOCKER_USERNAME}/komari"

# 帮助信息
show_help() {
    echo "用法: $0 [选项]"
    echo "选项:"
    echo "  -h, --help           显示帮助信息"
    echo "  -v, --version        指定版本号 (默认: git tag 或 'dev')"
    echo "  --no-docker          只构建二进制文件，不构建 Docker 镜像"
    echo "  --push              构建完成后推送 Docker 镜像"
    echo ""
    echo "环境变量:"
    echo "  DOCKER_USERNAME     Docker Hub 用户名"
    echo ""
    echo "示例:"
    echo "  DOCKER_USERNAME=myuser $0 --push     使用指定用户名构建并推送镜像"
    echo "  $0 --no-docker                      仅构建二进制文件"
}

# 解析命令行参数
NO_DOCKER=0
PUSH_IMAGE=0

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            VERSION="$2"
            shift 2
            ;;
        --no-docker)
            NO_DOCKER=1
            shift
            ;;
        --push)
            PUSH_IMAGE=1
            shift
            ;;
        *)
            echo "未知选项: $1"
            show_help
            exit 1
            ;;
    esac
done

echo -e "${GREEN}开始构建 Komari ARM32 版本 ${VERSION}${NC}"

# 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}请使用 sudo 运行此脚本${NC}"
    exit 1
fi

# 检查 Docker
if [ $NO_DOCKER -eq 0 ]; then
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}未找到 Docker，请先安装 Docker${NC}"
        exit 1
    fi
fi

# 步骤 1: 安装必要的交叉编译工具链
echo -e "${GREEN}正在安装交叉编译工具链...${NC}"
apt-get update
apt-get install -y gcc-arm-linux-gnueabi g++-arm-linux-gnueabi libc6-dev-armel-cross crossbuild-essential-armel

# 处理 Git 安全目录问题
if ! git config --global --get-all safe.directory | grep -q "^${PWD}$"; then
    echo -e "${YELLOW}配置 Git 安全目录...${NC}"
    git config --global --add safe.directory "${PWD}"
fi

# 步骤 2: 设置编译环境变量并执行构建
echo -e "${GREEN}开始编译...${NC}"
export CC=arm-linux-gnueabi-gcc
export CGO_ENABLED=1
export GOOS=linux
export GOARCH=arm
export GOARM=7
export CGO_CFLAGS="-march=armv7-a"
export CGO_LDFLAGS="-static"

# 步骤 3: 执行构建
echo -e "${GREEN}开始构建二进制文件...${NC}"
go build -tags "sqlite_omit_load_extension" \
    -buildvcs=false \
    -ldflags="-linkmode external -extldflags '-static' -X main.Version=${VERSION}" \
    -o komari-linux-armv7

if [ $? -ne 0 ]; then
    echo -e "${RED}构建失败${NC}"
    exit 1
fi

# 步骤 4: 移除调试信息以减小文件体积
echo -e "${GREEN}正在优化二进制文件大小...${NC}"
arm-linux-gnueabi-strip komari-linux-armv7

# 显示构建结果信息
echo -e "${GREEN}二进制文件构建完成!${NC}"
echo "二进制文件信息:"
file komari-linux-armv7
echo -e "\n文件大小:"
ls -lh komari-linux-armv7

# 步骤 5: 构建 Docker 镜像
if [ $NO_DOCKER -eq 0 ]; then
    echo -e "\n${GREEN}开始构建 Docker 镜像...${NC}"
    
    # 安装 qemu-user-static
    if ! dpkg -l | grep -q qemu-user-static; then
        echo -e "${YELLOW}正在安装 QEMU 支持...${NC}"
        apt-get update
        apt-get install -y qemu-user-static
    fi

    # 注册 QEMU 二进制文件
    echo -e "${YELLOW}正在注册 QEMU 处理器...${NC}"
    docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

    # 设置并确保 buildx 可用
    echo -e "${YELLOW}正在设置 docker buildx...${NC}"
    if ! docker buildx ls | grep -q armv7-builder; then
        docker buildx create --name armv7-builder --platform linux/arm/v7
    fi
    docker buildx use armv7-builder
    docker buildx inspect --bootstrap

    # 构建镜像
    if [ $PUSH_IMAGE -eq 1 ]; then
        echo -e "${GREEN}构建并推送 Docker 镜像...${NC}"
        docker buildx build --platform ${PLATFORM} \
            -t ${IMAGE_NAME}:${VERSION} \
            -t ${IMAGE_NAME}:latest \
            -f Dockerfile.arm32v7 \
            --push .
    else
        echo -e "${GREEN}构建 Docker 镜像...${NC}"
        docker buildx build --platform ${PLATFORM} \
            -t ${IMAGE_NAME}:${VERSION} \
            -t ${IMAGE_NAME}:latest \
            -f Dockerfile.arm32v7 \
            --load .
    fi

    BUILD_RESULT=$?
    if [ $BUILD_RESULT -eq 0 ]; then
        echo -e "${GREEN}Docker 镜像构建成功${NC}"
        echo "镜像名称: ${IMAGE_NAME}:${VERSION}"
        echo "平台: ${PLATFORM}"
        
        # 清理 buildx 实例
        echo -e "${YELLOW}清理构建环境...${NC}"
        docker buildx stop armv7-builder
        docker buildx rm armv7-builder
    else
        echo -e "${RED}Docker 镜像构建失败${NC}"
        # 清理 buildx 实例
        docker buildx stop armv7-builder >/dev/null 2>&1
        docker buildx rm armv7-builder >/dev/null 2>&1
        exit 1
    fi
fi

# 最终提示信息
echo -e "\n${GREEN}构建过程完成!${NC}"
echo "生成的文件: komari-linux-armv7"
if [ $NO_DOCKER -eq 0 ]; then
    echo "Docker 镜像: ${IMAGE_NAME}:${VERSION}"
fi
echo -e "${YELLOW}注意: 这是一个静态链接的 ARMv7 二进制文件，使用软浮点运算，可以在大多数 ARM Linux 系统上运行。${NC}"
