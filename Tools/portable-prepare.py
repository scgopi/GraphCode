"""Prepare the shared Swift fixture without platform-specific junctions."""

from pathlib import Path
import shutil


ROOT = Path(__file__).resolve().parents[1]
source = ROOT / "GraphcodeKit" / "Sources" / "Domain"
destination = ROOT / "investigation" / "spikes" / "swift-portable" / "Sources" / "GraphcodePortableDomain"
excluded = {"BackendCommand.swift", "RemoteProjectLocation.swift", "SessionBriefing.swift"}

if not source.is_dir():
    raise SystemExit(f"portable source directory is missing: {source}")

if destination.exists() or destination.is_symlink():
    if destination.is_dir() and not destination.is_symlink():
        shutil.rmtree(destination)
    else:
        destination.unlink()
destination.mkdir(parents=True)

for path in source.rglob("*.swift"):
    if path.name in excluded:
        continue
    target = destination / path.relative_to(source)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, target)

print(f"Prepared {destination} from {source}")
