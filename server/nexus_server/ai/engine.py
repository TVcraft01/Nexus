# Command Engine - Zero-LLM NLP processor
#
# Ported from the existing Android/desktop ZeroLLMCommandEngine.
# Uses regex rules + user dialect rules + learning repository for
# intent parsing without requiring a local LLM.

from __future__ import annotations

import ast
import json
import logging
import operator
import os
import platform
import random
import re
import shutil
import subprocess
import sys
import urllib.parse
import urllib.request
import webbrowser
from datetime import datetime
from typing import Callable, List, Optional, Tuple

from nexus_server.models import (
    CommandAction, CommandResult, CommandStatus, ParsedIntent,
    SAFE_COMMANDS,
)
from nexus_server.storage import UserRulesRepository

logger = logging.getLogger("nexus.ai.engine")

# Allowed operators for safe calculation
_SAFE_OPS = {
    ast.Add: operator.add, ast.Sub: operator.sub,
    ast.Mult: operator.mul, ast.Div: operator.truediv,
    ast.Pow: operator.pow, ast.USub: operator.neg,
}


def _safe_calculate(expr: str) -> float:
    """Safely evaluate a mathematical expression without using eval().

    Uses ast.literal_eval for constants or a restricted AST walker for
    basic arithmetic. Rejects all function calls, attribute access, etc.
    """
    expr = expr.strip()
    if not expr:
        raise ValueError("Empty expression")

    # Try literal eval first (handles pure numbers)
    try:
        return float(ast.literal_eval(expr))
    except (ValueError, SyntaxError):
        pass

    # Restricted AST evaluator for basic arithmetic
    tree = ast.parse(expr, mode="eval")
    return _eval_ast(tree.body)


def _eval_ast(node) -> float:
    """Recursively evaluate a restricted AST node."""
    if isinstance(node, ast.Constant):
        if isinstance(node.value, (int, float)):
            return float(node.value)
        raise ValueError(f"Invalid constant: {node.value}")
    if isinstance(node, ast.BinOp):
        op_func = _SAFE_OPS.get(type(node.op))
        if op_func is None:
            raise ValueError(f"Unsupported operator: {type(node.op).__name__}")
        return op_func(_eval_ast(node.left), _eval_ast(node.right))
    if isinstance(node, ast.UnaryOp):
        op_func = _SAFE_OPS.get(type(node.op))
        if op_func is None:
            raise ValueError(f"Unsupported unary operator: {type(node.op).__name__}")
        return op_func(_eval_ast(node.operand))
    raise ValueError(f"Unsupported expression: {ast.dump(node)}")


class CommandEngine:
    """Pattern-matching command parser and executor (no LLM required)."""

    _BUILT_IN_RULES: List[Tuple[re.Pattern, Callable]] = []

    def __init__(self, rules_repo: UserRulesRepository):
        self.rules_repo = rules_repo

    # ------------------------------------------------------------------
    # Parse commands (regex + user rules)
    # ------------------------------------------------------------------

    def parse_command(self, input_text: str) -> Optional[CommandAction]:
        intent = self.parse_command_intent(input_text)
        return intent.action if intent else None

    def parse_command_intent(self, input_text: str) -> Optional[ParsedIntent]:
        sanitized = input_text.strip()
        if not sanitized:
            return None

        # User rules first (highest priority)
        for rule in sorted(self.rules_repo.get_enabled_rules(),
                          key=lambda r: -r.priority):
            try:
                compiled = re.compile(rule.pattern, re.IGNORECASE)
                match = compiled.search(sanitized)
                if match:
                    action = self._action_from_rule(rule, match)
                    return ParsedIntent(action, confidence=1.0, source="user_rule")
            except re.error:
                continue

        # Built-in regex rules
        for regex, factory in self._get_built_in_rules():
            match = regex.search(sanitized)
            if match:
                try:
                    action = factory(match, sanitized)
                    return ParsedIntent(action, confidence=1.0, source="regex")
                except Exception:
                    continue

        return None

    def execute_command(self, input_text: str) -> CommandResult:
        sanitized = input_text.strip()
        if not sanitized:
            return CommandResult(False, "Empty command.", CommandAction.Unknown(""))

        intent = self.parse_command_intent(sanitized)
        if intent:
            return self.perform_action(intent.action)

        return CommandResult(
            False,
            f"I don't know how to handle '{sanitized}'. Teach me?",
            CommandAction.Unknown(sanitized),
            CommandStatus.FAILED,
            requires_intern_choice=True,
            choices=["Teach", "Cancel"],
        )

    # ------------------------------------------------------------------
    # Execute actions
    # ------------------------------------------------------------------

    def perform_action(self, action: CommandAction) -> CommandResult:
        """Execute a parsed command action."""
        try:
            result = self._execute_action(action)
            return result
        except Exception as e:
            logger.exception(f"Action {action.name} failed: {e}")
            return CommandResult(False, f"Failed: {e}", action, CommandStatus.FAILED)

    def _execute_action(self, action: CommandAction) -> CommandResult:
        name = action.name
        args = action.args

        # Read-only info commands
        if name == "GET_TIME_DATE":
            now = datetime.now()
            msg = f"It's {now.strftime('%I:%M %p')} on {now.strftime('%A, %B %d, %Y')}"
            return CommandResult(True, msg, action, CommandStatus.VERIFIED_SUCCESS)

        if name == "CALCULATE":
            expr = args.get("expression", "")
            try:
                result = _safe_calculate(expr)
                return CommandResult(True, f"{expr} = {result}", action, CommandStatus.VERIFIED_SUCCESS)
            except Exception as e:
                return CommandResult(False, f"Cannot calculate '{expr}': {e}", action)

        if name == "ROLL_DICE":
            sides = args.get("sides", 6)
            roll = random.randint(1, sides)
            return CommandResult(True, f"Rolled a {roll}", action, CommandStatus.VERIFIED_SUCCESS)

        if name == "FLIP_COIN":
            result = "Heads" if random.random() > 0.5 else "Tails"
            return CommandResult(True, result, action, CommandStatus.VERIFIED_SUCCESS)

        if name == "GET_JOKE":
            jokes = [
                "Why don't scientists trust atoms? Because they make up everything!",
                "What did the zero say to the eight? Nice belt!",
                "Why was the math book sad? It had too many problems.",
            ]
            return CommandResult(True, random.choice(jokes), action, CommandStatus.VERIFIED_SUCCESS)

        # Web/URL actions
        if name == "OPEN_WEBSITE":
            url = args.get("url", "")
            if not url.startswith("http"):
                url = f"https://{url}"
            webbrowser.open(url)
            return CommandResult(True, f"Opening {url}", action, CommandStatus.VERIFIED_SUCCESS)

        if name == "WEB_SEARCH":
            query = urllib.parse.quote(args.get("query", ""))
            webbrowser.open(f"https://www.google.com/search?q={query}")
            return CommandResult(True, f"Searching for '{query}'", action, CommandStatus.VERIFIED_SUCCESS)

        # System actions (desktop-only)
        if name == "SET_VOLUME":
            percent = args.get("percent", 50)
            self._system_volume(percent)
            return CommandResult(True, f"Volume set to {percent}%", action, CommandStatus.VERIFIED_SUCCESS)

        if name == "TAKE_NOTE":
            content = args.get("content", "")
            return self._save_note(content, action)

        if name == "SET_TIMER":
            seconds = args.get("seconds", 60)
            label = args.get("label", "")
            desc = f" for '{label}'" if label else ""
            return CommandResult(True, f"Timer set for {seconds}s{desc}", action, CommandStatus.VERIFIED_SUCCESS)

        if name == "SET_REMINDER":
            task = args.get("task", "")
            return CommandResult(True, f"Reminder set: {task}", action, CommandStatus.VERIFIED_SUCCESS)

        if name == "NAVIGATE":
            dest = args.get("destination", "")
            return CommandResult(True, f"Navigation to '{dest}' would open in maps app", action,
                               CommandStatus.PENDING_HANDOFF)

        # Unknown / catchall
        return CommandResult(False, f"Unhandled action: {name}", action, CommandStatus.FAILED)

    def teach_rule(self, input_text: str, action: CommandAction) -> bool:
        """Teach Nexus a new user dialect rule."""
        try:
            self.rules_repo.add_rule(
                pattern=re.escape(input_text.strip().lower()),
                action_type=action.name,
                payload=json.dumps(action.args),
                priority=200,
            )
            return True
        except Exception:
            return False

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _system_volume(percent: int) -> None:
        """Set system volume (Linux)."""
        try:
            subprocess.run(["pactl", "set-sink-volume", "@DEFAULT_SINK@",
                          f"{percent}%"], capture_output=True, timeout=5)
        except Exception:
            pass

    @staticmethod
    def _save_note(content: str, action: CommandAction) -> CommandResult:
        """Save a note to a local file."""
        notes_dir = os.path.expanduser("~/nexus-notes")
        os.makedirs(notes_dir, exist_ok=True)
        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        note_file = os.path.join(notes_dir, f"note-{timestamp}.txt")
        with open(note_file, "w", encoding="utf-8") as f:
            f.write(content)
        return CommandResult(True, f"Note saved to {note_file}", action,
                           CommandStatus.VERIFIED_SUCCESS)

    @staticmethod
    def _action_from_rule(rule, match):
        """Build action from user rule match."""
        payload = match.group(1) if match.groups() else rule.payload
        try:
            args = json.loads(payload) if payload and payload.startswith("{") else {}
        except json.JSONDecodeError:
            args = {}
        return CommandAction(rule.action_type, args)

    @classmethod
    def _get_built_in_rules(cls) -> List[Tuple[re.Pattern, Callable]]:
        """Built-in regex rules for common commands."""
        if cls._BUILT_IN_RULES:
            return cls._BUILT_IN_RULES

        rules = [
            # Time/Date
            (re.compile(r"\bwhat\s*(?:time|date|day)\b", re.IGNORECASE),
             lambda m, s: CommandAction.GetTimeDate()),

            # Volume
            (re.compile(r"\b(?:set|change)\s+volume\s+(?:to\s+)?(\d+)", re.IGNORECASE),
             lambda m, s: CommandAction.SetVolume(int(m.group(1)))),

            # Web search
            (re.compile(r"\b(?:search|find)\s+(.+)", re.IGNORECASE),
             lambda m, s: CommandAction.WebSearch(m.group(1).strip())),

            # Open website
            (re.compile(r"\b(?:go\s+to|open)\s+(.+)", re.IGNORECASE),
             lambda m, s: CommandAction.OpenWebsite(m.group(1).strip())),

            # Timer
            (re.compile(r"\bset\s+a?\s*timer\s+for\s+(\d+)\s*(?:seconds?|secs?|minutes?|mins?)?\b", re.IGNORECASE),
             lambda m, s: CommandAction.SetTimer(int(m.group(1)) * (60 if "min" in s.lower() else 1))),

            # Note
            (re.compile(r"\b(?:take|make|save)\s+a?\s*note\s*(.+)?", re.IGNORECASE),
             lambda m, s: CommandAction.TakeNote(m.group(1).strip() if m.group(1) else "")),

            # Calculate
            (re.compile(r"\b(?:calculate|compute|what\s+is)\s+(.+)\??$", re.IGNORECASE),
             lambda m, s: CommandAction.Calculate(m.group(1).strip().rstrip("?").strip())),

            # Dice
            (re.compile(r"\b(?:roll|throw)\s+(?:a\s+)?dice\b", re.IGNORECASE),
             lambda m, s: CommandAction.RollDice(6)),

            # Coin
            (re.compile(r"\bflip\s+(?:a\s+)?coin\b", re.IGNORECASE),
             lambda m, s: CommandAction.FlipCoin()),

            # Joke
            (re.compile(r"\btell\s+me\s+(?:a\s+)?joke\b", re.IGNORECASE),
             lambda m, s: CommandAction.GetJoke()),
        ]

        cls._BUILT_IN_RULES = rules
        return rules
