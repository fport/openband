#!/bin/sh
# Generate Openband.xcodeproj. Your Apple team id (Xcode › Settings › Accounts, or the OU of your
# "Apple Development" certificate) comes from $OPENBAND_TEAM or the untracked file ios/.team, so
# regenerating keeps signing set up.
cd "$(dirname "$0")"
if [ -z "$OPENBAND_TEAM" ] && [ -f .team ]; then OPENBAND_TEAM=$(cat .team); fi
OPENBAND_TEAM="$OPENBAND_TEAM" exec xcodegen generate
