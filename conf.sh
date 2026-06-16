#!/bin/sh
set -e

CPU_CORES=$(nproc 2>/dev/null || echo 1)

echo "=================================="
echo "        SUPERVIM BUILD MENU       "
echo "=================================="

echo "CPU cores detected: $CPU_CORES"
echo ""

# CPU 기반 추천 로직
if [ "$CPU_CORES" -le 2 ]; then
  RECOMMEND=2
  echo "⚠ Low-end system detected → recommend [2]"
elif [ "$CPU_CORES" -le 4 ]; then
  RECOMMEND=1
  echo "ℹ Mid system detected → recommend [1]"
else
  RECOMMEND=1
  echo "🚀 High performance system → recommend [1]"
fi

echo ""
echo "[1] FULL BUILD (GAP + async)"
echo "    - 최고 성능 / 기능 최대"
echo ""
echo "[2] LITE BUILD (no GAP / no async)"
echo "    - 라즈베리파이 / 초소형 / 저사양"
echo ""
echo "[3] STABLE BUILD (no undo / simple mode)"
echo "    - 안정성 최우선 / 보수적"
echo ""

echo "Recommended: [$RECOMMEND]"
echo ""

printf "Select option (default %s): " "$RECOMMEND"
read n

# default 처리
if [ -z "$n" ]; then
  n=$RECOMMEND
fi

case "$n" in
  1)
    echo ">>> Building FULL"
    sh build.sh
    ;;
  2)
    echo ">>> Building LITE"
    sh build-nogap.sh
    ;;
  3)
    echo ">>> Building STABLE"
    sh builds.sh
    ;;
  *)
    echo "Invalid option"
    ;;
esac