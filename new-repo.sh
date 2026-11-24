#!/usr/bin/env bash
# Creates a Forgejo repo from a template and configures it for the security pipeline.
# Usage: ./new-repo.sh [repo-name]      (reads ./.env, or the file in $ENV_FILE)
set -euo pipefail

ENV_FILE="${ENV_FILE:-.env}"
[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE (copy env.example to .env)" >&2; exit 1; }
set -a; source "$ENV_FILE"; set +a

REPO="${1:-${REPO:-}}"
SECRETS="${SECRETS:-DD_TOKEN DT_TOKEN SONAR_TOKEN CI_PR_TOKEN}"
VARIABLES="${VARIABLES:-DD_URL SONAR_URL DT_URL}"
PROTECT_BRANCH="${PROTECT_BRANCH:-true}"
REQUIRED_APPROVALS="${REQUIRED_APPROVALS:-0}"
CHECKS="${CHECKS:-pr-security / secrets (pull_request),pr-security / sonar (pull_request),pr-security / sbom (pull_request),pr-security / iac (pull_request)}"

# ---- validate all inputs before touching the server ----------------------
missing=0
for v in FORGEJO_URL FORGEJO_API_TOKEN ORG REPO TEMPLATE $SECRETS $VARIABLES; do
  [ -n "${!v:-}" ] || { echo "missing required value: $v" >&2; missing=1; }
done
[ "$missing" -eq 0 ] || exit 1
for n in $SECRETS $VARIABLES; do   # Forgejo/Gitea reject these prefixes
  if [[ "${n,,}" =~ ^(gitea|forgejo|github)(_|$) ]]; then
    echo "name '$n' is not allowed by Forgejo; rename it (e.g. CI_PR_TOKEN)" >&2; exit 1
  fi
done
if [ -n "${GITIGNORE_FILE:-}" ] && [ ! -f "$GITIGNORE_FILE" ]; then
  echo "GITIGNORE_FILE not found: $GITIGNORE_FILE" >&2; exit 1
fi
API="${FORGEJO_URL%/}/api/v1"

# ---- API helpers ----------------------------------------------------------
# call METHOD PATH [json]  -> sets API_CODE and API_BODY, never exits on HTTP errors
call() {
  local method="$1" path="$2" body="${3:-}" out
  local args=(-sS -w '\n%{http_code}' -X "$method"
              -H "Authorization: token $FORGEJO_API_TOKEN" -H 'Content-Type: application/json')
  [ -n "$body" ] && args+=(-d @-)
  out=$(printf '%s' "$body" | curl "${args[@]}" "$API$path") \
    || { echo "cannot reach $API" >&2; exit 1; }
  API_CODE=${out##*$'\n'}; API_BODY=${out%$'\n'*}
}
# must METHOD PATH [json] -> like call, but exits on a non-2xx status
must() {
  call "$@"
  case "$API_CODE" in 2*) ;; *) echo "FAILED $1 $2 -> HTTP $API_CODE: $API_BODY" >&2; exit 1 ;; esac
}

# ---- 1. preflight ---------------------------------------------------------
call GET "/orgs/$ORG"
[ "$API_CODE" = 200 ] || { echo "organisation '$ORG' not reachable (HTTP $API_CODE): token or name wrong?" >&2; exit 1; }
call GET "/repos/$ORG/$REPO"
[ "$API_CODE" = 404 ] || { echo "repo $ORG/$REPO already exists (HTTP $API_CODE), aborting" >&2; exit 1; }

# ---- 2. create from template ---------------------------------------------
echo "Creating $ORG/$REPO from template $TEMPLATE"
payload=$(jq -n --arg owner "$ORG" --arg name "$REPO" --arg desc "${DESCRIPTION:-}" \
  --argjson private "${PRIVATE:-true}" \
  '{owner:$owner, name:$name, description:$desc, private:$private, git_content:true}')
must POST "/repos/$TEMPLATE/generate" "$payload"

# ---- 3. make sure Actions is enabled (non-fatal) --------------------------
call PATCH "/repos/$ORG/$REPO" '{"has_actions":true}'
[ "${API_CODE:0:1}" = 2 ] || echo "warning: could not enable Actions (HTTP $API_CODE)" >&2

# ---- 4. .gitignore (commits straight to the default branch, so before protection)
if [ -n "${GITIGNORE_FILE:-}" ]; then
  echo "Setting .gitignore from $GITIGNORE_FILE"
  content=$(base64 < "$GITIGNORE_FILE" | tr -d '\n')
  call GET "/repos/$ORG/$REPO/contents/.gitignore"
  if [ "$API_CODE" = 200 ]; then
    sha=$(echo "$API_BODY" | jq -r .sha)
    must PUT "/repos/$ORG/$REPO/contents/.gitignore" \
      "$(jq -n --arg c "$content" --arg s "$sha" '{content:$c, sha:$s, message:"Set .gitignore"}')"
  else
    must POST "/repos/$ORG/$REPO/contents/.gitignore" \
      "$(jq -n --arg c "$content" '{content:$c, message:"Add .gitignore"}')"
  fi
fi

# ---- 5. admin user (optional) ---------------------------------------------
if [ -n "${OWNER_USER:-}" ]; then
  echo "Adding $OWNER_USER as admin collaborator"
  must PUT "/repos/$ORG/$REPO/collaborators/$OWNER_USER" '{"permission":"admin"}'
fi

# ---- 6. secrets -----------------------------------------------------------
for name in $SECRETS; do
  echo "Setting secret $name"
  must PUT "/repos/$ORG/$REPO/actions/secrets/$name" "$(jq -n --arg d "${!name}" '{data:$d}')"
done

# ---- 7. variables ---------------------------------------------------------
for name in $VARIABLES; do
  echo "Setting variable $name"
  body=$(jq -n --arg v "${!name}" '{value:$v}')
  call POST "/repos/$ORG/$REPO/actions/variables/$name" "$body"
  if [ "$API_CODE" = 409 ]; then must PUT "/repos/$ORG/$REPO/actions/variables/$name" "$body"
  else case "$API_CODE" in 2*) ;; *) echo "FAILED variable $name -> HTTP $API_CODE: $API_BODY" >&2; exit 1 ;; esac
  fi
done

# ---- 7b. DefectDojo organisation, asset, engagement (optional) -------------
# Needs DD_ADMIN_TOKEN: a superuser token, used ONLY here, never stored in the repo.
if [ -n "${DD_ADMIN_TOKEN:-}" ]; then
  DD_API="${DD_API_URL:-${DD_URL:?DD_URL needed}}"; DD_API="${DD_API%/}/api/v2"
  DD_ORG="${DD_ORG:-$ORG}"; DD_ENGAGEMENT="${DD_ENGAGEMENT:-forgejo-ci}"
  dd() {   # dd METHOD PATH [json] -> sets DD_CODE, DD_BODY
    local method="$1" path="$2" body="${3:-}" out
    local args=(-sS -w '\n%{http_code}' -X "$method"
                -H "Authorization: Token $DD_ADMIN_TOKEN" -H 'Content-Type: application/json')
    [ -n "$body" ] && args+=(-d @-)
    out=$(printf '%s' "$body" | curl "${args[@]}" "$DD_API$path") \
      || { echo "cannot reach DefectDojo at $DD_API" >&2; exit 1; }
    DD_CODE=${out##*$'\n'}; DD_BODY=${out%$'\n'*}
  }
  ddmust() { dd "$@"; case "$DD_CODE" in 2*) ;; *) echo "FAILED DefectDojo $1 $2 -> HTTP $DD_CODE: $DD_BODY" >&2; exit 1 ;; esac; }
  uri() { jq -rn --arg n "$1" '$n | @uri'; }

  echo "DefectDojo: organisation '$DD_ORG'"
  ddmust GET "/product_types/?name=$(uri "$DD_ORG")&limit=100"
  org_id=$(echo "$DD_BODY" | jq -r --arg n "$DD_ORG" '[.results[] | select(.name==$n)][0].id // empty')
  if [ -z "$org_id" ]; then
    ddmust POST /product_types/ "$(jq -n --arg n "$DD_ORG" '{name:$n}')"
    org_id=$(echo "$DD_BODY" | jq -r .id)
  fi

  echo "DefectDojo: asset '$REPO'"
  ddmust GET "/products/?name=$(uri "$REPO")&limit=100"
  asset_id=$(echo "$DD_BODY" | jq -r --arg n "$REPO" '[.results[] | select(.name==$n)][0].id // empty')
  if [ -z "$asset_id" ]; then
    ddmust POST /products/ "$(jq -n --arg n "$REPO" --arg d "${DESCRIPTION:-Created by new-repo.sh}" --argjson o "$org_id" \
      '{name:$n, description:$d, prod_type:$o}')"
    asset_id=$(echo "$DD_BODY" | jq -r .id)
  fi

  echo "DefectDojo: engagement '$DD_ENGAGEMENT'"
  ddmust GET "/engagements/?product=$asset_id&limit=100"
  eng_id=$(echo "$DD_BODY" | jq -r --arg n "$DD_ENGAGEMENT" '[.results[] | select(.name==$n)][0].id // empty')
  if [ -z "$eng_id" ]; then
    start=$(date +%F); end=$(date -d '+1 year' +%F 2>/dev/null || date -v+1y +%F)
    ddmust POST /engagements/ "$(jq -n --arg n "$DD_ENGAGEMENT" --argjson p "$asset_id" --arg s "$start" --arg e "$end" \
      '{name:$n, product:$p, target_start:$s, target_end:$e, engagement_type:"CI/CD", status:"In Progress"}')"
  fi

  if [ -n "${DD_CI_USER:-}" ]; then   # non-fatal: the API field may differ between versions
    echo "DefectDojo: authorizing $DD_CI_USER on the asset"
    dd GET "/users/?username=$(uri "$DD_CI_USER")"
    uid=$(echo "$DD_BODY" | jq -r --arg n "$DD_CI_USER" '[.results[]? | select(.username==$n)][0].id // empty')
    if [ -z "$uid" ]; then echo "warning: DefectDojo user '$DD_CI_USER' not found" >&2
    else
      dd GET "/products/$asset_id/"
      users=$(echo "$DD_BODY" | jq -c --argjson u "$uid" '(.authorized_users // []) + [$u] | unique')
      dd PATCH "/products/$asset_id/" "$(jq -n --argjson u "$users" '{authorized_users:$u}')"
      case "$DD_CODE" in 2*) ;; *) echo "warning: could not set authorized users (HTTP $DD_CODE: $DD_BODY). Add $DD_CI_USER by hand in the asset's Authorized Users." >&2 ;; esac
    fi
  fi
fi

# ---- 8. branch protection (last, so the steps above can still write to the branch)
if [ "$PROTECT_BRANCH" = "true" ]; then
  call GET "/repos/$ORG/$REPO"
  branch="${BRANCH:-$(echo "$API_BODY" | jq -r '.default_branch // "main"')}"
  echo "Protecting branch $branch (required checks: $CHECKS)"
  checks_json=$(jq -n --arg c "$CHECKS" '$c | split(",") | map(sub("^ +";"") | sub(" +$";""))')
  payload=$(jq -n --arg b "$branch" --argjson checks "$checks_json" --argjson appr "$REQUIRED_APPROVALS" '{
    rule_name: $b, branch_name: $b,
    enable_push: false,
    enable_status_check: true, status_check_contexts: $checks,
    required_approvals: $appr,
    block_on_rejected_reviews: true, dismiss_stale_approvals: true }')
  call POST "/repos/$ORG/$REPO/branch_protections" "$payload"
  case "$API_CODE" in
    2*) ;;
    *) first="HTTP $API_CODE: $API_BODY"       # maybe the rule exists already: try to update it
       must PATCH "/repos/$ORG/$REPO/branch_protections/$branch" "$payload" \
         || { echo "create failed ($first)" >&2; exit 1; } ;;
  esac
fi

echo "Done: ${FORGEJO_URL%/}/$ORG/$REPO"
