# lobmob build — build and push container images to GHCR
# Usage:
#   lobmob build base         -> build base image (amd64, push to GHCR)
#   lobmob build lobboss      -> build lobboss image
#   lobmob build lobwife      -> build lobwife image
#   lobmob build lobsigliere  -> build lobsigliere image
#   lobmob build lobster      -> build lobster image
#   lobmob build all          -> build all images in order
#
# Local builds (--env local):
#   lobmob --env local build <target>
#   Builds natively (arm64, no --platform), tags :local, imports into k3d

REGISTRY="ghcr.io/minsley"
CLUSTER_NAME="lobmob-local"

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  err "Usage: lobmob build <base|lobboss|lobwife|lobsigliere|lobster|all>"
  exit 1
fi

if [[ "$LOBMOB_ENV" == "local" ]]; then
  # Local: native build (arm64), :local tag, k3d import — no push
  require_local_deps
  BASE_IMAGE="${REGISTRY}/lobmob-base:local"

  build_local() {
    local name="$1"
    local dockerfile="$2"
    local image="${REGISTRY}/lobmob-${name}:local"
    local extra_args=()
    [[ $# -gt 2 ]] && extra_args=("${@:3}")

    log "Building ${name} locally (native arch, :local tag)..."
    docker build \
      ${extra_args[@]+"${extra_args[@]}"} \
      -t "$image" \
      -f "$PROJECT_DIR/$dockerfile" \
      "$PROJECT_DIR"

    log "Importing ${name} into k3d cluster '${CLUSTER_NAME}'..."
    k3d image import "$image" -c "$CLUSTER_NAME"
    log "${name} ready in k3d"
  }

  case "$TARGET" in
    base)
      build_local "base" "containers/base/Dockerfile"
      ;;
    lobboss)
      build_local "lobboss" "containers/lobboss/Dockerfile" \
        --build-arg "BASE_IMAGE=${BASE_IMAGE}"
      ;;
    lobwife)
      build_local "lobwife" "containers/lobwife/Dockerfile" \
        --build-arg "BASE_IMAGE=${BASE_IMAGE}"
      ;;
    lobsigliere)
      build_local "lobsigliere" "containers/lobsigliere/Dockerfile" \
        --build-arg "BASE_IMAGE=${BASE_IMAGE}"
      ;;
    lobster)
      build_local "lobster" "containers/lobster/Dockerfile" \
        --build-arg "BASE_IMAGE=${BASE_IMAGE}"
      ;;
    all)
      build_local "base" "containers/base/Dockerfile"
      build_local "lobboss" "containers/lobboss/Dockerfile" \
        --build-arg "BASE_IMAGE=${BASE_IMAGE}"
      build_local "lobwife" "containers/lobwife/Dockerfile" \
        --build-arg "BASE_IMAGE=${BASE_IMAGE}"
      build_local "lobsigliere" "containers/lobsigliere/Dockerfile" \
        --build-arg "BASE_IMAGE=${BASE_IMAGE}"
      build_local "lobster" "containers/lobster/Dockerfile" \
        --build-arg "BASE_IMAGE=${BASE_IMAGE}"
      ;;
    *)
      err "Unknown target: $TARGET"
      err "Valid targets: base, lobboss, lobwife, lobsigliere, lobster, all"
      exit 1
      ;;
  esac

else
  # Cloud: amd64 cross-build, push to GHCR
  BUILDER="amd64-builder"
  PLATFORM="linux/amd64"
  BASE_IMAGE="${REGISTRY}/lobmob-base:latest"

  build_image() {
    local name="$1"
    local dockerfile="$2"
    local image="${REGISTRY}/lobmob-${name}:latest"
    local extra_args=()
    [[ $# -gt 2 ]] && extra_args=("${@:3}")

    log "Building ${name} (${image})..."
    docker buildx build \
      --builder "$BUILDER" \
      --platform "$PLATFORM" \
      ${extra_args[@]+"${extra_args[@]}"} \
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
fi

log "Build complete."
