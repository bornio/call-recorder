#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
cd "$repo_root"
swift run -Xswiftc -warnings-as-errors -Xcc -Werror CallRecorderTests
swift build --configuration debug --product CallRecorder -Xswiftc -warnings-as-errors -Xcc -Werror
swift build --configuration release --product CallRecorder -Xswiftc -warnings-as-errors -Xcc -Werror
