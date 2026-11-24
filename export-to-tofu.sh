#!/bin/sh
# Export existing AWS or Azure resources to OpenTofu code with Unclick.
# Compatible with Windmill.dev using # sandbox clutchlabsapp/tofu-unclick:latest
#
# Inputs come from positional args (Windmill) or environment variables (docker compose).
# A non-empty arg wins over the variable.
#   $1 cloud                  CLOUD                 aws | azure (auto-detected from credentials if empty)
#   $2 region                 AWS_REGION, then AWS_DEFAULT_REGION (default us-east-1; AWS only)
#   $3 aws_access_key_id      AWS_ACCESS_KEY_ID
#   $4 aws_secret_access_key  AWS_SECRET_ACCESS_KEY
#   $5 aws_session_token      AWS_SESSION_TOKEN     (optional)
#   $6 azure_tenant_id        ARM_TENANT_ID
#   $7 azure_subscription_id  ARM_SUBSCRIPTION_ID
#   $8 azure_client_id        ARM_CLIENT_ID
#   $9 azure_client_secret    ARM_CLIENT_SECRET
# Also read from the environment (with defaults):
#   HOME=/tmp  UNCLICK_CACHE_DIR=/tmp/unclick  TF_IN_AUTOMATION=1  CHECKPOINT_DISABLE=1
#   TF_PLUGIN_CACHE_DIR=/opt/plugin-cache  OUTPUT_DIR=. (current directory)
#
# Needs: unclick, tofu, jq (e.g. the tofu-unclick image).
#
# Output: $OUTPUT_DIR/result.json = {"<file>.tf": "<text>", ...}
#         and the .tf files themselves in $OUTPUT_DIR/<aws|azurerm>/
# Inputs (declared this way so Windmill shows them as form fields)
cloud="${1:-}"
region="${2:-}"
aws_access_key_id="${3:-}"
aws_secret_access_key="${4:-}"
aws_session_token="${5:-}"
azure_tenant_id="${6:-}"
azure_subscription_id="${7:-}"
azure_client_id="${8:-}"
azure_client_secret="${9:-}"

set -eu

pick() {  # print the first non-empty argument
  for v in "$@"; do
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  done
}
fail() { echo "ERROR: $*" >&2; exit 1; }

aws_access_key_id=$(pick "$aws_access_key_id" "${AWS_ACCESS_KEY_ID:-}")
aws_secret_access_key=$(pick "$aws_secret_access_key" "${AWS_SECRET_ACCESS_KEY:-}")
aws_session_token=$(pick "$aws_session_token" "${AWS_SESSION_TOKEN:-}")
region=$(pick "$region" "${AWS_REGION:-}" "${AWS_DEFAULT_REGION:-}" us-east-1)
azure_tenant_id=$(pick "$azure_tenant_id" "${ARM_TENANT_ID:-}")
azure_subscription_id=$(pick "$azure_subscription_id" "${ARM_SUBSCRIPTION_ID:-}")
azure_client_id=$(pick "$azure_client_id" "${ARM_CLIENT_ID:-}")
azure_client_secret=$(pick "$azure_client_secret" "${ARM_CLIENT_SECRET:-}")

cloud=$(pick "$cloud" "${CLOUD:-}")
if [ -z "$cloud" ]; then
  if [ -n "$aws_access_key_id" ]; then cloud=aws
  elif [ -n "$azure_client_id" ]; then cloud=azure
  else fail "no credentials given: set AWS_* or ARM_* (or pass them as arguments)"
  fi
fi

home=$(pick "${HOME:-}" /tmp)
unclick_cache=$(pick "${UNCLICK_CACHE_DIR:-}" /tmp/unclick)
tf_automation=$(pick "${TF_IN_AUTOMATION:-}" 1)
checkpoint_disable=$(pick "${CHECKPOINT_DISABLE:-}" 1)
plugin_cache=$(pick "${TF_PLUGIN_CACHE_DIR:-}" /opt/plugin-cache)
output_dir=$(pick "${OUTPUT_DIR:-}" "$PWD")
work=$(mktemp -d /tmp/unclick-out.XXXXXX)
mkdir -p "$home" "$unclick_cache" "$output_dir"

# Run with only the variables listed here, so nothing else from the host leaks in.
run() {
  env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$home" \
    UNCLICK_CACHE_DIR="$unclick_cache" TF_IN_AUTOMATION="$tf_automation" \
    CHECKPOINT_DISABLE="$checkpoint_disable" TF_PLUGIN_CACHE_DIR="$plugin_cache" \
    "$@"
}

case "$cloud" in
  aws)
    [ -n "$aws_access_key_id" ] && [ -n "$aws_secret_access_key" ] \
      || fail "cloud=aws needs AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
    provider=aws
    run AWS_ACCESS_KEY_ID="$aws_access_key_id" \
        AWS_SECRET_ACCESS_KEY="$aws_secret_access_key" \
        AWS_SESSION_TOKEN="$aws_session_token" \
        AWS_REGION="$region" AWS_DEFAULT_REGION="$region" \
        unclick scan aws --config "region=$region" --path-output "$work" >&2
    ;;
  azure)
    [ -n "$azure_tenant_id" ] && [ -n "$azure_subscription_id" ] \
      && [ -n "$azure_client_id" ] && [ -n "$azure_client_secret" ] \
      || fail "cloud=azure needs ARM_TENANT_ID, ARM_SUBSCRIPTION_ID, ARM_CLIENT_ID and ARM_CLIENT_SECRET"
    provider=azurerm
    # resource_provider_registrations=none: a Reader principal can't register providers.
    # --config values are written into provider.tf, so secrets go only through env.
    run ARM_TENANT_ID="$azure_tenant_id" \
        ARM_SUBSCRIPTION_ID="$azure_subscription_id" \
        ARM_CLIENT_ID="$azure_client_id" \
        ARM_CLIENT_SECRET="$azure_client_secret" \
        unclick scan azurerm \
          --config "subscription_id=$azure_subscription_id" \
          --config "resource_provider_registrations=none" \
          --path-output "$work" >&2
    ;;
  *)
    fail "cloud must be aws or azure, got '$cloud'"
    ;;
esac

dir="$work/$provider"
if [ ! -d "$dir" ]; then
  echo "No resources found." >&2
  echo '{}' > "$output_dir/result.json"
  exit 0
fi

# The azurerm provider block needs `features {}`, which unclick doesn't write.
if [ "$provider" = azurerm ] && [ -f "$dir/provider.tf" ] && ! grep -q 'features' "$dir/provider.tf"; then
  awk '{print} /^provider "azurerm" \{/{print "  features {}"}' "$dir/provider.tf" > "$dir/provider.tf.new"
  mv "$dir/provider.tf.new" "$dir/provider.tf"
fi

rm -rf "${output_dir:?}/$provider"
mkdir -p "$output_dir/$provider"
cp "$dir"/*.tf "$output_dir/$provider/"

cd "$dir"
for f in *.tf; do
  [ -e "$f" ] || continue
  jq -Rs --arg n "$f" '{($n): .}' "$f"
done | jq -s 'add // {}' > "$output_dir/result.json"
rm -rf "$work"
echo "Wrote $output_dir/result.json and $output_dir/$provider/*.tf" >&2
