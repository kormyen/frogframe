#!/usr/bin/env python3
"""Check the Git file set without printing private credential values."""
from pathlib import Path
import json
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
PRIVATE_DIRS = {".wrangler", ".playwright-cli", ".gradle", ".build", "build", "output", "image-bucket", "node_modules"}
SECRET_PATTERNS = {
    "private key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
    "GitHub token": re.compile(rb"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,})\b"),
    "AWS access key": re.compile(rb"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
}


def git_files(git_dir=None):
    command = ["git", "-c", "core.excludesFile=/dev/null"]
    if git_dir:
        command += ["--git-dir=" + str(git_dir), "--work-tree=" + str(ROOT)]
    command += ["ls-files", "--cached", "--others", "--exclude-standard", "-z"]
    result = subprocess.run(command, cwd=ROOT, check=True, capture_output=True)
    return sorted(set(name.decode("utf-8") for name in result.stdout.split(b"\0") if name))


def private_path(name):
    path = Path(name)
    base = path.name
    if set(path.parts[:-1]) & PRIVATE_DIRS:
        return True
    if base in {"LOCAL.md", "local.properties", ".DS_Store"} or base.endswith((".local.json", ".local.jsonc", ".p12", ".pfx", ".key", ".pem", ".jks", ".keystore")):
        return True
    return (base == ".env" or base.startswith(".env.") or base.startswith(".dev.vars")) and base not in {".env.example", ".dev.vars.example"}


def local_values():
    values = []
    for name in ["manager.local.json", "viewer.local.json", "worker/wrangler.local.json"]:
        file = ROOT / name
        if not file.exists():
            continue
        document = json.loads(file.read_text())
        for key in ["token", "endpoint", "account_id"]:
            value = document.get(key)
            if isinstance(value, str) and len(value) >= 8 and not re.search(r"YOUR_|REPLACE_|\.example\b", value):
                values.append(("local " + key, value.encode()))
    profile = ROOT / "worker/.wrangler/personal-config/.wrangler/config/default.toml"
    if profile.exists():
        for key, value in re.findall(r'^([A-Za-z_]*token[A-Za-z_]*)\s*=\s*"([^"\n]+)"', profile.read_text(), re.M | re.I):
            if len(value) >= 8:
                values.append(("local sign-in token", value.encode()))
    return values


def inspect(names):
    values = local_values()
    findings = []
    for name in names:
        if private_path(name):
            findings.append((name, "private file is included in the Git file set"))
            continue
        file = ROOT / name
        if file.is_symlink():
            findings.append((name, "symbolic link needs manual review"))
            continue
        if not file.exists():  # A tracked file can be deleted but not yet staged.
            continue
        if file.stat().st_size > 5 * 1024 * 1024:
            findings.append((name, "file larger than 5 MiB needs manual review"))
            continue
        content = file.read_bytes()
        for kind, value in values:
            if value in content:
                findings.append((name, "contains a known " + kind + " value"))
        for kind, pattern in SECRET_PATTERNS.items():
            if pattern.search(content):
                findings.append((name, "possible " + kind))
    return sorted(set(findings))


def main():
    repository = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=ROOT, capture_output=True, text=True)
    if repository.returncode == 0:
        if Path(repository.stdout.strip()).resolve() != ROOT:
            raise RuntimeError("Frogframe must be the Git repository root for this check.")
        names = git_files()
        mode = "tracked and non-ignored files"
    else:
        # Apply this folder's ignore rules without creating a repository in it.
        with tempfile.TemporaryDirectory(prefix="phototab-public-check-") as temporary:
            subprocess.run(["git", "init", "-q", temporary], check=True, capture_output=True)
            names = git_files(Path(temporary) / ".git")
        mode = "non-ignored files (no Git history available)"
    findings = inspect(names)
    if findings:
        for name, reason in findings:
            print("FAIL: {}: {}".format(name, reason))
        return 1
    print("PASS: checked {} {}. No private paths or matching credential values found.".format(len(names), mode))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        print("Public-file check could not complete. Check local configuration files and Git access; no credential values were printed.", file=sys.stderr)
        sys.exit(1)
