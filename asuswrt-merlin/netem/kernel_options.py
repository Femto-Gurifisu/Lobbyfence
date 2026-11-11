"""Which options of a kernel configuration can reach a module's compilation.

  python3 kernel_options.py <kernel dir> <arch> <.config> <out> net/sched/sch_netem [<folder of kept .cmd files>]

Run in the kernel tree right after the module was built there (or give the
folder the build's .cmd files were copied to, "/" in their paths as "_").

The kernel's build system records, for every object it compiles, each CONFIG_
option named anywhere in the source file or in a header it includes
(scripts/basic/fixdep.c writes them into the object's .cmd file as
include/config/<name>.h; the object is rebuilt when one of them changes).
An option outside that list cannot change the object. To that list this adds
the options named in the makefiles that set the compiler's flags (the
kernel's main ones in full; of the folder makefiles the lines that set
flags), those behind the two generated headers (bounds.h, asm-offsets.h),
and the ones that say which compiler built the kernel.

Output, one line per option the configuration shows (set, or "is not set"):
  R CONFIG_NAME value   - can reach the module: the router must have this value (n = off)
  K CONFIG_NAME         - cannot: the router may have it either way
SPDX-License-Identifier: GPL-3.0-or-later
"""
import glob
import os
import re
import sys

kdir, arch, config, out, obj = sys.argv[1:6]
saved = sys.argv[6] if len(sys.argv) > 6 else None     # a folder of the .cmd files kept from the build
# always compared when the configuration shows them: which compiler built the kernel
ALWAYS = {"CONFIG_CC_IS_GCC", "CONFIG_GCC_VERSION", "CONFIG_CC_IS_CLANG", "CONFIG_CLANG_VERSION"}


def key(name):                      # as fixdep's print_dep() spells it
    return re.sub(r"/+", "/", name.lower().replace("_", "/")).lstrip("/")


keys = set()
d, b = os.path.split(obj)
cmds = ["%s/.%s.o.cmd" % (d, b), "%s/.%s.mod.o.cmd" % (d, b), "kernel/.bounds.s.cmd", "arch/%s/kernel/.asm-offsets.s.cmd" % arch]
for c in cmds:
    text = open(os.path.join(saved, c.replace("/", "_")) if saved else os.path.join(kdir, c)).read()
    found = re.findall(r"include/config/([^)\s]*)\.h", text)
    if not found:
        sys.exit("no options recorded in " + c)
    keys.update(found)
makefiles = ["Makefile", "arch/%s/Makefile" % arch, "scripts/Kbuild.include"] + \
    sorted(os.path.relpath(p, kdir) for p in glob.glob(os.path.join(kdir, "scripts/Makefile*"))) + \
    sorted(os.path.relpath(p, kdir) for p in glob.glob(os.path.join(kdir, "../bcmkernel/Makefile*")))
# the makefiles of the object's own folder and the folders above it only list
# which objects are built ("obj-$(CONFIG_X) += x.o" can't change another
# object): of those, just the lines that set flags or open a condition
dirfiles = []
while d:
    dirfiles += [d + "/Makefile", d + "/Kbuild"]
    d = os.path.dirname(d)
for m in makefiles + dirfiles:
    p = os.path.join(kdir, m)
    if not os.path.isfile(p):
        continue
    text = open(p, errors="replace").read()
    if m in dirfiles:
        text = "\n".join(l for l in text.replace("\\\n", " ").split("\n") if re.search(r"flags|^\s*(ifdef|ifndef|ifeq|ifneq)\b", l, re.I))
    for tok in re.findall(r"CONFIG_([A-Za-z0-9_]+)", text):
        keys.add(key(tok))
        if tok.endswith("_MODULE"):
            keys.add(key(tok[:-7]))
rows = []
for line in open(config):
    line = line.rstrip("\n")
    m = re.match(r"(CONFIG_[A-Za-z0-9_]+)=(.*)$", line)
    u = re.match(r"# (CONFIG_[A-Za-z0-9_]+) is not set$", line)
    if m:
        name, val = m.group(1), m.group(2)
    elif u:
        name, val = u.group(1), "n"
    else:
        continue
    if name == "CONFIG_NET_SCH_NETEM":
        continue
    k = key(name[7:])
    rel = k in keys or (name.endswith("_MODULE") and key(name[7:-7]) in keys) or name in ALWAYS
    if val.startswith('"'):         # names and paths: not something C code can lay out data by
        rel = False
    rows.append(("R %s %s" % (name, val)) if rel else ("K %s" % name))
with open(out, "w") as f:
    f.write("\n".join(rows) + "\n")
r = sum(1 for x in rows if x[0] == "R")
print("options: %d shown, %d can reach the module (%d of them on), %d cannot" % (
    len(rows), r, sum(1 for x in rows if x[0] == "R" and not x.endswith(" n")), len(rows) - r))
