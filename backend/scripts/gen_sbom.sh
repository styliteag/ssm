#!/usr/bin/env bash
# Generate CycloneDX SBOMs for SSM (production dependencies only).
#
#   sbom/ssm-backend.cdx.json    backend (Python) prod deps, CycloneDX 1.6
#   sbom/ssm-frontend.cdx.json   frontend (JS) prod deps,    CycloneDX 1.5
#
# Requirements: uv, uvx, npm (>=9.5), and an installed frontend/node_modules.
# Run after dependency changes:  ./backend/scripts/gen_sbom.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$REPO/sbom"
mkdir -p "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> backend SBOM (prod-only)"
uv export --project "$REPO/backend" --no-dev --no-emit-project \
  --format requirements-txt -o "$TMP/req-prod.txt"
uvx --from cyclonedx-bom cyclonedx-py requirements "$TMP/req-prod.txt" \
  --of JSON --sv 1.6 --mc-type application \
  --pyproject "$REPO/backend/pyproject.toml" \
  -o "$OUT/ssm-backend.cdx.json"

echo "==> enrich backend SBOM licenses from installed metadata"
uv run --project "$REPO/backend" python "$REPO/backend/scripts/enrich_sbom_licenses.py"

# Mirror the backend SBOM into the backend build context so the standalone
# backend image (backend/Dockerfile, context = backend/) can ship it too.
mkdir -p "$REPO/backend/sbom"
cp "$OUT/ssm-backend.cdx.json" "$REPO/backend/sbom/ssm-backend.cdx.json"

echo "==> frontend SBOM (prod-only)"
( cd "$REPO/frontend" && npm sbom --omit dev --sbom-format cyclonedx ) \
  > "$OUT/ssm-frontend.cdx.json"

echo "==> done:"
ls -1 "$OUT"
echo "    backend/sbom/ssm-backend.cdx.json (mirror for backend image)"
