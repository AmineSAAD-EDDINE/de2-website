#!/usr/bin/env bash
set -euo pipefail
 
# ====== EDIT ======
export GH_USER="${GH_USER:-AmineSAAD-EDDINE}"    # your GitHub user/org
export REPO="${REPO:-de1}"
export PROJ="${PROJ:-de1}"
export DOMAIN="${DOMAIN:-CHANGE_ME_DOMAIN}"                 # optional custom domain
export EMAIL_DOMAIN="${EMAIL_DOMAIN:-esiee.fr, edu.esiee.fr}" # comma-separated allowed email domains
export ACCESS_APP_NAME="${ACCESS_APP_NAME:-de1}"
export CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-528ffd989ba7b0825a190b8c9c82094b}"
export CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-quW6amv4gN1s5BopaVt11qsSoPAKzwXJm5Cu4hlB}"
export CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-528ffd989ba7b0825a190b8c9c82094b}"
export CF_API_TOKEN="${CF_API_TOKEN:-quW6amv4gN1s5BopaVt11qsSoPAKzwXJm5Cu4hlB}"
 
# ====== DO NOT EDIT BELOW STARTING THIS LINE ======
 
if [ "$CLOUDFLARE_API_TOKEN" = "REPLACE_WITH_API_TOKEN" ]; then
  echo "Set CLOUDFLARE_API_TOKEN before running." >&2; exit 1
fi
 
CF_API_BASE="https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID"
ACCESS_HOST="$PROJ.pages.dev"
[[ -n "$DOMAIN" && "$DOMAIN" != CHANGE_ME_DOMAIN ]] && ACCESS_HOST="$DOMAIN"
 
# ====== PATHS ======
export SITE_DIR="$HOME/de1-website/$REPO"
export ROOT="$HOME/de1-website"
export SRC_TREE="$ROOT/DE1"          # source tree containing labs-final, project-final, ...
export NOTEBOOK_SRC="${NOTEBOOK_SRC:-}"
export NB_STATIC="$SITE_DIR/quartz/static/nb"     # notebooks HTML root (Static plugin serves at /static/nb/...)
export NB_INDEX_MD="$SITE_DIR/content/notebooks.md"
 
has(){ command -v "$1" >/dev/null 2>&1; }
log_step(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$1"; }
 
quartz_degit_clone(){
  tmpdir=$(mktemp -d)
  echo " - Fallback: cloning Quartz template" >&2
  if git clone --depth 1 --branch v4 https://github.com/jackyzha0/quartz.git "$tmpdir/quartz" >/dev/null 2>&1; then
    rm -rf "$tmpdir/quartz/.git"; cp -a "$tmpdir/quartz"/. .; rm -rf "$tmpdir"; return 0
  fi
  rm -rf "$tmpdir"; return 1
}
 
write_index_from_readme(){
  local tmp=$(mktemp)
  # Fix roadmap links to proper Quartz paths
  sed -e 's#(DE1/roadmap-labs-project-DE1\.md)#(/roadmap/roadmap-labs-project-DE1)#g' \
      -e 's#(DE1/roadmap/roadmap-labs-project-DE1\.md)#(/roadmap/roadmap-labs-project-DE1)#g' \
      "$ROOT/README.md" > "$tmp"
  {
    printf '%s\n' '---'
    printf '%s\n' 'title: Home'
    printf '%s\n' 'publish: true'
    printf '%s\n' '---'
    cat "$tmp"
  } > content/index.md
  rm -f "$tmp"
}
 
sync_markdown_from_src(){
  # Copy Markdown from source tree into content/, stripping the leading DE1/ segment.
  # Exclude any files under */data/* directories (we keep small README_DOWNLOAD.md via sync_data_readmes)
  find "$SRC_TREE" \
    -path '*/data/*' -prune -o \
    \( -type f -name '*.md' ! -name 'README.md' -print \) | while IFS= read -r md; do
      rel="${md#"$SRC_TREE/"}"                   # labs-final/..., project-final/...
      dest="$SITE_DIR/content/$rel"
      mkdir -p "$(dirname "$dest")"
      if grep -q '^---' "$md" 2>/dev/null; then cp "$md" "$dest"
      else
        title="$(basename "$md" .md | sed 's/_/ /g')"
        { printf '%s\n' '---'; printf 'title: %s\n' "$title"; printf '%s\n' '---'; printf '\n'; cat "$md"; } > "$dest"
      fi
    done
}
 
# ====== ENSURE Assets() EMITTER IS ENABLED IN quartz.config.ts ======
ensure_assets_emitter() {
  local cfg="$SITE_DIR/quartz.config.ts"
  [ -f "$cfg" ] || return 0
 
  # already present? bail
  grep -q 'Assets[[:space:]]*(' "$cfg" && return 0
 
  cp "$cfg" "$cfg.bak.assets"
 
  # 1) add import if missing
  grep -q 'plugins/emitters/assets' "$cfg" || \
    sed -i '1i import { Assets } from "./quartz/plugins/emitters/assets"' "$cfg"
 
  # 2) register Assets() as first entry in **emitters** array
  awk '
    BEGIN{inEmit=0; injected=0}
    /emitters:[[:space:]]*\[/ && !injected { print; print "    Assets(),"; injected=1; next }
    { print }
  ' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
 
  echo "Patched Assets() into quartz.config.ts"
}
 
# -----------------------------------------------------------------------
 
# ====== 0) BASE TOOLS ======
log_step "0) Checking base tools"; for t in git curl jq; do has "$t" || { echo "Missing $t"; exit 1; }; done
 
# ====== 1) NODE 22 + NPM via NVM ======
log_step "1) Ensuring Node.js 22 via nvm"
if ! has node || [ "$(node -v | sed 's/^v//;s/\..*//')" -lt 22 ]; then
  if ! has nvm; then curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash; fi
  export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; nvm install 22; nvm use 22
fi
node -v; npm -v
 
# ====== 2) GH CLI, WRANGLER, NBCONVERT ======
log_step "2) Installing GitHub CLI, Wrangler, nbconvert"
if ! has gh; then
  if has apt-get; then sudo apt-get update && sudo apt-get install -y gh jq; else echo "Install gh"; exit 1; fi
fi
npm i -g wrangler@latest
if ! has python3; then
  if has apt-get; then sudo apt-get install -y python3 python3-pip; else echo "Install python3"; exit 1; fi
fi
python3 -m pip install --user --upgrade jupyter nbconvert
 
# ====== 3) AUTH ======
log_step "3) Authenticating with GitHub and Cloudflare"
gh auth status || gh auth login
wrangler whoami || wrangler login
 
# ====== 4) QUARTZ SCAFFOLD ======
log_step "4) Creating or refreshing the Quartz scaffold"
mkdir -p "$SITE_DIR"; cd "$SITE_DIR"
quartz_create(){ [ -d content ] && return 0; quartz_degit_clone; }
quartz_create
npm install
 
# ensure non-MD assets under content/ are emitted
ensure_assets_emitter
 
# ====== 5) SITE SKELETON ======
log_step "5) Creating base content structure"
# hard-clean stale output
rm -rf "$SITE_DIR/public" "$SITE_DIR/quartz/static/nb" "$SITE_DIR/content/DE1" "$SITE_DIR/content/nb"
mkdir -p "$SITE_DIR/content" "$NB_STATIC" "$SITE_DIR/quartz/static/img"
# Copy images to quartz/static/img (Static plugin serves static/ at /static/)
[ -d "$ROOT/static/img" ] && cp -a "$ROOT/static/img/." "$SITE_DIR/quartz/static/img/" || true
write_index_from_readme
sync_markdown_from_src
 
sync_assets_from_src(){
  # Copy non-markdown assets (CSV/JSON/SQL/PDF, images, etc.) but skip all files under any data/ folder
  find "$SRC_TREE" \
    -path '*/data/*' -prune -o \
    \( -type f \( -iname '*.csv' -o -iname '*.tsv' -o -iname '*.sql' \
                 -o -iname '*.json' -o -iname '*.txt' -o -iname '*.parquet' \
                 -o -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.pdf' -o -iname '*.zip' -o -iname '*.sh' -o -iname '*.ipynb' \) -print \) | \
  while IFS= read -r f; do
    rel="${f#"$SRC_TREE/"}"
    dest="$SITE_DIR/content/$rel"
    mkdir -p "$(dirname "$dest")"
      cp -f "$f" "$dest"
  done
}
sync_assets_from_src
 
# =========================
# Helpers used by Step 6/7
# =========================
 
# URL-encode a path (keeps “/”)
urlenc() {
  python3 - "$1" <<'PY'
import sys, urllib.parse as u
print(u.quote(sys.argv[1], safe="/"))
PY
}
 
# Ensure Quartz emits non-MD assets (CSV/JSON/SQL/PDF, images, etc.)
ensure_assets_emitter() {
  local cfg="$SITE_DIR/quartz.config.ts"
  [ -f "$cfg" ] || return 0
  grep -q 'Assets[[:space:]]*(' "$cfg" && return 0   # already enabled
  cp "$cfg" "$cfg.bak.assets"
 
  # import
  grep -q 'plugins/emitters/assets' "$cfg" || \
    sed -i '1i import { Assets } from "./quartz/plugins/emitters/assets"' "$cfg"
 
  # register under emitters:[ ... ]
  awk '
    BEGIN{injected=0}
    /emitters:[[:space:]]*\[/ && !injected { print; print "    Assets(),"; injected=1; next }
    { print }
  ' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  
  # Add nb/**/*.html to ignorePatterns so HTML files are treated as static assets only
  if ! grep -q '"nb/\*\*/\*.html"' "$cfg"; then
    sed -i 's/ignorePatterns: \[/ignorePatterns: ["nb\/**\/*.html", /' "$cfg"
    echo " - Added nb/**/*.html to ignorePatterns"
  fi
}
 
# Copy data assets from DE1 tree into /content (so they publish)
sync_assets_from_src() {
  # Exclude any files under data/ directories from being copied into the site content
  find "$SRC_TREE" -path '*/data/*' -prune -o -type f \
       \( -iname '*.csv' -o -iname '*.tsv' -o -iname '*.parquet' \
         -o -iname '*.json' -o -iname '*.sql' -o -iname '*.txt' \
         -o -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.pdf' -o -iname '*.zip' -o -iname '*.sh' -o -iname '*.ipynb' \) \
       -print0 |
  while IFS= read -r -d '' f; do
    rel="${f#"$SRC_TREE/"}"
    dest="$SITE_DIR/content/$rel"
    mkdir -p "$(dirname "$dest")"
    cp -f "$f" "$dest"
  done
}
 
# Auto “Downloads” section per folder (idempotent, URL-safe)
build_folder_downloads() {
  local roots=(
    "$SITE_DIR/content/labs-final"
    "$SITE_DIR/content/project-final"
    "$SITE_DIR/content/roadmap"
    "$SITE_DIR/content/support"
  )
  local -a exts=(
    -iname '*.csv' -o -iname '*.tsv' -o -iname '*.sql' -o -iname '*.json'
    -o -iname '*.txt' -o -iname '*.parquet' -o -iname '*.png' -o -iname '*.jpg'
    -o -iname '*.jpeg' -o -iname '*.pdf'
      -o -iname '*.zip' -o -iname '*.sh' -o -iname '*.ipynb'
  )
 
  local root dir idx rel name
  for root in "${roots[@]}"; do
    [ -d "$root" ] || continue
    find "$root" -type d -print0 | while IFS= read -r -d '' dir; do
      rel_dir="${dir#"$SITE_DIR/content/"}"
      mapfile -d '' -t files < <(find "$dir" -maxdepth 1 -type f \( "${exts[@]}" \) -print0)
      (( ${#files[@]} )) || continue
 
      idx="$dir/index.md"
      if [ ! -f "$idx" ]; then
        rel="$rel_dir"
        {
          printf '%s\n' '---'
          printf '%s\n' "title: $(basename "$dir" | sed 's/_/ /g')"
          printf '%s\n' 'publish: true'
          printf '%s\n' "permalink: /$(urlenc "$rel")/"
          printf '%s\n' '---'
          printf '\n'
        } > "$idx"
      fi
 
      # strip old block
      awk 'BEGIN{s=0}/<!-- BEGIN:downloads -->/{s=1;next}/<!-- END:downloads -->/{s=0;next}!s{print}' \
        "$idx" > "$idx.tmp" && mv "$idx.tmp" "$idx"
 
      # write fresh block
      {
        printf '%s\n' '<!-- BEGIN:downloads -->'
        printf '%s\n' '## Downloads'
        for f in "${files[@]}"; do
          rel="${f#"$SITE_DIR/content/"}"
          name="$(basename "$rel")"
          printf '%s\n' "- [$name](/$(urlenc "$rel"))"
        done
        printf '%s\n' '<!-- END:downloads -->'
        printf '\n'
      } >> "$idx"
    done
  done
}
 
# ==========================================
# 6) NOTEBOOKS → HTML + MD WRAPPERS + INDEX
# ==========================================
log_step "6) Converting notebooks to HTML and wrapping"
 
# make sure Assets() is active before the first build
ensure_assets_emitter
 
SCAN_ROOT="${NOTEBOOK_SRC:-$SRC_TREE}"
 
NB_HTML_ROOT="$SITE_DIR/quartz/static/nb"       # raw exported HTML (Static plugin serves at /static/nb/…)
NB_WRAP_ROOT="$SITE_DIR/content"        # Markdown wrappers + assets (Quartz content)
mkdir -p "$NB_HTML_ROOT" "$NB_WRAP_ROOT"
 
# 6.1 export all .ipynb to HTML, mirroring the source tree
find "$SCAN_ROOT" -type f -name "*.ipynb" ! -path "*/.ipynb_checkpoints/*" -print0 |
while IFS= read -r -d '' nb; do
  rel="${nb#"$SCAN_ROOT/"}"                      # labs-final/.../X.ipynb
  outdir="$NB_HTML_ROOT/$(dirname "$rel")"
  mkdir -p "$outdir"
  jupyter nbconvert --to html --output-dir "$outdir" "$nb"
done
 
# 6.2 create one Markdown wrapper per notebook with URL-encoded permalink + iframe
find "$NB_HTML_ROOT" -type f -name "*.html" -print0 |
while IFS= read -r -d '' html; do
  rel="${html#"$NB_HTML_ROOT/"}"                 # labs-final/.../X.html
  slug="${rel%.html}"                            # labs-final/.../X
  urlslug="$(urlenc "$slug")"                    # encode &, spaces, etc.
  title="$(basename "$slug" | sed 's/_/ /g')"
  out_md="$NB_WRAP_ROOT/$slug.md"
  mkdir -p "$(dirname "$out_md")"
  {
    printf '%s\n' '---'
    printf '%s\n' "title: ${title}"
    printf '%s\n' 'publish: true'
    printf '%s\n' "permalink: /${urlslug}"
    printf '%s\n' 'toc: false'
    printf '%s\n' '---'
    printf '%s\n' "<iframe src=\"/static/nb/${urlslug}.html\" width=\"100%\" height=\"1800\" style=\"border:none\"></iframe>"
  } > "$out_md"
done
 
# 6.3 copy DE1 data assets into /content so they publish
sync_assets_from_src
 
# Copy only the small README_DOWNLOAD.md files from data folders so the site shows download instructions
sync_data_readmes(){
  # Copy README_DOWNLOAD.md and download helpers from any data/ folder into the site content
  # Keep helpers executable when copied.
  find "$SRC_TREE" -type f \( -name 'README_DOWNLOAD.md' -o -name 'download_from_drive.sh' \) -print0 | while IFS= read -r -d '' md; do
    rel="${md#"$SRC_TREE/"}"
    dest="$SITE_DIR/content/$rel"
    mkdir -p "$(dirname "$dest")"
    cp -f "$md" "$dest"
    if [[ "$(basename "$md")" == "download_from_drive.sh" ]]; then
      chmod +x "$dest" || true
    fi
  done
}
 
sync_data_readmes
 
# 6.4 per-folder “Downloads” section (CSV/JSON/SQL/…)
build_folder_downloads
 
# Remove any non-placeholder files that may have leaked into content/*/data
prune_content_data_files() {
  log_step "Cleaning data files in site content (keep only README_DOWNLOAD.md and download_from_drive.sh)"
  # find files under any content/.../data excluding the two allowed filenames
  # prefer a simple find expression (avoid escaped parens which can be fragile in some shells)
  find "$SITE_DIR/content" -path '*/data/*' -type f \
    ! -name 'README_DOWNLOAD.md' ! -name 'download_from_drive.sh' -print0 | \
  while IFS= read -r -d '' f; do
    printf 'Removing site-copied data file: %s\n' "$f" >&2
    rm -f "$f" || true
  done
 
  # remove empty data directories (left after deletions)
  find "$SITE_DIR/content" -type d -name data -print0 | while IFS= read -r -d '' d; do
    if [ -z "$(find "$d" -mindepth 1 -print -quit 2>/dev/null)" ]; then
      rmdir "$d" 2>/dev/null || true
    fi
  done
}
 
 
# ==========================
# 7) Resources page (index)
# ==========================
log_step "7) Building notebooks index"
NB_INDEX_MD="$SITE_DIR/content/resources.md"
{
  printf '%s\n' '---'
  printf '%s\n' 'title: Resources'
  printf '%s\n' 'publish: true'
  printf '%s\n' 'permalink: /resources'
  printf '%s\n' '---'
  printf '%s\n' '# Resources'
  printf '\n'
  printf '%s\n' '## Setup Guide'
  printf '%s\n' '- [Home (README - Setup Instructions)](/)'
  printf '\n'
  printf '%s\n' '## Support Docs'
  printf '%s\n' '- [Support Library](/support)'
  printf '\n'
  printf '%s\n' '## Labs & Assignments'
  find "$NB_WRAP_ROOT" -type f -name "*.md" \
       \( -path "$NB_WRAP_ROOT/labs-final/*" -o -path "$NB_WRAP_ROOT/project-final/*" \) \
       ! -name "index.md" -print0 |
  while IFS= read -r -d '' md; do
    rel="${md#"$NB_WRAP_ROOT/"}"; base="${rel%.md}"
    title="$(basename "$base" | sed 's/_/ /g')"
    printf '%s\n' "- [$title](/$(urlenc "$base"))"
  done
} > "$NB_INDEX_MD"
 
 
 
# ====== 8) BUILD SITE LOCALLY ======
log_step "8) Building Quartz site locally"
npx quartz build
 
# ====== 9) GITHUB (PRIVATE) ======
log_step "9) Initialising Git and pushing to GitHub"
git init -b main >/dev/null 2>&1 || true
git add .; git commit -m "Quartz init + notebooks mirror + wrappers" || true
if ! git remote | grep -q '^origin$'; then
  gh repo create "$GH_USER/$REPO" --private --source=. --remote=origin --push || true
else
  git push -u origin main || true
fi
 
# ====== 10) CLOUDFLARE PAGES DEPLOY ======
log_step "10) Deploying to Cloudflare Pages"
project_tmp=$(mktemp)
project_status=$(curl -s -o "$project_tmp" -w "%{http_code}" "$CF_API_BASE/pages/projects/$PROJ" -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json")
case "$project_status" in
  200) echo "Project $PROJ already exists, skipping create" >&2;;
  404) wrangler pages project create "$PROJ" --production-branch main || echo "Warn: wrangler create failed" >&2;;
  *) echo "Warn: verify project (HTTP $project_status): $(cat "$project_tmp")" >&2; wrangler pages project create "$PROJ" --production-branch main || true;;
esac
rm -f "$project_tmp"
wrangler pages deploy ./public --project-name "$PROJ"
 
# ====== 11) CUSTOM DOMAIN + ACCESS (reusable policy, sane session) ======
log_step "11) Configuring Cloudflare custom domain and reusable Access policy"
 
# 11.0 Pick the host we will protect
ACCESS_HOST="$PROJ.pages.dev"
if [[ -n "$DOMAIN" && "$DOMAIN" != CHANGE_ME_DOMAIN ]]; then
  ACCESS_HOST="$DOMAIN"
fi
echo "Access host ⇒ $ACCESS_HOST"
 
# 11.1 Optional: link a custom domain only when you actually set one
if [[ "$ACCESS_HOST" != "$PROJ.pages.dev" ]]; then
  domain_payload=$(jq -n --arg domain "$ACCESS_HOST" '{domain:$domain}')
  tmp=$(mktemp)
  http=$(curl -s -o "$tmp" -w "%{http_code}" -X POST \
    "$CF_API_BASE/pages/projects/$PROJ/domains" \
    -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
    --data "$domain_payload")
  case "$http" in
    200|201) : ;;
    409) echo "Domain $ACCESS_HOST already linked to $PROJ" >&2 ;;
    *)  echo "Warning: domain link failed ($http): $(cat "$tmp")" >&2 ;;
  esac
  rm -f "$tmp"
else
  echo "Skipping domain linking (using default Pages host)."
fi
 
# 11.2 Build include rules from EMAIL_DOMAIN (comma separated)
include_rules=$(
  jq -n --arg s "$EMAIL_DOMAIN" '
    [ $s
      | split(",")
      | map(gsub("^\\s+|\\s+$";""))
      | map(select(length>0))[]
      | {email_domain:{domain:.}}
    ]'
)
 
# 11.3 Upsert a reusable policy (account-scoped)
POLICY_NAME="${POLICY_NAME:-course-website-access-policy}"
policy_payload=$(jq -n \
  --arg name "$POLICY_NAME" \
  --arg sd "720h" \
  --argjson include "$include_rules" \
  '{name:$name, decision:"allow", include:$include, session_duration:$sd}')
 
pol_list=$(mktemp)
curl -s "$CF_API_BASE/access/policies?per_page=100" \
  -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" > "$pol_list"
 
POLICY_ID=$(jq -r --arg name "$POLICY_NAME" '
  ( .result // [] )
  | map(select(type=="object" and (.name // "")==$name))
  | (.[0] | .id) // empty
' "$pol_list")
rm -f "$pol_list"
 
if [[ -n "$POLICY_ID" ]]; then
  curl -s -X PUT "$CF_API_BASE/access/policies/$POLICY_ID" \
    -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
    --data "$policy_payload" >/dev/null
else
  POLICY_ID=$(
    curl -s -X POST "$CF_API_BASE/access/policies" \
      -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
      --data "$policy_payload" | jq -r '.result.id'
  )
fi
 
# 11.4 Upsert the Access app (self-hosted) and attach only the reusable policy
access_payload=$(jq -n --arg name "$ACCESS_APP_NAME" --arg host "$ACCESS_HOST" '{
  name:$name, domain:$host, self_hosted_domains:[$host], type:"self_hosted",
  session_duration:"720h",
  allow_authenticate_via_warp:false, allow_iframe:false, app_launcher_visible:false,
  skip_interstitial:false, http_only_cookie_attribute:true, path_cookie_attribute:true,
  same_site_cookie_attribute:"lax", service_auth_401_redirect:false, options_preflight_bypass:false
}')
 
app_get=$(mktemp)
curl -s "$CF_API_BASE/access/apps?per_page=100" \
  -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" > "$app_get"
 
# ⚠️ Robust jq: only look at objects; guard missing fields; never index arrays like .domain on non-objects
APP_ID=$(jq -r --arg host "$ACCESS_HOST" --arg name "$ACCESS_APP_NAME" '
  ( .result // [] )
  | map(select(type=="object"))
  | map(select(
      ((.self_hosted_domains // []) | index($host))
      or ((.domain // "") == $host)
      or ((.name   // "") == $name)
    ))
  | (.[0] | .id) // empty
' "$app_get")
rm -f "$app_get"
 
if [[ -z "$APP_ID" ]]; then
  APP_ID=$(
    curl -s -X POST "$CF_API_BASE/access/apps" \
      -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
      --data "$access_payload" | jq -r '.result.id'
  )
else
  curl -s -X PUT "$CF_API_BASE/access/apps/$APP_ID" \
    -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
    --data "$access_payload" >/dev/null
fi
 
# 11.5 Remove any legacy app-scoped policies to avoid precedence conflicts
curl -s "$CF_API_BASE/access/apps/$APP_ID/policies?per_page=100" \
  -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" |
jq -r '(.result // []) | .[].id' | while read -r PID; do
  [[ -n "$PID" ]] && curl -s -X DELETE "$CF_API_BASE/access/apps/$APP_ID/policies/$PID" \
    -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" >/dev/null
done
 
# 11.6 Attach exactly one reusable policy with precedence 1
update_payload=$(jq -n --argjson base "$access_payload" --arg pid "$POLICY_ID" '
  $base + {policies:[{id:$pid, precedence:1}]}
')
resp=$(curl -s -o /tmp/appupd -w "%{http_code}" -X PUT \
  "$CF_API_BASE/access/apps/$APP_ID" \
  -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
  --data "$update_payload")
 
if [[ "$resp" != "200" && "$resp" != "201" ]]; then
  echo "Warning: failed to attach reusable policy ($resp): $(cat /tmp/appupd)" >&2
fi
rm -f /tmp/appupd
 
 
# ====== 12) FINAL DEPLOY ======
log_step "12) Rebuilding site and publishing final deploy"
# Safety: ensure large data folder wasn't accidentally copied into content/
# First, prune any non-placeholder files from content (keep only README_DOWNLOAD.md and download_from_drive.sh)
prune_content_data_files || true
 
# KISS: prune and then ensure there are no files >25 MiB anywhere under site content.
prune_content_data_files || true
large_count=$(find "$SITE_DIR/content" -type f -size +25M | wc -l || true)
if [ "${large_count:-0}" -gt 0 ]; then
  log_step "Found $large_count file(s) >25MiB under $SITE_DIR/content — refusing to deploy."
  find "$SITE_DIR/content" -type f -size +25M -exec ls -lh {} \; || true
  echo
  if [ "${FORCE_DEPLOY:-0}" != "1" ]; then
    echo "Aborting deploy. To force deploy anyway (script will remove offending files), set FORCE_DEPLOY=1 and re-run." >&2
    exit 1
  else
    log_step "FORCE_DEPLOY=1 set — removing files >25MiB under $SITE_DIR/content before deploy"
    find "$SITE_DIR/content" -type f -size +25M -print0 | xargs -0 rm -f || true
  fi
else
  log_step "No files >25MiB found under $SITE_DIR/content after pruning — continuing deploy."
fi
 
npx quartz build
wrangler pages deploy ./public --project-name "$PROJ"
 
echo "Deployment done at $(date '+%Y-%m-%d %H:%M:%S')  |  Site root: https://$ACCESS_HOST"
 
 