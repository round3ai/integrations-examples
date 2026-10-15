"""providers.py — one LangChain chat model per provider, pointed at the Three.dev gateway,
and the agent middleware that carries the session id. This is the whole integration: the
rest of the app is ordinary LangChain code.

Each model keeps the app's own provider key (api_key) and changes two things:
  - the base URL: the gateway path for that provider (see the table in the README)
  - the default headers: x-three-api-key, x-three-use-case and x-three-ai-provider, sent on
    every request made with the model. The session id is sent per call (see main.py).
"""

import os
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlsplit

from langchain.agents.middleware import AgentMiddleware, ModelRequest, ModelResponse, wrap_model_call
from langchain_anthropic import ChatAnthropic
from langchain_core.language_models import BaseChatModel
from langchain_google_genai import ChatGoogleGenerativeAI
from langchain_openai import AzureChatOpenAI, ChatOpenAI


@dataclass
class ProviderTarget:
    """One provider the app talks to, with the models its conversation uses."""

    # Label printed in the output.
    name: str
    # The model for one conversation (invoke, stream, agent), given its session id.
    model: Callable[[str], BaseChatModel]
    # Keyword arguments that carry the session id on invoke / stream, and in the agent
    # middleware's model_settings.
    call_kwargs: Callable[[str], dict[str, Any]]
    # Azure only: a model on deployment URLs, run once when set.
    deployment_chat_model: BaseChatModel | None = None


@dataclass
class Session:
    """The agent's run context: `agent.invoke(input, context=Session(session_id))`."""

    session_id: str


def session_kwargs(session_id: str) -> dict[str, Any]:
    # extra_headers merge with the model's default_headers, and the per-call value wins.
    return {"extra_headers": {"x-three-session-id": session_id}}


def no_session_kwargs(session_id: str) -> dict[str, Any]:
    # Gemini: the session id is on the model itself.
    return {}


def three_session(
    call_kwargs: Callable[[str], dict[str, Any]],
) -> AgentMiddleware[Any, Session, Any]:
    """Sets the session id on every model call of an agent run, from the run's context.
    One agent can then serve many conversations, each with its own session."""

    @wrap_model_call
    def set_session(
        request: ModelRequest[Session],
        handler: Callable[[ModelRequest[Session]], ModelResponse[Any]],
    ) -> ModelResponse[Any]:
        settings = {**request.model_settings, **call_kwargs(request.runtime.context.session_id)}
        return handler(request.override(model_settings=settings))

    return set_session


def env(name: str) -> str | None:
    value = (os.environ.get(name) or "").strip()
    return value or None


def require_env(name: str) -> str:
    value = env(name)
    if not value:
        raise RuntimeError(f"Missing required env var: {name} (see .env.example)")
    return value


# The per-provider paths are appended to these URLs, so a path here (e.g. the /v1 that
# the OpenAI SDK example puts in THREE_GATEWAY_URL) would produce URLs like /v1/v1.
def origin_only(name: str, value: str, example: str) -> str:
    try:
        url = urlsplit(value)
        url.port  # raises ValueError on a malformed port
    except ValueError:
        raise RuntimeError(f"{name} is not a valid URL: {value}") from None
    if url.scheme not in ("http", "https") or not url.hostname:
        raise RuntimeError(f"{name} is not a valid URL: {value}")
    if url.path not in ("", "/") or url.query or url.fragment:
        raise RuntimeError(f"{name} must have no path, e.g. {example} (got {value})")
    return f"{url.scheme}://{url.netloc}"


def load_providers() -> tuple[list[ProviderTarget], list[str]]:
    """Build the models for every provider whose keys are set in .env."""
    gateway = origin_only(
        "THREE_GATEWAY_URL",
        env("THREE_GATEWAY_URL") or "https://gate.three.dev",
        "https://gate.three.dev",
    )

    # Headers shared by every provider; x-three-ai-provider is added per provider below.
    three = {
        "x-three-api-key": require_env("THREE_API_KEY"),
        "x-three-use-case": require_env("USE_CASE_SLUG"),
    }

    targets: list[ProviderTarget] = []
    skipped: list[str] = []

    # OpenAI — Chat Completions. A custom base_url turns stream_usage off, and streams are
    # then recorded without tokens, so it is turned back on.
    openai_key = env("OPENAI_API_KEY")
    if openai_key:
        openai = ChatOpenAI(
            api_key=openai_key,
            model=env("OPENAI_MODEL") or "gpt-5.4-mini",
            base_url=f"{gateway}/v1",
            stream_usage=True,
            default_headers={**three, "x-three-ai-provider": "openai"},
        )
        targets.append(ProviderTarget("openai", lambda _: openai, session_kwargs))
    else:
        skipped.append("openai (OPENAI_API_KEY not set)")

    # Anthropic — the base_url has no /v1 (the Anthropic SDK adds /v1/messages), unlike the
    # Vercel AI SDK's.
    anthropic_key = env("ANTHROPIC_API_KEY")
    if anthropic_key:
        anthropic = ChatAnthropic(
            api_key=anthropic_key,
            model=env("ANTHROPIC_MODEL") or "claude-haiku-5-5",
            base_url=gateway,
            default_headers={**three, "x-three-ai-provider": "anthropic"},
        )
        targets.append(ProviderTarget("anthropic", lambda _: anthropic, session_kwargs))
    else:
        skipped.append("anthropic (ANTHROPIC_API_KEY not set)")

    # Gemini — the base_url has no path (google-genai adds /v1beta/models/...), the headers
    # go in additional_headers and the provider value is "gemini". The session id is set on
    # the model, one model per conversation.
    google_key = env("GOOGLE_GENERATIVE_AI_API_KEY")
    if google_key:
        google_model = env("GOOGLE_MODEL") or "gemini-3.8-flash"

        def gemini(session_id: str) -> BaseChatModel:
            return ChatGoogleGenerativeAI(
                api_key=google_key,
                model=google_model,
                base_url=gateway,
                additional_headers={
                    **three,
                    "x-three-ai-provider": "gemini",
                    "x-three-session-id": session_id,
                },
            )

        targets.append(ProviderTarget("gemini", gemini, no_session_kwargs))
    else:
        skipped.append("gemini (GOOGLE_GENERATIVE_AI_API_KEY not set)")

    # OpenRouter — through ChatOpenAI; the gateway needs OpenRouter's own base URL in
    # x-three-ai-provider-baseurl.
    openrouter_key = env("OPENROUTER_API_KEY")
    if openrouter_key:
        openrouter = ChatOpenAI(
            api_key=openrouter_key,
            model=env("OPENROUTER_MODEL") or "qwen/qwen3.8-27b",
            base_url=f"{gateway}/v1",
            stream_usage=True,
            default_headers={
                **three,
                "x-three-ai-provider": "openrouter",
                "x-three-ai-provider-baseurl": "https://openrouter.ai/api/v1",
            },
        )
        targets.append(ProviderTarget("openrouter", lambda _: openrouter, session_kwargs))
    else:
        skipped.append("openrouter (OPENROUTER_API_KEY not set)")

    # Azure OpenAI — the model is the deployment name, and AZURE_ENDPOINT is the resource
    # address with no path (https://<resource>.openai.azure.com).
    azure_key = env("AZURE_API_KEY")
    azure_endpoint_value = env("AZURE_ENDPOINT")
    azure_deployment = env("AZURE_DEPLOYMENT")
    if azure_key and azure_endpoint_value and azure_deployment:
        azure_endpoint = origin_only(
            "AZURE_ENDPOINT", azure_endpoint_value, "https://<resource>.openai.azure.com"
        )

        # v1 URLs: ChatOpenAI with the deployment name as the model.
        azure = ChatOpenAI(
            api_key=azure_key,
            model=azure_deployment,
            base_url=f"{gateway}/v1",
            stream_usage=True,
            default_headers={
                **three,
                "x-three-ai-provider": "azure_openai",
                "x-three-ai-provider-baseurl": f"{azure_endpoint}/openai/v1",
            },
        )

        # Deployment URLs, only when AZURE_API_VERSION is set. It is an Azure API version
        # such as 2025-04-01-preview, not the model version; a wrong value gets 404 from Azure.
        api_version = env("AZURE_API_VERSION")
        azure_deployments = (
            AzureChatOpenAI(
                api_key=azure_key,
                azure_endpoint=gateway,
                azure_deployment=azure_deployment,
                api_version=api_version,
                model=azure_deployment,  # the model Three.dev records, as on v1 URLs
                default_headers={
                    **three,
                    "x-three-ai-provider": "azure_openai",
                    "x-three-ai-provider-baseurl": azure_endpoint,
                },
            )
            if api_version
            else None
        )

        targets.append(ProviderTarget("azure", lambda _: azure, session_kwargs, azure_deployments))
    else:
        skipped.append("azure (AZURE_API_KEY, AZURE_ENDPOINT and AZURE_DEPLOYMENT not all set)")

    return targets, skipped
