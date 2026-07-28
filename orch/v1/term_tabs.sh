#!/usr/bin/env bash
set -euo pipefail

################################################################################
# term_tabs.sh — open one Terminator window with named command tabs.
# (orch/v1; proven launcher ported from the reference sim's terms_tabs.sh.)
#
# Each tab runs its command in the caller's environment (so ID etc. thread
# through), keeps the tab open with a titled shell after the command exits,
# and preserves TTY so docker -it works.
################################################################################

TITLE="Terminator Tabs"
WORKDIR="$PWD"
FILE=""

usage() {
  cat <<'EOF'
Usage:
  term_tabs.sh [-t WINDOW_TITLE] [-d WORKDIR] "name::cmd" "name::cmd" ...
  term_tabs.sh [-t WINDOW_TITLE] [-d WORKDIR] -f commands.txt

Format:
  name::command     Tab named "name" runs "command"
  command           Tab named "command" runs "command"
  (# comments and blank lines in -f files are skipped)
EOF
  exit 2
}

while getopts ":t:d:f:h" opt; do
  case "$opt" in
    t) TITLE="$OPTARG" ;;
    d) WORKDIR="$OPTARG" ;;
    f) FILE="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done
shift $((OPTIND-1))

command -v terminator >/dev/null 2>&1 || { echo "ERROR: terminator not installed" >&2; exit 2; }
[[ -d "$WORKDIR" ]] || { echo "ERROR: WORKDIR not a directory: $WORKDIR" >&2; exit 2; }

ENTRIES=()
if [[ -n "$FILE" ]]; then
  [[ -r "$FILE" ]] || { echo "ERROR: cannot read $FILE" >&2; exit 2; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    ENTRIES+=("$line")
  done < "$FILE"
else
  ENTRIES=("$@")
fi
[[ ${#ENTRIES[@]} -gt 0 ]] || usage

split_entry() {
  local entry="$1" name cmd
  if [[ "$entry" == *"::"* ]]; then
    name="${entry%%::*}"
    cmd="${entry#*::}"
  else
    name="$entry"
    cmd="$entry"
  fi
  name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"
  cmd="${cmd#"${cmd%%[![:space:]]*}"}"; cmd="${cmd%"${cmd##*[![:space:]]}"}"
  [[ -n "$cmd" ]] || { echo "ERROR: empty command for entry: $entry" >&2; exit 2; }
  [[ -n "$name" ]] || name="$cmd"
  printf '%s\t%s\n' "$name" "$cmd"
}

TMPBASE="${TMPDIR:-/tmp}"
WORKBASE="$(mktemp -d -p "$TMPBASE" termtabs.XXXXXX)"
CFG="$WORKBASE/terminator.cfg"

LAYOUT="termtabs_layout"

# Build labels list for Notebook (Python list format)
build_labels() {
  local result=""
  for entry in "${ENTRIES[@]}"; do
    IFS=$'\t' read -r name _ < <(split_entry "$entry")
    name="${name//\'/\'\"\'\"\'}"
    result+="${result:+, }'$name'"
  done
  echo "$result"
}

LABELS="$(build_labels)"

# Create wrapper script for each tab
create_wrapper() {
  local idx="$1" name="$2" cmd="$3"
  local wrapper="$WORKBASE/tab_${idx}.sh"

  cat > "$wrapper" <<WRAPPER
#!/usr/bin/env bash

cd $(printf '%q' "$WORKDIR") || exit 1

TABNAME=$(printf '%q' "$name")
CMD=$(printf '%q' "$cmd")

# Set tab title
set_title() {
  printf '\033]0;%s\007' "\$TABNAME"
  printf '\033]2;%s\007' "\$TABNAME"
}
set_title

echo -e "\033[1;34m▶ Running:\033[0m \$CMD"
echo ""

# Run command directly (not backgrounded) - this preserves TTY for docker etc.
eval "\$CMD"
rc=\$?

echo ""
echo -e "\033[1;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "\033[1;32m✓ Command finished\033[0m (exit code: \$rc)"
echo -e "\033[0;36m  Tab stays open. Type 'exit' to close.\033[0m"
echo -e "\033[1;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo ""

# Create rcfile that preserves tab title
RCFILE="\$(mktemp)"
cat > "\$RCFILE" <<'RCEOF'
[[ -r /etc/bash.bashrc ]] && source /etc/bash.bashrc
[[ -r ~/.bashrc ]] && source ~/.bashrc
__termtabs_title() {
  printf '\033]0;%s\007' "\$TABNAME"
  printf '\033]2;%s\007' "\$TABNAME"
}
if [[ -n "\${PROMPT_COMMAND:-}" ]]; then
  PROMPT_COMMAND="__termtabs_title; \$PROMPT_COMMAND"
else
  PROMPT_COMMAND="__termtabs_title"
fi
__termtabs_title
rm -f "\$BASH_SOURCE" 2>/dev/null || true
RCEOF

export TABNAME
exec bash --rcfile "\$RCFILE" -i
WRAPPER

  chmod +x "$wrapper"
  echo "$wrapper"
}

# Generate Terminator config
{
  cat <<'CFG_HEAD'
[global_config]
  suppress_multiple_term_dialog = True

[keybindings]

[profiles]
  [[default]]
    scrollback_lines = 5000
    use_system_font = True

[layouts]
CFG_HEAD

  echo "  [[${LAYOUT}]]"
  echo "    [[[child0]]]"
  echo "      type = Window"
  echo "      parent = \"\""
  echo "      order = 0"
  echo "      size = 1200, 800"

  if [[ ${#ENTRIES[@]} -eq 1 ]]; then
    # Single tab: No Notebook needed, just Terminal directly under Window
    IFS=$'\t' read -r name cmd < <(split_entry "${ENTRIES[0]}")
    wrapper="$(create_wrapper 0 "$name" "$cmd")"

    echo "    [[[terminal0]]]"
    echo "      type = Terminal"
    echo "      parent = child0"
    echo "      order = 0"
    echo "      profile = default"
    echo "      directory = ${WORKDIR}"
    echo "      command = ${wrapper}"
    echo "      title = ${name}"
  else
    # Multiple tabs: Use Notebook
    echo "    [[[child1]]]"
    echo "      type = Notebook"
    echo "      parent = child0"
    echo "      order = 0"
    echo "      labels = ${LABELS}"
    echo ""

    for i in "${!ENTRIES[@]}"; do
      IFS=$'\t' read -r name cmd < <(split_entry "${ENTRIES[$i]}")
      wrapper="$(create_wrapper "$i" "$name" "$cmd")"

      echo "    [[[terminal${i}]]]"
      echo "      type = Terminal"
      echo "      parent = child1"
      echo "      order = ${i}"
      echo "      profile = default"
      echo "      directory = ${WORKDIR}"
      echo "      command = ${wrapper}"
      echo ""
    done
  fi

  echo ""
  echo "[plugins]"
} > "$CFG"

if [[ "${DEBUG:-}" == "1" ]]; then
  echo "=== Generated Config ===" >&2
  cat "$CFG" >&2
  echo "========================" >&2
fi

# Launch Terminator
terminator --no-dbus -g "$CFG" -l "$LAYOUT" -T "$TITLE" &

# Delayed cleanup in background
(
  sleep 10
  rm -rf "$WORKBASE" 2>/dev/null || true
) &
disown 2>/dev/null || true

echo "Launched Terminator with ${#ENTRIES[@]} tab(s)"
