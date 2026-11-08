#!/usr/bin/env python3
"""Compare the documented WaveDrom sample points with a simulation VCD."""
import json
import re
import sys
from pathlib import Path


def read_vcd(path):
    ids = {}
    widths = {}
    scope = []
    values = {}
    samples = []
    last_point = None
    in_header = True

    def flush():
        nonlocal last_point
        point_id = ids.get("doc_point")
        if point_id is None or point_id not in values:
            return
        raw = values[point_id]
        if any(c in raw for c in "xz"):
            return
        point = int(raw, 2)
        if point != last_point and point != 255:
            samples.append((point, {
                name: values.get(code, "x") for name, code in ids.items()
            }))
        last_point = point

    for line in path.read_text().splitlines():
        parts = line.split()
        if in_header:
            if parts[:1] == ["$scope"]:
                scope.append(parts[2])
            elif parts[:1] == ["$upscope"]:
                scope.pop()
            elif parts[:1] == ["$var"] and scope == ["tb"]:
                widths[parts[4]] = int(parts[2])
                ids[parts[4]] = parts[3]
            elif parts[:1] == ["$enddefinitions"]:
                in_header = False
        elif line.startswith("#"):
            flush()
        elif line and line[0] in "01xXzZ":
            values[line[1:]] = line[0].lower()
        elif line and line[0] in "bB":
            bit, code = line.split()
            values[code] = bit[1:].lower()
    flush()
    return widths, samples


def normalize(raw, width):
    raw = raw.lower()
    fill = raw[0] if raw and raw[0] in "xz" else "0"
    return raw.rjust(width, fill)


def documented(path, widths):
    match = re.search(r"```wavedrom\s*\n(.*?)\n```", path.read_text(), re.S)
    if not match:
        raise ValueError(f"missing WaveDrom block in {path}")
    lanes = json.loads(match.group(1))["signal"]
    sample_lane = next(lane for lane in lanes if lane["name"] == "sample")
    count = len(sample_lane["data"])
    if sample_lane["wave"] != "=" * count or sample_lane["data"] != [str(i) for i in range(count)]:
        raise ValueError("sample lane must enumerate all points in order")
    expected = {}
    for lane in lanes:
        name = lane["name"]
        if name == "sample":
            continue
        if name not in widths:
            raise ValueError(f"VCD signal missing: {name}")
        wave = lane["wave"]
        if len(wave) != count:
            raise ValueError(f"{name}: {len(wave)} slots, expected {count}")
        data = iter(lane.get("data", []))
        decoded = []
        current = None
        for symbol in wave:
            if symbol == ".":
                if current is None:
                    raise ValueError(f"{name}: first slot cannot hold")
            elif symbol == "=":
                label = next(data)
                if re.fullmatch(r"[01xXzZ]+", label) and len(label) == widths[name]:
                    current = label.lower()
                else:
                    current = format(int(label, 0), f"0{widths[name]}b")
            elif symbol in "01xz":
                current = normalize(symbol, widths[name])
            else:
                raise ValueError(f"{name}: unsupported WaveDrom symbol {symbol}")
            decoded.append(current)
        if next(data, None) is not None:
            raise ValueError(f"{name}: unused data labels")
        expected[name] = decoded
    return count, expected


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: check_wave.py EXERCISE")
    name = sys.argv[1]
    widths, samples = read_vcd(Path(f"sim/{name}.vcd"))
    count, expected = documented(Path(f"exercises/{name}/README.md"), widths)
    errors = []
    if [point for point, _ in samples] != list(range(count)):
        errors.append(f"sample indices: VCD {[p for p, _ in samples]}, doc {list(range(count))}")
    for point, signals in samples:
        if point >= count:
            continue
        for signal_name, sequence in expected.items():
            actual = normalize(signals[signal_name], widths[signal_name])
            if actual != sequence[point]:
                errors.append(f"sample {point} {signal_name}: VCD {actual}, WaveDrom {sequence[point]}")
    if errors:
        print("FAIL wave " + name + ": " + "; ".join(errors))
        raise SystemExit(1)
    print(f"PASS wave {name}: {count} documented samples match sim/{name}.vcd")


if __name__ == "__main__":
    main()
