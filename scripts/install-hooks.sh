#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_DIR="$ROOT_DIR/.git/hooks"

mkdir -p "$HOOKS_DIR"

cat > "$HOOKS_DIR/pre-commit" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(git rev-parse --show-toplevel)"
exec "$ROOT_DIR/scripts/harness.sh" --quick
EOF

cat > "$HOOKS_DIR/pre-push" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(git rev-parse --show-toplevel)"
exec "$ROOT_DIR/scripts/harness.sh"
EOF

chmod +x "$HOOKS_DIR/pre-commit" "$HOOKS_DIR/pre-push" "$ROOT_DIR/scripts/harness.sh"
echo "✅ Installed Git pre-commit and pre-push guardrails in .git/hooks/"
