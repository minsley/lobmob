# lobmob logs — tail pod logs
# Usage:
#   lobmob logs                 -> lobboss logs
#   lobmob logs lobboss         -> lobboss logs
#   lobmob logs lobwife         -> lobwife logs
#   lobmob logs lobsigliere     -> lobsigliere logs
#   lobmob logs <job-name>      -> specific lobster pod logs

if [[ "$LOBMOB_ENV" == "dev" ]]; then
  KUBE_CONTEXT="do-nyc3-lobmob-dev-k8s"
elif [[ "$LOBMOB_ENV" == "local" ]]; then
  KUBE_CONTEXT="k3d-lobmob-local"
else
  KUBE_CONTEXT="do-nyc3-lobmob-k8s"
fi

TARGET="${1:-lobboss}"

case "$TARGET" in
  lobboss|lobwife|lobsigliere)
    kubectl --context "$KUBE_CONTEXT" -n lobmob logs -f "deployment/$TARGET" --tail=100
    ;;
  *)
    # Find pod for a lobster job
    POD=$(kubectl --context "$KUBE_CONTEXT" -n lobmob get pods -l "job-name=$TARGET" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -z "$POD" ]]; then
      err "No pod found for job: $TARGET"
      exit 1
    fi
    kubectl --context "$KUBE_CONTEXT" -n lobmob logs -f "pod/$POD" -c lobster --tail=100
    ;;
esac
