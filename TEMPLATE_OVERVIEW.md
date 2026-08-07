# Deploy and Host Mem0 on Railway

Mem0 is a long term memory layer for AI agents and assistants. It reads a
conversation, decides what is worth keeping, and stores it as searchable facts
so your agent remembers a user across sessions instead of starting cold every
time.

This template runs the self hosted mem0 server together with its web dashboard,
so memories are something you can browse, search and delete by hand rather than
only reach through code.

## About Hosting Mem0

Three services deploy together: the API server, the web dashboard, and Postgres
with the vector extension. Memories and their change history sit on persistent
volumes, so redeploys do not lose anything.

Authentication is on from the first request. The first visit to the dashboard
shows a setup form, and the account you create there becomes the only admin.
Registration closes the instant it exists, so a public URL is not an open door.
From there you issue API keys for your agents and revoke them when a key leaks.

The images are built from a pinned mem0 release rather than pulled from Docker
Hub, because mem0's own published server image is built for arm64 only and
cannot run on Railway's hardware at all. These images also run database
migrations at boot and answer on both IPv4 and IPv6, two things Railway needs
and the upstream image does not do.

## Common Use Cases

- Give a chatbot or support agent memory of a user across separate sessions
- Personalise an assistant with stated preferences, constraints and history
  instead of stuffing everything into the prompt
- Keep a private, self hosted memory store when sending conversation history to
  a managed service is not an option
- Inspect and correct what an agent has decided to remember, using the dashboard

## Dependencies for Mem0 Hosting

- Postgres with the pgvector extension, included in this template
- An OpenAI API key, which you supply at deploy time

### Deployment Dependencies

- mem0 source: https://github.com/mem0ai/mem0
- Self hosting docs: https://docs.mem0.ai/open-source/features/rest-api
- Images and build definitions: https://github.com/hmseeb/mem0-railway
- OpenAI API keys: https://platform.openai.com/api-keys

### Implementation Details

**What you need before deploying.** An OpenAI API key. Memory extraction and
embedding both call OpenAI and there is no bundled local model, so memory writes
fail without one. Everything else is generated for you.

**First boot.** Migrations run before the server starts. If Postgres is not
ready yet the API retries every two seconds for up to a minute, so a short spell
of restarts right after deploying is normal and not a failure.

**Setting up your account.** Open the dashboard address and fill in the setup
form. That first account is the admin, and registration closes as soon as it is
created. Nobody else can claim your instance afterwards. There are no default
credentials to rotate, because none are seeded.

**Connecting an agent.** Create an API key in the dashboard, then point a mem0
client at the API service address:

```python
from mem0 import MemoryClient

client = MemoryClient(api_key="mem0_...", host="https://your-api.up.railway.app")
client.add([{"role": "user", "content": "I am allergic to shellfish"}], user_id="alice")
client.search("what should I avoid ordering?", user_id="alice")
```

**Changing models.** `MEM0_DEFAULT_LLM_MODEL` decides what is worth remembering
and `MEM0_DEFAULT_EMBEDDER_MODEL` powers search. Anthropic and Gemini are
bundled as alternatives and can be selected through the API's `/configure`
endpoint after deploying.

**Custom domains.** If you move the dashboard to your own domain, update
`DASHBOARD_URL` on the API service to match. It is the only browser origin the
API accepts, and a mismatch shows up as a dashboard that loads but where every
action fails.

**Telemetry.** mem0 sends at most two anonymous events per install, when the
first admin is created and when the setup wizard finishes. This template leaves
upstream's default in place rather than changing it quietly. Set
`MEM0_TELEMETRY` to `false` on the API service to opt out.

**Scaling and limits.** Everything runs single instance. The memory change
history is a file on the API service's volume, so that service does not scale
horizontally without moving it. Postgres is a plain container rather than a
managed cluster; for production volume, point the API's Postgres settings at a
managed database and keep the vector extension enabled there.

## Why Deploy Mem0 on Railway?

Railway is a singular platform to deploy your infrastructure stack. Railway will
host your infrastructure so you don't have to deal with configuration, while
allowing you to vertically and horizontally scale it.

By deploying Mem0 on Railway, you are one step closer to supporting a complete
full stack application with minimal burden. Host your servers, databases, AI
agents, and more on Railway.

Mem0 in particular benefits from it: three services that have to find each other
over a private network, two persistent volumes, and generated secrets are all
handled by the deploy itself, so the only decision left to you is which OpenAI
key to use.
