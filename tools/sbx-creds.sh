#!/usr/bin/env bash
# sbx-creds: copy an elm credential profile into a Docker sandbox (sbx), or
# remove it again. Run it on the host, not in the sandbox. Keeps credentials
# out of the repo, which the sandbox mounts: they go to the sandbox's own
# ~/.config/logicmonitor/credentials/, mode 600.
#
# Usage:
#   sbx-creds.sh [-s SANDBOX] cp PROFILE [NAME]  # copy PROFILE.ini in as NAME.ini
#                                                # (default: the same name)
#   sbx-creds.sh [-s SANDBOX] rm NAME            # delete NAME.ini from the sandbox
#   sbx-creds.sh [-s SANDBOX] ls                 # list the profiles in the sandbox
#
# Options:
#   -s SANDBOX   the sandbox name (sbx ls); defaults to $SBX
#   -h, --help   show this help
#
# Examples:
#   sbx-creds.sh -s claude-elm cp config       # the test portal, as the default
#   sbx-creds.sh -s claude-elm cp busy         # another portal, under its own name
#   sbx-creds.sh -s claude-elm cp test config  # test.ini in as the default
#   sbx-creds.sh -s claude-elm rm busy
#
# The file's contents are never printed. A sandbox that is recreated loses its
# profiles: run this again.
#
# Requires: sbx

set -euo pipefail

usage() { sed -n '2,/^# Requires/s/^# \{0,1\}//p' "$0"; }

sandbox=${SBX:-}
while [[ $# -gt 0 ]]; do
  case $1 in
    -s) sandbox=${2:?-s needs a sandbox name}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) break ;;
  esac
done
[[ $# -ge 1 ]] || { usage >&2; exit 2; }
[[ -n $sandbox ]] || { echo "sbx-creds: no sandbox: use -s SANDBOX or set SBX" >&2; exit 2; }

creds="$HOME/.config/logicmonitor/credentials"
dir='$HOME/.config/logicmonitor/credentials'     # expanded in the sandbox

name_ok() {
  [[ $1 =~ ^[A-Za-z0-9_.-]+$ && $1 != *.example && $1 != .* ]] ||
    { echo "sbx-creds: '$1' is not a profile name" >&2; exit 2; }
}

case $1 in
  ls)
    sbx exec -u agent "$sandbox" sh -c "ls $dir 2>/dev/null | sed -n 's/\.ini\$//p'"
    ;;
  rm)
    name=${2:?rm needs a profile name}; name=${name%.ini}; name_ok "$name"
    sbx exec -u agent "$sandbox" sh -c "rm $dir/\"\$1\".ini" sh "$name"
    echo "removed $name.ini from $sandbox"
    ;;
  cp)
    profile=${2:?cp needs a profile name}; profile=${profile%.ini}; name=${3:-$profile}; name=${name%.ini}
    name_ok "$profile"; name_ok "$name"
    [[ -r $creds/$profile.ini ]] || { echo "sbx-creds: no profile $creds/$profile.ini" >&2; exit 1; }
    sbx exec -i -u agent "$sandbox" sh -c \
      "umask 077; mkdir -p $dir && cat > $dir/\"\$1\".ini && chmod 600 $dir/\"\$1\".ini" \
      sh "$name" < "$creds/$profile.ini"
    echo "copied $profile.ini to $sandbox as $name.ini"
    ;;
  *)
    echo "sbx-creds: '$1' is not cp, rm or ls" >&2; usage >&2; exit 2
    ;;
esac
