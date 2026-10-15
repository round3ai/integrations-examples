# Three.dev Gateway for LangChain and LangGraph (Python)

Record every LLM call of an app built on [LangChain](https://python.langchain.com) and
[LangGraph](https://langchain-ai.github.io/langgraph/) in Three.dev. The app keeps its own
provider keys and its LangChain code; only the chat models change: each one points its base
URL at the Three.dev gateway and carries a few `x-three-*` headers. The gateway forwards
each call to the provider and records it.

This example is a small weather assistant. For each provider with keys in `.env` (OpenAI,
Anthropic, Gemini, OpenRouter, Azure OpenAI) it runs one conversation of three calls —
`invoke`, `stream` and an agent with a tool — and groups the conversation into one session
in Three.dev.

## How it works

**1. Point the chat models at the gateway.** Each model class takes the gateway URL and the
headers in its own parameters (see [Provider wiring](#provider-wiring)):

```python
gateway = "https://gate.three.dev"

openai = ChatOpenAI(
    api_key=os.environ["OPENAI_API_KEY"],      # your own OpenAI key
    model="gpt-5.4-mini",
    base_url=f"{gateway}/v1",
    stream_usage=True,                         # required, see Things to know
    default_headers={
        "x-three-api-key": os.environ["THREE_API_KEY"],
        "x-three-use-case": os.environ["USE_CASE_SLUG"],
        "x-three-ai-provider": "openai",
    },
)
```

**2. Send the session id per call.** `extra_headers` passed to `invoke` / `stream` merge
with the model's `default_headers`, and the per-call value wins. That is how one model
serves many conversations, each with its own session id:

```python
extra_headers = {"x-three-session-id": session_id}  # one per conversation

openai.invoke(messages, extra_headers=extra_headers)
```

**3. Set the session per agent run with middleware.** A `wrap_model_call` middleware reads
the session id from the run's `context` and adds it to every model call of the run, so one
agent serves many conversations:

```python
@dataclass
class Session:
    session_id: str

@wrap_model_call
def three_session(request, handler):
    headers = {"x-three-session-id": request.runtime.context.session_id}
    return handler(request.override(model_settings={**request.model_settings, "extra_headers": headers}))

agent = create_agent(openai, tools=[get_weather], middleware=[three_session], context_schema=Session)
agent.invoke({"messages": messages}, context=Session(session_id))
```

All of it is in [`src/providers.py`](./src/providers.py) and
[`src/main.py`](./src/main.py).

## Provider wiring

Every model sends `x-three-api-key`, `x-three-use-case` and `x-three-ai-provider`;
`<gateway>` is `THREE_GATEWAY_URL` (default `https://gate.three.dev`).

| Package | Class | Gateway URL | Headers in | `x-three-ai-provider` | Extra header |
|---|---|---|---|---|---|
| `langchain-openai` | `ChatOpenAI(stream_usage=True)` | `base_url=<gateway>/v1` | `default_headers` | `openai` | none |
| `langchain-anthropic` | `ChatAnthropic` | `base_url=<gateway>` | `default_headers` | `anthropic` | none |
| `langchain-google-genai` | `ChatGoogleGenerativeAI` | `base_url=<gateway>` | `additional_headers` | `gemini` | none |
| `langchain-openai` (OpenRouter) | `ChatOpenAI(stream_usage=True)` | `base_url=<gateway>/v1` | `default_headers` | `openrouter` | `x-three-ai-provider-baseurl: https://openrouter.ai/api/v1` |
| `langchain-openai`, Azure v1 URLs | `ChatOpenAI(stream_usage=True)` (model = deployment) | `base_url=<gateway>/v1` | `default_headers` | `azure_openai` | `x-three-ai-provider-baseurl: <AZURE_ENDPOINT>/openai/v1` |
| `langchain-openai`, Azure deployment URLs | `AzureChatOpenAI(azure_deployment, api_version)` | `azure_endpoint=<gateway>` | `default_headers` | `azure_openai` | `x-three-ai-provider-baseurl: <AZURE_ENDPOINT>` |

Things to know:

- **`stream_usage=True`:** a custom `base_url` turns `ChatOpenAI`'s `stream_usage` off, and
  streams are then recorded without tokens. Set it on every `ChatOpenAI` pointed at the
  gateway.
- **Anthropic:** the `base_url` has no `/v1`, like the Anthropic SDK's. This differs from
  the Vercel AI SDK, whose Anthropic `baseURL` includes `/v1`.
- **Gemini:** this example sets the session id on the model, in `additional_headers`, with
  one model per conversation.
- **Session id:** per-call `extra_headers` (or `.bind(extra_headers=...)`) become headers;
  `RunnableConfig` metadata (`config={"metadata": ...}`) does not.
- **Azure:** `AZURE_ENDPOINT` is the resource address with no path
  (`https://<resource>.openai.azure.com`), and the model is the deployment name.
  `AZURE_API_VERSION` is used only with deployment URLs. It is an Azure API version such
  as `2025-04-01-preview` (the value after `api-version=` in the deployment's Target URI),
  not the model version. Azure answers a wrong value with `404 Resource not found`.
- **Embeddings:** `OpenAIEmbeddings` goes through the gateway, but embeddings are recorded
  without messages, tokens or cost.
- **Stored keys:** this example sends the app's own provider keys. To use the provider keys
  stored in Three.dev instead, see the Three.dev docs.

## What the app does

For each provider with keys in `.env` (the others are skipped with one line saying so):

1. `invoke` with a short prompt,
2. `stream`, printing the text as it streams,
3. an agent: `create_agent` with a mock `get_weather` tool ([`src/tools.py`](./src/tools.py),
   `@tool`) and the session middleware, asking which of two cities is warmer.

The three calls share one session id (`uuid.uuid4()`), so each provider's conversation is
one session in Three.dev. For Azure, the three calls use v1 URLs; when `AZURE_API_VERSION`
is set, one more call uses deployment URLs, in the same session.

The app prints one short line per call (provider, call, first words of the answer). It
never prints keys or request headers.

## Prerequisites

- Python 3.10+ (required by LangChain 1.x)
- [uv](https://docs.astral.sh/uv/)
- [Task](https://taskfile.dev) (optional)
- A Three.dev API key (`r3_sk_...`)
- An API key for at least one of the providers

## Setup

```bash
cp .env.example .env
# Edit .env: THREE_API_KEY, USE_CASE_SLUG and the keys of the providers you want to run
```

| Variable | Required | Description |
|---|---|---|
| `THREE_API_KEY` | Yes | Three.dev API key (`r3_sk_...`), sent as `x-three-api-key` |
| `USE_CASE_SLUG` | Yes | Use case slug, sent as `x-three-use-case`. A new slug is created on its first request (up to 20 per organization) |
| `THREE_GATEWAY_URL` | No | Gateway base URL, no path (default: `https://gate.three.dev`) |
| `OPENAI_API_KEY` / `OPENAI_MODEL` | No | OpenAI key and model (default: `gpt-5.4-mini`) |
| `ANTHROPIC_API_KEY` / `ANTHROPIC_MODEL` | No | Anthropic key and model (default: `claude-haiku-5-5`) |
| `GOOGLE_GENERATIVE_AI_API_KEY` / `GOOGLE_MODEL` | No | Gemini key and model (default: `gemini-3.8-flash`) |
| `OPENROUTER_API_KEY` / `OPENROUTER_MODEL` | No | OpenRouter key and model (default: `qwen/qwen3.8-27b`) |
| `AZURE_API_KEY` / `AZURE_ENDPOINT` / `AZURE_DEPLOYMENT` | No | Azure OpenAI key, resource address (no path) and deployment name; all three are needed |
| `AZURE_API_VERSION` | No | Azure API version for the deployment-URL call, e.g. `2025-04-01-preview`; leave empty to skip that call |

## Running the example

```bash
task run
```

This installs dependencies, creates `.env` from `.env.example` if needed, and runs the
example. Without Task, use `uv run src/main.py`. `task typecheck` type-checks the code
(mypy `--strict`).

## What to verify in Three.dev

Open the use case (`USE_CASE_SLUG`) in Three.dev:

- **Requests:** one request per call, with the provider, model, messages, tokens and cost.
  The agent shows one request per step, with its tool calls and results.
- **Sessions:** one session per provider, holding that provider's calls (the app prints
  each session id).

## Using LangChain 0.3

The model wiring above was also verified with the 0.3 line: `langchain` 0.3.30,
`langchain-openai` 0.3.35, `langchain-anthropic` 0.3.22, `langgraph` 0.6.11,
`langchain-google-genai` 2.1.12. The differences in this example:

| 1.x | 0.3 |
|---|---|
| `langchain.agents.create_agent` with the session middleware | `create_agent` and agent middleware don't exist; the agent and its per-run session are built differently |
| `ChatGoogleGenerativeAI(base_url=..., additional_headers=...)` | `langchain-google-genai` 2.x is wired differently |
| `message.text` | `message.text()` |

## Design

- **Your own provider keys** — each model keeps its `api_key`; the gateway forwards it to
  the provider and records the call.
- **The integration is only the models and one middleware** — the gateway URL plus the
  `x-three-*` headers, and the session middleware, all in `src/providers.py`. The `invoke`
  / `stream` / `create_agent` calls in `src/main.py` are ordinary LangChain code.
- **Session id per call** — one model serves every conversation; each call passes its own
  `x-three-session-id` in `extra_headers`, and each agent run in its `context`.
- **Fail fast on misconfiguration** — `THREE_GATEWAY_URL` and `AZURE_ENDPOINT` must have
  no path, so a value like `https://gate.three.dev/v1` is rejected instead of producing
  `/v1/v1` URLs.

## Project structure

```
├── src/
│   ├── main.py         # The conversation per provider: invoke, stream, agent
│   ├── providers.py    # Chat models pointed at the gateway, built from .env; session middleware
│   └── tools.py        # Mock get_weather tool
├── .env.example        # Environment variable template
├── .python-version     # Python version uv uses (3.13; 3.10+ supported)
├── Taskfile.yml        # task install / task run / task typecheck
├── pyproject.toml      # Pinned dependencies
└── uv.lock
```
