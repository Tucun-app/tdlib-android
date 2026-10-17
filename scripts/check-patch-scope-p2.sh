#!/usr/bin/env bash
# Content guard for patches/0002-remote-file-hashes.patch (td_api function getRemoteFileHashes).
#
# The patch may add ONE read-only function that asks the server for upload.getFileHashes and hands the answer to the
# caller. It must never be able to read, write, rename or delete a local file, start a download, or touch FileManager state.
# Rules (by content, not line numbers, so they survive a TDLib upgrade):
#   1. the patch touches exactly td/generate/scheme/td_api.tl, td/telegram/Requests.h, td/telegram/Requests.cpp; applying it
#      to the base tree (stock + 0001) gives exactly the patched tree; it contains NO deleted or changed line (so a stock line
#      such as the `begins_with(...get_files_dir...)` condition of FileManager::delete_file can never be edited); the patched
#      tree differs from the base tree in exactly those three files.
#   2. every added line of Requests.cpp lies between `// getRemoteFileHashes: begin` and `// getRemoteFileHashes: end`
#      (removing exactly those marker lines and everything between gives the base file back). Inside the block:
#        a. every `receiver->method`, `receiver.method`, `Class::member` pair must be in the receiver/method whitelist
#           (td_->file_manager_ may only call get_file_view, ...);
#        b. every bare identifier must be in the identifier whitelist, a C++ keyword, or a name the block itself declares;
#        c. a name declared inside the block must not equal any whitelist/denylist word or any member name of FileManager.h,
#           Td.h, Requests.h (so `int get_content = 0;` followed by a call cannot launder a forbidden call);
#        d. denylist words and constructs are rejected even if they somehow appear in a whitelist (#define, line-ending
#           backslash, using, download, upload, local, path, FileFd, unlink, rename, open, get_content, read_file_part, ...,
#           create_handler of any type other than GetRemoteFileHashesQuery);
#        e. structure: the ResultHandler overrides on_error (forwarding to promise_.set_error) and on_result converts a
#           fetch_result error into on_error before any move_as_ok.
#   3. td_api.tl gains exactly the three declarations (types before `---functions---`, the function after it) plus comments;
#      Requests.h gains exactly one `on_request(uint64 id, const td_api::getRemoteFileHashes &request)` declaration.
#   4. --self-test: the real patch passes; every counter-example (1-12 of plan section 5.2-4) fails on the rule it targets;
#      and a control guard WITHOUT 2-a/2-c (denylist + bare identifiers only) passes the variants that avoid denylist words,
#      which proves 2-a/2-c are what stops them.
#
# Usage:
#   scripts/check-patch-scope-p2.sh <base-td-dir> <patched-td-dir> <patch-file>
#   scripts/check-patch-scope-p2.sh --self-test <base-td-dir> <patched-td-dir> <patch-file>
# base-td-dir = stock TDLib + 0001; patched-td-dir = stock + 0001 + 0002.
set -euo pipefail

PY=$(command -v python3 || command -v python)
"$PY" - "$@" <<'PYEOF'
import hashlib
import os
import re
import sys

TL = "td/generate/scheme/td_api.tl"
HDR = "td/telegram/Requests.h"
CPP = "td/telegram/Requests.cpp"
ALLOWED_FILES = {TL, HDR, CPP}
BEGIN = "// getRemoteFileHashes: begin"
END = "// getRemoteFileHashes: end"
HEADER_FILES = ["td/telegram/files/FileManager.h", "td/telegram/Td.h", "td/telegram/Requests.h"]

# 2-a receiver -> methods/members. A receiver of "<expr>" is the result of a call/parenthesis ( `)->x`, `).x` ).
PAIRS = {
    "Td": {"ResultHandler"},
    "td_": {"file_manager_", "create_handler"},
    "file_manager_": {"get_file_view"},
    "file_view": {"empty", "has_full_remote_location", "get_full_remote_location", "is_encrypted_any", "size"},
    "location": {"is_web", "is_document", "as_input_file_location", "get_dc_id"},
    "<expr>": {"net_query_creator", "create", "send", "str"},
    "hash": {"offset_", "limit_", "hash_"},
    "hash_": {"as_slice"},
    "promise": {"set_value", "set_error"},
    "promise_": {"set_value", "set_error"},
    "Status": {"Error"},
    "result_ptr": {"is_error", "move_as_error", "move_as_ok"},
    "request": {"file_id_", "offset_"},
    "td_api": {"object_ptr", "make_object", "fileHashPart", "fileHashParts", "getRemoteFileHashes"},
    "telegram_api": {"upload_getFileHashes", "fileHash"},
    "NetQuery": {"Type"},
    "Type": {"Download", "DownloadSmall"},
    "std": {"move"},
    "Requests": {"on_request"},
}
# 2-b bare identifiers (plan list, calibrated per 2-e: only language/promise/status/numeric names were added)
BARE = {
    "Promise", "BufferSlice", "FileId", "FileView", "Status", "CREATE_REQUEST_PROMISE", "GetRemoteFileHashesQuery",
    "fetch_result", "transform", "send_query", "on_result", "on_error", "tl_object_ptr", "G", "td_", "uint64", "int64",
    "id", "request", "std", "td_api", "telegram_api", "NetQuery", "Td", "Requests", "ResultHandler",
    # 2-e additions (pure language / promise / status / numbers)
    "promise", "set_error", "set_value", "move", "is_error", "move_as_ok", "move_as_error", "as_slice", "str",
    "narrow_cast", "static_cast", "bool", "auto", "const", "return", "void", "class", "final", "explicit", "public",
    "if", "true", "false", "nullptr", "else", "send",
}
KEYWORDS = {"class", "final", "explicit", "public", "void", "bool", "auto", "const", "return", "if", "else", "true", "false",
            "nullptr", "int", "unsigned", "static_cast", "operator"}
# 2-d denylist (whole words, anywhere in the block)
DENY = {
    "messages_manager_", "file_manager_actor_", "delete_file", "download_file", "download", "local", "path", "FileFd", "unlink",
    "rename", "open", "read_file", "read_file_part", "write_file", "copy_file", "get_content", "upload", "cancel_download",
    "check_local_location", "pread", "pwrite", "using", "send_closure", "FileManager", "FileLoadManager", "FileDownloader",
}
CPP_WORDS = KEYWORDS


def read_text(root, rel):
    with open(os.path.join(root, rel), encoding="utf-8", newline="") as f:
        return f.read()


class Tree:
    def __init__(self, root, overrides=None):
        self.root = root
        self.overrides = overrides or {}

    def read(self, rel):
        if rel in self.overrides:
            return self.overrides[rel]
        return read_text(self.root, rel)


def strip_code(text):
    """Blank comments and string/char literals (same length) so words inside them do not count."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = " "
            i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if out[k] != "\n":
                    out[k] = " "
            i = j
        elif c in "\"'":
            j = i + 1
            while j < n and text[j] != c:
                j += 2 if text[j] == "\\" else 1
            for k in range(i + 1, min(j, n)):
                out[k] = " "
            i = j + 1
        else:
            i += 1
    return "".join(out)


def parse_patch(patch_text):
    """{path: {"hunks": [(old_start, [(kind, text)...])], "del": n, "add": [texts]}}"""
    files, cur, hunk = {}, None, None
    lines = patch_text.split("\n")
    i = 0
    while i < len(lines):
        ln = lines[i]
        if ln.startswith("--- ") and i + 1 < len(lines) and lines[i + 1].startswith("+++ "):
            new_path = lines[i + 1][4:].strip().split("\t")[0]
            old_path = ln[4:].strip().split("\t")[0]
            path = new_path if new_path != "/dev/null" else old_path
            path = re.sub(r"^[ab]/", "", path)
            cur = files.setdefault(path, {"hunks": [], "del": 0, "add": [], "new": old_path == "/dev/null"})
            hunk = None
            i += 2
            continue
        m = re.match(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", ln)
        if m and cur is not None:
            hunk = (int(m.group(1)), [])
            cur["hunks"].append(hunk)
            i += 1
            continue
        if cur is not None and hunk is not None:
            if ln.startswith("+"):
                hunk[1].append(("+", ln[1:]))
                cur["add"].append(ln[1:])
            elif ln.startswith("-"):
                hunk[1].append(("-", ln[1:]))
                cur["del"] += 1
            elif ln.startswith(" "):
                hunk[1].append((" ", ln[1:]))
            elif ln.startswith("\\"):
                pass
            elif ln == "":
                pass  # trailing empty string from split
            else:
                hunk = None
        i += 1
    return files


def apply_insert_only(base_text, hunks):
    """Applies a patch that has only context and '+' lines. Returns (new_text, added_line_numbers(1-based in new text)) or raises."""
    base = base_text.split("\n")
    out, added = [], []
    pos = 0  # next base line index
    for old_start, body in hunks:
        start = old_start - 1 if any(k == " " for k, _ in body) or old_start == 0 else old_start
        # hunks with no context lines (pure adds) use old_start as the line AFTER which to insert
        has_ctx = any(k == " " for k, _ in body)
        start = old_start - 1 if has_ctx else old_start
        if start < pos:
            raise ValueError("hunks overlap or out of order")
        out.extend(base[pos:start])
        pos = start
        for kind, text in body:
            if kind == " ":
                if pos >= len(base) or base[pos] != text:
                    raise ValueError("context mismatch at base line %d" % (pos + 1))
                out.append(base[pos])
                pos += 1
            elif kind == "+":
                out.append(text)
                added.append(len(out))
            else:
                raise ValueError("patch deletes a line")
    out.extend(base[pos:])
    return "\n".join(out), added


def tree_digest(root):
    out = {}
    for dp, dn, fn in os.walk(root):
        dn[:] = [d for d in dn if d != ".git"]
        for f in fn:
            if f == ".git":  # a worktree's .git is a file naming its own gitdir; not tree content
                continue
            p = os.path.join(dp, f)
            rel = os.path.relpath(p, root).replace(os.sep, "/")
            with open(p, "rb") as fh:
                out[rel] = hashlib.sha256(fh.read()).hexdigest()
    return out


def changed_files(base_root, patched_root):
    s, p = tree_digest(base_root), tree_digest(patched_root)
    return sorted(k for k in set(s) | set(p) if s.get(k) != p.get(k))


def member_names(base):
    names = set()
    for rel in HEADER_FILES:
        t = strip_code(base.read(rel))
        names |= set(re.findall(r"\b(\w+)\s*\(", t))
        names |= set(re.findall(r"\b(\w+_)\s*[;=]", t))
    return names


def declared_names(code):
    """Names the block declares: `type name =|;|,|)|{` (variables, parameters, members) and class names."""
    names = set()
    for m in re.finditer(r"(?:\bauto|\bconst|[\w>:])\s*(?:&&|&|\*|\s)\s*(?:const\s+)?([A-Za-z_]\w*)\s*(?=[=;,){])", code):
        w = m.group(1)
        if w not in KEYWORDS and w not in ("final", "return", "else"):
            before = code[:m.start(1)].rstrip()
            prev = re.search(r"([A-Za-z_]\w*)$", before)
            if prev and prev.group(1) in ("return", "else", "case", "new", "delete", "throw"):
                continue
            names.add(w)
    for m in re.finditer(r"\bclass\s+([A-Za-z_]\w*)", code):
        names.add(m.group(1))
    return names


def on_result_body(code):
    m = re.search(r"void\s+on_result\s*\([^)]*\)\s*(?:final)?\s*\{", code)
    if not m:
        return None
    depth, i = 0, m.end() - 1
    for k in range(i, len(code)):
        if code[k] == "{":
            depth += 1
        elif code[k] == "}":
            depth -= 1
            if depth == 0:
                return code[m.end():k]
    return None


def on_error_body(code):
    m = re.search(r"void\s+on_error\s*\([^)]*\)\s*(?:final)?\s*\{", code)
    if not m:
        return None
    depth, i = 0, m.end() - 1
    for k in range(i, len(code)):
        if code[k] == "{":
            depth += 1
        elif code[k] == "}":
            depth -= 1
            if depth == 0:
                return code[m.end():k]
    return None


def check_block(block_text, members, mode):
    """Rule 2 on the text between (and including) the markers. mode: 'full' or 'denylist' (control: no 2-a, no 2-c)."""
    v = []
    code = strip_code(block_text)
    if re.search(r"#\s*\w+", code):
        v.append(("2", "preprocessor directive inside the block"))
    if re.search(r"\\[ \t]*$", block_text, re.M):
        v.append(("2", "line-ending backslash inside the block"))
    # 2-d denylist words anywhere
    for w in sorted(set(re.findall(r"[A-Za-z_]\w*", code))):
        if w in DENY:
            v.append(("2", "denylist word `%s`" % w))
    for m in re.finditer(r"create_handler\s*<\s*([\w:]+)\s*>", code):
        if m.group(1) != "GetRemoteFileHashesQuery":
            v.append(("2", "create_handler of `%s`" % m.group(1)))
    # 2-a pairs
    if mode == "full":
        for m in re.finditer(r"(\)|\b[A-Za-z_]\w*)\s*(->|\.|::)\s*(?=([A-Za-z_]\w*))", code):
            recv = "<expr>" if m.group(1) == ")" else m.group(1)
            name = m.group(3)
            if name not in PAIRS.get(recv, set()):
                v.append(("2", "pair `%s%s%s` is not in the receiver/method whitelist" % (m.group(1), m.group(2), name)))
    # 2-b bare identifiers
    declared = declared_names(code)
    bare_ok = BARE | CPP_WORDS | declared
    for m in re.finditer(r"(?<![\w])([A-Za-z_]\w*)", code):
        before = code[:m.start()].rstrip()
        if before.endswith("->") or before.endswith(".") or before.endswith("::"):
            continue
        w = m.group(1)
        if w not in bare_ok:
            v.append(("2", "identifier `%s` is not in the identifier whitelist" % w))
    # 2-c declared names
    if mode == "full":
        methods = set().union(*PAIRS.values())
        bad = (members | DENY | methods) - BARE
        for w in sorted(declared):
            if w in bad:
                v.append(("2", "declared name `%s` collides with a whitelist/denylist/member name" % w))
    # 2-e structure
    ob = on_error_body(code)
    if ob is None or not re.search(r"\bpromise_\s*\.\s*set_error\s*\(", ob):
        v.append(("2", "handler has no on_error override forwarding to promise_.set_error"))
    orb = on_result_body(code)
    if orb is None:
        v.append(("2", "handler has no on_result override"))
    else:
        fr = re.search(r"fetch_result\s*<\s*telegram_api::upload_getFileHashes\s*>", orb)
        ie = re.search(r"result_ptr\s*\.\s*is_error\s*\(\s*\)", orb)
        ret = re.search(r"return\s+on_error\s*\(", orb)
        mk = re.search(r"result_ptr\s*\.\s*move_as_ok\s*\(", orb)
        if not (fr and ie and ret and mk and fr.start() < ie.start() < ret.start() < mk.start()):
            v.append(("2", "on_result must test fetch_result's is_error() and `return on_error(...)` before move_as_ok()"))
    return v


TL_TYPE_RES = [
    r"^fileHashPart offset:int53 size:int32 sha256:bytes = FileHashPart;$",
    r"^fileHashParts parts:vector<fileHashPart> = FileHashParts;$",
]
TL_FUNC_RE = r"^getRemoteFileHashes file_id:int32 offset:int53 = FileHashParts;$"
HDR_RE = r"^  void on_request\(uint64 id, const td_api::getRemoteFileHashes &request\);$"


def check(base, patched, patch_text, changed, mode="full"):
    """Returns [(rule, message)]. Empty = pass. `changed` = files that differ between the trees."""
    v = []
    files = parse_patch(patch_text)
    # rule 1
    if set(files) != ALLOWED_FILES:
        v.append(("1", "patch touches %s, expected exactly %s" % (sorted(files), sorted(ALLOWED_FILES))))
    if set(changed) != ALLOWED_FILES:
        v.append(("1", "patched tree differs from the base tree in %s, expected exactly %s" % (sorted(changed), sorted(ALLOWED_FILES))))
    applied = {}
    for rel, info in files.items():
        if info["del"]:
            v.append(("1", "%s: the patch deletes or changes %d stock line(s)" % (rel, info["del"])))
            continue
        if info.get("new"):
            v.append(("1", "%s: the patch creates a new file" % rel))
            continue
        try:
            text, added = apply_insert_only(base.read(rel), info["hunks"])
        except (ValueError, FileNotFoundError, KeyError) as exc:
            v.append(("1", "%s: the patch does not apply to the base tree as pure insertions: %s" % (rel, exc)))
            continue
        if text != patched.read(rel):
            v.append(("1", "%s: base + patch != patched tree (patch and tree disagree, or the tree has extra edits)" % rel))
        applied[rel] = (text, added)
    for rel in set(changed) - ALLOWED_FILES:
        if rel not in files:
            v.append(("1", "%s: changed in the patched tree but not by the patch" % rel))
    # rule 3
    if TL in applied:
        text, added = applied[TL]
        lines = text.split("\n")
        fn_at = next((i + 1 for i, l in enumerate(lines) if l == "---functions---"), None)
        decl_lines = [(n, lines[n - 1]) for n in added if lines[n - 1].strip() and not lines[n - 1].startswith("//")]
        if len(decl_lines) != 3:
            v.append(("3", "td_api.tl: expected exactly 3 added declarations, got %d" % len(decl_lines)))
        for n, l in decl_lines:
            ok_t = any(re.match(r, l) for r in TL_TYPE_RES) and fn_at is not None and n < fn_at
            ok_f = re.match(TL_FUNC_RE, l) and fn_at is not None and n > fn_at
            if not (ok_t or ok_f):
                v.append(("3", "td_api.tl: added line is not one of the three allowed declarations: %s" % l.strip()))
        for n in added:
            l = lines[n - 1]
            if l.strip() and not l.startswith("//") and not (any(re.match(r, l) for r in TL_TYPE_RES) or re.match(TL_FUNC_RE, l)):
                pass
    if HDR in applied:
        text, added = applied[HDR]
        lines = text.split("\n")
        non_blank = [lines[n - 1] for n in added if lines[n - 1].strip()]
        if len(non_blank) != 1 or not re.match(HDR_RE, non_blank[0]):
            v.append(("3", "Requests.h: the only allowed addition is one on_request(getRemoteFileHashes) declaration, got %r" % non_blank))
    # rule 2
    if CPP in applied:
        text, added = applied[CPP]
        base_text = base.read(CPP)
        lines = text.split("\n")
        if BEGIN in base_text or END in base_text:
            v.append(("2", "Requests.cpp: the base tree already contains the markers"))
        begins = [i for i, l in enumerate(lines) if l.strip() == BEGIN]
        ends = [i for i, l in enumerate(lines) if l.strip() == END]
        if len(begins) != 1 or len(ends) != 1 or begins[0] >= ends[0]:
            v.append(("2", "Requests.cpp: expected exactly one begin marker followed by one end marker"))
        else:
            b, e = begins[0], ends[0]
            outside = [n for n in added if not (b + 1 <= n <= e + 1)]
            if outside:
                v.append(("2", "Requests.cpp: %d added line(s) outside the markers, first: %r" % (len(outside), lines[outside[0] - 1])))
            if "\n".join(lines[:b] + lines[e + 1:]) != base_text:
                v.append(("2", "Requests.cpp: removing the marker block does not give back the base file"))
            members = member_names(base)
            v.extend(check_block("\n".join(lines[b:e + 1]), members, mode))
    return v


# ---------------------------------------------------------------------------------------------------------------- self-test
def unified(rel, a_text, b_text):
    """Insert-only (or arbitrary) unified diff using difflib; good enough for counter-examples."""
    import difflib
    a, b = a_text.split("\n"), b_text.split("\n")
    out = ["--- a/%s" % rel, "+++ b/%s" % rel]
    for g in difflib.SequenceMatcher(None, a, b, autojunk=False).get_grouped_opcodes(3):
        a0, a1, b0, b1 = g[0][1], g[-1][2], g[0][3], g[-1][4]
        out.append("@@ -%d,%d +%d,%d @@" % (a0 + 1, a1 - a0, b0 + 1, b1 - b0))
        for tag, i1, i2, j1, j2 in g:
            if tag == "equal":
                out.extend(" " + x for x in a[i1:i2])
            else:
                out.extend("-" + x for x in a[i1:i2])
                out.extend("+" + x for x in b[j1:j2])
    return "\n".join(out) + "\n"


def self_test(base_root, patched_root, patch_text):
    base = Tree(base_root)
    patched = Tree(patched_root)
    real_changed = changed_files(base_root, patched_root)
    ok = True
    real = check(base, patched, patch_text, real_changed)
    if real:
        ok = False
        print("SELFTEST FAIL real patch rejected:")
        for r in real:
            print("  rule %s: %s" % r)
    else:
        print("SELFTEST OK   real patch passes")
    real_cpp = patched.read(CPP)
    real_tl = patched.read(TL)
    base_cpp = base.read(CPP)
    cpp_lines = real_cpp.split("\n")
    b = next(i for i, l in enumerate(cpp_lines) if l.strip() == BEGIN)
    e = next(i for i, l in enumerate(cpp_lines) if l.strip() == END)
    block = "\n".join(cpp_lines[b:e + 1])

    def with_block(new_block):
        return "\n".join(cpp_lines[:b] + new_block.split("\n") + cpp_lines[e + 1:])

    def replace_once(text, old, new):
        if text.count(old) != 1:
            raise SystemExit("SELFTEST anchor %r found %d times in the real patch (guard self-test out of date)" % (old, text.count(old)))
        return text.replace(old, new)

    entry_anchor = "  CREATE_REQUEST_PROMISE();\n"
    entry_tail = "  td_->create_handler<GetRemoteFileHashesQuery>(std::move(promise))"
    cases = []  # (name, rule, edits{rel: text}, denylist_control_passes)

    def add(name, rule, cpp_block=None, edits=None, control=None):
        e_ = dict(edits or {})
        if cpp_block is not None:
            e_[CPP] = with_block(cpp_block)
        cases.append((name, rule, e_, control))

    fm = "td/telegram/files/FileManager.cpp"
    fm_text = base.read(fm)
    anchor1 = "if (begins_with(file_view.get_full_local_location()->path_, get_files_dir(file_view.get_type()))) {"
    cases.append(("1: rewrite delete_file's begins_with condition", "1",
                  {fm: replace_once(fm_text, anchor1, "if (!begins_with(file_view.get_full_local_location()->path_, get_files_dir(file_view.get_type()))) {")}, None))
    add("2: on_request calls delete_file via send_closure(file_manager_actor_)", "2",
        replace_once(block, entry_anchor, entry_anchor + "  send_closure(td_->file_manager_actor_, &FileManager::delete_file, FileId(request.file_id_, 0), std::move(promise), \"x\");\n"))
    add("3: handler sends upload.getFile", "2", replace_once(block, "telegram_api::upload_getFileHashes(location->as_input_file_location(), offset)",
                                                              "telegram_api::upload_getFile(0, false, false, location->as_input_file_location(), offset, 1048576)"))
    add("4: FileFd::open in the block", "2", replace_once(block, entry_anchor, entry_anchor + "  auto fd = FileFd::open(\"/x\", FileFd::Write);\n"))
    fd_cpp = "td/telegram/files/FileDownloader.cpp"
    cases.append(("5: edit FileDownloader.cpp", "1", {fd_cpp: base.read(fd_cpp) + "// x\n"}, None))
    add("6: #define inside the block", "2", replace_once(block, entry_anchor, "#define X 1\n" + entry_anchor))
    # 7: delete a stock line of Requests.cpp
    del_line = "  CHECK_IS_USER();\n"
    idx = base_cpp.index(del_line)
    cases.append(("7: delete a stock line of Requests.cpp", "1", {CPP: real_cpp.replace(del_line, "", 1)}, None))
    for tag, body in (
        ("8a: FileFd", "  FileFd fd;\n"),
        ("8b: download_file", "  td_->file_manager_->download_file(FileId(request.file_id_, 0), 1, 0, 0, false, std::move(promise));\n"),
        ("8c: messages_manager_", "  td_->messages_manager_->clear_all_draft_messages(false, std::move(promise));\n"),
        ("8d: create_handler<other Query>", "  td_->create_handler<GetOtherQuery>(std::move(promise));\n"),
        ("8e: send_closure(td_->file_manager_actor_)", "  send_closure(td_->file_manager_actor_, &FileManager::download, FileId(request.file_id_, 0));\n"),
    ):
        add(tag + " in on_request", "2", replace_once(block, entry_anchor, entry_anchor + body))
    # 9: any added line outside the markers
    cases.append(("9: one added line after the end marker", "2",
                  {CPP: real_cpp.replace(END + "\n", END + "\n// stray\n", 1)}, None))
    cases.append(("9b: one added line before the begin marker", "2",
                  {CPP: real_cpp.replace(BEGIN + "\n", "// stray\n" + BEGIN + "\n", 1)}, None))
    # 10: structure
    on_err = re.search(r"  void on_error\(Status status\) final \{\n    promise_\.set_error\(std::move\(status\)\);\n  \}\n", block)
    assert on_err, "anchor on_error"
    add("10a: handler without on_error", "2", block.replace(on_err.group(0), ""))
    add("10b: on_result without the is_error branch", "2",
        replace_once(block, "    if (result_ptr.is_error()) {\n      return on_error(result_ptr.move_as_error());\n    }\n", ""))
    # 11: whitelisted receiver, non-whitelisted method
    for tag, call, plain in (
        ("11a: get_content", "td_->file_manager_->get_content(FileId(request.file_id_, 0));", False),
        ("11b: read_file_part", "td_->file_manager_->read_file_part(FileId(request.file_id_, 0), 0, 1, 2, std::move(promise));", False),
        ("11c: upload", "td_->file_manager_->upload(FileId(request.file_id_, 0), nullptr, 1, 0, 0);", False),
        ("11d: check_local_location", "td_->file_manager_->check_local_location(FileId(request.file_id_, 0), false);", False),
        ("11e: cancel_download", "td_->file_manager_->cancel_download(FileId(request.file_id_, 0), 0, false);", False),
        ("11f: get_file_object (not in the denylist)", "td_->file_manager_->get_file_object(FileId(request.file_id_, 0));", True),
        ("11g: get_file_node (not in the denylist)", "td_->file_manager_->get_file_node(FileId(request.file_id_, 0));", True),
    ):
        add(tag, "2", replace_once(block, entry_anchor, entry_anchor + "  " + call + "\n"), control=("passes" if plain else None))
    # 12: same-name declaration bypass
    for tag, decl, call, plain in (
        ("12a: int get_content = 0; then call", "  int get_content = 0;\n", "  td_->file_manager_->get_content(FileId(request.file_id_, 0));\n", False),
        ("12b: auto read_file_part = 1; then call", "  auto read_file_part = 1;\n", "  td_->file_manager_->read_file_part(FileId(request.file_id_, 0), 0, 1, 2, std::move(promise));\n", False),
        ("12c: auto get_file_object = 1; then call (no denylist word)", "  auto get_file_object = 1;\n", "  td_->file_manager_->get_file_object(FileId(request.file_id_, 0));\n", True),
        ("12d: declaration alone (auto get_file_node = 1;)", "  auto get_file_node = 1;\n", "", True),
    ):
        add(tag, "2", replace_once(block, entry_anchor, entry_anchor + decl + call), control=("passes" if plain else None))

    for name, rule, edits, control in cases:
        pat_parts, changed_set = [], set(real_changed)
        for rel in sorted(set(edits) | ALLOWED_FILES):
            new_text = edits.get(rel, patched.read(rel))
            old_text = base.read(rel)
            if new_text != old_text:
                pat_parts.append(unified(rel, old_text, new_text))
                changed_set.add(rel)
            else:
                changed_set.discard(rel)
        mut = Tree(patched_root, edits)
        ptext = "".join(pat_parts)
        got = check(base, mut, ptext, sorted(changed_set))
        rules = sorted(set(r for r, _ in got))
        if rule in rules:
            print("SELFTEST OK   rejected by rule %s (all: %s): %s  <= %s" % (rule, ",".join(rules), name, [m for r, m in got if r == rule][0][:110]))
        else:
            ok = False
            print("SELFTEST FAIL not rejected by rule %s (got %s): %s" % (rule, rules, name))
        if control == "passes":
            ctl = check(base, mut, ptext, sorted(changed_set), mode="denylist")
            if ctl:
                ok = False
                print("SELFTEST FAIL control (denylist only) should PASS this variant but got: %s : %s" % (ctl[0], name))
            else:
                print("SELFTEST OK   control without 2-a/2-c passes it (so the whitelist is what blocks it): %s" % name)
    return ok


def main(argv):
    selftest = argv and argv[0] == "--self-test"
    if selftest:
        argv = argv[1:]
    if len(argv) != 3:
        print("usage: check-patch-scope-p2.sh [--self-test] <base-td-dir> <patched-td-dir> <patch-file>")
        return 2
    base_root, patched_root, patch_path = argv
    with open(patch_path, encoding="utf-8", newline="") as f:
        patch_text = f.read()
    if selftest:
        return 0 if self_test(base_root, patched_root, patch_text) else 1
    got = check(Tree(base_root), Tree(patched_root), patch_text, changed_files(base_root, patched_root))
    for rule, msg in got:
        print("FAIL rule %s: %s" % (rule, msg))
    if got:
        print("RESULT: FAIL (%d violations)" % len(got))
        return 1
    print("RESULT: PASS (rules 1-3)")
    return 0


sys.exit(main(sys.argv[1:]))
PYEOF
