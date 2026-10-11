# Lab exercises (fork only)

Hands-on checks against a running gateway, written for this fork. Tuskira's own walkthroughs live in [`examples/`](../examples/); these go one step further on the security properties. Run them in the Codespace after `bash .devcontainer/lab-up.sh`.

| Script | Proves | Needs first |
|---|---|---|
| [`01-bound-key.sh`](01-bound-key.sh) | A key **bound** to a profile can't use tools outside it, even when it names another profile. An **unbound** key can pick any profile by name. Revoking a key takes effect at once. | `./examples/05-profiles/run.sh` (creates "Echo Only" and "Full Access") |

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
