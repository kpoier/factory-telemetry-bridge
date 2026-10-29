#!/usr/bin/env python3
"""Exercise the packaged mod on a new temporary world, never a running service."""
import argparse
import json
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def run_engine(binary, config, mods, args, work, label):
    result = subprocess.run(
        [str(binary), "--config", str(config), "--mod-directory", str(mods), *args],
        cwd=work, capture_output=True, text=True, timeout=180,
    )
    (work / (label + ".log")).write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f"Factorio {label} failed ({result.returncode}):\n"
                           + "\n".join((result.stdout + result.stderr).splitlines()[-40:]))


def sample_server(binary, config, mods, save, work):
    """Player index 0 exports require an actual multiplayer server."""
    settings = work / "server-settings.json"
    options = json.loads((binary.parents[2] / "data/server-settings.example.json").read_text())
    options.update({
        "name": "FTB isolated CI smoke",
        "description": "Temporary loopback-only test",
        "visibility": {"public": False, "lan": False},
        "require_user_verification": False,
        "auto_pause": False,
        "autosave_interval": 10,
        "autosave_slots": 1,
        "username": "",
        "password": "",
        "token": "",
        "game_password": "",
    })
    settings.write_text(json.dumps(options))
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    log = work / "server.log"
    state_file = work / "script-output/factory-telemetry-bridge/state.json"
    state = None
    with log.open("w") as output:
        process = subprocess.Popen([
            str(binary), "--config", str(config), "--mod-directory", str(mods),
            "--start-server", str(save), "--server-settings", str(settings),
            "--bind", "127.0.0.1", "--port", str(port),
        ], cwd=work, stdout=output, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError("Temporary server exited before telemetry was produced")
                if state_file.is_file():
                    try:
                        state = json.loads(state_file.read_text())
                        if state.get("tick", 0) >= 600:
                            break
                    except json.JSONDecodeError:
                        pass  # File may be between truncate and write.
                time.sleep(0.2)
            else:
                raise RuntimeError("Temporary server did not produce telemetry by tick 600")
        except BaseException:
            print("\n".join(log.read_text().splitlines()[-40:]))
            raise
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGINT)
                try:
                    process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                    raise RuntimeError("Temporary server did not shut down cleanly")
        if process.returncode:
            raise RuntimeError(f"Temporary server failed ({process.returncode})")
    return state


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--factorio", type=Path, required=True)
    args = parser.parse_args()
    binary = args.factorio.resolve()
    if not binary.is_file():
        parser.error("Factorio binary does not exist")
    info = json.loads((ROOT / "mod/info.json").read_text())
    with tempfile.TemporaryDirectory(prefix="ftb-smoke-") as temporary:
        work = Path(temporary)
        mods = work / "mods"
        mods.mkdir()
        subprocess.run(
            ["python3", str(ROOT / "scripts/build.py"), "--output", str(work / "dist")],
            cwd=ROOT, check=True,
        )
        archive = work / "dist" / f"{info['name']}_{info['version']}.zip"
        shutil.copy2(archive, mods / archive.name)
        data = binary.parents[2] / "data"
        enabled_mods = [
            {"name": "base", "enabled": True},
            {"name": info["name"], "enabled": True},
        ]
        for builtin in sorted(data.glob("*/info.json")):
            name = json.loads(builtin.read_text()).get("name")
            if name not in ("core", "base", info["name"]):
                enabled_mods.append({"name": name, "enabled": False})
        (mods / "mod-list.json").write_text(json.dumps({"mods": enabled_mods}))
        config = work / "config.ini"
        config.write_text(f"[path]\nread-data={data}\nwrite-data={work}\n")
        save = work / "smoke.zip"
        run_engine(binary, config, mods, ["--create", str(save)], work, "create")
        state = sample_server(binary, config, mods, save, work)
        assert state["schema_version"] == 2, "Unexpected telemetry schema"
        assert state["mod_version"] == info["version"], "Wrong packaged mod loaded"
        assert state["tick"] >= 300, "Periodic sampling was not exercised"
        assert state["force"] == "player" and state["surface"] == "nauvis"
        for key in ("items", "fluids", "players", "power", "trains"):
            assert key in state, f"Missing telemetry field: {key}"
        print(f"Headless smoke passed: version {info['version']}, tick {state['tick']}, schema 2")


if __name__ == "__main__":
    main()
