#!/usr/bin/env bash
# Every relative link in the repository's Markdown files resolves: the target
# file or directory exists, and a `#anchor` names a heading (or an explicit
# `<a id|name="…">`) of the target Markdown file.
#
# Checked: inline links and images `[text](target)` and reference
# definitions `[label]: target`, outside fenced code blocks and inline code.
# Not checked: absolute URLs (http, https, mailto) — they are outside this
# repository. Anchors follow GitHub's rule: the heading's text, lower-cased,
# punctuation removed, spaces turned into hyphens, `-1`, `-2`… appended to
# repeats.
#
# Files: every *.md that git tracks or would track (untracked but not
# ignored), as present in the working tree.
#
# Usage: tests/docs.sh   (bash, git, coreutils, grep, sed, awk)
# Output: one "file:line: message" per broken link, then a count; exit 1 if
# any.
set -euo pipefail
export LC_ALL=C

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

# links <file>: "line<TAB>target" for each relative link of a Markdown file.
links() {
  awk '
    /^[ \t]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    {
      line = $0
      gsub(/`[^`]*`/, "", line)                    # inline code
      # Reference definition: [label]: target
      if (match(line, /^[ \t]*\[[^]]+\]:[ \t]*[^ \t]+/)) {
        t = substr(line, RSTART, RLENGTH); sub(/^[ \t]*\[[^]]+\]:[ \t]*/, "", t)
        print NR "\t" t
        next
      }
      # Inline links and images: ](target) or ](target "title")
      while (match(line, /\]\([^) \t]+/)) {
        t = substr(line, RSTART + 2, RLENGTH - 2)
        print NR "\t" t
        line = substr(line, RSTART + RLENGTH)
      }
    }' "$1" | awk -F'\t' '
      { t = $2; sub(/^</, "", t); sub(/>$/, "", t) }
      t ~ /^(https?|mailto|ftp):/ { next }
      t == "" { next }
      { print $1 "\t" t }'
}

# anchors <file>: every anchor a Markdown file defines, one per line.
anchors() {
  awk '
    /^[ \t]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    {
      # Explicit HTML anchors.
      s = $0
      while (match(s, /<a[ \t]+(id|name)="[^"]+"/)) {
        a = substr(s, RSTART, RLENGTH); sub(/^<a[ \t]+(id|name)="/, "", a); sub(/"$/, "", a)
        print a
        s = substr(s, RSTART + RLENGTH)
      }
    }
    /^#+[ \t]/ && match($0, /^#+/) && RLENGTH <= 6 {
      h = $0
      sub(/^#+[ \t]+/, "", h); sub(/[ \t]+#*[ \t]*$/, "", h)
      # Link text only: [text](url) -> text
      while (match(h, /\[[^]]*\]\([^)]*\)/)) {
        inner = substr(h, RSTART + 1, RLENGTH - 1); sub(/\]\(.*$/, "", inner)
        h = substr(h, 1, RSTART - 1) inner substr(h, RSTART + RLENGTH)
      }
      h = tolower(h)
      # Common non-ASCII punctuation GitHub drops (UTF-8 byte sequences):
      # em dash, en dash, middle dot, arrows, curly quotes, ellipsis.
      gsub(/\342\200\224|\342\200\223|\302\267|\342\206\222|\342\206\220|\342\200\231|\342\200\230|\342\200\234|\342\200\235|\342\200\246/, "", h)
      # ASCII: keep letters, digits, space, hyphen, underscore; drop the rest.
      gsub(/[^a-z0-9 _\200-\377-]/, "", h)
      gsub(/ /, "-", h)
      n = seen[h]++
      print (n ? h "-" n : h)
    }' "$1"
}

errors=0
report() { echo "$1:$2: $3"; errors=$((errors + 1)); }

files=()
while IFS= read -r f; do
  [ -f "$f" ] && files+=("$f")
done < <(git ls-files --cached --others --exclude-standard -- '*.md' | sort -u)
[ "${#files[@]}" -gt 0 ] || { echo "no Markdown files found" >&2; exit 1; }

checked=0
for f in "${files[@]}"; do
  dir=$(dirname "$f")
  while IFS=$'\t' read -r line target; do
    checked=$((checked + 1))
    path=${target%%#*}
    anchor=""
    [[ "$target" == *"#"* ]] && anchor=${target#*#}
    # Query strings never name a file.
    path=${path%%\?*}
    if [ -z "$path" ]; then
      dest=$f
    elif [[ "$path" == /* ]]; then
      dest=${path#/}
    else
      dest="$dir/$path"
    fi
    if [ ! -e "$dest" ]; then
      report "$f" "$line" "broken link: $target ($dest does not exist)"
      continue
    fi
    if [ -n "$anchor" ]; then
      case "$dest" in
        *.md)
          if ! anchors "$dest" | grep -qxF -- "$anchor"; then
            report "$f" "$line" "broken anchor: $target (no heading '#$anchor' in $dest)"
          fi ;;
        *) ;;  # #L10-style anchors on source files: GitHub's viewer, not checked
      esac
    fi
  done < <(links "$f")
done

if [ "$errors" -gt 0 ]; then
  echo "FAIL: $errors broken link(s) out of $checked in ${#files[@]} Markdown files" >&2
  exit 1
fi
echo "PASS: $checked relative links in ${#files[@]} Markdown files resolve"
