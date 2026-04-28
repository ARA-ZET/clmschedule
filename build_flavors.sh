#!/bin/bash

# Build script for CLM Schedule app flavors
# Usage: ./build_flavors.sh [flavor] [build_type]
#
# Flavors: clm, happysun, maps
# Build types: debug, release, run

set -e

FLAVOR=${1:-clm}
BUILD_TYPE=${2:-debug}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}CLM Schedule Flavor Build${NC}"
echo -e "${GREEN}================================${NC}"
echo ""

# Validate flavor
if [[ "$FLAVOR" != "clm" && "$FLAVOR" != "happysun" && "$FLAVOR" != "maps" && "$FLAVOR" != "trackEditor" && "$FLAVOR" != "erfProperty" && "$FLAVOR" != "dropsheet" ]]; then
    echo -e "${RED}Error: Invalid flavor '$FLAVOR'${NC}"
    echo "Valid flavors: clm, happysun, maps, trackEditor, erfProperty, dropsheet"
    exit 1
fi

# Set target file based on flavor
TARGET_FILE="lib/main_${FLAVOR}.dart"
DART_DEFINE="FLAVOR=${FLAVOR}"

echo -e "${YELLOW}Flavor:${NC} $FLAVOR"
echo -e "${YELLOW}Build Type:${NC} $BUILD_TYPE"
echo -e "${YELLOW}Target:${NC} $TARGET_FILE"
echo -e "${YELLOW}Dart Define:${NC} $DART_DEFINE"
echo ""

# Run the build
case $BUILD_TYPE in
    debug)
        echo -e "${GREEN}Building debug APK...${NC}"
        flutter build apk --flavor "$FLAVOR" --target "$TARGET_FILE" --dart-define="$DART_DEFINE"
        echo ""
        echo -e "${GREEN}✓ Debug APK built successfully!${NC}"
        echo -e "Location: build/app/outputs/flutter-apk/app-${FLAVOR}-debug.apk"
        ;;
    
    release)
        echo -e "${GREEN}Building release APK...${NC}"
        flutter build apk --release --flavor "$FLAVOR" --target "$TARGET_FILE" --dart-define="$DART_DEFINE"
        echo ""
        echo -e "${GREEN}✓ Release APK built successfully!${NC}"
        echo -e "Location: build/app/outputs/flutter-apk/app-${FLAVOR}-release.apk"
        ;;
    
    bundle)
        echo -e "${GREEN}Building release App Bundle...${NC}"
        flutter build appbundle --release --flavor "$FLAVOR" --target "$TARGET_FILE" --dart-define="$DART_DEFINE"
        echo ""
        echo -e "${GREEN}✓ Release App Bundle built successfully!${NC}"
        echo -e "Location: build/app/outputs/bundle/${FLAVOR}Release/app-${FLAVOR}-release.aab"
        ;;
    
    run)
        echo -e "${GREEN}Running app on device...${NC}"
        flutter run --flavor "$FLAVOR" --target "$TARGET_FILE" --dart-define="$DART_DEFINE"
        ;;

    web)
        echo -e "${GREEN}Running app on Chrome (web)...${NC}"
        flutter run -d chrome --target "$TARGET_FILE" --dart-define="$DART_DEFINE"
        ;;
    
    *)
        echo -e "${RED}Error: Invalid build type '$BUILD_TYPE'${NC}"
        echo "Valid build types: debug, release, bundle, run"
        exit 1
        ;;
esac

echo ""
echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}Build Complete!${NC}"
echo -e "${GREEN}================================${NC}"
