"""Full test pipeline for the Bash WP-CLI Update project.

Runs, through Git Bash for Windows:
  1. bash -n syntax checks on both scripts
  2. tests/scenarios/test_discovery.sh  (Find_WP_Senior.sh)
  3. tests/scenarios/test_main_update.sh (Bash_WP-CLI_Update.sh)
  4. shfmt -d advisory formatting check (skipped when shfmt is missing)

The Bash interpreter is resolved via the BASH_BIN environment variable,
falling back to 'bash' from PATH (works on Linux/macOS too).
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]


def resolve_bash() -> str:
    env = os.environ.get("BASH_BIN")
    if env:
        return env
    # Windows: prefer Git Bash before any WSL/bash shim in PATH
    candidates = [
        r"C:\Program Files\Git\bin\bash.exe",
        r"C:\Program Files (x86)\Git\bin\bash.exe",
    ]
    for cand in candidates:
        if os.path.isfile(cand):
            return cand
    fallback = shutil.which("bash")
    if fallback:
        return fallback
    raise RuntimeError("bash not found; set BASH_BIN")


def posix(path: Path, bash: str) -> str:
    """Convert a Windows path to Git Bash POSIX form (Linux paths unchanged)."""
    if os.name == "nt":
        out = subprocess.run(
            [bash, "-c", 'cygpath -u "$1"', "--", str(path)],
            capture_output=True, text=True, timeout=60,
        )
        return out.stdout.strip()
    return str(path)


def run_bash(bash: str, args: list[str], timeout: int = 300) -> subprocess.CompletedProcess:
    return subprocess.run([bash] + args, capture_output=True, text=True, timeout=timeout)


def test_syntax():
    bash = resolve_bash()
    for script in ("Bash_WP-CLI_Update.sh", "Find_WP_Senior.sh"):
        result = run_bash(bash, ["-n", str(PROJECT_ROOT / script)], timeout=120)
        assert result.returncode == 0, f"bash -n {script} failed:\n{result.stderr}"


def test_discovery_scenarios():
    bash = resolve_bash()
    suite = PROJECT_ROOT / "tests" / "scenarios" / "test_discovery.sh"
    result = run_bash(bash, [posix(suite, bash), posix(PROJECT_ROOT, bash)], timeout=300)
    if result.returncode != 0:
        print(result.stdout)
        print(result.stderr, file=sys.stderr)
    assert result.returncode == 0, "test_discovery.sh failed"
    assert "0 failed" in result.stdout


def test_main_update_scenarios():
    bash = resolve_bash()
    suite = PROJECT_ROOT / "tests" / "scenarios" / "test_main_update.sh"
    result = run_bash(bash, [posix(suite, bash), posix(PROJECT_ROOT, bash)], timeout=600)
    if result.returncode != 0:
        print(result.stdout)
        print(result.stderr, file=sys.stderr)
    assert result.returncode == 0, "test_main_update.sh failed"
    assert "0 failed" in result.stdout


def test_shfmt_advisory():
    """Advisory formatting check; never fails the suite, but warns on output."""
    import warnings
    shfmt = shutil.which("shfmt.EXE") or shutil.which("shfmt")
    if shfmt is None:
        import pytest
        pytest.skip("shfmt not installed")
    for script in ("Bash_WP-CLI_Update.sh", "Find_WP_Senior.sh"):
        result = subprocess.run(
            [shfmt, "-d", str(PROJECT_ROOT / script)],
            capture_output=True, text=True, timeout=60,
        )
        if result.returncode != 0:
            warnings.warn(
                f"shfmt -d {script} found style differences:\n{result.stdout}",
                stacklevel=2,
            )
