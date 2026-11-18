#!/bin/bash

# Script to build and deploy the standalone CLM Maps app
# Deploys to: https://clm-maps.web.app
# Usage: ./deploy_maps.sh

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== CLM Maps Web Deployment ===${NC}"
echo -e "${BLUE}Target: https://clm-maps.web.app${NC}"

# Deploy as the account that owns clmschedule, whatever the Firebase CLI's
# default login happens to be. One-time setup:
#   firebase login:add richardatclm@gmail.com
# Override with CLM_FIREBASE_ACCOUNT=you@example.com ./deploy_maps.sh
FIREBASE_ACCOUNT="${CLM_FIREBASE_ACCOUNT:-richardatclm@gmail.com}"
if ! firebase login:list 2>/dev/null | grep -qF "$FIREBASE_ACCOUNT"; then
  echo -e "${RED}✗ Firebase CLI is not logged in as ${FIREBASE_ACCOUNT}${NC}"
  echo -e "${YELLOW}   Run once: firebase login:add ${FIREBASE_ACCOUNT}${NC}"
  echo -e "${YELLOW}   (your other logins stay as they are)${NC}"
  exit 1
fi
echo -e "${BLUE}Firebase deploys will use: ${GREEN}${FIREBASE_ACCOUNT}${NC}"

# Step 1: Build the maps flavor
echo -e "\n${BLUE}Step 1: Building maps flavor...${NC}"
flutter pub get
dart run tools/replace_maps_key.dart
# Own output folder: hosting:main publishes build/web, so building Maps there
# put the Maps app on clmschedule.web.app whenever the two deploys overlapped.
flutter build web --release --target lib/main_maps.dart --dart-define=FLAVOR=maps --output "$PWD/build/web_maps"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Build successful${NC}"
else
    echo -e "${RED}✗ Build failed${NC}"
    exit 1
fi

# Step 1b: Rebrand built index.html + manifest.json for CLM Maps
echo -e "\n${BLUE}Step 1b: Rebranding build output for CLM Maps...${NC}"

MAPS_TITLE="CLM Maps"
MAPS_DESC="Interactive GPS-tracked flyer distribution maps by Community Life Media, Cape Town"
# Absolute origin for link-preview images (relative og:image URLs are ignored
# by WhatsApp/Outlook). Switch to https://maps.communitylifemedia.co.za once
# the custom domain is live. /map/** pages are rendered by the mapPage
# function, which sets per-map tags on top of this template.
MAPS_ORIGIN="https://maps.communitylifemedia.co.za"

INDEX_FILE="build/web_maps/index.html"
MANIFEST_FILE="build/web_maps/manifest.json"

if [ -f "$INDEX_FILE" ]; then
    # macOS/BSD sed requires -i ''
    sed -i '' \
        -e "s|<title>CLM Schedule</title>|<title>${MAPS_TITLE}</title>|g" \
        -e "s|<meta name=\"description\" content=\"CLM Schedule - Enterprise scheduling application\">|<meta name=\"description\" content=\"${MAPS_DESC}\">|g" \
        -e "s|<meta name=\"apple-mobile-web-app-title\" content=\"CLM Schedule\">|<meta name=\"apple-mobile-web-app-title\" content=\"${MAPS_TITLE}\">|g" \
        -e "s|<meta property=\"og:title\" content=\"CLM Schedule\">|<meta property=\"og:title\" content=\"${MAPS_TITLE}\">|g" \
        -e "s|<meta property=\"og:description\" content=\"CLM Schedule - Enterprise scheduling application\">|<meta property=\"og:description\" content=\"${MAPS_DESC}\">|g" \
        -e "s|<meta name=\"twitter:title\" content=\"CLM Schedule\">|<meta name=\"twitter:title\" content=\"${MAPS_TITLE}\">|g" \
        -e "s|<meta name=\"twitter:description\" content=\"CLM Schedule - Enterprise scheduling application\">|<meta name=\"twitter:description\" content=\"${MAPS_DESC}\">|g" \
        -e "s|<meta property=\"og:image\" content=\"icons/Icon-512.png\">|<meta property=\"og:image\" content=\"${MAPS_ORIGIN}/assets/assets/clm-official-logo.jpeg\">|g" \
        -e "s|<meta name=\"twitter:image\" content=\"icons/Icon-512.png\">|<meta name=\"twitter:image\" content=\"${MAPS_ORIGIN}/assets/assets/clm-official-logo.jpeg\">|g" \
        -e "s|var SINGLE_TAB    = false;|var SINGLE_TAB    = true; |" \
        "$INDEX_FILE"
    # Maps has no Firestore persistence, so duplicate tabs must stay blocked.
    if ! grep -q "var SINGLE_TAB    = true;" "$INDEX_FILE"; then
        echo -e "${RED}✗ Failed to enable single-tab lock in $INDEX_FILE${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Rebranded $INDEX_FILE${NC}"
else
    echo -e "${RED}✗ $INDEX_FILE not found${NC}"
    exit 1
fi

if [ -f "$MANIFEST_FILE" ]; then
    sed -i '' \
        -e "s|\"name\": \"CLM Schedule\"|\"name\": \"${MAPS_TITLE}\"|g" \
        -e "s|\"short_name\": \"CLM Schedule\"|\"short_name\": \"${MAPS_TITLE}\"|g" \
        -e "s|\"description\": \"CLM Schedule - Enterprise scheduling application for distributor job management\"|\"description\": \"${MAPS_DESC}\"|g" \
        "$MANIFEST_FILE"
    echo -e "${GREEN}✓ Rebranded $MANIFEST_FILE${NC}"
fi

# Step 2: Deploy to Firebase Hosting (maps target → clm-maps site)
echo -e "\n${BLUE}Step 2: Deploying mapPage + photoPage functions + Firebase Hosting (maps target)...${NC}"
# Both functions must ship with (or before) Hosting — the /map/** and
# /photos/** rewrites point at them.
firebase deploy --only functions:mapPage,functions:photoPage,hosting:maps --project clmschedule --account "$FIREBASE_ACCOUNT"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Deployment successful${NC}"
else
    echo -e "${RED}✗ Deployment failed${NC}"
    exit 1
fi

echo -e "\n${GREEN}=== CLM Maps Deployment Complete ===${NC}"
echo -e "${BLUE}Live at: ${GREEN}https://clm-maps.web.app${NC}"
