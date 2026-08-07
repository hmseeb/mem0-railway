# Mem0 on Railway

A long term memory layer for AI agents, with the web dashboard, running as three
services on Railway: the API server, the dashboard, and Postgres with the vector
extension.

## What you get

- The current mem0 self hosted server, pinned to release `v2.0.17`
- The web dashboard, so memories are browsable instead of only reachable by API
- A setup form on first visit that creates the single admin account and then
  closes registration
- API keys you can issue and revoke from the dashboard
- Memories and their change history on a persistent volume

## Deploying

You need one thing before you start: an OpenAI API key. Memories are extracted
from conversations and embedded for search through OpenAI, and there is no
bundled local model, so nothing works without it.

1. Click the deploy button and paste your OpenAI key when asked.
2. Wait for all three services to go green. First boot runs database migrations
   and usually finishes in under two minutes.
3. Open the dashboard address. You land on a setup form.
4. Fill in your name, email and a password. That account becomes the admin.
   Registration closes the moment it exists, so nobody else can claim the
   instance.
5. Create an API key from the dashboard and point your mem0 client at the API
   address.

## Using it from code

```python
from mem0 import MemoryClient

client = MemoryClient(
    api_key="mem0_...",                        # from the dashboard
    host="https://your-api.up.railway.app",    # the mem0 service address
)

client.add(
    [{"role": "user", "content": "I am allergic to shellfish"}],
    user_id="alice",
)
client.search("what should I avoid ordering?", user_id="alice")
```

Or straight over HTTP:

```bash
curl -X POST https://your-api.up.railway.app/memories \
  -H "Authorization: Bearer mem0_..." \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"I am allergic to shellfish"}],"user_id":"alice"}'
```

## Settings worth knowing

| Setting | Default | What it does |
| --- | --- | --- |
| `OPENAI_API_KEY` | you supply it | Extracts and embeds memories. Required. |
| `MEM0_DEFAULT_LLM_MODEL` | `gpt-5-mini` | Model that decides what is worth remembering |
| `MEM0_DEFAULT_EMBEDDER_MODEL` | `text-embedding-3-small` | Model used for search |
| `NEXT_PUBLIC_INSTANCE_NAME` | `Mem0` | Name shown in the dashboard header |
| `MEM0_TELEMETRY` | `true` | Two anonymous events per install, sent to mem0. Set to `false` to opt out. |
| `DASHBOARD_URL` | the dashboard address | The only browser origin the API accepts. Change it if you put the dashboard on a custom domain. |

Anthropic and Gemini are bundled as alternative models. Set them through the
API's `/configure` endpoint after deploying.

## If something looks wrong

**The dashboard loads but every action fails.** The API is refusing the
dashboard's origin. Check that `DASHBOARD_URL` on the API service matches the
address you are actually opening, including `https://` and no trailing slash.
This bites after adding a custom domain.

**Memory writes fail while everything else works.** Almost always the OpenAI
key: expired, out of credit, or without access to the configured model.

**The setup form says setup is already done, but you have no account.** Somebody
reached your instance first. Delete the row from the `users` table in the
database service and reload.

**Both app services restart for a minute after a fresh deploy.** Expected.
Postgres has not finished starting, so the API retries its migrations every two
seconds for up to a minute before giving up.

## Why these images and not mem0's

mem0 publishes `mem0/mem0-api-server`, but its most recent build is from
September 2025 and it is built for arm64 only. Railway runs amd64, so that image
cannot start there at all. `test/manifest_test.sh` in this repo asserts exactly
that and fails against upstream's image.

The images here build the same server from a pinned release with four
differences:

1. The Postgres driver ships with its own client library, so the vector store
   actually imports. Upstream's requirements pull a source only build that
   cannot compile on the slim base.
2. Database migrations run at boot rather than never.
3. The listener answers on both IPv4 and IPv6 from one socket. Railway's private
   network is IPv6 only while its health checker is IPv4, and Python refuses to
   do both from a plain `--host ::`.
4. The dashboard build keeps upstream's security overrides for patched
   dependencies. Upstream's own Dockerfile drops them by not copying the file
   that declares them.

## Repo layout

| Path | What it is |
| --- | --- |
| `Dockerfile.api` | API server image |
| `Dockerfile.dashboard` | Dashboard image |
| `serve.py` | Starts the API on one socket that answers IPv4 and IPv6 |
| `docker-entrypoint.sh` | Waits for the database, migrates, then starts the server |
| `template.json` | Full build sheet for the Railway template, with the reasoning behind every choice |
| `test/api_test.sh` | Boot contract for the API image |
| `test/dashboard_test.sh` | Boot contract for the dashboard image |
| `test/manifest_test.sh` | Checks published images run on the hardware Railway has |
| `TEMPLATE_OVERVIEW.md` | Marketplace listing copy |

Run the contract tests locally against a build:

```bash
docker build -f Dockerfile.api -t mem0-api:test .
./test/api_test.sh mem0-api:test
```

## Credit

mem0 is built by [mem0ai](https://github.com/mem0ai/mem0) and licensed Apache
2.0. This repo only packages it.
