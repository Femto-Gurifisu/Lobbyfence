"""Struct layouts from DWARF, for checking that a kernel module built here
lays out the kernel's structures exactly like the firmware's own kernel.

  python3 dwarf_layouts.py <readelf> <object>...   -> one line per struct

Each line is "<struct name> <signature>": the struct's size and, for every
member (anonymous unions / structs expanded in place), its name, byte offset,
bit position and the size of its type - so any difference in a member's
place or size anywhere in the struct changes the signature. Uses only the
text output of `readelf --debug-dump=info` (no Python packages needed).
SPDX-License-Identifier: GPL-3.0-or-later
"""
import re
import subprocess
import sys

DIE = re.compile(r"^\s*<(\d+)><([0-9a-f]+)>: Abbrev Number: (\d+)(?: \((DW_TAG_\w+)\))?")
ATTR = re.compile(r"^\s*<[0-9a-f]+>\s+(DW_AT_\w+)\s*:\s*(.*)$")
# binutils 2.35 and newer put the attribute's form first ("(data2) 576",
# "(strp) (offset: 0x..): name"); older ones print the value alone
FORM = re.compile(r"^\([a-z_]+[0-9]*\)\s+")


def parse(readelf, path):
    out = subprocess.run([readelf, "--debug-dump=info", "--wide", path], capture_output=True, text=True).stdout
    dies, stack, cur = {}, [], None
    for line in out.splitlines():
        m = DIE.match(line)
        if m:
            depth, off, abbrev, tag = int(m.group(1)), int(m.group(2), 16), int(m.group(3)), m.group(4)
            if abbrev == 0:
                cur = None
                continue
            while stack and stack[-1][0] >= depth:
                stack.pop()
            parent = stack[-1][1] if stack else None
            cur = {"tag": tag, "attrs": {}, "children": [], "off": off}
            dies[off] = cur
            if parent is not None:
                dies[parent]["children"].append(off)
            stack.append((depth, off))
            continue
        a = ATTR.match(line)
        if a and cur is not None:
            cur["attrs"][a.group(1)] = FORM.sub("", a.group(2), count=1)
    return dies


def aval(die, key):
    v = die["attrs"].get(key)
    if v is None:
        return None
    if "): " in v and v.startswith("("):          # (indirect string, offset: 0x..): name
        v = v.split("): ", 1)[1]
    return v.strip()


def ref(die, key):
    v = die["attrs"].get(key)
    if v is None:
        return None
    m = re.search(r"<0x([0-9a-f]+)>", v)
    return int(m.group(1), 16) if m else None


def num(v):
    if v is None:
        return None
    m = re.match(r"(0x[0-9a-f]+|-?\d+)", v.strip())
    return int(m.group(1), 0) if m else None


def type_size(dies, off, depth=0):
    """byte size of a type (following typedefs / qualifiers), array sizes multiplied"""
    if off is None or depth > 40:
        return 0
    d = dies.get(off)
    if d is None:
        return -1
    tag = d["tag"]
    bs = num(aval(d, "DW_AT_byte_size"))
    if tag in ("DW_TAG_typedef", "DW_TAG_const_type", "DW_TAG_volatile_type", "DW_TAG_restrict_type", "DW_TAG_atomic_type"):
        return type_size(dies, ref(d, "DW_AT_type"), depth + 1)
    if tag == "DW_TAG_array_type":
        n = 1
        for c in d["children"]:
            sub = dies[c]
            if sub["tag"] == "DW_TAG_subrange_type":
                ub = num(aval(sub, "DW_AT_upper_bound"))
                cnt = num(aval(sub, "DW_AT_count"))
                n *= (ub + 1) if ub is not None else (cnt if cnt is not None else 0)
        return n * type_size(dies, ref(d, "DW_AT_type"), depth + 1)
    if tag == "DW_TAG_pointer_type":
        return bs or 8
    return bs if bs is not None else 0


def type_name(dies, off, depth=0):
    if off is None or depth > 40:
        return "void"
    d = dies.get(off)
    if d is None:
        return "?"
    tag = d["tag"]
    n = aval(d, "DW_AT_name")
    if tag in ("DW_TAG_const_type", "DW_TAG_volatile_type", "DW_TAG_typedef", "DW_TAG_restrict_type", "DW_TAG_atomic_type"):
        return (n + "=" if tag == "DW_TAG_typedef" else "") + type_name(dies, ref(d, "DW_AT_type"), depth + 1)
    if tag == "DW_TAG_pointer_type":
        return "*"            # pointers: only their size matters for the layout
    if tag == "DW_TAG_array_type":
        return type_name(dies, ref(d, "DW_AT_type"), depth + 1) + "[]"
    return (n or "<anon>")


def layout(dies, d, prefix="", base=0, depth=0):
    """[(name, byte offset, bit offset, bit size, type name, type size)] with anonymous members expanded"""
    rows = []
    for c in d["children"]:
        m = dies[c]
        if m["tag"] != "DW_TAG_member":
            continue
        name = aval(m, "DW_AT_name")
        loc = num(aval(m, "DW_AT_data_member_location")) or 0
        bits = (num(aval(m, "DW_AT_data_bit_offset")), num(aval(m, "DW_AT_bit_offset")), num(aval(m, "DW_AT_bit_size")))
        t = ref(m, "DW_AT_type")
        td = dies.get(t)
        # follow typedefs to see whether an unnamed member is an anonymous struct / union
        tt = td
        while tt is not None and tt["tag"] in ("DW_TAG_typedef", "DW_TAG_const_type", "DW_TAG_volatile_type"):
            tt = dies.get(ref(tt, "DW_AT_type"))
        if name is None and tt is not None and tt["tag"] in ("DW_TAG_structure_type", "DW_TAG_union_type") and depth < 20:
            rows.append((prefix + "<anon>", base + loc, bits, type_size(dies, t), tt["tag"][7:]))
            rows += layout(dies, tt, prefix + "  ", base + loc, depth + 1)
        else:
            rows.append((prefix + (name or "<anon>"), base + loc, bits, type_size(dies, t), type_name(dies, t)))
    return rows


def structs(readelf, paths):
    res = {}
    for p in paths:
        dies = parse(readelf, p)
        for off, d in dies.items():
            if d["tag"] not in ("DW_TAG_structure_type", "DW_TAG_union_type"):
                continue
            name = aval(d, "DW_AT_name")
            if not name or "DW_AT_declaration" in d["attrs"]:
                continue
            sig = "size=%s|" % num(aval(d, "DW_AT_byte_size")) + ";".join(
                "%s@%d%s:%d:%s" % (r[0].strip(), r[1], ("/b%s,%s,%s" % r[2]) if any(x is not None for x in r[2]) else "", r[3], r[4])
                for r in layout(dies, d))
            res.setdefault((d["tag"][7:], name), set()).add(sig)
    return res


if __name__ == "__main__":
    rd, objs = sys.argv[1], sys.argv[2:]
    for (kind, name), sigs in sorted(structs(rd, objs).items()):
        for s in sorted(sigs):
            print(kind, name, s)
