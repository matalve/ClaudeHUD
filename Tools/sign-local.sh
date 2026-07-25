#!/bin/sh
# Sign a built ClaudeHUD.app with a stable local identity.
#
# Why: the project builds ad-hoc signed so anyone can compile it without an
# Apple Developer account. But an ad-hoc signature changes on every build, so
# macOS can never recognise the app as "the one you approved" — and the
# keychain permission for the Claude Code OAuth token is asked for again after
# every rebuild.
#
# Signing with a stable certificate gives the app a designated requirement of
#     identifier "se.matalve.ClaudeHUD" and certificate leaf = H"<cert hash>"
# which contains no cdhash, so it survives rebuilds and the keychain approval
# sticks.
#
# A self-signed certificate is enough (no Apple account, no personal details
# in the binary). Create one once:
#
#   Keychain Access > Certificate Assistant > Create a Certificate…
#     Name: ClaudeHUD Dev
#     Identity Type: Self Signed Root
#     Certificate Type: Code Signing
#
# Then:  ./Tools/sign-local.sh /Applications/ClaudeHUD.app
#
# Override the identity with SIGN_IDENTITY if yours is named differently.

set -eu

APP="${1:-/Applications/ClaudeHUD.app}"
IDENTITY="${SIGN_IDENTITY:-ClaudeHUD Dev}"

if [ ! -d "$APP" ]; then
    echo "error: no app bundle at $APP" >&2
    exit 1
fi

if ! security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    echo "error: no certificate named '$IDENTITY' in your keychain." >&2
    echo "       Create one (see the comments at the top of this script)," >&2
    echo "       or set SIGN_IDENTITY to the name of an existing one." >&2
    exit 1
fi

codesign --force --deep --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo "signed $APP as '$IDENTITY'"
codesign -d -r- "$APP" 2>&1 | grep designated
