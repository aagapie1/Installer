#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/config.sh - loads, overrides and validates client.yaml.
#
# The YAML file is flattened by a small Python helper (python3 + PyYAML,
# present by default on Ubuntu Server 24.04 through cloud-init) into the
# global associative array AAI_CFG with dotted keys:
#   client.name            -> "Primăria Municipiului Buzău"
#   admin.allowed_ips.#    -> "2"            (list length)
#   admin.allowed_ips.0    -> "10.0.0.0/8"
# No eval is used: the helper emits NUL-separated key/value pairs.
#
# Relative paths in the config (documents_dir, assistant.template, tls.*_file)
# are resolved against the repository root (AAI_ROOT), see config_path.

if [[ -n "${AAI_CONFIG_LOADED:-}" ]]; then
  return 0
fi
AAI_CONFIG_LOADED=1

declare -gA AAI_CFG=()
AAI_CFG_FILE=''

AAI_CFG_SCALAR_KEYS=(
  client.name client.short_name client.phone_public_relations
  domain admin.email
  tls.mode tls.email tls.cert_file tls.key_file
  inference.profile inference.chat_model inference.embedding_model inference.rerank_model
  documents_dir assistant.template assistant.opener
  retention_days dify_version
)
AAI_CFG_LIST_KEYS=(admin.allowed_ips assistant.starter_questions)

declare -gA AAI_CFG_DEFAULTS=(
  [tls.mode]='letsencrypt'
  [tls.email]=''
  [tls.cert_file]=''
  [tls.key_file]=''
  [inference.profile]='auto'
  [inference.chat_model]='auto'
  [inference.embedding_model]='bge-m3'
  [inference.rerank_model]='bge-reranker-v2-m3'
  [assistant.template]='templates/chatflow-primarie.yml'
  [assistant.opener]='Bună ziua! Sunt asistentul virtual al {client.name}. Cum vă pot ajuta?'
  [retention_days]='90'
  [dify_version]='1.19.0'
)

AAI_CFG_REQUIRED_KEYS=(
  client.name client.short_name client.phone_public_relations
  domain admin.email documents_dir
)

# Python helper: YAML file -> NUL-separated "key\0value\0" pairs on stdout.
# Messages on stderr are shown to the operator, hence in Romanian.
read -r -d '' _AAI_FLATTEN_PY <<'PY' || true
import re
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("lipsește modulul Python 'yaml' (pachetul python3-yaml)\n")
    sys.exit(3)

KEY_RE = re.compile(r"^[A-Za-z0-9_]+$")
out = sys.stdout


def fail(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(2)


def emit(key, value):
    if "\0" in value:
        fail("valoarea pentru '%s' conține caractere nepermise" % key)
    out.write(key + "\0" + value + "\0")


def walk(prefix, node):
    if isinstance(node, dict):
        for k, v in node.items():
            k = str(k)
            if not KEY_RE.match(k):
                fail("cheie invalidă: '%s'" % k)
            walk(prefix + "." + k if prefix else k, v)
    elif isinstance(node, list):
        emit(prefix + ".#", str(len(node)))
        for i, v in enumerate(node):
            if isinstance(v, (dict, list)):
                fail("lista '%s' trebuie să conțină doar valori simple" % prefix)
            walk("%s.%d" % (prefix, i), v)
    elif node is None:
        emit(prefix, "")
    elif isinstance(node, bool):
        emit(prefix, "true" if node else "false")
    else:
        emit(prefix, str(node))


try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = yaml.safe_load(fh)
except UnicodeDecodeError:
    fail("fișierul nu este text UTF-8")
except yaml.YAMLError as exc:
    fail("YAML invalid: %s" % str(exc).replace("\n", " "))

if data is None:
    data = {}
if not isinstance(data, dict):
    fail("conținutul trebuie să fie un dicționar (chei: valori)")
walk("", data)
PY

_aai_in_list() {
  local needle=$1 item
  shift
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

config_is_list_key() { _aai_in_list "$1" "${AAI_CFG_LIST_KEYS[@]}"; }
config_is_scalar_key() { _aai_in_list "$1" "${AAI_CFG_SCALAR_KEYS[@]}"; }

# Loads a YAML file into AAI_CFG (replacing previous content) and applies
# defaults. Prints a Romanian error and returns 1 on failure.
config_load() {
  local file=$1 tmp err rc=0 key value
  if [[ ! -f "$file" || ! -r "$file" ]]; then
    aai_error "Fișierul de configurare nu există sau nu poate fi citit: $file"
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    aai_error "Lipsește python3, necesar pentru citirea fișierului de configurare."
    aai_error "Ce trebuie făcut: apt install -y python3 python3-yaml"
    return 1
  fi
  tmp=$(mktemp)
  err=$(python3 -I -c "$_AAI_FLATTEN_PY" "$file" 2>&1 >"$tmp") || rc=$?
  if ((rc != 0)); then
    rm -f -- "$tmp"
    aai_error "Nu pot citi fișierul de configurare $file: ${err:-eroare necunoscută}"
    ((rc == 3)) && aai_error "Ce trebuie făcut: apt install -y python3-yaml"
    return 1
  fi
  AAI_CFG=()
  while IFS= read -r -d '' key && IFS= read -r -d '' value; do
    AAI_CFG["$key"]=$value
  done <"$tmp"
  rm -f -- "$tmp"
  AAI_CFG_FILE=$file
  config_apply_defaults
}

config_apply_defaults() {
  local key
  for key in "${!AAI_CFG_DEFAULTS[@]}"; do
    [[ -v "AAI_CFG[$key]" ]] || AAI_CFG["$key"]=${AAI_CFG_DEFAULTS[$key]}
  done
  for key in "${AAI_CFG_LIST_KEYS[@]}"; do
    [[ -v "AAI_CFG[$key.#]" || -v "AAI_CFG[$key]" ]] || AAI_CFG["$key.#"]=0
  done
}

config_has() {
  [[ -v "AAI_CFG[$1]" ]]
}

# Prints the value of a scalar key (empty if missing).
config_get() {
  printf '%s' "${AAI_CFG[$1]-}"
}

# Prints the items of a list key, one per line.
config_list() {
  local key=$1 n i
  n=${AAI_CFG[$key.#]-0}
  for ((i = 0; i < n; i++)); do
    printf '%s\n' "${AAI_CFG[$key.$i]-}"
  done
}

config_list_len() {
  printf '%s\n' "${AAI_CFG[$1.#]-0}"
}

# Absolute path for a path-valued key, relative paths against AAI_ROOT.
config_path() {
  local value
  value=$(config_get "$1")
  [[ -z "$value" ]] && return 0
  if [[ "$value" == /* ]]; then
    printf '%s\n' "$value"
  else
    value=${value#./}
    printf '%s/%s\n' "${AAI_ROOT:?AAI_ROOT nedefinit}" "$value"
  fi
}

# Overrides one key (from the CLI: --set key=value). List keys take a
# comma-separated value. Unknown keys are rejected.
config_set() {
  local key=$1 value=$2 i n item
  if config_is_scalar_key "$key"; then
    AAI_CFG["$key"]=$value
    return 0
  fi
  if config_is_list_key "$key"; then
    n=${AAI_CFG[$key.#]-0}
    for ((i = 0; i < n; i++)); do
      unset "AAI_CFG[$key.$i]"
    done
    unset "AAI_CFG[$key]"
    n=0
    if [[ -n "$value" ]]; then
      local -a items
      IFS=',' read -r -a items <<<"$value"
      for item in "${items[@]}"; do
        item=${item#"${item%%[![:space:]]*}"}
        item=${item%"${item##*[![:space:]]}"}
        [[ -z "$item" ]] && continue
        AAI_CFG["$key.$n"]=$item
        n=$((n + 1))
      done
    fi
    AAI_CFG["$key.#"]=$n
    return 0
  fi
  aai_error "Cheie de configurare necunoscută: '$key'."
  return 1
}

# Parses "key=value" and calls config_set.
config_set_kv() {
  local kv=$1
  if [[ "$kv" != *=* ]]; then
    aai_error "Format invalid pentru --set: '$kv' (se așteaptă cheie=valoare)."
    return 1
  fi
  config_set "${kv%%=*}" "${kv#*=}"
}

# Replaces {client.name}, {domain}, ... with config values. Other braces
# (e.g. Dify's {{#context#}}) are left untouched.
config_render() {
  local text=$1 key
  for key in "${AAI_CFG_SCALAR_KEYS[@]}"; do
    [[ "$text" == *"{$key}"* ]] || continue
    text=${text//"{$key}"/"${AAI_CFG[$key]-}"}
  done
  printf '%s' "$text"
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

aai_is_ipv4() {
  local ip=$1 octet
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for octet in "${BASH_REMATCH[@]:1}"; do
    [[ "$octet" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
    ((octet <= 255)) || return 1
  done
}

aai_is_ipv6() {
  local ip=$1
  [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:]+$ && ${#ip} -le 39 ]] || return 1
  [[ "$ip" != *:::* ]]
}

# Accepts an IPv4/IPv6 address, optionally with a CIDR prefix.
aai_is_ip_or_cidr() {
  local value=$1 addr prefix
  addr=${value%%/*}
  if [[ "$value" == */* ]]; then
    prefix=${value#*/}
    [[ "$prefix" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
  fi
  if aai_is_ipv4 "$addr"; then
    [[ -z "${prefix:-}" ]] || ((prefix <= 32))
  elif aai_is_ipv6 "$addr"; then
    [[ -z "${prefix:-}" ]] || ((prefix <= 128))
  else
    return 1
  fi
}

aai_is_domain() {
  local d=$1
  ((${#d} <= 253)) || return 1
  [[ "$d" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

aai_is_email() {
  [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
}

# Validates AAI_CFG. Prints every problem found; returns 1 if any error.
config_validate() {
  local -a errors=() warnings=()
  local key value i n

  for key in "${AAI_CFG_REQUIRED_KEYS[@]}"; do
    [[ -n "${AAI_CFG[$key]-}" ]] || errors+=("lipsește valoarea obligatorie '$key'")
  done

  # Shape: scalars must not be lists and vice versa.
  for key in "${AAI_CFG_SCALAR_KEYS[@]}"; do
    [[ -v "AAI_CFG[$key.#]" ]] && errors+=("'$key' trebuie să fie o valoare simplă, nu o listă")
  done
  for key in "${AAI_CFG_LIST_KEYS[@]}"; do
    [[ -v "AAI_CFG[$key]" ]] && errors+=("'$key' trebuie să fie o listă (ex. [\"a\", \"b\"])")
  done

  # Unknown keys (probably typos) are reported as warnings.
  for key in "${!AAI_CFG[@]}"; do
    local base=$key
    [[ "$base" =~ ^(.+)\.(#|[0-9]+)$ ]] && base=${BASH_REMATCH[1]}
    config_is_scalar_key "$base" || config_is_list_key "$base" ||
      warnings+=("cheie necunoscută '$key' (ignorată; verificați scrierea)")
  done

  value=${AAI_CFG[client.short_name]-}
  if [[ -n "$value" && ! "$value" =~ ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$ ]]; then
    errors+=("client.short_name '$value' poate conține doar litere mici, cifre și '-' (max. 32 caractere)")
  fi

  local phone_re='^[0-9+][0-9 ().+-]*$'
  value=${AAI_CFG[client.phone_public_relations]-}
  if [[ -n "$value" && ! "$value" =~ $phone_re ]]; then
    errors+=("client.phone_public_relations '$value' nu arată ca un număr de telefon")
  fi

  value=${AAI_CFG[domain]-}
  if [[ -n "$value" ]] && ! aai_is_domain "$value"; then
    errors+=("domain '$value' nu este un nume de domeniu valid (litere mici, fără http:// sau /)")
  fi

  value=${AAI_CFG[admin.email]-}
  if [[ -n "$value" ]] && ! aai_is_email "$value"; then
    errors+=("admin.email '$value' nu este o adresă de e-mail validă")
  fi

  n=${AAI_CFG[admin.allowed_ips.#]-0}
  if ((n == 0)) && [[ ! -v "AAI_CFG[admin.allowed_ips]" ]]; then
    errors+=("admin.allowed_ips trebuie să conțină cel puțin un IP sau o rețea (accesul la consola Dify)")
  fi
  for ((i = 0; i < n; i++)); do
    value=${AAI_CFG[admin.allowed_ips.$i]-}
    aai_is_ip_or_cidr "$value" || errors+=("admin.allowed_ips: '$value' nu este un IP sau o rețea CIDR validă")
  done

  case "${AAI_CFG[tls.mode]-}" in
    letsencrypt)
      value=${AAI_CFG[tls.email]-}
      if [[ -z "$value" ]]; then
        errors+=("tls.email este obligatoriu pentru tls.mode 'letsencrypt'")
      elif ! aai_is_email "$value"; then
        errors+=("tls.email '$value' nu este o adresă de e-mail validă")
      fi
      ;;
    custom)
      [[ -n "${AAI_CFG[tls.cert_file]-}" ]] || errors+=("tls.cert_file este obligatoriu pentru tls.mode 'custom'")
      [[ -n "${AAI_CFG[tls.key_file]-}" ]] || errors+=("tls.key_file este obligatoriu pentru tls.mode 'custom'")
      ;;
    none)
      warnings+=("tls.mode 'none': fără HTTPS, doar pentru teste interne")
      ;;
    *)
      errors+=("tls.mode '${AAI_CFG[tls.mode]-}' invalid (valori permise: letsencrypt, custom, none)")
      ;;
  esac

  case "${AAI_CFG[inference.profile]-}" in
    auto | cpu | gpu) ;;
    *) errors+=("inference.profile '${AAI_CFG[inference.profile]-}' invalid (valori permise: auto, cpu, gpu)") ;;
  esac

  for key in inference.chat_model inference.embedding_model inference.rerank_model; do
    value=${AAI_CFG[$key]-}
    if [[ -z "$value" ]]; then
      errors+=("$key nu poate fi gol")
    elif [[ ! "$value" =~ ^[A-Za-z0-9._:/-]+$ ]]; then
      errors+=("$key '$value' conține caractere nepermise")
    fi
  done

  value=${AAI_CFG[retention_days]-}
  if [[ ! "$value" =~ ^[1-9][0-9]{0,4}$ ]]; then
    errors+=("retention_days '$value' trebuie să fie un număr întreg pozitiv de zile")
  fi

  value=${AAI_CFG[dify_version]-}
  if [[ ! "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    errors+=("dify_version '$value' trebuie să aibă forma X.Y.Z (scrieți-o între ghilimele, ex. \"1.19.0\")")
  fi

  for value in "${warnings[@]+"${warnings[@]}"}"; do
    aai_warn "Configurare: $value"
  done
  if ((${#errors[@]} > 0)); then
    aai_error "Fișierul de configurare ${AAI_CFG_FILE:-} are ${#errors[@]} problem(e):"
    for value in "${errors[@]}"; do
      aai_error "  - $value"
    done
    return 1
  fi
  return 0
}

# Prints "label value" with the label padded by characters, not bytes
# (printf %-Ns miscounts Romanian diacritics in UTF-8).
_aai_kv_line() {
  local label=$1 value=$2 width=24
  printf '  %s%*s%s\n' "$label" $((width - ${#label})) '' "$value"
}

# Human-readable summary of the effective configuration (no secrets in it).
config_print_summary() {
  local ips
  ips=$(config_list admin.allowed_ips | paste -sd ',' - | sed 's/,/, /g')
  _aai_kv_line 'Client:' "$(config_get client.name) ($(config_get client.short_name))"
  _aai_kv_line 'Domeniu:' "$(config_get domain)"
  _aai_kv_line 'TLS:' "$(config_get tls.mode)"
  _aai_kv_line 'Profil inferență:' "$(config_get inference.profile)"
  _aai_kv_line 'Model chat:' "$(config_get inference.chat_model)"
  _aai_kv_line 'Embeddings / rerank:' "$(config_get inference.embedding_model) / $(config_get inference.rerank_model)"
  _aai_kv_line 'Versiune Dify:' "$(config_get dify_version)"
  _aai_kv_line 'IP-uri administrare:' "${ips:-(niciunul)}"
  _aai_kv_line 'Documente:' "$(config_path documents_dir)"
  _aai_kv_line 'Retenție conversații:' "$(config_get retention_days) zile"
}
