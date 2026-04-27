#!/bin/bash
set -euo pipefail

# =============================================
# Build e push multi-arch (linux/amd64 + linux/arm64)
# da imagem Docker para o Docker Hub.
#
# Requer: docker com buildx, e QEMU registrado no binfmt
# (para arm64 em host amd64):
#   docker run --privileged --rm tonistiigi/binfmt --install arm64
#
# Uso:
#   IMAGE_TAG=v6 ./build-multiarch.sh
#   IMAGE_TAG=v6 ALSO_LATEST=1 ./build-multiarch.sh
#   PUSH=0 IMAGE_TAG=dev ./build-multiarch.sh
# =============================================

IMAGE_REPO="${IMAGE_REPO:-ethie/ipv6-multiple-proxy-server}"
IMAGE_TAG="${IMAGE_TAG:-}"
PUSH="${PUSH:-1}"
ALSO_LATEST="${ALSO_LATEST:-0}"

if [[ -z "$IMAGE_TAG" ]]; then
  echo "[ERRO] IMAGE_TAG não definido. Exemplo: IMAGE_TAG=v6 $0" >&2
  exit 1
fi

if ! docker buildx version >/dev/null 2>&1; then
  echo "[ERRO] docker buildx não está disponível." >&2
  exit 1
fi

BUILDER_NAME="multiarch"
if ! docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
  echo ">>> Criando builder buildx: ${BUILDER_NAME}..."
  docker buildx create --name "$BUILDER_NAME" --driver docker-container --bootstrap
fi
docker buildx use "$BUILDER_NAME"

TAGS=("-t" "${IMAGE_REPO}:${IMAGE_TAG}")
if [[ "$ALSO_LATEST" == "1" ]]; then
  TAGS+=("-t" "${IMAGE_REPO}:latest")
fi

PLATFORM="linux/amd64,linux/arm64"

if [[ "$PUSH" == "1" ]]; then
  echo ">>> Build multi-arch e push: ${IMAGE_REPO}:${IMAGE_TAG} (platforms: ${PLATFORM})"
  docker buildx build \
    --platform "$PLATFORM" \
    "${TAGS[@]}" \
    --push \
    .
else
  echo ">>> Build local (apenas linux/amd64, sem push)."
  echo "    Aviso: buildx não consegue carregar multi-arch no daemon local; buildando só amd64."
  docker buildx build \
    --platform "linux/amd64" \
    "${TAGS[@]}" \
    --load \
    .
fi

echo ""
echo ">>> Concluído. Tags: ${IMAGE_REPO}:${IMAGE_TAG}$([[ "$ALSO_LATEST" == "1" ]] && echo " ${IMAGE_REPO}:latest")"
