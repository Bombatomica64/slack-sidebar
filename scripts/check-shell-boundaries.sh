#!/bin/sh
set -eu

fail=0

reject() {
    pattern=$1
    description=$2
    if grep -R -n -E "$pattern" Core --include='*.qml'; then
        echo "error: Core must not depend on $description" >&2
        fail=1
    fi
}

reject 'import[[:space:]]+qs\.' 'a host shell QML module'
reject 'pluginApi' 'Noctalia pluginApi'
reject '(noctalia|dms|end-4|caelestia)[-/]' 'a host-specific filesystem layout'

exit "$fail"
