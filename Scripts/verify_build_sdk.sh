#!/bin/zsh

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <Mach-O executable>" >&2
    exit 1
fi

SDK_VERSION="$(xcrun --show-sdk-version)"
if ! BUILD_INFO="$(xcrun vtool -show-build "$1")"; then
    echo "Error: could not read build SDK from $1" >&2
    exit 1
fi

if ! awk -v expected="${SDK_VERSION}" '
    function normalize(version, parts) {
        if (version !~ /^[0-9]+(\.[0-9]+)?(\.[0-9]+)?$/) return ""
        split(version, parts, ".")
        return sprintf("%d.%d.%d", parts[1], parts[2], parts[3])
    }
    BEGIN {
        normalized_expected = normalize(expected)
        if (normalized_expected == "") {
            print "Error: invalid Xcode SDK version: " expected
            failed = 1
        }
    }
    $1 == "sdk" {
        count++
        actual = normalize($2)
        if (NF != 2 || actual == "" || actual != normalized_expected) {
            print "Error: build SDK " $2 " does not match Xcode SDK " expected
            failed = 1
        }
    }
    END {
        if (!count) {
            print "Error: no SDK values found in vtool build information"
            failed = 1
        }
        exit failed
    }
' <<< "${BUILD_INFO}" >&2; then
    echo "Error: SDK verification failed for $1; packaging aborted." >&2
    exit 1
fi

echo "Verified build SDK matches Xcode SDK ${SDK_VERSION}: $1"
