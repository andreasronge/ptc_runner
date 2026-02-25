#!/usr/bin/env python3
"""Mock ALFWorld bridge for testing the Port wrapper.

Speaks the same JSON-line protocol as the real bridge but returns
canned responses without requiring ALFWorld to be installed.
"""

import json
import sys

MOCK_TASKS = [
    "path/to/task1.tw-pddl",
    "path/to/task2.tw-pddl",
    "path/to/task3.tw-pddl",
]

INITIAL_OBS = (
    "You are in the middle of a room. Looking quickly around you, "
    "you see a desk 1, a shelf 1, and a drawer 1.\n"
    "Your task is to put a mug in shelf."
)

STEP_RESPONSES = {
    "go to desk 1": {
        "obs": "On the desk 1, you see a mug 1 and a pen 1.",
        "admissible_commands": [
            "take mug 1 from desk 1",
            "take pen 1 from desk 1",
            "go to shelf 1",
            "go to drawer 1",
        ],
        "done": False,
        "score": 0,
    },
    "take mug 1 from desk 1": {
        "obs": "You pick up the mug 1 from the desk 1.",
        "admissible_commands": [
            "go to shelf 1",
            "go to drawer 1",
            "go to desk 1",
            "put mug 1 in/on shelf 1",
            "put mug 1 in/on drawer 1",
        ],
        "done": False,
        "score": 0,
    },
    "go to shelf 1": {
        "obs": "You arrive at shelf 1. On the shelf 1, you see nothing.",
        "admissible_commands": [
            "put mug 1 in/on shelf 1",
            "go to desk 1",
            "go to drawer 1",
        ],
        "done": False,
        "score": 0,
    },
    "put mug 1 in/on shelf 1": {
        "obs": "You put the mug 1 in/on the shelf 1.",
        "admissible_commands": [],
        "done": True,
        "score": 1,
    },
}

DEFAULT_STEP = {
    "obs": "Nothing happens.",
    "admissible_commands": [
        "go to desk 1",
        "go to shelf 1",
        "go to drawer 1",
        "look",
        "inventory",
    ],
    "done": False,
    "score": 0,
}


def send(data):
    sys.stdout.write(json.dumps(data) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            cmd = json.loads(line)
        except json.JSONDecodeError:
            send({"status": "error", "error": "Invalid JSON"})
            continue

        action = cmd.get("cmd")

        if action == "init":
            send({"status": "ok", "task_count": len(MOCK_TASKS)})

        elif action == "list_tasks":
            send({"tasks": MOCK_TASKS})

        elif action == "reset":
            send({
                "obs": INITIAL_OBS,
                "admissible_commands": [
                    "go to desk 1",
                    "go to shelf 1",
                    "go to drawer 1",
                    "look",
                    "inventory",
                ],
                "goal": "Your task is to put a mug in shelf.",
                "done": False,
                "score": 0,
            })

        elif action == "step":
            act = cmd.get("action", "")
            resp = STEP_RESPONSES.get(act, DEFAULT_STEP)
            send(resp)

        elif action == "shutdown":
            send({"status": "ok"})
            break

        else:
            send({"status": "error", "error": f"Unknown command: {action}"})


if __name__ == "__main__":
    main()
