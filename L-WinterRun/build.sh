#!/bin/bash
# L冬跑 编译脚本
# 用法: ./build.sh [机型] [输出文件名]
#   例: ./build.sh fenix7xpro LWinterRun-fenix7x.prg
# 说明: 需要 Connect IQ SDK + Java 21，设备配置文件放在
#       %APPDATA%\Garmin\ConnectIQ\Devices\<机型> 下

set -e

DEVICE="${1:-fenix7x}"
OUT="${2:-bin/LWinterRun-$DEVICE.prg}"

JAVA="${JAVA:-C:/Users/HUAWEI/WorkBuddy/2026-11-16-11-38-27/tools/jdk/jdk-21.0.13.0.2+1/bin/java.exe}"
SDK="${CIQ_SDK:-C:/Users/HUAWEI/AppData/Roaming/Garmin/ConnectIQ/Sdks/connectiq-sdk-win-9.3.0-2026-10-20-95888f262}"
KEY="${KEY:-../keys/developer_key.der}"

mkdir -p "$(dirname "$OUT")"

"$JAVA" -Xms1g -Dfile.encoding=UTF-8 \
  -cp "$SDK/bin/monkeybrains.jar" \
  com.garmin.monkeybrains.Monkeybrains \
  -d "$DEVICE" \
  -f monkey.jungle \
  -o "$OUT" \
  -y "$KEY" \
  -w -l 2

echo "OK -> $OUT"
