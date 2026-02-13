# lobmob logs — tail lobboss pod logs

if [[ "$LOBMOB_ENV" == "dev" ]]; then
  KUBE_CONTEXT="do-nyc3-lobmob-dev-k8s"
else
  KUBE_CONTEXT="do-nyc3-lobmob-k8s"
fi

TARGET="${1:-lobboss}"

if [[ "$TARGET" == "lobboss" ]]; then
  kubectl --context "$KUBE_CONTEXT" -n lobmob logs -f deployment/lobboss --tail=100
else
  # Find pod for a lobster job
  POD=$(kubectl --context "$KUBE_CONTEXT" -n lobmob get pods -l "job-name=$TARGET" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "$POD" ]]; then
    err "No pod found for job: $TARGET"
    exit 1
  fi
  kubectl --context "$KUBE_CONTEXT" -n lobmob logs -f "pod/$POD" -c lobster --tail=100
fi
