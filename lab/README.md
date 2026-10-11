# Lab exercises (fork only)

Hands-on checks against a running gateway, written for this fork. Tuskira's own walkthroughs live in [`examples/`](../examples/); these go one step further on the security properties. Run them in the Codespace after `bash .devcontainer/lab-up.sh`.

| Script | Proves | Needs first |
|---|---|---|
| [`01-bound-key.sh`](01-bound-key.sh) | A key **bound** to a profile can't use tools outside it, even when it names another profile. An **unbound** key can pick any profile by name. Revoking a key takes effect at once. | `./examples/05-profiles/run.sh` (creates "Echo Only" and "Full Access") |
| [`02-claude-code-via-gateway.sh`](02-claude-code-via-gateway.sh) | Routes **Claude Code's own model calls** through the LLM plane, so each one shows in **LLM Logs** with model, tokens, estimated cost and session. Optional `--daily-usd N` budget, enforced by the gateway. | `lab-up.sh` (add `--analytics` for the Overview dashboard) |

## 02: monitoring your Claude Code usage

```sh
bash .devcontainer/lab-up.sh --analytics   # once; turns on the Overview dashboard (remembered)
bash lab/02-claude-code-via-gateway.sh     # add --daily-usd 5 to set a budget
curl -fsSL https://claude.ai/install.sh | bash   # if Claude Code isn't installed in this Codespace yet
source ~/.gateway-claude.env && claude
```

- **Your login stays yours.** The gateway key travels in its own `X-Gateway-Key` header (set through `ANTHROPIC_CUSTOM_HEADERS`) and is stripped before forwarding. Claude Code's own credential, such as your claude.ai login, reaches Anthropic untouched, so usage still counts against your subscription. The "cost" the console shows is the gateway's estimate from its rate card, not a bill.
- **What the gateway sees.** In the lab, request and response bodies (prompts, code, answers) are stored so the console can show them. Credentials are masked in what it records. Turn bodies off with `GATEWAY_LLM_PROXY_CAPTURE_STORE_BODIES=false`.
- **Check it's routed.** Inside Claude Code, `/status` shows `Anthropic base URL: http://localhost:8082`.
- **Go direct again.** Open a new terminal; nothing is changed permanently.
- **Scope.** Only Claude Code sessions started this way in this Codespace pass through the gateway. Claude Code on your laptop, the Claude apps and claude.ai don't.

Each script creates its own keys, revokes them when it finishes, prints `PASS`/`FAIL` per check, and exits non-zero if any check fails. A check passes only on an explicit JSON-RPC result or error, never on an empty or unexpected response.

## What 01 shows, and why it matters

| Key | Header sent | Calls | Gateway answer |
|---|---|---|---|
| bound to Echo Only | none | `echo` | allowed |
| bound to Echo Only | none | `get-env` | `-32003` tool not allowed by profile |
| bound to Echo Only | `Full Access` | `get-env` | `-32003` key is bound to a different profile |
| unbound | `Echo Only` | `get-env` | `-32003` |
| unbound | `Full Access` | `get-env` | **allowed**: the caller chose its own profile |
| revoked | none | `echo` | `-32001` unauthorized |

`get-env` returns the sample MCP server's environment variables. In a Codespace that environment can include tokens such as `GITHUB_TOKEN`. The script counts sensitive-looking variable **names** to make the point, and never prints values. That's the risk the unbound row shows: a leaked unbound key can name the most permissive profile and reach tools like this one. Bind every agent key.
