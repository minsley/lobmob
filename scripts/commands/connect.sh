case "${OSTYPE:-}" in
  darwin*)
    bash "$SCRIPT_DIR/connect-mac.sh" "$@"
    ;;
  linux*)
    bash "$SCRIPT_DIR/connect-linux.sh" "$@"
    ;;
  msys*|cygwin*|win*)
    if command -v powershell.exe >/dev/null 2>&1; then
      powershell.exe -ExecutionPolicy Bypass -File "$SCRIPT_DIR/connect-windows.ps1" "$@"
    else
      err "On Windows, run: powershell -ExecutionPolicy Bypass -File scripts\\connect-windows.ps1"
      exit 1
    fi
    ;;
  *)
    # Fallback: try to detect
    if [ "$(uname -s)" = "Darwin" ]; then
      bash "$SCRIPT_DIR/connect-mac.sh" "$@"
    elif [ "$(uname -s)" = "Linux" ]; then
      bash "$SCRIPT_DIR/connect-linux.sh" "$@"
    else
      err "Unsupported platform: $(uname -s)"
      err "Run the appropriate script directly: connect-mac.sh, connect-linux.sh, or connect-windows.ps1"
      exit 1
    fi
    ;;
esac
