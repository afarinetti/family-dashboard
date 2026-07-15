#!/bin/sh
# Configure the Ubuntu Frame kiosk stack to display family_dashboard
# fullscreen in portrait on the wall monitor (1080x1920). Run this after
# install.sh has the app serving on localhost. See deploy/README.md.
set -eu

PORT="${FAMILY_DASHBOARD_PORT:-4000}"
# normal | left | right | inverted — "left"/"right" both yield portrait;
# pick whichever matches which way the monitor is physically rotated.
ORIENTATION="${FAMILY_DASHBOARD_ORIENTATION:-left}"

echo "==> Installing Ubuntu Frame + WPE WebKit kiosk snaps..."
sudo snap install ubuntu-frame
sudo snap install wpe-webkit-mir-kiosk

echo "==> Pointing the kiosk at the dashboard..."
sudo snap set wpe-webkit-mir-kiosk url="http://localhost:${PORT}"

# Frame usually auto-connects wayland + starts its daemon on Ubuntu Core, but
# this isn't universally documented — connecting/enabling explicitly is a
# harmless no-op if already done, and required if it wasn't.
sudo snap connect wpe-webkit-mir-kiosk:wayland ubuntu-frame:wayland 2>/dev/null || true
sudo snap set wpe-webkit-mir-kiosk daemon=true 2>/dev/null || true
sudo snap set ubuntu-frame daemon=true 2>/dev/null || true

echo
echo "==> Finding the connected display output..."
echo "    Frame logs the available output names (e.g. HDMI-A-1, eDP-1) at"
echo "    startup — there's no dedicated 'list outputs' command. Check:"
echo
echo "      snap logs ubuntu-frame"
echo
echo "    Then set portrait rotation with the real output name, e.g.:"
echo
cat <<'EOF'
      sudo snap set ubuntu-frame display="
      layouts:
        default:
          cards:
          - card-id: 0
            HDMI-A-1:
              orientation: left"
EOF
echo
echo "    (Swap HDMI-A-1 for your actual output, and 'left' for 'right' if the"
echo "     rotation comes out upside down or backwards. If the monitor has a"
echo "     hardware/OSD portrait mode instead, skip this and leave 'normal'.)"
echo
echo "==> Verify: snap connections wpe-webkit-mir-kiosk ; snap logs wpe-webkit-mir-kiosk"
