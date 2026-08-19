#!/bin/sh

marker=$1
mode=${2:-serve}
seen_ids=" "

if [ "$mode" = "stderr-warn" ]; then
  printf '%s\n' "stdio-fixture: write_text_file will refuse every call." >&2
  mode=serve
fi

if [ "$mode" = "mark-close" ]; then
  trap 'printf "%s\n" session-closed >> "$marker"' EXIT
  mode=serve
fi

case "$mode" in
  unsupported-protocol|unsupported-protocol-bare)
    trap 'printf "%s\n" session-closed >> "$marker"' EXIT
    ;;
esac

write_text_result() {
  response_id=$1
  text_bytes=$2

  printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","content":[{"type":"text","text":"' "$response_id"
  awk -v count="$text_bytes" 'BEGIN { for (i = 0; i < count; i++) printf "x" }'
  printf '"}]}}\n'
}

while IFS= read -r line
do
  id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([1-9][0-9]*\).*/\1/p')

  case "$line" in
    *'"jsonrpc":"2.0"'*) ;;
    *) exit 65 ;;
  esac

  case "$line" in
    *'"io.modelcontextprotocol/protocolVersion":"2026-07-28"'*) ;;
    *) exit 65 ;;
  esac

  case "$line" in
    *'"io.modelcontextprotocol/clientInfo":{"name":"ptc_runner","version":"0.x"}'*) ;;
    *) exit 65 ;;
  esac

  case "$line" in
    *'"io.modelcontextprotocol/clientCapabilities":{}'*) ;;
    *) exit 65 ;;
  esac

  case "$line" in
    *'"method":"tools/call"'*)
      case "$line" in
        *'"traceparent":"00-'*) ;;
        *) exit 65 ;;
      esac
      ;;
  esac

  case "$seen_ids" in
    *" $id "*) exit 65 ;;
    *) seen_ids="${seen_ids}${id} " ;;
  esac

  case "$line" in
    *'"method":"server/discover"'*)
      printf '%s:%s\n' "$id" 'server/discover' >> "$marker"
      if [ "$mode" = "unsupported-protocol" ]; then
        printf '%s\n' 'PRIVATE_STDERR_DETAIL' >&2
        printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"PRIVATE_REMOTE_MESSAGE","data":{"secret":"PRIVATE_REMOTE_DATA"}}}\n' "$id"
      elif [ "$mode" = "slow-unsupported-protocol" ]; then
        # Healthy legacy server that is simply slower than the acquisition
        # budget: the same bytes as `unsupported-protocol-bare`, arriving after
        # the caller has already given up. A cold `npx` launch behaves this way.
        sleep 3
        printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found"}}\n' "$id"
      elif [ "$mode" = "unsupported-protocol-bare" ]; then
        # Byte shape of @modelcontextprotocol/server-filesystem answering the
        # pinned profile's first request: code and message, nothing else.
        printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found"}}\n' "$id"
      else
        printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"fixture","version":"1.0"}},"ttlMs":0,"cacheScope":"private"}}\n' "$id"
      fi
      if [ "$mode" = "exit-after-discover" ]; then
        exit 0
      fi
      ;;
    *'"method":"tools/list"'*'"cursor":"page-2"'*)
      printf '%s:%s\n' "$id" 'tools/list' >> "$marker"
      printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","tools":[{"name":"text","description":"Fixture tool.","inputSchema":{"type":"object","properties":{"query":{"type":"string","x-mcp-header":"Query"}},"required":["query"]}},{"name":"fail","description":"Fixture tool.","inputSchema":{"type":"object","properties":{"query":{"type":"string","x-mcp-header":"Query"}},"required":["query"]}}],"ttlMs":0,"cacheScope":"private"}}\n' "$id"
      ;;
    *'"method":"tools/list"'*)
      printf '%s:%s\n' "$id" 'tools/list' >> "$marker"
      printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","tools":[{"name":"structured","description":"Return one structured value.","inputSchema":{"type":"object","properties":{"query":{"type":"string","x-mcp-header":"Query"}},"required":["query"]},"outputSchema":{"type":"object","properties":{"value":{"type":"integer"}},"required":["value"]}}],"nextCursor":"page-2","ttlMs":0,"cacheScope":"private"}}\n' "$id"
      ;;
    *'"method":"tools/call"'*'"name":"structured"'*)
      case "$line" in *'"query":"x"'*) ;; *) exit 65 ;; esac
      printf '%s:%s\n' "$id" 'tools/call' >> "$marker"
      if [ "$mode" = "exit-before-response" ]; then
        exit 0
      fi
      printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","structuredContent":{"value":42},"content":[]}}\n' "$id"
      if [ "$mode" = "exit-after-response" ]; then
        exit 0
      fi
      ;;
    *'"method":"tools/call"'*'"name":"text"'*)
      case "$line" in *'"query":"x"'*) ;; *) exit 65 ;; esac
      printf '%s:%s\n' "$id" 'tools/call' >> "$marker"
      case "$mode" in
        text-logical-max) write_text_result "$id" 1048513 ;;
        text-1000) write_text_result "$id" 1000 ;;
        large-text) write_text_result "$id" 40000 ;;
        *) printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","content":[{"type":"text","text":"hello"}]}}\n' "$id" ;;
      esac
      ;;
    *'"method":"tools/call"'*'"name":"fail"'*)
      case "$line" in *'"query":"x"'*) ;; *) exit 65 ;; esac
      printf '%s:%s\n' "$id" 'tools/call' >> "$marker"
      printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","isError":true,"content":[]}}\n' "$id"
      ;;
    *)
      exit 65
      ;;
  esac
done
