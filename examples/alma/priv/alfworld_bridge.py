#!/usr/bin/env python3
"""ALFWorld bridge for ALMA.

Reads JSON-line commands from stdin, writes JSON-line responses to stdout.
Stays alive for multiple episodes (Port reuse).

Protocol:
  -> {"cmd": "init", "config_path": "...", "split": "eval_out_of_distribution"}
  <- {"status": "ok", "task_count": 134}

  -> {"cmd": "list_tasks"}
  <- {"tasks": ["path1.tw-pddl", ...]}

  -> {"cmd": "reset", "game_file": "path/to/task.tw-pddl"}
  <- {"obs": "...", "admissible_commands": [...], "goal": "...", "done": false, "score": 0}

  -> {"cmd": "step", "action": "go to desk 1"}
  <- {"obs": "...", "admissible_commands": [...], "done": false, "score": 0}

  -> {"cmd": "shutdown"}
"""

import json
import sys
import os


def send(data):
    """Write a JSON line to stdout and flush."""
    sys.stdout.write(json.dumps(data) + "\n")
    sys.stdout.flush()


def send_error(msg):
    send({"status": "error", "error": msg})


def default_config(alfworld_data, split):
    """Build a minimal ALFWorld config dict programmatically."""
    return {
        "dataset": {
            "data_path": os.path.join(alfworld_data, "json_2.1.1", "train"),
            "eval_id_data_path": os.path.join(alfworld_data, "json_2.1.1", "valid_seen"),
            "eval_ood_data_path": os.path.join(alfworld_data, "json_2.1.1", "valid_unseen"),
            "num_train_games": -1,
            "num_eval_games": -1,
        },
        "logic": {
            "domain": os.path.join(alfworld_data, "logic", "alfred.pddl"),
            "grammar": os.path.join(alfworld_data, "logic", "alfred.twl2"),
        },
        "env": {
            "type": "AlfredTWEnv",
            "regen_game_files": False,
            "domain_randomization": False,
            "task_types": [1, 2, 3, 4, 5, 6],
            "goal_desc_human_anns_prob": 0,
            "expert_type": "handcoded",
        },
        "controller": {
            "type": "oracle",
            "debug": False,
        },
        "general": {
            "random_seed": 42,
            "training_method": "dagger",
        },
        "dagger": {
            "training": {
                "max_nb_steps_per_episode": 50,
            },
        },
    }


def set_game_files(env, files):
    """Walk the gym wrapper chain and set game_files at every level."""
    e = env
    while e is not None:
        for attr in ("game_files", "gameFiles"):
            if hasattr(e, attr):
                setattr(e, attr, files)
        e = getattr(e, "env", getattr(e, "_wrapped_env", None))


def main():
    env = None
    tw_env = None
    game_files = []

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            cmd = json.loads(line)
        except json.JSONDecodeError as e:
            send_error(f"Invalid JSON: {e}")
            continue

        action = cmd.get("cmd")

        if action == "init":
            try:
                from alfworld.agents.environment.alfred_tw_env import AlfredTWEnv
                from alfworld.info import ALFWORLD_DATA

                config_path = cmd.get("config_path")
                split = cmd.get("split", "eval_out_of_distribution")
                alfworld_data = cmd.get("alfworld_data", ALFWORLD_DATA)

                if config_path:
                    import yaml
                    with open(config_path) as f:
                        config = yaml.safe_load(f)
                    ds = config.get("dataset", {})
                    for key in ["data_path", "eval_id_data_path", "eval_ood_data_path"]:
                        if key in ds and not os.path.isabs(ds[key]):
                            ds[key] = os.path.join(alfworld_data, ds[key])
                else:
                    config = default_config(alfworld_data, split)

                tw_env = AlfredTWEnv(config, train_eval=split)
                env = tw_env.init_env(batch_size=1)

                game_files = list(tw_env.game_files)

                send({"status": "ok", "task_count": len(game_files)})
            except Exception as e:
                import traceback
                send_error(f"Failed to initialize ALFWorld: {e}\n{traceback.format_exc()}")

        elif action == "list_tasks":
            send({"tasks": game_files})

        elif action == "reset":
            if env is None:
                send_error("Environment not initialized. Call init first.")
                continue

            try:
                game_file = cmd.get("game_file")
                if game_file:
                    files = [game_file]
                    tw_env.game_files = files
                    set_game_files(env, files)

                obs, infos = env.reset()
                obs_text = obs[0] if isinstance(obs, (list, tuple)) else str(obs)
                admissible = infos.get("admissible_commands", [[]])[0]

                # Extract goal from observation text (first line usually)
                lines = obs_text.strip().split("\n")
                goal = lines[0] if lines else ""

                send({
                    "obs": obs_text,
                    "admissible_commands": admissible,
                    "goal": goal,
                    "done": False,
                    "score": 0,
                })
            except Exception as e:
                import traceback
                send_error(f"Reset failed: {e}\n{traceback.format_exc()}")

        elif action == "step":
            if env is None:
                send_error("Environment not initialized. Call init first.")
                continue

            try:
                act = cmd.get("action", "look")
                obs, scores, dones, infos = env.step([act])

                obs_text = obs[0] if isinstance(obs, (list, tuple)) else str(obs)
                done = bool(dones[0]) if isinstance(dones, (list, tuple)) else bool(dones)
                score = float(scores[0]) if isinstance(scores, (list, tuple)) else float(scores)
                admissible = infos.get("admissible_commands", [[]])[0]

                send({
                    "obs": obs_text,
                    "admissible_commands": admissible,
                    "done": done,
                    "score": score,
                })
            except Exception as e:
                import traceback
                send_error(f"Step failed: {e}\n{traceback.format_exc()}")

        elif action == "shutdown":
            if env is not None:
                try:
                    env.close()
                except Exception:
                    pass
            send({"status": "ok"})
            break

        else:
            send_error(f"Unknown command: {action}")


if __name__ == "__main__":
    main()
