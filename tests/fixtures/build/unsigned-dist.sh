# shellcheck shell=bash
# A distribution in the shape reprepro exports it before it is signed: two
# architectures, each with Packages, Packages.gz and its own Release, and a
# Release that declares all six under MD5Sum, SHA1 and SHA256. The tests of
# scripts/build/add-by-hash.sh source it, so they run without reprepro.
#
# mkdist <root> [<version>]   writes <root>/dists/stable for package `fixture`

mkdist() {
	local dist="$1/dists/stable" version="${2:-1.0}" arch sum
	for arch in amd64 arm64; do
		mkdir -p "$dist/main/binary-$arch"
		printf 'Package: fixture\nVersion: %s\nArchitecture: %s\nMaintainer: Test <fixture@test.invalid>\nFilename: pool/main/f/fixture/fixture_%s_%s.deb\nSize: 10\nSHA256: %064d\nDescription: by-hash fixture\n\n' \
			"$version" "$arch" "$version" "$arch" 0 > "$dist/main/binary-$arch/Packages"
		gzip -n -9 -c "$dist/main/binary-$arch/Packages" > "$dist/main/binary-$arch/Packages.gz"
		printf 'Archive: stable\nComponent: main\nOrigin: Glyndor\nLabel: Glyndor\nArchitecture: %s\nDescription: Glyndor apt repository\n' \
			"$arch" > "$dist/main/binary-$arch/Release"
	done
	{
		printf '%s\n' 'Origin: Glyndor' 'Label: Glyndor' 'Suite: stable' 'Codename: stable'
		printf 'Date: %s\nValid-Until: %s\n' "$(LC_ALL=C date -u -R)" "$(LC_ALL=C date -u -R -d '+14 days')"
		printf '%s\n' 'Architectures: amd64 arm64' 'Components: main' 'Description: Glyndor apt repository'
		for sum in md5sum sha1sum sha256sum; do
			case "$sum" in md5sum) echo 'MD5Sum:' ;; sha1sum) echo 'SHA1:' ;; sha256sum) echo 'SHA256:' ;; esac
			(cd "$dist" && for f in main/binary-*/Packages main/binary-*/Packages.gz main/binary-*/Release; do
				printf ' %s %s %s\n' "$($sum < "$f" | cut -d' ' -f1)" "$(stat -c%s "$f")" "$f"
			done | LC_ALL=C sort -k3)
		done
	} > "$dist/Release"
}
