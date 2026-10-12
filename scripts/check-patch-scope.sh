#!/usr/bin/env bash
# Content guard for patches/0001-parallel-file-hashes.patch (parallel upload.getFileHashes in only-check mode).
#
# The patch must never be able to report a file as verified without comparing it. FileDownloader::check_loop holds
# the only comparison code (read local bytes -> sha256 -> compare with the server hash -> advance the checked
# prefix -> tell PartsManager). This guard proves, by content (not by line numbers, so it survives a TDLib upgrade):
#   1. check_loop of the patched source, with the two allowed regions R1 (the "no hash for this offset" branch that
#      sends a query) and R2 (the dispatch loop) cut out, is identical (whitespace-normalised) to stock check_loop
#      with the same two regions cut out; inside each region the `hash_inflight_limit_ <= 1` branch is the stock text
#      unchanged; the R1 `else` branch ends with `break;`.
#   2. process_check_query and add_hash_info bodies are identical to stock.
#   3. the patch deletes (or changes) stock lines of FileDownloader.cpp only inside R1 and R2, and none of
#      FileDownloader.h.
#   4. no added line of FileDownloader.cpp contains a forbidden token (return, need_check_, writes to
#      checked_prefix_size, parts_manager_, sha256(, pread(, hash_info_ mutation, FILE_DOWNLOAD_RESTART, on_ok(, ...);
#      FileDownloader.h only gains the include and plain member declarations; FileHashWindow.h includes only
#      standard headers and touches nothing of FileDownloader.
#   5. the patch touches exactly td/telegram/files/{FileHashWindow.h,FileDownloader.h,FileDownloader.cpp}, and the
#      patched tree differs from stock in exactly those files.
#   6. --self-test: the real patch passes and every counter-example patch fails on the rule it targets.
#
# Usage:
#   scripts/check-patch-scope.sh <stock-td-dir> <patched-td-dir> <patch-file>
#   scripts/check-patch-scope.sh --self-test <stock-td-dir> <patched-td-dir> <patch-file>
set -euo pipefail

PY=$(command -v python3 || command -v python)
"$PY" - "$@" <<'PYEOF'
import difflib
import hashlib
import os
import re
import sys

CPP = "td/telegram/files/FileDownloader.cpp"
HDR = "td/telegram/files/FileDownloader.h"
WIN = "td/telegram/files/FileHashWindow.h"
ALLOWED_FILES = {CPP, HDR, WIN}

R1_STOCK_BEGIN = "    if (!has_hash_query_) {\n"
R1_STOCK_END = "    // Should fail?\n    break;\n"
R2_STOCK_BEGIN = "  for (auto &query : queries) {\n"
MARK = "// x_file_hashes_inflight: %s %s"

FORBIDDEN_CPP = [
    (r"\breturn\b", "return"),
    (r"\bgoto\b", "goto"),
    (r"\bcontinue\b", "continue"),
    (r"\bTRY_[A-Z_]+", "TRY_* macro (hides a return)"),
    (r"#\s*(define|include|undef)\b", "preprocessor directive"),
    (r"\bneed_check_\b", "need_check_"),
    (r"\bonly_check_\s*(?:[-+*/%&|^]|<<|>>)?=(?!=)", "write to only_check_"),
    (r"\bchecked_prefix_size\s*(?:[-+*/%&|^]|<<|>>)?=(?!=)", "write to checked_prefix_size"),
    (r"(?:\+\+|--)\s*checked_prefix_size\b|\bchecked_prefix_size\s*(?:\+\+|--)", "increment of checked_prefix_size"),
    (r"&\s*checked_prefix_size\b", "reference to checked_prefix_size"),
    (r"\bready_prefix_size\s*(?:[-+*/%&|^]|<<|>>)?=(?!=)", "write to ready_prefix_size"),
    (r"\bis_ready\s*=(?!=)", "write to is_ready"),
    (r"\bis_changed\b", "is_changed"),
    (r"\bstop_flag_\s*=(?!=)", "write to stop_flag_"),
    (r"\b(?:std::)?(?:swap|exchange|tie)\s*\(", "swap/exchange/tie"),
    (r"set_checked_prefix_size", "set_checked_prefix_size"),
    (r"set_need_check", "set_need_check"),
    (r"\bparts_manager_\b", "parts_manager_"),
    (r"\bsha256\s*\(", "sha256("),
    (r"\bpread\s*\(", "pread("),
    (r"\bit->hash\b", "it->hash"),
    (r"\bhash_info_\s*(?:\.|->)\s*(?:insert|emplace|erase|clear|upper_bound|lower_bound|swap|find)\b", "hash_info_ lookup/mutation"),
    (r"\bhash_info_\s*=(?!=)", "assignment to hash_info_"),
    (r"\badd_hash_info\b", "add_hash_info"),
    (r"FILE_DOWNLOAD_RESTART", "FILE_DOWNLOAD_RESTART"),
    (r"\bon_ok\s*\(", "on_ok("),
    (r"\bon_error\s*\(", "on_error("),
    (r"\bcallback_\b", "callback_"),
    (r"\b(?:do_loop|check_loop|loop)\s*\(", "loop call"),
]
HDR_ADDED_OK = [
    r'^#include "td/telegram/files/FileHashWindow\.h"$',
    r"^\s*//.*$",
    r"^\s*$",
    r"^\s*[A-Za-z_][\w:<>, ]*[\w>]\s+[a-z_]+_(?:\s*=\s*[\w]+)?;$",
]
WIN_FORBIDDEN = [
    (r'#\s*include\s*"', "non-standard include"),
    (r"FileDownloader", "FileDownloader"),
    (r"\bsha256\b|\bpread\b|\bhash_info_\b|\bparts_manager", "comparison/state access"),
    (r"#\s*define\b", "macro definition"),
]


def norm(text):
    return re.sub(r"\s+", " ", text).strip()


def read(root, rel):
    with open(os.path.join(root, rel), encoding="utf-8", newline="") as f:
        return f.read()


def strip_code(text):
    """Blank out comments and string/char literals (same length) so braces inside them do not count."""
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


def function_span(text, signature):
    """[start, end) of the function definition starting at `signature` (to its closing brace)."""
    if text.count(signature) != 1:
        raise ValueError("signature %r found %d times" % (signature, text.count(signature)))
    start = text.index(signature)
    code = strip_code(text)
    brace = code.index("{", start)
    depth = 0
    for i in range(brace, len(code)):
        if code[i] == "{":
            depth += 1
        elif code[i] == "}":
            depth -= 1
            if depth == 0:
                return start, i + 1
    raise ValueError("unbalanced braces in %r" % signature)


def block_span(text, begin_line, start_at=0):
    """[start, end) of the block whose first line is begin_line (to the end of its closing-brace line)."""
    pos = text.index(begin_line, start_at)
    code = strip_code(text)
    depth = 0
    for i in range(pos, len(code)):
        if code[i] == "{":
            depth += 1
        elif code[i] == "}":
            depth -= 1
            if depth == 0:
                end = text.index("\n", i) + 1
                return pos, end
    raise ValueError("unbalanced block %r" % begin_line)


def stock_regions(stock_cpp):
    fs, fe = function_span(stock_cpp, "Status FileDownloader::check_loop(")
    body = stock_cpp[fs:fe]
    if body.count(R1_STOCK_BEGIN) != 1 or body.count(R1_STOCK_END) != 1:
        raise ValueError("stock R1 anchors not found exactly once")
    r1s = fs + body.index(R1_STOCK_BEGIN)
    r1e = fs + body.index(R1_STOCK_END) + len(R1_STOCK_END)
    if body.count(R2_STOCK_BEGIN) != 1:
        raise ValueError("stock R2 anchor not found exactly once")
    r2s, r2e = block_span(stock_cpp, R2_STOCK_BEGIN, fs)
    return (fs, fe), (r1s, r1e), (r2s, r2e)


def patched_region(text, fs, fe, name):
    body = text[fs:fe]
    b, e = MARK % ("begin", name), MARK % ("end", name)
    if body.count(b) != 1 or body.count(e) != 1:
        raise ValueError("markers for %s not found exactly once inside check_loop" % name)
    s = fs + body.index(b)
    s = text.rindex("\n", 0, s) + 1
    t = fs + body.index(e)
    t = text.index("\n", t) + 1
    return s, t


def line_of(text, offset):
    return text.count("\n", 0, offset) + 1


def parse_patch(patch_text):
    """{path: {"del": [old line numbers], "add": [added line texts], "new": bool}}"""
    files = {}
    cur = None
    old_ln = new_ln = 0
    old_path = None
    lines = patch_text.split("\n")
    i = 0
    while i < len(lines):
        ln = lines[i]
        if ln.startswith("--- "):
            old_path = ln[4:].strip()
            nxt = lines[i + 1] if i + 1 < len(lines) else ""
            if nxt.startswith("+++ "):
                new_path = nxt[4:].strip()
                path = new_path if new_path != "/dev/null" else old_path
                path = re.sub(r"^[ab]/", "", path.split("\t")[0])
                cur = files.setdefault(path, {"del": [], "add": [], "new": old_path == "/dev/null"})
                i += 2
                continue
        m = re.match(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", ln)
        if m and cur is not None:
            old_ln, new_ln = int(m.group(1)), int(m.group(3))
            i += 1
            continue
        if cur is not None and ln.startswith("-") and not ln.startswith("---"):
            cur["del"].append(old_ln)
            old_ln += 1
        elif cur is not None and ln.startswith("+") and not ln.startswith("+++"):
            cur["add"].append(ln[1:])
            new_ln += 1
        elif cur is not None and ln.startswith(" "):
            old_ln += 1
            new_ln += 1
        i += 1
    return files


def tree_digest(root):
    out = {}
    for dp, dn, fn in os.walk(root):
        dn[:] = [d for d in dn if d != ".git" and not d.startswith("build")]
        for f in fn:
            if f == ".git":
                continue
            p = os.path.join(dp, f)
            rel = os.path.relpath(p, root).replace(os.sep, "/")
            with open(p, "rb") as fh:
                out[rel] = hashlib.sha256(fh.read()).hexdigest()
    return out


def check(stock_root, patched_root, patch_text, changed_files=None):
    """Returns a list of (rule, message). Empty = pass."""
    v = []
    stock_cpp = read(stock_root, CPP)
    pat_cpp = read(patched_root, CPP)
    try:
        (fs, fe), (r1s, r1e), (r2s, r2e) = stock_regions(stock_cpp)
        stock_r1 = stock_cpp[r1s:r1e]
        stock_r2 = stock_cpp[r2s:r2e]
        stock_rest = stock_cpp[fs:r1s] + "@R1@" + stock_cpp[r1e:r2s] + "@R2@" + stock_cpp[r2e:fe]
    except ValueError as exc:
        return [("1", "stock source: %s" % exc)]

    # rule 1
    try:
        pfs, pfe = function_span(pat_cpp, "Status FileDownloader::check_loop(")
        p1s, p1e = patched_region(pat_cpp, pfs, pfe, "R1")
        p2s, p2e = patched_region(pat_cpp, pfs, pfe, "R2")
        if not (pfs <= p1s < p1e <= p2s < p2e <= pfe):
            raise ValueError("regions out of order")
        pat_rest = pat_cpp[pfs:p1s] + "@R1@" + pat_cpp[p1e:p2s] + "@R2@" + pat_cpp[p2e:pfe]
        if norm(pat_rest) != norm(stock_rest):
            sm = difflib.unified_diff(norm(stock_rest).split(" ; "), norm(pat_rest).split(" ; "), lineterm="", n=0)
            v.append(("1", "check_loop outside R1/R2 differs from stock: %s" % " | ".join(list(sm)[2:8])))
        for name, (ps, pe), stock_text, tail in (("R1", (p1s, p1e), stock_r1, "break; }"), ("R2", (p2s, p2e), stock_r2, "}")):
            region = pat_cpp[ps:pe]
            region_n = norm(re.sub(r"//\s*x_file_hashes_inflight:[^\n]*", "", region))
            head = norm("if (hash_inflight_limit_ <= 1) {\n" + stock_text + "} else {")
            if not region_n.startswith(head + " "):
                v.append(("1", "%s: the `hash_inflight_limit_ <= 1` branch is not the stock text unchanged" % name))
            if not region_n.endswith(tail):
                v.append(("1", "%s: the else branch must end with `%s`" % (name, tail)))
            # the else branch is one block: the stock branch must not be followed by more than one else block
            code = strip_code(region)
            ib = code.index("if (hash_inflight_limit_ <= 1)") if "if (hash_inflight_limit_ <= 1)" in code else -1
            if ib >= 0:
                depth, closes, ends = 0, [], None
                for i in range(ib, len(code)):
                    if code[i] == "{":
                        depth += 1
                    elif code[i] == "}":
                        depth -= 1
                        if depth == 0:
                            closes.append(i)
                            if len(closes) == 2:
                                ends = i
                                break
                if ends is None or norm(code[ends + 1:]) != "":
                    v.append(("1", "%s: code after the if/else block inside the region" % name))
    except ValueError as exc:
        v.append(("1", "patched check_loop: %s" % exc))

    # rule 2
    for sig in ("Status FileDownloader::process_check_query(", "void FileDownloader::add_hash_info("):
        try:
            a, b = function_span(stock_cpp, sig)
            c, d = function_span(pat_cpp, sig)
            if norm(stock_cpp[a:b]) != norm(pat_cpp[c:d]):
                v.append(("2", "%s body differs from stock" % sig))
        except ValueError as exc:
            v.append(("2", str(exc)))

    files = parse_patch(patch_text)
    # rule 5
    if set(files) != ALLOWED_FILES:
        v.append(("5", "patch touches %s, expected exactly %s" % (sorted(files), sorted(ALLOWED_FILES))))
    if changed_files is not None and set(changed_files) != ALLOWED_FILES:
        v.append(("5", "patched tree differs from stock in %s" % sorted(changed_files)))

    # rule 3
    r1_lines = range(line_of(stock_cpp, r1s), line_of(stock_cpp, r1e - 1) + 1)
    r2_lines = range(line_of(stock_cpp, r2s), line_of(stock_cpp, r2e - 1) + 1)
    for ln in files.get(CPP, {}).get("del", []):
        if ln not in r1_lines and ln not in r2_lines:
            v.append(("3", "FileDownloader.cpp: stock line %d deleted/changed outside R1/R2" % ln))
    if files.get(HDR, {}).get("del"):
        v.append(("3", "FileDownloader.h: stock lines deleted/changed: %s" % files[HDR]["del"]))
    if WIN in files and not files[WIN]["new"]:
        v.append(("3", "FileHashWindow.h must be a new file"))

    # rule 4
    for text in files.get(CPP, {}).get("add", []):
        code = strip_code(text)
        for rx, what in FORBIDDEN_CPP:
            src = text if what == "preprocessor directive" else code
            if re.search(rx, src):
                v.append(("4", "FileDownloader.cpp added line uses %s: %s" % (what, text.strip())))
    for text in files.get(HDR, {}).get("add", []):
        if not any(re.match(rx, text) for rx in HDR_ADDED_OK):
            v.append(("4", "FileDownloader.h added line is not an include/member declaration: %s" % text.strip()))
    for text in files.get(WIN, {}).get("add", []):
        code = strip_code(text)
        for rx, what in WIN_FORBIDDEN:
            src = text if "include" in what or "macro" in what else code
            if re.search(rx, src):
                v.append(("4", "FileHashWindow.h line uses %s: %s" % (what, text.strip())))
    return v


def unified(stock_root, mut_root, rels):
    out = []
    for rel in sorted(rels):
        sp = os.path.join(stock_root, rel)
        a = open(sp, encoding="utf-8", newline="").read().splitlines(True) if os.path.exists(sp) else []
        b = open(os.path.join(mut_root, rel), encoding="utf-8", newline="").read().splitlines(True)
        out.extend(difflib.unified_diff(a, b, "a/" + rel if a else "/dev/null", "b/" + rel, n=3))
    return "".join(x if x.endswith("\n") else x + "\n" for x in out)


def changed(stock_root, patched_root):
    s, p = tree_digest(stock_root), tree_digest(patched_root)
    return sorted(k for k in set(s) | set(p) if s.get(k) != p.get(k))


def self_test(stock_root, patched_root, patch_text):
    import shutil
    import tempfile
    real = check(stock_root, patched_root, patch_text, changed(stock_root, patched_root))
    ok = True
    if real:
        ok = False
        print("SELFTEST FAIL real patch rejected:")
        for r in real:
            print("  rule %s: %s" % r)
    else:
        print("SELFTEST OK   real patch passes")
    pat_cpp = read(patched_root, CPP)
    pat_win = read(patched_root, WIN)
    else_tail = "      break;\n    }\n    // x_file_hashes_inflight: end R1\n"
    if pat_cpp.count(else_tail) != 1:
        print("SELFTEST FAIL cannot locate the R1 else tail in the real patch")
        return False
    compare_copy = (
        "        auto slice = BufferSlice(1);\n"
        "        TRY_RESULT(read_size, fd_.pread(slice.as_mutable_slice(), checked_prefix_size));\n"
        "        string hash(32, ' ');\n"
        "        sha256(slice.as_slice(), hash);\n"
        "        checked_prefix_size = size_;\n")
    cases = [
        ("copy of the comparison into the T>1 branch", "4",
         {CPP: pat_cpp.replace(else_tail, compare_copy + else_tail)}),
        ("process_check_query changed", "2",
         {CPP: pat_cpp.replace("  has_hash_query_ = false;\n  TRY_STATUS(check_net_query(net_query));",
                               "  has_hash_query_ = false;\n  hash_no_new_queries_ = false;\n  TRY_STATUS(check_net_query(net_query));")}),
        ("T>1 branch returns early (skips set_need_check)", "4",
         {CPP: pat_cpp.replace(else_tail, "      return Status::OK();\n    }\n    // x_file_hashes_inflight: end R1\n")}),
        ("T>1 branch does not end with break", "1",
         {CPP: pat_cpp.replace(else_tail, "    }\n    // x_file_hashes_inflight: end R1\n")}),
        ("set_need_check deleted", "1",
         {CPP: pat_cpp.replace("    parts_manager_.set_need_check();\n", "")}),
        ("need_check_ = false added", "4",
         {CPP: pat_cpp.replace(else_tail, "      need_check_ = false;\n" + else_tail)}),
        ("checked_prefix_size += added", "4",
         {CPP: pat_cpp.replace(else_tail, "      checked_prefix_size += 1048576;\n" + else_tail)}),
        ("sha256( added outside check_loop", "4",
         {CPP: pat_cpp.replace("      hash_query_cancel.release();\n",
                               "      hash_query_cancel.release();\n      sha256(Slice(), name_);\n")}),
        ("goto in the T>1 branch", "4",
         {CPP: pat_cpp.replace(else_tail, "      goto done;\n" + else_tail)}),
        ("stock branch of R1 modified", "1",
         {CPP: pat_cpp.replace("        has_hash_query_ = true;\n", "", 1)}),
        ("stock line changed outside check_loop", "3",
         {CPP: pat_cpp.replace("callback_->on_ok(FullLocalFileLocation(remote_.file_type_, std::move(path), 0), size, !only_check_);",
                               "callback_->on_ok(FullLocalFileLocation(remote_.file_type_, std::move(path), 0), size, false);")}),
        ("code appended after the R2 if/else inside the region", "1",
         {CPP: pat_cpp.replace("    hash_new_tokens_.clear();\n  }\n  // x_file_hashes_inflight: end R2\n",
                               "    hash_new_tokens_.clear();\n  }\n  queries.clear();\n  // x_file_hashes_inflight: end R2\n")}),
        ("extra file touched", "5",
         {"td/telegram/files/PartsManager.cpp": read(patched_root, "td/telegram/files/PartsManager.cpp") + "// x\n"}),
        ("window header includes a td header", "4",
         {WIN: pat_win.replace("#include <atomic>\n", "#include <atomic>\n#include \"td/telegram/files/FileDownloader.h\"\n")}),
    ]
    tmp = tempfile.mkdtemp(prefix="patch-scope-selftest-")
    try:
        for name, rule, edits in cases:
            mut = os.path.join(tmp, "mut")
            if os.path.exists(mut):
                shutil.rmtree(mut)
            os.makedirs(mut)
            rels = set(ALLOWED_FILES) | set(edits)
            for rel in rels:
                dst = os.path.join(mut, rel)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                text = edits.get(rel, read(patched_root, rel))
                with open(dst, "w", encoding="utf-8", newline="") as f:
                    f.write(text)
            if edits.get(CPP) == pat_cpp or edits.get(WIN) == pat_win:
                print("SELFTEST FAIL counter-example %r did not change anything (anchor drift)" % name)
                ok = False
                continue
            ptext = unified(stock_root, mut, rels)
            got = check(stock_root, mut, ptext, sorted(r for r in rels
                                                       if not os.path.exists(os.path.join(stock_root, r))
                                                       or read(stock_root, r) != read(mut, r)))
            rules = sorted(set(r for r, _ in got))
            if rule in rules:
                print("SELFTEST OK   counter-example rejected by rule %s (all: %s): %s" % (rule, ",".join(rules), name))
            else:
                ok = False
                print("SELFTEST FAIL counter-example not rejected by rule %s (got %s): %s" % (rule, rules, name))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return ok


def main(argv):
    selftest = argv and argv[0] == "--self-test"
    if selftest:
        argv = argv[1:]
    if len(argv) != 3:
        print(__doc__ or "usage: check-patch-scope.sh [--self-test] <stock-td-dir> <patched-td-dir> <patch-file>")
        return 2
    stock_root, patched_root, patch_path = argv
    with open(patch_path, encoding="utf-8", newline="") as f:
        patch_text = f.read()
    if selftest:
        return 0 if self_test(stock_root, patched_root, patch_text) else 1
    got = check(stock_root, patched_root, patch_text, changed(stock_root, patched_root))
    for rule, msg in got:
        print("FAIL rule %s: %s" % (rule, msg))
    if got:
        print("RESULT: FAIL (%d violations)" % len(got))
        return 1
    print("RESULT: PASS (rules 1-5)")
    return 0


sys.exit(main(sys.argv[1:]))
PYEOF
