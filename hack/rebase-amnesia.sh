#!/usr/bin/env bash
# Rebase amnesia onto the custom-kernel 615 driver stack (no Image Factory).
#
# Pipeline:
#   1. (CI) kernel/modules/firmware/toolkit/imager/uinput rebuilt by GitHub
#      Actions on timblakely/talos-nvidia-open-extension -> ghcr.io/timblakely/*
#   2. (here) build the metal installer image locally with the custom imager:
#         podman run --privileged ghcr.io/timblakely/imager:<talos> installer profile.json
#      -> installer tarball (docker tarball) -> podman load -> push to
#         ghcr.io/timblakely/installer-amd64:<driver>-<talos>
#   3. cordon/drain amnesia (gaming idle!), then:
#         talosctl -n amnesia upgrade --image=ghcr.io/timblakely/installer-amd64:<tag>
#      `upgrade` rebases the OS (new kernel+extensions) and PRESERVES STATE,
#      EPHEMERAL and user volumes -- including /var/mnt/local-hostpath PVs
#      (dreamcast/tim-steam, llm/flashnext-amnesia). NEVER use reset-node
#      here: it wipes u-local-hostpath.
#   4. validate, then pin install.image (+digest) in cogito's amnesia.yaml.j2.
#
# Usage: rebase-amnesia.sh <driver> <talos>   e.g. 615.78.08 v1.14.2
set -euo pipefail

DRIVER="${1:?usage: rebase-amnesia.sh <driver> <talos>}"   # 615.78.08
TALOS="${2:?talos}"                                        # v1.14.2
NS=ghcr.io/timblakely
WORK="${TMPDIR:-/tmp}/amnesia-installer-${DRIVER}-${TALOS}"
TOOLKIT_TAG=v1.19.1
IMAGER=$NS/imager:$TALOS
DEST=$NS/installer-amd64:$DRIVER-$TALOS

# Stock firmware-only extensions carry no kernel modules -> Sidero signatures fine.
AMD_UCODE=ghcr.io/siderolabs/amd-ucode:20260916        # official catalog v1.14.2
REALTEK=ghcr.io/siderolabs/realtek-firmware:20260916   # official catalog v1.14.2
# Our signed builds:
MODS=$NS/nvidia-open-modules:$DRIVER-$TALOS
FW=$NS/nvidia-open-firmware:$DRIVER-$TALOS
TOOLKIT=$NS/nvidia-open-toolkit:$DRIVER-$TOOLKIT_TAG
UINPUT=$NS/uinput:$TALOS                                # rebuilt against our kernel

for img in "$IMAGER" "$MODS" "$FW" "$TOOLKIT" "$UINPUT"; do
  podman image exists "$img" 2>/dev/null || podman pull -q "$img" >/dev/null
done

mkdir -p "$WORK"
cat > "$WORK/profile.json" <<EOF
{
  "name": "amnesia-$DRIVER",
  "platform": "metal",
  "architecture": "amd64",
  "baseImage": "ghcr.io/siderolabs/installer-base:$TALOS",
  "customization": {
    "systemExtensions": [
      {"image": "$AMD_UCODE"},
      {"image": "$REALTEK"},
      {"image": "$MODS"},
      {"image": "$FW"},
      {"image": "$TOOLKIT"},
      {"image": "$UINPUT"}
    ]
  },
  "output": {"kind": "installer", "outFormat": "raw"}
}
EOF

if ! compgen -G "$WORK/*installer*.tar" > /dev/null; then
  echo "==> building installer image with $IMAGER"
  # imager CLI: positional arg = built-in base profile name ("installer" =
  # OutKindInstaller, metal, amd64); extensions via repeatable flag; version
  # defaults to the imager's own build tag (v1.14.2 here).
  podman run --rm --privileged --net=host -v "$WORK:/out:z" \
    "$IMAGER" installer \
    --system-extension-image="$AMD_UCODE" \
    --system-extension-image="$REALTEK" \
    --system-extension-image="$MODS" \
    --system-extension-image="$FW" \
    --system-extension-image="$TOOLKIT" \
    --system-extension-image="$UINPUT"
fi
TAR=$(ls "$WORK"/*.tar | head -1)
echo "==> installer tarball: $TAR"

echo "==> load + push as $DEST"
LOADOUT=$(podman load -i "$TAR")
echo "$LOADOUT"
# imager names the image after the baseImage ref (e.g. ghcr.io/siderolabs/installer-base:v1.14.2)
LOADED=$(echo "$LOADOUT" | sed -n 's/^Loaded image: //p' | head -1)
[ -n "$LOADED" ] || { echo "!! could not determine loaded image name"; exit 1; }
podman tag "$LOADED" "$DEST"
podman push "$DEST"
DIGEST=$(skopeo inspect --format '{{ .Digest }}' "docker://$DEST")
echo
echo "==> pin in cogito talos/machineconfig/amnesia.yaml.j2:"
echo "    image: ${DEST}@${DIGEST}"
echo
echo "==> cutover (when gaming is idle):"
echo "    cd /home/tim/git/cogito && mise exec -- talosctl -n amnesia upgrade \\"
echo "      --image=$DEST -m default --drain --drain-timeout=5m"
echo "    # upgrade rebases the OS partitions and drains the node itself;"
echo "    # monitor: mise exec -- talosctl -n amnesia events | head"
