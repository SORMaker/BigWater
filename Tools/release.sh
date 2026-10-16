#!/usr/bin/env bash
set -euo pipefail

task_invocation_dir="$PWD"
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_notes_file=""
task_publish=false

while (($#)); do
    case "$1" in
        --notes-file)
            if (($# < 2)); then
                echo "--notes-file requires a path." >&2
                exit 2
            fi
            task_notes_file="$2"
            shift
            ;;
        --publish) task_publish=true ;;
        -h|--help)
            echo "Usage: $0 [--notes-file FILE] [--publish]"
            echo "Prepares a universal Sparkle release in dist/releases/vVERSION."
            echo "Publishing is performed only when --publish is supplied."
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--notes-file FILE] [--publish]" >&2
            exit 2
            ;;
    esac
    shift
done

if [[ -n "$task_notes_file" && "$task_notes_file" != /* ]]; then
    task_notes_file="$task_invocation_dir/$task_notes_file"
fi
cd "$task_root"

task_plist="$task_root/Resources/Info.plist"
task_tools="$task_root/.build/artifacts/sparkle/Sparkle/bin"
task_account="com.oil.bigwater.sparkle"
task_feed_url="https://github.com/SORMaker/BigWater/releases/latest/download/appcast.xml"
task_expected_repo="SORMaker/BigWater"

for task_tool in generate_keys generate_appcast sign_update; do
    if [[ ! -x "$task_tools/$task_tool" ]]; then
        echo "Sparkle tool is missing: $task_tools/$task_tool" >&2
        echo "Resolve the Sparkle 2.10.0 package dependency first." >&2
        exit 1
    fi
done

task_short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$task_plist")"
task_build_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$task_plist")"
task_public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$task_plist")"
task_configured_feed="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$task_plist")"
if [[ ! "$task_short_version" =~ ^[0-9]+(\.[0-9]+){0,2}$ || ! "$task_build_version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "Info.plist must contain numeric CFBundleShortVersionString and CFBundleVersion values." >&2
    exit 1
fi
if [[ "$task_configured_feed" != "$task_feed_url" ]]; then
    echo "Info.plist SUFeedURL does not match the BigWater GitHub appcast URL." >&2
    exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "$task_plist")" != true || "$(/usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' "$task_plist")" != true ]]; then
    echo "Signed feeds require SURequireSignedFeed and SUVerifyUpdateBeforeExtraction." >&2
    exit 1
fi

task_keychain_public_key="$("$task_tools/generate_keys" --account "$task_account" -p)"
if [[ -z "$task_keychain_public_key" || "$task_keychain_public_key" != "$task_public_key" ]]; then
    echo "The Sparkle public key in Info.plist does not match Keychain account $task_account." >&2
    exit 1
fi
task_source_commit="$(git rev-parse HEAD)"
task_worktree_status="$(git status --porcelain)"
task_source_clean=false
if [[ -z "$task_worktree_status" ]]; then
    task_source_clean=true
fi

if [[ -n "$task_notes_file" ]]; then
    if [[ ! -f "$task_notes_file" ]]; then
        echo "Release notes file does not exist: $task_notes_file" >&2
        exit 1
    fi
    case "${task_notes_file##*.}" in
        md) task_notes_extension="md" ;;
        *)
            echo "Release notes must use .md so Sparkle can embed them in the signed appcast." >&2
            exit 1
            ;;
    esac
fi

task_tag="v$task_short_version"
task_release_parent="$task_root/dist/releases"
task_release_final="$task_release_parent/$task_tag"
task_archive_base="BigWater-$task_short_version"
task_preview=false
# Preview builds must not occupy the versioned, publishable release directory.
if [[ "$task_publish" != true && ( "$task_source_clean" != true || -z "$task_notes_file" ) ]]; then
    task_preview=true
    task_release_parent="$task_root/dist/previews"
    task_release_final="$task_release_parent/$task_tag-$(uuidgen)"
fi
task_reuse_prepared=false
if [[ -e "$task_release_final" ]]; then
    if [[ "$task_publish" != true ]]; then
        echo "Release output already exists; preserving it: $task_release_final" >&2
        echo "Use --publish to validate and upload those prepared artifacts." >&2
        exit 1
    fi
    task_reuse_prepared=true
elif [[ "$task_publish" == true ]]; then
    echo "No prepared release exists at $task_release_final." >&2
    echo "Prepare and review it before invoking --publish." >&2
    exit 1
fi

if [[ "$task_publish" == true ]]; then
    if ! command -v gh >/dev/null 2>&1; then
        echo "GitHub CLI (gh) is required for --publish." >&2
        exit 1
    fi
    task_remote="$(git remote get-url origin 2>/dev/null || true)"
    if [[ "$task_remote" != *"github.com:$task_expected_repo.git" && "$task_remote" != *"github.com/$task_expected_repo.git" && "$task_remote" != *"github.com/$task_expected_repo" ]]; then
        echo "The origin remote does not point to $task_expected_repo: $task_remote" >&2
        exit 1
    fi
    if [[ -z "$task_notes_file" ]]; then
        echo "Pass --notes-file when publishing so the GitHub release has reviewed notes." >&2
        exit 1
    fi
    task_worktree_status="$(git status --porcelain)"
    if [[ -n "$task_worktree_status" ]]; then
        echo "Commit the release source and notes before publishing; the working tree is not clean." >&2
        exit 1
    fi
    task_remote_tags="$(git ls-remote --tags "https://github.com/$task_expected_repo.git" \
        "refs/tags/$task_tag" "refs/tags/$task_tag^{}")"
    task_remote_commit="$(printf '%s\n' "$task_remote_tags" | awk -v tag_ref="refs/tags/$task_tag" '
        $2 == tag_ref { commit = $1 }
        $2 == tag_ref "^{}" { peeled = $1 }
        END { print (peeled != "" ? peeled : commit) }
    ')"
    if [[ -n "$task_remote_commit" && "$task_remote_commit" != "$task_source_commit" ]]; then
        echo "Remote tag $task_tag points to a different commit; refusing to publish." >&2
        exit 1
    fi
fi

task_stage_dir=""
task_verify_dir=""
task_cleanup() {
    if [[ -n "$task_verify_dir" && -d "$task_verify_dir" ]]; then
        rm -rf "$task_verify_dir"
    fi
    if [[ -n "$task_stage_dir" && -d "$task_stage_dir" ]]; then
        rm -rf "$task_stage_dir"
    fi
}
trap task_cleanup EXIT
task_download_prefix="https://github.com/$task_expected_repo/releases/download/$task_tag"
if [[ "$task_reuse_prepared" == true ]]; then
    task_release_dir="$task_release_final"
    task_archive="$task_release_dir/$task_archive_base.zip"
    task_appcast="$task_release_dir/appcast.xml"
    task_revision_file="$task_release_dir/source-revision.txt"
    if [[ ! -f "$task_archive" || ! -f "$task_appcast" || ! -f "$task_revision_file" ]]; then
        echo "Prepared release is missing its archive, appcast, or source revision." >&2
        exit 1
    fi
    task_prepared_commit="$(sed -n '1p' "$task_revision_file")"
    task_prepared_clean="$(sed -n '2p' "$task_revision_file")"
    if [[ "$task_prepared_commit" != "$(git rev-parse HEAD)" || "$task_prepared_clean" != true ]]; then
        echo "Prepared release was built from a different commit; refusing to publish stale artifacts." >&2
        echo "Prepare a release from a clean committed tree before publishing." >&2
        exit 1
    fi
else
    ./Tools/build.sh --universal

    task_app="$task_root/dist/Big Water.app"
    task_app_plist="$task_app/Contents/Info.plist"
    for task_pair in \
        "CFBundleShortVersionString:$task_short_version" \
        "CFBundleVersion:$task_build_version" \
        "SUPublicEDKey:$task_public_key" \
        "SUFeedURL:$task_feed_url"; do
        task_key="${task_pair%%:*}"
        task_expected="${task_pair#*:}"
        task_actual="$(/usr/libexec/PlistBuddy -c "Print :$task_key" "$task_app_plist")"
        if [[ "$task_actual" != "$task_expected" ]]; then
            echo "Built app has unexpected $task_key: $task_actual" >&2
            exit 1
        fi
    done

    mkdir -p "$task_release_parent"
    task_stage_dir="$(mktemp -d "$task_release_parent/.${task_tag}.XXXXXX")"
    task_release_dir="$task_stage_dir"
    task_archive="$task_release_dir/$task_archive_base.zip"
    task_appcast="$task_release_dir/appcast.xml"
    if [[ -n "$task_notes_file" ]]; then
        cp "$task_notes_file" "$task_release_dir/$task_archive_base.$task_notes_extension"
    fi

    ditto -c -k --sequesterRsrc --keepParent "$task_app" "$task_archive"
    task_generate_args=(
        --account "$task_account"
        --download-url-prefix "$task_download_prefix/"
        --link "https://github.com/$task_expected_repo"
        --embed-release-notes
    )
    "$task_tools/generate_appcast" "${task_generate_args[@]}" "$task_release_dir"
    "$task_tools/sign_update" --account "$task_account" "$task_appcast"
    printf '%s\n%s\n' "$task_source_commit" "$task_source_clean" > "$task_release_dir/source-revision.txt"
fi

task_verify_dir="$(mktemp -d "${TMPDIR:-/tmp}/bigwater-release.XXXXXX")"
ditto -x -k "$task_archive" "$task_verify_dir"
task_archived_app="$task_verify_dir/Big Water.app"
task_archived_framework="$task_archived_app/Contents/Frameworks/Sparkle.framework"
if [[ ! -x "$task_archived_app/Contents/MacOS/BigWater" || ! -x "$task_archived_framework/Autoupdate" ]]; then
    echo "Release ZIP lost an app or Sparkle executable permission." >&2
    exit 1
fi
if [[ ! -L "$task_archived_framework/Versions/Current" || ! -L "$task_archived_framework/Sparkle" || ! -L "$task_archived_framework/Updater.app" || ! -L "$task_archived_framework/XPCServices" ]]; then
    echo "Release ZIP did not preserve Sparkle.framework symlinks." >&2
    exit 1
fi
codesign --verify --deep --strict "$task_archived_app"
task_archived_plist="$task_archived_app/Contents/Info.plist"
for task_pair in \
    "CFBundleShortVersionString:$task_short_version" \
    "CFBundleVersion:$task_build_version" \
    "CFBundleIdentifier:com.oil.bigwater" \
    "SUPublicEDKey:$task_public_key" \
    "SUFeedURL:$task_feed_url" \
    "SURequireSignedFeed:true" \
    "SUVerifyUpdateBeforeExtraction:true"; do
    task_key="${task_pair%%:*}"
    task_expected="${task_pair#*:}"
    task_actual="$(/usr/libexec/PlistBuddy -c "Print :$task_key" "$task_archived_plist")"
    if [[ "$task_actual" != "$task_expected" ]]; then
        echo "Release ZIP has unexpected $task_key: $task_actual" >&2
        exit 1
    fi
done

task_signature="$(/usr/bin/python3 - "$task_appcast" "$(basename "$task_archive")" "$task_build_version" "$task_short_version" "$task_download_prefix" <<'PY'
import sys
import xml.etree.ElementTree as ET

appcast_path, archive_name, expected_build, expected_short, download_prefix = sys.argv[1:]
root = ET.parse(appcast_path).getroot()

def local_name(name):
    return name.rsplit("}", 1)[-1]

for item in root.iter():
    if local_name(item.tag) != "item":
        continue
    values = {}
    for child in item.iter():
        name = local_name(child.tag)
        if name in {"version", "shortVersionString"} and child.text:
            values[name] = child.text.strip()
    for enclosure in (child for child in item.iter() if local_name(child.tag) == "enclosure"):
        if enclosure.attrib.get("url") != f"{download_prefix}/{archive_name}":
            continue
        signature = next((value for key, value in enclosure.attrib.items()
                          if local_name(key) == "edSignature"), "")
        if values.get("version") != expected_build or values.get("shortVersionString") != expected_short:
            raise SystemExit("Appcast version metadata does not match Info.plist.")
        if not signature:
            raise SystemExit("Sparkle did not add an EdDSA signature to the appcast enclosure.")
        print(signature)
        raise SystemExit(0)

raise SystemExit("Appcast does not contain the release archive.")
PY
)"
"$task_tools/sign_update" --account "$task_account" --verify "$task_archive" "$task_signature"
"$task_tools/sign_update" --account "$task_account" --verify "$task_appcast"

if [[ -n "$task_notes_file" ]]; then
    task_saved_notes="$task_release_dir/$task_archive_base.$task_notes_extension"
    if [[ ! -f "$task_saved_notes" ]] || ! cmp -s "$task_notes_file" "$task_saved_notes"; then
        echo "Prepared release notes do not match the supplied notes file." >&2
        exit 1
    fi
    /usr/bin/python3 - "$task_appcast" "$task_notes_file" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
expected_notes = open(sys.argv[2], encoding="utf-8").read().strip()
def local_name(name):
    return name.rsplit("}", 1)[-1]

items = [node for node in root.iter() if local_name(node.tag) == "item"]
if not items or any(any(local_name(node.tag) == "releaseNotesLink" for node in item.iter())
                     for item in items):
    raise SystemExit("Expected inline release notes without an external releaseNotesLink.")
descriptions = [(node.text or "") for node in items[-1].iter()
                if local_name(node.tag) == "description"]
if not expected_notes or not any(expected_notes in description for description in descriptions):
    raise SystemExit("The appcast item does not contain the supplied release notes.")
PY
fi

if [[ "$task_reuse_prepared" != true ]]; then
    if [[ -e "$task_release_final" ]]; then
        echo "Release output appeared during preparation; preserving it: $task_release_final" >&2
        exit 1
    fi
    mv "$task_stage_dir" "$task_release_final"
    task_stage_dir=""
    task_release_dir="$task_release_final"
    task_archive="$task_release_dir/$task_archive_base.zip"
    task_appcast="$task_release_dir/appcast.xml"
fi

echo "Prepared: $task_release_dir"
if [[ "$task_preview" == true ]]; then
    echo "Preview only: commit the source and supply release notes before preparing a publishable release."
fi
echo "Archive: $task_archive"
echo "Appcast: $task_appcast"

if [[ "$task_publish" == true ]]; then
    gh release create "$task_tag" \
        --repo "github.com/$task_expected_repo" \
        --target "$(git rev-parse HEAD)" \
        --latest \
        --title "Big Water $task_short_version" \
        --notes-file "$task_notes_file" \
        "$task_archive" "$task_appcast"
    echo "Published GitHub release $task_tag."
fi
