#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Hardened build script — packages a LuCI app as .apk / .ipk without the
# full OpenWrt SDK/buildroot.
#
# Design goal: the package Makefile stays the single source of truth.
# conffiles / dependencies / title are parsed from the Makefile instead of
# being hand-copied here (which silently drifts over time).
#
# Versioning: prefer PKG_VERSION/PKG_RELEASE from the Makefile
# (canonical <version>-r<release>), fall back to a snapshot-style
# <epoch>~<commit>-r99 version so every run is distinguishable.
#
# Usage: build-pkg.sh <apk|ipk> [event_name]

set -o errexit
set -o pipefail
set -o nounset

PKG_MGR="${1:-apk}"
RELEASE_TYPE="${2:-snapshot}"

if [[ "$PKG_MGR" != "apk" && "$PKG_MGR" != "ipk" ]]; then
	echo "error: unknown package manager '$PKG_MGR' (expected apk or ipk)" >&2
	exit 1
fi

export PKG_SOURCE_DATE_EPOCH="$(date "+%s")"
export SOURCE_DATE_EPOCH="$PKG_SOURCE_DATE_EPOCH"

BASE_DIR="$(cd "$(dirname "$0")"; pwd)"
PKG_DIR="$BASE_DIR/.."
MAKEFILE="$PKG_DIR/Makefile"

if [ ! -f "$MAKEFILE" ]; then
	echo "error: Makefile not found at $MAKEFILE" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Makefile parsing helpers
# ---------------------------------------------------------------------------

# Single-line `KEY:=value` fields, e.g. PKG_NAME, PKG_VERSION.
get_mk_value() {
	awk -F "$1:=" '/^'"$1"':=/{print $2}' "$MAKEFILE" | xargs
}

# Multi-line `KEY:= \` ... continuation fields, e.g. LUCI_DEPENDS.
# Joins backslash-continued lines, strips OpenWrt's "+" (auto-select)
# prefix, collapses whitespace.
get_mk_multiline_value() {
	sed ':a;N;$!ba;s/\\\n/ /g' "$MAKEFILE" \
		| grep -oP "^$1:=\K.*" \
		| tr -s ' \t' ' ' \
		| sed -E 's/(^| )\+/\1/g' \
		| xargs || true   # grep 无匹配返回 1，set -o pipefail 下不能让它终止脚本
}

# Extracts a `define Package/<name>/conffiles ... endef` block's body,
# one path per line, exactly as declared in the Makefile.
get_conffiles() {
	awk -v pkg="$1" '
		$0 ~ "^define Package/"pkg"/conffiles" { flag=1; next }
		flag && /^endef/ { flag=0; next }
		flag && NF { print }
	' "$MAKEFILE"
}

PKG_NAME="$(get_mk_value "PKG_NAME")"
if [ -z "$PKG_NAME" ]; then
	echo "error: PKG_NAME not found in Makefile" >&2
	exit 1
fi

# LuCI app id used for po/ filenames and i18n package naming.
# Convention: po/<lang>/<app_id>.po, package luci-app-<app_id>.
APP_ID="${PKG_NAME#luci-app-}"

DEPENDS="$(get_mk_multiline_value "LUCI_DEPENDS")"
if [ -z "$DEPENDS" ]; then
	echo "warning: LUCI_DEPENDS not found in Makefile — package will ship without runtime dependencies" >&2
fi
DESCRIPTION="$(get_mk_value "LUCI_TITLE")"
[ -n "$DESCRIPTION" ] || DESCRIPTION="$PKG_NAME"

mapfile -t CONFFILES < <(get_conffiles "$PKG_NAME")
if [ "${#CONFFILES[@]}" -eq 0 ]; then
	echo "warning: no Package/$PKG_NAME/conffiles block found in Makefile — package will ship without conffile protection" >&2
fi

# ---------------------------------------------------------------------------
# Version resolution
#
# Prefer explicit PKG_VERSION/PKG_RELEASE from the Makefile (canonical
# <version>-r<release>, e.g. 27.0807.001-r99). Without them, a release
# build falls back to the nearest git tag, and everything else gets a
# snapshot-style <epoch>~<commit>-r99 version.
# ---------------------------------------------------------------------------

MK_PKG_VERSION="$(get_mk_value "PKG_VERSION")"
MK_PKG_RELEASE="$(get_mk_value "PKG_RELEASE")"

if [ -n "$MK_PKG_VERSION" ]; then
	if [ -n "$MK_PKG_RELEASE" ]; then
		PKG_VERSION="${MK_PKG_VERSION}-r${MK_PKG_RELEASE}"
	else
		PKG_VERSION="$MK_PKG_VERSION"
	fi
elif [ "$RELEASE_TYPE" == "release" ]; then
	# Makefile has no explicit version (common for LuCI apps that rely on
	# luci.mk defaults during a real SDK build). Use the nearest git tag.
	PKG_VERSION="$(git -C "$PKG_DIR" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')" || true
	if [ -z "$PKG_VERSION" ]; then
		echo "warning: PKG_VERSION missing in Makefile and no git tag found — using snapshot version" >&2
		PKG_VERSION="$PKG_SOURCE_DATE_EPOCH~$(git -C "$PKG_DIR" rev-parse --short HEAD)-r99"
	fi
else
	# Snapshot build: distinguishable, sortable artifact per run.
	PKG_VERSION="$PKG_SOURCE_DATE_EPOCH~$(git -C "$PKG_DIR" rev-parse --short HEAD)-r99"
fi

echo "Building $PKG_NAME $PKG_VERSION ($PKG_MGR)"
[ -n "$MK_PKG_VERSION" ] && echo "  Makefile PKG_VERSION=$MK_PKG_VERSION PKG_RELEASE=${MK_PKG_RELEASE:-<unset>}"

# ---------------------------------------------------------------------------
# Assemble main package file tree
# ---------------------------------------------------------------------------

TEMP_DIR="$(mktemp -d -p "$BASE_DIR")"
trap 'rm -rf "$TEMP_DIR"' EXIT

TEMP_PKG_DIR="$TEMP_DIR/$PKG_NAME"
mkdir -p "$TEMP_PKG_DIR/lib/upgrade/keep.d/"
mkdir -p "$TEMP_PKG_DIR/usr/lib/lua/luci/i18n/"
mkdir -p "$TEMP_PKG_DIR/www/"
if [ "$PKG_MGR" == "apk" ]; then
	mkdir -p "$TEMP_PKG_DIR/lib/apk/packages/"
else
	mkdir -p "$TEMP_PKG_DIR/CONTROL/"
fi

# Guard against empty dirs: an unexpanded glob like htdocs/* would make
# cp fail and set -e would abort the whole build.
if [ -d "$PKG_DIR/htdocs" ] && [ "$(ls -A "$PKG_DIR/htdocs" 2>/dev/null)" ]; then
	cp -fpR "$PKG_DIR/htdocs"/* "$TEMP_PKG_DIR/www/"
fi
if [ -d "$PKG_DIR/root" ] && [ "$(ls -A "$PKG_DIR/root" 2>/dev/null)" ]; then
	cp -fpR "$PKG_DIR/root"/* "$TEMP_PKG_DIR/"
fi

# lib/upgrade/keep.d/ covers sysupgrade (whole-firmware reflash) survival.
# Everything in the Makefile's conffiles list EXCEPT the main uci config
# file goes here — the uci config itself is handled by the package
# manager's own conffiles mechanism below.
if [ "${#CONFFILES[@]}" -gt 0 ]; then
	{
		for f in "${CONFFILES[@]}"; do
			[[ "$f" == "/etc/config/$APP_ID" ]] && continue
			echo "$f"
		done
	} > "$TEMP_PKG_DIR/lib/upgrade/keep.d/$PKG_NAME"
	# Drop the file if it ended up empty (only the uci config was declared).
	[ -s "$TEMP_PKG_DIR/lib/upgrade/keep.d/$PKG_NAME" ] || rm -f "$TEMP_PKG_DIR/lib/upgrade/keep.d/$PKG_NAME"
fi

# ---------------------------------------------------------------------------
# Translations: loop over every po/<lang>/<app_id>.po instead of assuming
# a single hardcoded language.
# ---------------------------------------------------------------------------

# Best-effort LuCI locale code mapping (po dir name -> LuCI i18n code).
# Unmapped locales fall back to a lowercased, hyphenated dir name.
declare -A LUCI_LOCALE_MAP=(
	[zh_Hans]="zh-cn"
	[zh_Hant]="zh-tw"
	[pt_BR]="pt-br"
	[bn_BD]="bn"
)

declare -a I18N_PACKAGES=()

if [ -d "$PKG_DIR/po" ]; then
	for podir in "$PKG_DIR"/po/*/; do
		[ -d "$podir" ] || continue
		lang_dir="$(basename "$podir")"
		pofile="$podir$APP_ID.po"
		[ -f "$pofile" ] || continue

		locale="${LUCI_LOCALE_MAP[$lang_dir]:-$(echo "$lang_dir" | tr '[:upper:]_' '[:lower:]-')}"
		lmo_name="$APP_ID.$locale.lmo"

		po2lmo "$pofile" "$TEMP_DIR/$lmo_name"

		i18n_name="luci-i18n-${APP_ID}-${locale}"
		i18n_dir="$TEMP_DIR/$i18n_name"
		mkdir -p "$i18n_dir/usr/lib/lua/luci/i18n/"
		cp "$TEMP_DIR/$lmo_name" "$i18n_dir/usr/lib/lua/luci/i18n/"

		if [ "$PKG_MGR" == "apk" ]; then
			# Keep the .list inside the package (same as the main package) so
			# `apk info -L` reports the i18n files too. Write it outside the
			# tree first so find doesn't include the (empty) .list itself.
			mkdir -p "$i18n_dir/lib/apk/packages/"
			find "$i18n_dir" -type f,l -printf '/%P\n' | sort > "$TEMP_DIR/$i18n_name.list"
			mv "$TEMP_DIR/$i18n_name.list" "$i18n_dir/lib/apk/packages/$i18n_name.list"
			apk mkpkg \
				--info "name:$i18n_name" \
				--info "version:$PKG_VERSION" \
				--info "description:$DESCRIPTION ($locale translation)" \
				--info "arch:noarch" \
				--info "depends:$PKG_NAME" \
				--files "$i18n_dir" \
				--output "$TEMP_DIR/${i18n_name}-${PKG_VERSION}.apk"
			# apk-tools v3 规范要求 <name>_<version>_<arch>.<ext>，noarch 包用 _all。
			# 顺手把 I18N_PACKAGES 数组里的引用也同步更新。
			mv "$TEMP_DIR/${i18n_name}-${PKG_VERSION}.apk" "$BASE_DIR/${i18n_name}_${PKG_VERSION}_all.apk"
			I18N_PACKAGES+=("$BASE_DIR/${i18n_name}_${PKG_VERSION}_all.apk")
		else
			mkdir -p "$i18n_dir/CONTROL/"
			cat > "$i18n_dir/CONTROL/control" <<-EOF
				Package: $i18n_name
				Version: $PKG_VERSION
				Depends: $PKG_NAME
				Architecture: all
				Description: $DESCRIPTION ($locale translation)
			EOF
			ipkg-build -m "" "$i18n_dir" "$TEMP_DIR"
			# ipkg-build 天然产出 _all.ipk；保留 _all 以匹配 apk-tools v3 规范。
			mv "$TEMP_DIR/${i18n_name}_${PKG_VERSION}_all.ipk" "$BASE_DIR/${i18n_name}_${PKG_VERSION}_all.ipk"
			I18N_PACKAGES+=("$BASE_DIR/${i18n_name}_${PKG_VERSION}_all.ipk")
		fi
	done
fi

if [ "${#I18N_PACKAGES[@]}" -eq 0 ]; then
	echo "note: no po/<lang>/$APP_ID.po files found — skipping i18n packages"
fi

# ---------------------------------------------------------------------------
# Main package
# ---------------------------------------------------------------------------

if [ "$PKG_MGR" == "apk" ]; then
	# Write the manifest outside the tree first: redirecting straight into
	# lib/apk/packages/ would make find include the (empty) .list file
	# itself. Move it in afterwards so the manifest is accurate.
	find "$TEMP_PKG_DIR" -type f,l -printf '/%P\n' | sort > "$TEMP_DIR/$PKG_NAME.list"
	mv "$TEMP_DIR/$PKG_NAME.list" "$TEMP_PKG_DIR/lib/apk/packages/$PKG_NAME.list"

	if printf '%s\n' "${CONFFILES[@]}" | grep -qx "/etc/config/$APP_ID" 2>/dev/null || [ "${#CONFFILES[@]}" -eq 0 ]; then
		echo "/etc/config/$APP_ID" >> "$TEMP_PKG_DIR/lib/apk/packages/$PKG_NAME.conffiles"
	fi
	if [ -f "$TEMP_PKG_DIR/lib/apk/packages/$PKG_NAME.conffiles" ]; then
		# OpenWrt sysupgrade parses conffiles_static as "<path> <csum>"
		# (see list_changed_conffiles in base-files sbin/sysupgrade), so emit
		# absolute paths with a single space. Raw `sha256sum` output (hash
		# first, double space, relative path) breaks that parsing.
		while IFS= read -r file; do
			[ -f "$TEMP_PKG_DIR/$file" ] || continue
			csum="$(sha256sum "$TEMP_PKG_DIR/$file" | awk '{print $1}')"
			echo "$file $csum" >> "$TEMP_PKG_DIR/lib/apk/packages/$PKG_NAME.conffiles_static"
		done < "$TEMP_PKG_DIR/lib/apk/packages/$PKG_NAME.conffiles"
	fi

	cat > "$TEMP_DIR/post-install" <<-EOF
		#!/bin/sh
		[ "\${IPKG_NO_SCRIPT}" = "1" ] && exit 0
		[ -s \${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
		. \${IPKG_INSTROOT}/lib/functions.sh
		export root="\${IPKG_INSTROOT}"
		export pkgname="$PKG_NAME"
		add_group_and_user
		default_postinst
		[ -n "\${IPKG_INSTROOT}" ] || {
			rm -f /tmp/luci-indexcache.*
			rm -rf /tmp/luci-modulecache/
			killall -HUP rpcd 2>/dev/null
			exit 0
		}
	EOF

	cat > "$TEMP_DIR/post-upgrade" <<-EOF
		#!/bin/sh
		export PKG_UPGRADE=1
		[ "\${IPKG_NO_SCRIPT}" = "1" ] && exit 0
		[ -s \${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
		. \${IPKG_INSTROOT}/lib/functions.sh
		export root="\${IPKG_INSTROOT}"
		export pkgname="$PKG_NAME"
		add_group_and_user
		default_postinst
		[ -n "\${IPKG_INSTROOT}" ] || {
			rm -f /tmp/luci-indexcache.*
			rm -rf /tmp/luci-modulecache/
			killall -HUP rpcd 2>/dev/null
			exit 0
		}
	EOF

	cat > "$TEMP_DIR/pre-deinstall" <<-EOF
		#!/bin/sh
		[ -s \${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
		. \${IPKG_INSTROOT}/lib/functions.sh
		export root="\${IPKG_INSTROOT}"
		export pkgname="$PKG_NAME"
		default_prerm
	EOF

	apk mkpkg \
		--info "name:$PKG_NAME" \
		--info "version:$PKG_VERSION" \
		--info "description:$DESCRIPTION" \
		--info "arch:noarch" \
		--info "origin:$PKG_NAME" \
		--info "maintainer:unspecified" \
		${DEPENDS:+--info "depends:libc $DEPENDS"} \
		--script "post-install:$TEMP_DIR/post-install" \
		--script "post-upgrade:$TEMP_DIR/post-upgrade" \
		--script "pre-deinstall:$TEMP_DIR/pre-deinstall" \
		--files "$TEMP_PKG_DIR" \
		--output "$TEMP_DIR/${PKG_NAME}-${PKG_VERSION}.apk"

	# apk-tools v3 规范要求 <name>_<version>_<arch>.<ext>，noarch 包用 _all。
	mv "$TEMP_DIR/${PKG_NAME}-${PKG_VERSION}.apk" "$BASE_DIR/${PKG_NAME}_${PKG_VERSION}_all.apk"
else
	mkdir -p "$TEMP_PKG_DIR/CONTROL/"

	cat > "$TEMP_PKG_DIR/CONTROL/control" <<-EOF
		Package: $PKG_NAME
		Version: $PKG_VERSION
		Depends: libc, ${DEPENDS// /, }
		Source: $PKG_NAME
		SourceName: $PKG_NAME
		Section: luci
		SourceDateEpoch: $PKG_SOURCE_DATE_EPOCH
		Maintainer: unspecified
		Architecture: all
		Installed-Size: TO-BE-FILLED-BY-IPKG-BUILD
		Description: $DESCRIPTION
	EOF
	chmod 0644 "$TEMP_PKG_DIR/CONTROL/control"

	if [ "${#CONFFILES[@]}" -gt 0 ]; then
		printf '%s\n' "${CONFFILES[@]}" | grep -x "/etc/config/$APP_ID" > "$TEMP_PKG_DIR/CONTROL/conffiles" || \
			echo "/etc/config/$APP_ID" > "$TEMP_PKG_DIR/CONTROL/conffiles"
	else
		echo "/etc/config/$APP_ID" > "$TEMP_PKG_DIR/CONTROL/conffiles"
	fi

	cat > "$TEMP_PKG_DIR/CONTROL/postinst" <<-'EOF'
		#!/bin/sh
		[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
		[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
		. ${IPKG_INSTROOT}/lib/functions.sh
		default_postinst $0 $@
	EOF
	chmod 0755 "$TEMP_PKG_DIR/CONTROL/postinst"

	cat > "$TEMP_PKG_DIR/CONTROL/postinst-pkg" <<-EOF
		[ -n "\${IPKG_INSTROOT}" ] || {
			# root/etc/uci-defaults/ 里的文件按 luci-<app_id> 命名（如
			# luci-homeproxy），不是 luci-app-<app_id>；且 default_postinst
			# 已通过 list 遍历执行并删除，这里只做兜底，避免 source 失败噪音。
			[ -f /etc/uci-defaults/luci-$APP_ID ] && . /etc/uci-defaults/luci-$APP_ID && rm -f /etc/uci-defaults/luci-$APP_ID
			rm -f /tmp/luci-indexcache
			rm -rf /tmp/luci-modulecache/
			exit 0
		}
	EOF
	chmod 0755 "$TEMP_PKG_DIR/CONTROL/postinst-pkg"

	cat > "$TEMP_PKG_DIR/CONTROL/prerm" <<-'EOF'
		#!/bin/sh
		[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
		. ${IPKG_INSTROOT}/lib/functions.sh
		default_prerm $0 $@
	EOF
	chmod 0755 "$TEMP_PKG_DIR/CONTROL/prerm"

	ipkg-build -m "" "$TEMP_PKG_DIR" "$TEMP_DIR"

	# ipkg-build 天然产出 _all.ipk；保留 _all 以匹配 apk-tools v3 规范。
	mv "$TEMP_DIR/${PKG_NAME}_${PKG_VERSION}_all.ipk" "$BASE_DIR/${PKG_NAME}_${PKG_VERSION}_all.ipk"
fi

echo "Done. Output in $BASE_DIR:"
ls -la "$BASE_DIR"/*."$PKG_MGR" 2>/dev/null || true
