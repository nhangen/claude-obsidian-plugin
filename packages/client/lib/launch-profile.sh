#!/usr/bin/env bash

client_error() {
  printf '%s\n' 'obsidian-mcp-client: invalid configuration' >&2
  exit 64
}

client_value() {
  local name="$1"
  local value="${!name-}"
  [ -n "$value" ] || client_error
  printf '%s' "$value"
}

client_has_control() {
  [[ "$1" =~ [[:cntrl:]] ]]
}

client_valid_identifier() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

client_validate_endpoint() {
  local endpoint="$1"
  client_has_control "$endpoint" && client_error
  case "$endpoint" in
    http://*|https://*) ;;
    *) client_error ;;
  esac
  local authority="${endpoint#*://}"
  authority="${authority%%/*}"
  authority="${authority%%\?*}"
  [ -n "$authority" ] || client_error
  case "$authority" in
    *'@'*|*'['*']'*'@'*|*' '*|*'#'*) client_error ;;
  esac
  case "$endpoint" in
    http://*) client_validate_http_host "$authority" ;;
  esac
  printf '%s' "$authority"
}

client_validate_http_host() {
  local authority="$1"
  [ "${OBSIDIAN_MCP_ALLOW_HTTP-}" = "1" ] || client_error
  local host="$authority"
  case "$host" in
    '[::1]'|'[::1]:'*) return 0 ;;
    *:*) host="${host%%:*}" ;;
  esac
  case "$host" in
    localhost|127.0.0.1) return 0 ;;
    *.ts.net)
      [ "${OBSIDIAN_MCP_ALLOW_TAILNET_HTTP-}" = "1" ] || client_error
      return 0
      ;;
    *.*.*.*)
      local first second third fourth
      IFS=. read -r first second third fourth <<EOF
$host
EOF
      [[ "$first" =~ ^[0-9]{1,3}$ && "$second" =~ ^[0-9]{1,3}$ && "$third" =~ ^[0-9]{1,3}$ && "$fourth" =~ ^[0-9]{1,3}$ ]] || client_error
      (( 10#$first <= 255 && 10#$second <= 255 && 10#$third <= 255 && 10#$fourth <= 255 )) || client_error
      (( 10#$first == 100 && 10#$second >= 64 && 10#$second <= 127 )) || client_error
      [ "${OBSIDIAN_MCP_ALLOW_TAILNET_HTTP-}" = "1" ] || client_error
      return 0
      ;;
    *) client_error ;;
  esac
}

client_private_token_file() {
  local token_file="$1"
  [ -f "$token_file" ] && [ ! -L "$token_file" ] && [ -r "$token_file" ] && [ -O "$token_file" ] || client_error
  local mode
  if mode="$(stat -f '%Lp' "$token_file" 2>/dev/null)"; then
    :
  elif mode="$(stat -c '%a' "$token_file" 2>/dev/null)"; then
    :
  else
    client_error
  fi
  case "$mode" in
    [46]00) ;;
    *) client_error ;;
  esac
}

client_validate_origin() {
  local origin="$1"
  client_has_control "$origin" && client_error
  case "$origin" in
    http://*|https://*) ;;
    *) client_error ;;
  esac
  local authority="${origin#*://}"
  [ -n "$authority" ] || client_error
  case "$authority" in
    */*|*'?'*|*'#'*|*'@'*|*' '*) client_error ;;
  esac
}

client_read_token() {
  local prefix="$1"
  local provider
  provider="$(client_value "${prefix}_CREDENTIAL_PROVIDER")"
  CLIENT_TOKEN=""
  CLIENT_RAW_TOKEN_VARIABLE=""
  case "$provider" in
    env)
      local variable
      variable="$(client_value "${prefix}_TOKEN_ENV")"
      client_valid_identifier "$variable" || client_error
      CLIENT_TOKEN="$(client_value "$variable")"
      CLIENT_RAW_TOKEN_VARIABLE="$variable"
      ;;
    file)
      local token_file
      token_file="$(client_value "${prefix}_TOKEN_FILE")"
      client_private_token_file "$token_file"
      CLIENT_TOKEN="$(<"$token_file")"
      [ -n "$CLIENT_TOKEN" ] || client_error
      ;;
    keychain)
      local service account
      service="$(client_value "${prefix}_KEYCHAIN_SERVICE")"
      account="$(client_value "${prefix}_KEYCHAIN_ACCOUNT")"
      command -v security >/dev/null 2>&1 || client_error
      CLIENT_TOKEN="$(security find-generic-password -a "$account" -s "$service" -w)" || client_error
      [ -n "$CLIENT_TOKEN" ] || client_error
      ;;
    *) client_error ;;
  esac
  client_has_control "$CLIENT_TOKEN" && client_error
  return 0
}

client_unset_opposite_profile_token() {
  local prefix="$1"
  local provider_name="${prefix}_CREDENTIAL_PROVIDER"
  local provider="${!provider_name-}"
  [ "$provider" = "env" ] || return 0
  local variable_name="${prefix}_TOKEN_ENV"
  local variable="${!variable_name-}"
  client_valid_identifier "$variable" || client_error
  unset "$variable"
}

launch_profile() {
  local profile="$1"
  shift
  [ "$#" -eq 0 ] || client_error
  case "$profile" in
    read) ;;
    write) ;;
    *) client_error ;;
  esac
  local upper
  case "$profile" in
    read) upper=READ ;;
    write) upper=WRITE ;;
  esac
  local prefix="OBSIDIAN_MCP_${upper}"
  local opposite_prefix
  case "$profile" in
    read) opposite_prefix=OBSIDIAN_MCP_WRITE ;;
    write) opposite_prefix=OBSIDIAN_MCP_READ ;;
  esac
  unset OBSIDIAN_MCP_READ_AUTHORIZATION OBSIDIAN_MCP_WRITE_AUTHORIZATION
  client_unset_opposite_profile_token "$opposite_prefix"
  local endpoint
  endpoint="$(client_value "${prefix}_ENDPOINT")"
  local authority
  authority="$(client_validate_endpoint "$endpoint")"
  local origin_name="${prefix}_ORIGIN"
  local origin="${!origin_name-}"
  if [ -z "${origin-}" ]; then
    origin="${endpoint%%://*}://$authority"
  fi
  client_validate_origin "$origin"
  export "$origin_name=$origin"
  client_read_token "$prefix"
  local token="$CLIENT_TOKEN"
  unset CLIENT_TOKEN
  local authorization_var="OBSIDIAN_MCP_${upper}_AUTHORIZATION"
  export "$authorization_var=Bearer $token"
  unset token
  if [ -n "$CLIENT_RAW_TOKEN_VARIABLE" ]; then
    unset "$CLIENT_RAW_TOKEN_VARIABLE"
  fi
  unset CLIENT_RAW_TOKEN_VARIABLE
  local client_root runtime node_bin
  client_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || client_error
  runtime="$(python3 "$client_root/lib/verify-read-bridge.py" --client-root "$client_root")" || client_error
  node_bin="$(command -v node)" || client_error
  case "$endpoint" in
    http://*)
      exec "$node_bin" "$runtime" "$endpoint" --allow-http \
        --preauthenticated-http \
        --header "Authorization:\${$authorization_var}" \
        --header "Origin:\${OBSIDIAN_MCP_${upper}_ORIGIN}" --silent
      ;;
  esac
  exec "$node_bin" "$runtime" "$endpoint" \
    --preauthenticated-http \
    --header "Authorization:\${$authorization_var}" \
    --header "Origin:\${OBSIDIAN_MCP_${upper}_ORIGIN}" --silent
}
