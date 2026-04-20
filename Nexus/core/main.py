"""
Nexus Core — Main Loop
======================
Conversation loop powered by Ollama (local AI).
"""
import json, os, requests
from memory import Memory
from skill_loader import SkillLoader

CORE_FILE  = os.path.join(os.path.dirname(__file__), "data", "core_memory.json")
OLLAMA_URL = "http://localhost:11434/api/chat"

def chat(model, messages):
    r = requests.post(OLLAMA_URL, json={"model": model, "messages": messages, "stream": False})
    return r.json()["message"]["content"]

def system_prompt(ctx):
    facts = "\n".join(f"- {f}" for f in ctx["recent_facts"]) or "None yet."
    return f"""You are Nexus, a personal AI assistant.
Calm. Direct. Honest. Never say "Great question!". Never apologise for existing.
Be honest about your limits, then move to what you can do.

The person you are talking to: {ctx['name']}
Their language: {ctx['language']}

What you know about them:
{facts}

Be brief unless depth is needed."""

def main():
    if not os.path.exists(CORE_FILE):
        print("Run seed/install.py first.")
        return
    with open(CORE_FILE) as f:
        core = json.load(f)

    mem    = Memory()
    skills = SkillLoader()
    model  = core.get("model", "phi3:mini")

    print(f"\nNexus online. Hi {core['name']}.\n")

    while True:
        try:
            user_input = input("You: ").strip()
        except (KeyboardInterrupt, EOFError):
            print("\nNexus: Goodbye.")
            break
        if not user_input: continue

        ctx = mem.get_context()
        mem.add_working("user", user_input)
        messages = [{"role": "system", "content": system_prompt(ctx)}] + mem.working
        response = chat(model, messages)
        mem.add_working("assistant", response)
        print(f"\nNexus: {response}\n")

if __name__ == "__main__":
    main()
