#!/usr/bin/env bash
# sbx-creds: copy an elm credential profile into a Docker sandbox (sbx), or
# remove it again. Run it on the host, not in the sandbox. Keeps credentials
# out of the repo, which the sandbox mounts: they go to the sandbox's own
# ~/.config/logicmonitor/credentials/, mode 600.
#
# Usage:
#   sbx-creds.sh avail                         # the profiles on this Mac, to cp
#   sbx-creds.sh [-s SANDBOX|-a] cp PROFILE [NAME]  # copy PROFILE.ini in as NAME.ini
#                                              # (default: the same name)
#   sbx-creds.sh [-s SANDBOX|-a] rm NAME       # delete NAME.ini from the sandbox
#   sbx-creds.sh [-s SANDBOX|-a] rm --all      # delete every profile there (asks first)
#   sbx-creds.sh [-s SANDBOX|-a] ls            # list the profiles in the sandbox
#
# Options:
#   -s SANDBOX   the sandbox name (sbx ls); defaults to $SBX
#   -a           every running sandbox, one after another (a stopped one is
#                skipped: sbx exec would start it)
#   -h, --help   show this help
#
# To skip -s, set SBX once, for example in ~/.zshrc:
#   export SBX=claude-elm
#   sbx-creds.sh cp portal01
#
# Examples:
#   sbx-creds.sh avail                             # what there is to copy
#   sbx-creds.sh -s claude-elm cp config           # the test portal, as the default
#   sbx-creds.sh -s claude-elm cp portal01         # another portal, under its own name
#   sbx-creds.sh -s claude-elm cp portal01 config  # swap portal01 in as the default
#   sbx-creds.sh -s claude-elm rm portal01
#   sbx-creds.sh -a ls                             # what every sandbox has
#   sbx-creds.sh -a rm portal01                    # take it out of all of them
#   sbx-creds.sh -a rm --all                       # empty every sandbox, after a y
#
# Every command but avail goes from the Mac to the sandbox, or acts there. cp
# overwrites, as cp does: everything in the sandbox is a copy, so cp it again.
# There is no cat, on purpose: the contents are never printed. A sandbox that
# is recreated loses its profiles: run this again.
#
# Requires: sbx

set -euo pipefail

usage() { sed -n '2,/^# Requires/s/^# \{0,1\}//p' "$0"; }

sandbox=${SBX:-} all=
while [[ $# -gt 0 ]]; do
  case $1 in
    -s) sandbox=${2:?-s needs a sandbox name}; shift 2 ;;
    -a) all=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) break ;;
  esac
done
[[ $# -ge 1 ]] || { usage >&2; exit 2; }

creds="$HOME/.config/logicmonitor/credentials"
dir='$HOME/.config/logicmonitor/credentials'     # expanded in the sandbox

name_ok() {
  [[ $1 =~ ^[A-Za-z0-9_.-]+$ && $1 != *.example && $1 != .* ]] ||
    { echo "sbx-creds: '$1' is not a profile name" >&2; exit 2; }
}

# The profiles on this Mac: names only, as elm --list shows them.
if [[ $1 == avail ]]; then
  for f in "$creds"/*.ini; do
    [[ -e $f ]] || continue
    f=${f##*/}; f=${f%.ini}
    [[ $f == *.example ]] || echo "$f"
  done
  exit 0
fi

one() {   # one command, in one sandbox (-a runs it after ||, where set -e is off)
  local sandbox=$1; shift
  case $1 in
    ls)
      sbx exec -u agent "$sandbox" sh -c "ls $dir 2>/dev/null | sed -n 's/\.ini\$//p'" || return
      ;;
    rm)
      if [[ ${2:-} == --all ]]; then
        sbx exec -u agent "$sandbox" sh -c "rm -f $dir/*.ini" || return
        echo "removed every profile from $sandbox"
        return
      fi
      name=${2:?rm needs a profile name}; name=${name%.ini}; name_ok "$name"
      sbx exec -u agent "$sandbox" sh -c "rm $dir/\"\$1\".ini" sh "$name" || return
      echo "removed $sandbox:~/.config/logicmonitor/credentials/$name.ini"
      ;;
    cp)
      profile=${2:?cp needs a profile name}; profile=${profile%.ini}; name=${3:-$profile}; name=${name%.ini}
      name_ok "$profile"; name_ok "$name"
      [[ -r $creds/$profile.ini ]] || { echo "sbx-creds: no profile $creds/$profile.ini" >&2; exit 1; }
      sbx exec -i -u agent "$sandbox" sh -c \
        "umask 077; mkdir -p $dir && cat > $dir/\"\$1\".ini && chmod 600 $dir/\"\$1\".ini" \
        sh "$name" < "$creds/$profile.ini" || return
      echo "copied $creds/$profile.ini to $sandbox:~/.config/logicmonitor/credentials/$name.ini"
      ;;
    *)
      echo "sbx-creds: '$1' is not avail, cp, rm or ls" >&2; usage >&2; exit 2
      ;;
  esac
}

if [[ -n $all ]]; then
  # -a: the running sandboxes, from the STATUS column of sbx ls ("● running").
  # A sandbox that fails is reported and skipped, and the rest still run.
  list=$(sbx ls)
  sandboxes=$(awk '{ for (i = 2; i <= NF; i++) if ($i == "running") { print $1; next } }' <<< "$list")
  stopped=$(awk '{ for (i = 2; i <= NF; i++) if ($i == "stopped") { n++; next } } END { print n + 0 }' <<< "$list")
  [[ $stopped == 0 ]] || echo "sbx-creds: skipping $stopped stopped sandboxes" >&2
  [[ -n $sandboxes ]] || { echo "sbx-creds: no sandbox is running" >&2; exit 1; }
else
  [[ -n $sandbox ]] || { echo "sbx-creds: no sandbox: use -s SANDBOX, -a, or set SBX" >&2; exit 2; }
  sandboxes=$sandbox
fi

# rm --all asks once, for every sandbox it will empty; anything but y stops it.
if [[ $1 == rm && ${2:-} == --all ]]; then
  read -r -p "Remove every profile from $(echo $sandboxes | sed 's/ /, /g')? [y/N] " yes < /dev/tty
  [[ $yes == [yY] ]] || { echo "sbx-creds: nothing removed" >&2; exit 1; }
fi

if [[ -z $all ]]; then
  one "$sandbox" "$@"
  exit
fi
rc=0
for s in $sandboxes; do
  [[ $1 == ls ]] && echo "$s:"
  ( one "$s" "$@" ) || { echo "sbx-creds: $s: failed" >&2; rc=1; }
done
exit $rc
