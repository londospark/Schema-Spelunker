import re
import sys


def main():
    if len(sys.argv) < 2:
        print("Usage: fix_foreign_prefixes.py <path-to-imgui.odin>", file=sys.stderr)
        sys.exit(1)

    filepath = sys.argv[1]
    with open(filepath, "r") as f:
        lines = f.readlines()

    # Find the foreign block
    body_start = None
    body_end = None
    depth = 0
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped == "foreign imguilib {":
            body_start = i + 1
            depth = 1
        elif body_start is not None:
            if "{" in line:
                depth += line.count("{")
            if "}" in line:
                depth -= line.count("}")
                if depth == 0:
                    body_end = i
                    break

    if body_start is None or body_end is None:
        print("Error: could not find foreign imguilib block", file=sys.stderr)
        sys.exit(1)

    header = lines[: body_start - 2]   # exclude @attr line and foreign line
    body_all = lines[body_start:body_end]

    ig = []
    im = []
    buf = []
    cur = None

    for line in body_all:
        m = re.match(r'^\t(\w[\w_]*) :: proc', line)
        if m:
            if buf and cur is not None:
                text = "".join(buf)
                if "_" in cur:
                    im.append(text)
                else:
                    ig.append(text)
            cur = m.group(1)
            buf = [line]
        else:
            buf.append(line)

    if buf and cur is not None:
        text = "".join(buf)
        if "_" in cur:
            im.append(text)
        else:
            ig.append(text)

    out = []
    out.extend(header)
    out.append('')
    out.append('@(default_calling_convention = "c", link_prefix = "ImGui_")')
    out.append('foreign imguilib {')
    out.extend(ig)
    out.append('}')
    out.append('')
    out.append('@(default_calling_convention = "c", link_prefix = "Im")')
    out.append('foreign imguilib {')
    out.extend(im)
    out.append('}')

    with open(filepath, "w") as f:
        f.writelines(out)

    print(f"Fixed {filepath}: {len(ig)} ImGui_ prefix + {len(im)} Im prefix functions")


if __name__ == "__main__":
    main()
