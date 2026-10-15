"""main.py — a small weather assistant built on LangChain and LangGraph. Every LLM call goes
through the Three.dev gateway (wired in providers.py) and is recorded there.

For each provider with keys in .env, the app runs one conversation of three calls: invoke,
stream and an agent with a tool. The three calls share one session id, sent as
x-three-session-id, so each conversation is one session in Three.dev.
Run with `task run` / `uv run src/main.py`.
"""

import os
import sys
import uuid

from dotenv import load_dotenv
from langchain.agents import create_agent
from langchain_core.messages import AIMessage, BaseMessage, HumanMessage, SystemMessage

from providers import ProviderTarget, Session, load_providers, three_session
from tools import get_weather

# Load .env when present. Variables already set in the environment win.
load_dotenv(".env", override=False)

INSTRUCTIONS = "You are a concise weather assistant. Answer in one or two sentences."


def preview(text: str, words: int = 12) -> str:
    """The first words of an answer, for a one-line summary."""
    parts = text.split()
    if not parts:
        return "(no text)"
    return " ".join(parts[:words]) + (" …" if len(parts) > words else "")


def prompt(text: str) -> list[BaseMessage]:
    return [SystemMessage(INSTRUCTIONS), HumanMessage(text)]


def run_conversation(target: ProviderTarget) -> None:
    name = target.name

    # One session id per conversation, sent with each call.
    session_id = str(uuid.uuid4())
    model = target.model(session_id)
    call_kwargs = target.call_kwargs(session_id)
    print(f"\n[{name}] session {session_id}")

    # 1. invoke
    first = model.invoke(
        prompt("In one sentence, what should I pack for a spring weekend in Paris?"),
        **call_kwargs,
    )
    print(f"[{name}] invoke: {preview(first.text)}")

    # 2. stream, printed as it streams.
    print(f"[{name}] stream: ", end="", flush=True)
    for chunk in model.stream(
        prompt("Give me one tip for staying cool on a hot day in Madrid."),
        **call_kwargs,
    ):
        print(chunk.text, end="", flush=True)
    print()

    # 3. Agent — the model calls get_weather for each city, then answers. The middleware
    #    sets the session id on each of the agent's model calls, from the run's context.
    agent = create_agent(
        model,
        tools=[get_weather],
        system_prompt=INSTRUCTIONS,
        middleware=[three_session(target.call_kwargs)],
        context_schema=Session,
    )
    result = agent.invoke(
        {"messages": [HumanMessage("Which is warmer right now, Paris or Lisbon? Use the weather tool.")]},
        context=Session(session_id),
    )
    answers = [m for m in result["messages"] if isinstance(m, AIMessage)]
    tool_calls = sum(len(m.tool_calls) for m in answers)
    print(f"[{name}] agent ({tool_calls} tool calls): {preview(answers[-1].text if answers else '')}")

    # Azure only: one call on deployment URLs, in the same session.
    if target.deployment_chat_model is not None:
        chat = target.deployment_chat_model.invoke(
            prompt("Is Lisbon usually warm in May? Answer in one sentence."),
            **call_kwargs,
        )
        print(f"[{name}] invoke (deployment URLs): {preview(chat.text)}")


def main() -> int:
    targets, skipped = load_providers()
    for line in skipped:
        print(f"skipping {line}")
    if not targets:
        print("No provider keys set — add at least one to .env (see .env.example).", file=sys.stderr)
        return 1

    failed: list[str] = []
    for target in targets:
        try:
            run_conversation(target)
        except Exception as err:
            failed.append(target.name)
            print(f"[{target.name}] failed: {err}", file=sys.stderr)

    # An exit code instead of sys.exit() mid-run, so every provider runs and the output is
    # flushed.
    exit_code = 0
    if failed:
        print(f"\nFailed: {', '.join(failed)}.", file=sys.stderr)
        exit_code = 1
    if len(failed) < len(targets):
        print(
            f'\nDone. In Three.dev, open the use case "{os.environ.get("USE_CASE_SLUG")}": each call '
            "is on its Requests page, and each provider's conversation is one session on its "
            "Sessions page."
        )
    return exit_code


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as err:
        print(err, file=sys.stderr)
        sys.exit(1)
