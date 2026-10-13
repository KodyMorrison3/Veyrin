#!/usr/bin/env python3
"""Local, value-redacted triage; a match needs review, not automatic history repair."""
import collections
import json
import re
import subprocess
from pathlib import Path


def git(*args):
    return subprocess.check_output(["git", *args])


patterns = {
    "private-key": rb"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----",
    "provider-credential": rb"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|AKIA[0-9A-Z]{16}|sk-(?:proj-)?[A-Za-z0-9_-]{24,})",
    "jwt": rb"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b",
    "literal-auth-header": rb"(?i)(?:Token|Bearer|Basic)\s+[A-Za-z0-9+/_.=-]{16,}",
    "secret-assignment": rb"(?i)(?:session.?token|api.?key|password|authorization|cookie|client.?secret|access.?token|refresh.?token)\s*[\"']?\s*[:=]\s*[\"']([^\"'\r\n]{8,})",
    "long-opaque-string": rb"[\"'][A-Za-z0-9_+/=-]{40,}[\"']",
    "personal-email": rb"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b",
    "account-or-conversation-literal": rb"(?i)(?:raw_content|user__id|user_id|creator_id|chat_id|author_id|username|user__username)\\?[\"']\s*:\s*(?:\\?[\"'][^\r\n]{1,120}|[0-9]{4,})",
}
compiled = {name: re.compile(pattern) for name, pattern in patterns.items()}
objects = [line.split() for line in git("cat-file", "--batch-all-objects", "--batch-check=%(objectname) %(objecttype) %(objectsize)").decode().splitlines()]
paths = collections.defaultdict(set)
first_commit = {}
commits = [oid for oid, kind, _ in objects if kind == "commit"]
for commit in commits:
    for entry in git("ls-tree", "-r", "-z", commit).split(b"\0"):
        if not entry:
            continue
        metadata, name = entry.split(b"\t", 1)
        oid = metadata.split()[2].decode()
        paths[oid].add(name.decode(errors="replace"))
        first_commit.setdefault(oid, commit)

findings = []
binary = []
for oid, kind, size in objects:
    if kind not in ("blob", "commit", "tag"):
        continue
    data = git("cat-file", kind, oid)
    if kind == "blob" and (b"\0" in data[:8192] or data.startswith(b"\x89PNG")):
        binary.append({"object": oid, "paths": sorted(paths[oid]), "bytes": int(size)})
    for category, pattern in compiled.items():
        lines = sorted({data.count(b"\n", 0, match.start()) + 1 for match in pattern.finditer(data)})
        if lines:
            findings.append({"category": category, "object": oid, "kind": kind,
                             "paths": sorted(paths[oid]), "example_commit": first_commit.get(oid, oid if kind == "commit" else None),
                             "lines": lines})

suspicious_paths = sorted({name for names in paths.values() for name in names if re.search(
    r"(?i)(?:\.env(?:\.|$)|\.(?:har|log|pem|p12|key|dmg|xcuserstate)$|captures?/|request.dum|xcuserdata/|credentials?|secrets?|diagnostic)", name)})
result = {"head": git("rev-parse", "HEAD").decode().strip(),
          "refs": git("for-each-ref", "--format=%(refname) %(objectname)").decode().splitlines(),
          "shallow": git("rev-parse", "--is-shallow-repository").decode().strip(),
          "counts": dict(collections.Counter(kind for _, kind, _ in objects)),
          "historical_paths": sorted({name for names in paths.values() for name in names}),
          "suspicious_paths": suspicious_paths, "binary_objects": binary, "findings": findings}
output = Path("build/release-audit/history-triage.json")
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(result, indent=2) + "\n")
print("Local object inventory:", result["counts"])
print("Candidate counts (values withheld):", dict(collections.Counter(item["category"] for item in findings)))
print("History paths needing review:", suspicious_paths)
print("Redacted triage:", output)
