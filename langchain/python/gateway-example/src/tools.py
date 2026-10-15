"""tools.py — the tool the agent can call. In a real app it would call your own weather
service; here it returns canned data so the example is deterministic and self-contained."""

from langchain.tools import tool

TEMPERATURES_C = {
    "paris": 18,
    "lisbon": 24,
    "london": 14,
    "madrid": 27,
}


@tool(parse_docstring=True)
def get_weather(city: str) -> dict[str, str | int]:
    """Get the current weather for a city.

    Args:
        city: City name, e.g. 'Paris'
    """
    return {
        "city": city,
        # "Lisbon, Portugal" -> "lisbon"; unknown cities get a default.
        "temperatureC": TEMPERATURES_C.get(city.split(",")[0].strip().lower(), 20),
        "condition": "sunny",
    }
