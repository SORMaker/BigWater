#!/usr/bin/env bash
set -euo pipefail

invocation_dir="$PWD"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
notes_file=""
publish=false

while (($#)); do
    case "$1" in
        --notes-file)
            if (($# < 2)); then
                echo "--notes-file requires a path." >&2
                exit 2
            fi
            notes_file="$2"
            shift
            ;;
        --publish) publish=true ;;
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

if [[ -n "$notes_file" && "$notes_file" != /* ]]; then
    notes_file="$invocation_dir/$notes_file"
fi
cd "$root"

plist="$root/Resources/Info.plist"
tools="$root/.build/artifacts/sparkle/Sparkle/bin"
account="com.oil.bigwater.sparkle"
feed_url="https://github.com/SORMaker/BigWater/releases/latest/download/appcast.xml"
expected_repo="SORMaker/BigWater"

for tool in generate_keys generate_appcast sign_update; do
    if [[ ! -x "$tools/$tool" ]]; then
        echo "Sparkle tool is missing: $tools/$tool" >&2
        echo "Resolve the Sparkle 2.10.0 package dependency first." >&2
        exit 1
    fi
done

short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
build_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist")"
configured_feed="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$plist")"
if [[ ! "$short_version" =~ ^[0-9]+(\.[0-9]+){0,2}$ || ! "$build_version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "Info.plist must contain numeric CFBundleShortVersionString and CFBundleVersion values." >&2
    exit 1
fi
if [[ "$configured_feed" != "$feed_url" ]]; then
    echo "Info.plist SUFeedURL does not match the BigWater GitHub appcast URL." >&2
    exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "$plist")" != true || "$(/usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' "$plist")" != true ]]; then
    echo "Signed feeds require SURequireSignedFeed and SUVerifyUpdateBeforeExtraction." >&2
    exit 1
fi

keychain_public_key="$("$tools/generate_keys" --account "$account" -p)"
if [[ -z "$keychain_public_key" || "$keychain_public_key" != "$public_key" ]]; then
    echo "The Sparkle public key in Info.plist does not match Keychain account $account." >&2
    exit 1
fi
source_commit="$(git rev-parse HEAD)"
worktree_status="$(git status --porcelain)"
source_clean=false
if [[ -z "$worktree_status" ]]; then
    source_clean=true
fi

if [[ -n "$notes_file" ]]; then
    if [[ ! -f "$notes_file" ]]; then
        echo "Release notes file does not exist: $notes_file" >&2
        exit 1
    fi
    case "${notes_file##*.}" in
        md) notes_extension="md" ;;
        *)
            echo "Release notes must use .md so Sparkle can embed them in the signed appcast." >&2
            exit 1
            ;;
    esac
fi

tag="v$short_version"
release_parent="$root/dist/releases"
release_final="$release_parent/$tag"
archive_base="BigWater-$short_version"
preview=false
# Preview builds must not occupy the versioned, publishable release directory.
if [[ "$publish" != true && ( "$source_clean" != true || -z "$notes_file" ) ]]; then
    preview=true
    release_parent="$root/dist/previews"
    release_final="$release_parent/$tag-$(uuidgen)"
fi
reuse_prepared=false
if [[ -e "$release_final" ]]; then
    if [[ "$publish" != true ]]; then
        echo "Release output already exists; preserving it: $release_final" >&2
        echo "Use --publish to validate and upload those prepared artifacts." >&2
        exit 1
    fi
    reuse_prepared=true
elif [[ "$publish" == true ]]; then
    echo "No prepared release exists at $release_final." >&2
    echo "Prepare and review it before invoking --publish." >&2
    exit 1
fi

if [[ "$publish" == true ]]; then
    if ! command -v gh >/dev/null 2>&1; then
        echo "GitHub CLI (gh) is required for --publish." >&2
        exit 1
    fi
    remote="$(git remote get-url origin 2>/dev/null || true)"
    if [[ "$remote" != *"github.com:$expected_repo.git" && "$remote" != *"github.com/$expected_repo.git" && "$remote" != *"github.com/$expected_repo" ]]; then
        echo "The origin remote does not point to $expected_repo: $remote" >&2
        exit 1
    fi
    if [[ -z "$notes_file" ]]; then
        echo "Pass --notes-file when publishing so the GitHub release has reviewed notes." >&2
        exit 1
    fi
    worktree_status="$(git status --porcelain)"
    if [[ -n "$worktree_status" ]]; then
        echo "Commit the release source and notes before publishing; the working tree is not clean." >&2
        exit 1
    fi
    remote_tags="$(git ls-remote --tags "https://github.com/$expected_repo.git" \
        "refs/tags/$tag" "refs/tags/$tag^{}")"
    remote_commit="$(printf '%s\n' "$remote_tags" | awk -v tag_ref="refs/tags/$tag" '
        $2 == tag_ref { commit = $1 }
        $2 == tag_ref "^{}" { peeled = $1 }
        END { print (peeled != "" ? peeled : commit) }
    ')"
    if [[ -n "$remote_commit" && "$remote_commit" != "$source_commit" ]]; then
        echo "Remote tag $tag points to a different commit; refusing to publish." >&2
        exit 1
    fi
fi

stage_dir=""
verify_dir=""
cleanup() {
    if [[ -n "$verify_dir" && -d "$verify_dir" ]]; then
        rm -rf "$verify_dir"
    fi
    if [[ -n "$stage_dir" && -d "$stage_dir" ]]; then
        rm -rf "$stage_dir"
    fi
}
trap cleanup EXIT
download_prefix="https://github.com/$expected_repo/releases/download/$tag"
if [[ "$reuse_prepared" == true ]]; then
    release_dir="$release_final"
    archive="$release_dir/$archive_base.zip"
    appcast="$release_dir/appcast.xml"
    revision_file="$release_dir/source-revision.txt"
    if [[ ! -f "$archive" || ! -f "$appcast" || ! -f "$revision_file" ]]; then
        echo "Prepared release is missing its archive, appcast, or source revision." >&2
        exit 1
    fi
    prepared_commit="$(sed -n '1p' "$revision_file")"
    prepared_clean="$(sed -n '2p' "$revision_file")"
    if [[ "$prepared_commit" != "$(git rev-parse HEAD)" || "$prepared_clean" != true ]]; then
        echo "Prepared release was built from a different commit; refusing to publish stale artifacts." >&2
        echo "Prepare a release from a clean committed tree before publishing." >&2
        exit 1
    fi
else
    ./Tools/build.sh --universal

    app="$root/dist/Big Water.app"
    app_plist="$app/Contents/Info.plist"
    for pair in \
        "CFBundleShortVersionString:$short_version" \
        "CFBundleVersion:$build_version" \
        "SUPublicEDKey:$public_key" \
        "SUFeedURL:$feed_url"; do
        key="${pair%%:*}"
        expected="${pair#*:}"
        actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$app_plist")"
        if [[ "$actual" != "$expected" ]]; then
            echo "Built app has unexpected $key: $actual" >&2
            exit 1
        fi
    done

    mkdir -p "$release_parent"
    stage_dir="$(mktemp -d "$release_parent/.${tag}.XXXXXX")"
    release_dir="$stage_dir"
    archive="$release_dir/$archive_base.zip"
    appcast="$release_dir/appcast.xml"
    if [[ -n "$notes_file" ]]; then
        cp "$notes_file" "$release_dir/$archive_base.$notes_extension"
    fi

    ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
    generate_args=(
        --account "$account"
        --download-url-prefix "$download_prefix/"
        --link "https://github.com/$expected_repo"
        --embed-release-notes
    )
    "$tools/generate_appcast" "${generate_args[@]}" "$release_dir"
    "$tools/sign_update" --account "$account" "$appcast"
    printf '%s\n%s\n' "$source_commit" "$source_clean" > "$release_dir/source-revision.txt"
fi

verify_dir="$(mktemp -d "${TMPDIR:-/tmp}/bigwater-release.XXXXXX")"
ditto -x -k "$archive" "$verify_dir"
archived_app="$verify_dir/Big Water.app"
archived_framework="$archived_app/Contents/Frameworks/Sparkle.framework"
if [[ ! -x "$archived_app/Contents/MacOS/BigWater" || ! -x "$archived_framework/Autoupdate" ]]; then
    echo "Release ZIP lost an app or Sparkle executable permission." >&2
    exit 1
fi
if [[ ! -L "$archived_framework/Versions/Current" || ! -L "$archived_framework/Sparkle" || ! -L "$archived_framework/Updater.app" || ! -L "$archived_framework/XPCServices" ]]; then
    echo "Release ZIP did not preserve Sparkle.framework symlinks." >&2
    exit 1
fi
codesign --verify --deep --strict "$archived_app"
archived_plist="$archived_app/Contents/Info.plist"
for pair in \
    "CFBundleShortVersionString:$short_version" \
    "CFBundleVersion:$build_version" \
    "CFBundleIdentifier:com.oil.bigwater" \
    "SUPublicEDKey:$public_key" \
    "SUFeedURL:$feed_url" \
    "SURequireSignedFeed:true" \
    "SUVerifyUpdateBeforeExtraction:true"; do
    key="${pair%%:*}"
    expected="${pair#*:}"
    actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$archived_plist")"
    if [[ "$actual" != "$expected" ]]; then
        echo "Release ZIP has unexpected $key: $actual" >&2
        exit 1
    fi
done

signature="$(/usr/bin/python3 - "$appcast" "$(basename "$archive")" "$build_version" "$short_version" "$download_prefix" <<'PY'
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
"$tools/sign_update" --account "$account" --verify "$archive" "$signature"
"$tools/sign_update" --account "$account" --verify "$appcast"

if [[ -n "$notes_file" ]]; then
    saved_notes="$release_dir/$archive_base.$notes_extension"
    if [[ ! -f "$saved_notes" ]] || ! cmp -s "$notes_file" "$saved_notes"; then
        echo "Prepared release notes do not match the supplied notes file." >&2
        exit 1
    fi
    /usr/bin/python3 - "$appcast" "$notes_file" <<'PY'
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

if [[ "$reuse_prepared" != true ]]; then
    if [[ -e "$release_final" ]]; then
        echo "Release output appeared during preparation; preserving it: $release_final" >&2
        exit 1
    fi
    mv "$stage_dir" "$release_final"
    stage_dir=""
    release_dir="$release_final"
    archive="$release_dir/$archive_base.zip"
    appcast="$release_dir/appcast.xml"
fi

echo "Prepared: $release_dir"
if [[ "$preview" == true ]]; then
    echo "Preview only: commit the source and supply release notes before preparing a publishable release."
fi
echo "Archive: $archive"
echo "Appcast: $appcast"

if [[ "$publish" == true ]]; then
    gh release create "$tag" \
        --repo "github.com/$expected_repo" \
        --target "$(git rev-parse HEAD)" \
        --latest \
        --title "Big Water $short_version" \
        --notes-file "$notes_file" \
        "$archive" "$appcast"
    echo "Published GitHub release $tag."
fi
