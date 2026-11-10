#!/usr/bin/env python3
"""Unsigned, local-only production-source/full-SDK ownership regression."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
BASELINE = "5cabee844fe41f98a8541e5e93ca19917a0ad7df"
SDK_SHA256 = "2721c3d4338cc2a350599ffcee2a8008abaa756acfd45dd710720c64ca8c8ce3"


def preservation():
    changed = subprocess.run(
        ["git", "diff", "--name-only", BASELINE, "--"], cwd=ROOT, check=True,
        text=True, stdout=subprocess.PIPE,
    ).stdout.splitlines()
    allowed = {
        "4D Plugin API/Classes/ARRAY_TEXT.cpp",
        "4D Plugin API/Classes/C_PICTURE.cpp",
        "README.md",
        ".github/workflows/native-ownership.yml",
        "tests/native/ownership.mm",
        "tests/native/run.py",
    }
    unexpected = set(changed) - allowed
    if unexpected:
        raise SystemExit(f"unexpected tracked changes to preserved surfaces: {sorted(unexpected)}")


def cases():
    for empty in (0, 1):
        for fixture in ("ascii", "bmp", "supplementary", "empty"):
            for name in ("path", "copy", "array", "scalar", "setter-rejections", "wrapper-rejections", "dispatcher"):
                yield (name, fixture, empty, 0, 0, 0)
        for fixture in ("png", "jpg", "tif"):
            yield ("copy", fixture, empty, 0, 0, 0)
        for name in ("set-bytes", "grayscale", "properties", "thumbnail", "reject-array"):
            yield (name, "empty", empty, 0, 0, 0)
        for name in ("path", "copy", "grayscale", "properties", "thumbnail"):
            # Owning command-result cleanup; undefined procedure returns; errors;
            # and the SDK's raw-zero-kind command-handle allocation sentinel.
            for returned in (1, 2):
                yield (name, "empty", empty, returned, 0, 0)
            yield (name, "empty", empty, 0, 1, 0)
            yield (name, "empty", empty, 0, 0, 1)


def build(source, destination):
    sdk = source / "4D Plugin API"
    assert hashlib.sha256((sdk / "4DPluginAPI.c").read_bytes()).hexdigest() == SDK_SHA256
    files = [sdk / "4DPluginAPI.c", *sorted((sdk / "Classes").glob("*.cpp")),
             source / "4DPlugin.cpp", ROOT / "tests/native/ownership.mm"]
    command = [
        "xcrun", "clang++", "-std=c++11", "-x", "objective-c++",
        "-include", "Carbon/Carbon.h", "-I", str(sdk), "-I", str(sdk / "Classes"),
        "-fsanitize=address,undefined", "-fno-omit-frame-pointer", "-g", "-O1",
        "-Wno-deprecated-declarations", "-Wno-writable-strings",
        *map(str, files), "-framework", "Cocoa", "-framework", "Carbon",
        "-o", str(destination),
    ]
    subprocess.run(command, check=True)


def run(binary, logs):
    failures = []
    env = dict(os.environ, ASAN_OPTIONS="detect_leaks=0:halt_on_error=1",
               UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1")
    all_cases = list(cases())
    for index, case in enumerate(all_cases):
        result = subprocess.run([str(binary), *map(str, case)], env=env,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if result.returncode:
            path = logs / f"{index:03d}-{'-'.join(map(str, case))}.log"
            path.write_text(result.stdout)
            failures.append((case, result.stdout, path))
    print(f"{binary.name}: {len(all_cases) - len(failures)}/{len(all_cases)} passed", flush=True)
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", action="store_true", help="also prove the immutable baseline fails")
    parser.add_argument("--output", type=Path, required=True, help="scratch artifact directory outside tracked output")
    args = parser.parse_args()
    preservation()
    args.output.mkdir(parents=True, exist_ok=True)
    fixed = args.output / "ownership-fixed"
    build(ROOT, fixed)
    failures = run(fixed, args.output)
    if failures:
        for case, output, path in failures[:5]:
            print(case, path, output[:2000])
        raise SystemExit("fixed production regression failed")
    if args.baseline:
        with tempfile.TemporaryDirectory(prefix="font-name-baseline-") as directory:
            baseline = Path(directory)
            archive = subprocess.run(["git", "archive", BASELINE], cwd=ROOT, check=True,
                                     stdout=subprocess.PIPE).stdout
            subprocess.run(["tar", "-xf", "-", "-C", directory], input=archive, check=True)
            original = args.output / "ownership-baseline"
            build(baseline, original)
            failures = run(original, args.output)
        named = {
            "path-string-double-dispose": lambda case, out: case[0] == "path" and "path-string-double-dispose" in out,
            "charset-bytes-not-utf16-units": lambda case, out: case[:2] == ("copy", "ascii") and "AddressSanitizer: heap-buffer-overflow" in out,
            "overwritten-initial-string-owner": lambda case, out: case[:3] == ("copy", "empty", 1) and "string-owner-balance" in out,
            "overwritten-initial-picture-owner": lambda case, out: case[0] == "properties" and "picture-reference-balance" in out,
            "setBytes-temporary-reference": lambda case, out: case[0] == "set-bytes" and "picture-reference-balance" in out,
            "rejected-array-storage": lambda case, out: case[0] == "reject-array" and "must report failure" in out,
            "owning-command-return": lambda case, out: case[0] == "properties" and case[3] == 1 and "string-owner-balance" in out,
        }
        for name, predicate in named.items():
            matches = [path for case, out, path in failures if predicate(case, out)]
            if not matches:
                raise SystemExit(f"baseline did not fail named defect: {name}")
            print(f"BASELINE FAIL {name}: {matches[0]}", flush=True)
        print(f"Immutable baseline: {BASELINE}; bundled SDK SHA256: {SDK_SHA256}")


if __name__ == "__main__":
    main()
