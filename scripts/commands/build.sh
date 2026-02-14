# lobmob build — build and push container images to GHCR
# Usage:
#   lobmob build base         -> build base image
#   lobmob build lobboss      -> build lobboss image
#   lobmob build lobwife      -> build lobwife image
#   lobmob build lobsigliere  -> build lobsigliere image
#   lobmob build lobster      -> build lobster image
#   lobmob build all          -> build all images in order

REGISTRY="ghcr.io/minsley"
BUILDER="amd64-builder"
PLATFORM="linux/amd64"
BASE_IMAGE="${REGISTRY}/lobmob-base:latest"

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  err "Usage: lobmob build <base|lobboss|lobwife|lobsigliere|lobster|all>"
  exit 1
fi

build_image() {
  local name="$1"
  local dockerfile="$2"
  local image="${REGISTRY}/lobmob-${name}:latest"
  local extra_args=("${@:3}")

  log "Building ${name} (${image})..."
  docker buildx build \
    --builder "$BUILDER" \
    --platform "$PLATFORM" \
    "${extra_args[@]}" \
    -t "$image" \
    --push \
    -f "$PROJECT_DIR/$dockerfile" \
    "$PROJECT_DIR"

  log "${name} pushed to ${image}"
}

case "$TARGET" in
  base)
    build_image "base" "containers/base/Dockerfile"
    ;;
  lobboss)
    build_image "lobboss" "containers/lobboss/Dockerfile" \
      --build-arg "BASE_IMAGE=${BASE_IMAGE}"
    ;;
  lobwife)
    build_image "lobwife" "containers/lobwife/Dockerfile" \
      --build-arg "BASE_IMAGE=${BASE_IMAGE}"
    ;;
  lobsigliere)
    build_image "lobsigliere" "containers/lobsigliere/Dockerfile" \
      --build-arg "BASE_IMAGE=${BASE_IMAGE}"
    ;;
  lobster)
    build_image "lobster" "containers/lobster/Dockerfile" \
      --build-arg "BASE_IMAGE=${BASE_IMAGE}"
    ;;
  all)
    build_image "base" "containers/base/Dockerfile"
    build_image "lobboss" "containers/lobboss/Dockerfile" \
      --build-arg "BASE_IMAGE=${BASE_IMAGE}"
    build_image "lobwife" "containers/lobwife/Dockerfile" \
      --build-arg "BASE_IMAGE=${BASE_IMAGE}"
    build_image "lobsigliere" "containers/lobsigliere/Dockerfile" \
      --build-arg "BASE_IMAGE=${BASE_IMAGE}"
    build_image "lobster" "containers/lobster/Dockerfile" \
      --build-arg "BASE_IMAGE=${BASE_IMAGE}"
    ;;
  *)
    err "Unknown target: $TARGET"
    err "Valid targets: base, lobboss, lobwife, lobsigliere, lobster, all"
    exit 1
    ;;
esac

log "Build complete."
