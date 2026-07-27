#!/usr/bin/env bash
# Bump the VibeTiles plugin ID (forces KWin to recompile its cached QML).
#
# Why: KWin caches compiled QML per-plugin-ID for the life of the kwin_wayland
# process. Editing main.qml in place and reconfiguring is *not* enough to pick
# up changes - you have to convince KWin the script is something new. The
# accepted workaround is to bump KPlugin.Id / X-KDE-PluginKeyword to a fresh
# name and symlink the same source under the new ID.
#
# What this does:
#   1. finds the currently-live plugin ID by scanning for the symlink in
#      ~/.local/share/kwin/scripts/ that points back at this package
#      (falls back to metadata.json if no symlink exists, with a warning)
#   2. picks the next free vibetiles<N> name not already symlinked in
#      ~/.local/share/kwin/scripts
#   3. rewrites metadata.json to the new ID
#   4. symlinks kwinscript/ as the new ID
#   5. copies every per-script config key under [Script-<oldId>] forward to
#      [Script-<newId>] - the kwinrc section name IS the plugin ID, so without
#      this migration every previous setting is silently lost
#   6. flips the enabled flag (new on, old off) and unloads the old script
#   7. reconfigure, then deletes the old symlink and purges the dead kwinrc
#      section
#
# Does NOT touch plasma-kwin_wayland.service, so no Wayland apps are killed.
# For your first install (no VibeTiles yet), run ./install.sh instead.

set -euo pipefail

cd "$(dirname "$0")"

CURRENT_ID=$(grep -oE '"vibetiles[0-9]+"' kwinscript/metadata.json | head -1 | tr -d '"')
SCRIPTS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/kwin/scripts"
SRC_DIR="$(pwd)/kwinscript"
KWINRC="${XDG_CONFIG_HOME:-$HOME/.config}/kwinrc"

# Determine the actually-live ID by scanning for our symlink on disk (most
# reliable). Reading from metadata.json alone is unreliable when this script
# is run after metadata.json has already been bumped by hand or by a stale
# previous attempt - we'd silently migrate to the wrong kwinrc section.
SRC_REAL="$(readlink -f "${SRC_DIR}")"
CURRENT_ID=""
for link in "${SCRIPTS_DIR}"/vibetiles*; do
    [[ -L "${link}" ]] || continue
    [[ "$(readlink -f "${link}")" == "${SRC_REAL}" ]] || continue
    CURRENT_ID="$(basename "${link}")"
    break
done
if [[ -z "${CURRENT_ID}" ]]; then
    # No symlink at all - the script isn't installed yet, or the symlink
    # points somewhere else. Use the metadata.json ID as a last resort and
    # hope the user knows what they're doing.
    CURRENT_ID=$(grep -oE '"vibetiles[0-9]+"' kwinscript/metadata.json | head -1 | tr -d '"')
    echo "warning: no symlink pointing at ${SRC_DIR} found; falling back to metadata.json ID (${CURRENT_ID}). kwinrc key migration may be inaccurate - re-run after install." >&2
fi

# Find next free ID of the form vibetilesN where no symlink already exists.
# Walk forward from current; in practice the bumps are always 1.
N=$(echo "${CURRENT_ID}" | grep -oE '[0-9]+$')
while [[ -e "${SCRIPTS_DIR}/vibetiles$((++N))" ]]; do
    : # keep walking
done
NEW_ID="vibetiles${N}"

if [[ "${NEW_ID}" == "${CURRENT_ID}" ]]; then
    echo "already at ${CURRENT_ID}; nothing to bump"
    exit 0
fi

echo "bumping ${CURRENT_ID} -> ${NEW_ID}"

# 1. update metadata.json so the live package description points at the new ID.
#    Rewrite *whatever* vibetiles<N> id is in there, not specifically CURRENT_ID:
#    CURRENT_ID comes from the symlink name, which can legitimately differ from
#    the id in metadata.json (e.g. after a fresh clone over an existing install).
#    Substituting CURRENT_ID then matches nothing, silently leaving the package
#    declaring a stale id while its directory carries the new one - which the
#    KWin script config dialog reports as "could not locate package metadata".
sed -i -E "s/vibetiles[0-9]+/${NEW_ID}/g" kwinscript/metadata.json
if ! grep -q "\"${NEW_ID}\"" kwinscript/metadata.json; then
    echo "error: metadata.json still does not declare ${NEW_ID} after rewrite - fix it by hand" >&2
    exit 1
fi

# 2. enumerate every key currently set under [Script-<oldId>] in kwinrc so we
#    can re-apply them under the new section name. kreadconfig6 can't list keys;
#    parse kwinrc directly. Don't trust memory of which keys were set - this
#    has caused lost values in past bumps.
if [[ -f "${KWINRC}" ]]; then
    KEYS=$(awk -v grp="Script-${CURRENT_ID}" '
        /^\[/ { in_grp = ($0 == "[" grp "]"); next }
        in_grp && /^[A-Za-z0-9_]+=/ {
            sub(/=.*/, "")
            print
        }' "${KWINRC}")
else
    KEYS=""
fi

# 3. create new symlink. If a stale entry happens to be there from a prior
#    failed bump, refuse to clobber it.
if [[ -e "${SCRIPTS_DIR}/${NEW_ID}" ]]; then
    echo "error: ${SCRIPTS_DIR}/${NEW_ID} already exists - clean up manually first" >&2
    exit 1
fi
ln -s "${SRC_DIR}" "${SCRIPTS_DIR}/${NEW_ID}"
echo "  created symlink ${SCRIPTS_DIR}/${NEW_ID} -> ${SRC_DIR}"

# 4. migrate every per-key value forward
if [[ -n "${KEYS}" ]]; then
    while IFS= read -r key; do
        val=$(kreadconfig6 --file kwinrc --group "Script-${CURRENT_ID}" --key "${key}")
        # an empty read means the key holds no value (or reads back as its default) - don't
        # write a spurious empty `key=` line into the new section; leaving it unset makes
        # the new script fall back to the same default anyway.
        if [[ -z "${val}" ]]; then
            echo "  skipped ${key} (empty)"
            continue
        fi
        kwriteconfig6 --file kwinrc --group "Script-${NEW_ID}" --key "${key}" "${val}"
        echo "  migrated ${key} = ${val}"
    done <<< "${KEYS}"
else
    echo "  (no per-script keys to migrate)"
fi

# 5. flip the enabled flag: new on, old off
kwriteconfig6 --file kwinrc --group Plugins --key "${NEW_ID}Enabled" true
kwriteconfig6 --file kwinrc --group Plugins --key "${CURRENT_ID}Enabled" false

# 6. unload the old script (kglobalaccel entries registered by it go with it),
#    then explicitly load the new one. reconfigure() alone is NOT reliable for
#    picking up a freshly-created plugin id - confirmed live: enabling the new
#    id and calling reconfigure() left isScriptLoaded() false and the previous
#    generation kept running unchanged (silently - no error, no journal entry).
#    loadDeclarativeScript() with an explicit path loads it immediately, and is
#    idempotent if called again on an already-loaded id (returns -1, no
#    duplicate ShortcutHandler registration), so this is safe to run every time.
qdbus-qt6 org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript "${CURRENT_ID}"
qdbus-qt6 org.kde.KWin /Scripting org.kde.kwin.Scripting.loadDeclarativeScript "${SCRIPTS_DIR}/${NEW_ID}/contents/ui/main.qml" "${NEW_ID}"
qdbus-qt6 org.kde.KWin /KWin reconfigure

# 7. remove the old symlink + purge dead kwinrc section (so the file doesn't
#    accumulate cruft after every bump)
if [[ -L "${SCRIPTS_DIR}/${CURRENT_ID}" ]]; then
    rm "${SCRIPTS_DIR}/${CURRENT_ID}"
    echo "  removed old symlink ${SCRIPTS_DIR}/${CURRENT_ID}"
fi
if [[ -n "${KEYS}" ]]; then
    while IFS= read -r key; do
        kwriteconfig6 --file kwinrc --group "Script-${CURRENT_ID}" --key "${key}" --delete
    done <<< "${KEYS}"
fi

# 8. confirm the new script loaded and the old one didn't leave junk in
#    kglobalaccel (the rare race where both scripts register a handler under
#    the same name shows up as journal spam)
echo
echo "  verifying load..."
LOADED=$(qdbus-qt6 org.kde.KWin /Scripting org.kde.kwin.Scripting.isScriptLoaded "${NEW_ID}")
echo "  isScriptLoaded(${NEW_ID}) = ${LOADED}"
echo
echo "VibeTiles is now at ${NEW_ID}."
echo "If the script isn't responding, journalctl for clues:"
echo "  journalctl --user -b --no-pager | grep -i vibetiles"
