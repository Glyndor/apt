#!/usr/bin/env bash
#
# Tests for scripts/quality/hygiene/check-secrets.sh. The credential-shaped strings are
# assembled at run time, so this file does not trip the check it tests, and no
# value is ever printed by the script.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$HERE/scripts/quality/hygiene/check-secrets.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

rep() { printf '%*s' "$2" '' | tr ' ' "$1"; } # <char> <count>

repo="$WORK/repo"
git init -q "$repo"
gitc() { git -C "$repo" -c user.name=t -c user.email=t@x -c commit.gpgSign=false "$@"; }
echo base > "$repo/README"; gitc add -A; gitc commit -q -m base
base="$(git -C "$repo" rev-parse HEAD)"

# add <file> <line>: commit one new line on top of the base, then scan it.
scan() { # <line>
	git -C "$repo" reset -q --hard "$base"
	printf '%s\n' "$1" > "$repo/probe.txt"; gitc add -A; gitc commit -q -m probe
	(cd "$repo" && "$SCRIPT" "$base" HEAD 2>&1)
}

out="$(scan 'just an ordinary line')"; check "an ordinary line passes" 0 "$?"

flag() { # <description> <line> <pattern name>
	local out rc value
	value="$2"
	out="$(scan "$value")"; rc=$?
	check "$1 fails" 1 "$rc"
	check "$1 is named" 1 "$(printf '%s' "$out" | grep -c "$3")"
	check "$1 reports the file and line, not the value" 1 "$(printf '%s' "$out" | grep -c 'probe.txt:1')"
	check "$1 does not print the value" 0 "$(printf '%s' "$out" | grep -cF -- "$value")"
}

flag "a private key block" "-----BEGIN $(printf 'RSA')$(printf ' PRIVATE KEY')-----" "private key block"
flag "an AWS access key" "id AKI$(printf 'A')$(rep Q 16)" "AWS access key"
flag "a GitHub token" "t=gh$(printf 'p')_$(rep a 36)" "GitHub token"
flag "a fine-grained GitHub token" "github_pat""_$(rep b 60)" "GitHub token"
flag "a JWT" "e""yJ$(rep h 20).e""yJ$(rep p 20).sig" "JWT"
flag "a long value assigned to a secret-like name" "release_secret = \"$(rep c 40)\"" "secret-like name"
flag "a signing key assigned in a config" "SIGNING_KEY: $(rep d 43)" "secret-like name"
# The names the release workflow gives its two signing keys. The second one has no
# word of its own in common with the first, so it needs a pattern of its own.
flag "the Ed25519 release key assigned in a config" "GLYNDOR_RELEASE_ED25519_KEY: $(rep e 43)" "secret-like name"
flag "the ML-DSA-65 release key assigned in a config" "GLYNDOR_RELEASE_MLDSA65_KEY: $(rep f 43)=" "secret-like name"
flag "an ML-DSA key named with separators" "ml_dsa_65_key = \"$(rep g 43)\"" "secret-like name"
out="$(scan "GLYNDOR_RELEASE_MLDSA65_KEY: \${{ secrets.GLYNDOR_RELEASE_MLDSA65_KEY }}")"
check "the ML-DSA-65 key read from a CI secret passes" 0 "$?"
out="$(scan "GLYNDOR_RELEASE_MLDSA65_KEY=short")"
check "a short value for the ML-DSA-65 key name passes" 0 "$?"

# Code that writes or checks the header is not a key; a key inside a string is.
out="$(scan 'let mut pem = String::from("-----BEGIN PRIVATE KEY-----\n");')"
check "code that only writes the header passes" 0 "$?"
out="$(scan '{"private_key":"-----BEGIN PRIVATE KEY-----\nMIIE...fake...\n"}')"
check "a fake key with dots passes" 0 "$?"
flag "a key body inside a string" "{\"k\":\"-----BEGIN PRIVATE KEY-----\\n$(rep M 40)\"}" "private key inside a string"

out="$(scan "api_key = \"$(rep c 40)\" # secret-scan:allow public on purpose")"
check "the allow marker skips the line" 0 "$?"

out="$(scan "token: \${{ secrets.SOMETHING_TOKEN_NAME_THAT_IS_LONG_ENOUGH_TO_MATCH }}")"
check "a reference to a CI secret passes" 0 "$?"

out="$(scan "password_file = \"/run/secrets/$(rep x 40)\"")"
check "a variable that names a file or a path passes" 0 "$?"

out="$(scan "api_key = \"your-$(rep x 40)\"")"
check "a placeholder passes" 0 "$?"

# The words of a sample value excuse a value that is one, and nothing near it: they are
# read from the value alone, as whole words.
flag "a key that starts with a sample word and goes on" "GLYNDOR_RELEASE_ED25519_KEY=example$(rep A 40)=" "secret-like name"
flag "a real key followed by a comment that says example" "release_secret = \"$(rep c 40)\" # example" "secret-like name"
flag "a real key whose name says example" "example_release_secret = \"$(rep c 40)\"" "secret-like name"
flag "a base64 value that holds fake between letters" "signing_key = \"$(rep c 20)fake$(rep d 20)\"" "secret-like name"
flag "a base64 value that holds fake after letters and before a dash" "signing_key = \"$(rep c 20)fake-$(rep d 20)\"" "secret-like name"
flag "a real key whose name goes on with a sample word" "signing_key_fake = \"$(rep c 40)\"" "secret-like name"
out="$(scan "api_key = \"your-api-key-here-$(rep x 20)\"")"
check "a value that starts with the word your is a sample" 0 "$?"
out="$(scan "GLYNDOR_RELEASE_ED25519_KEY=placeholder_$(rep x 40)")"
check "a value that starts with the word placeholder is a sample" 0 "$?"
out="$(scan "release_secret = \"fake-$(rep x 40)\"")"
check "a value with the word fake before a dash is a sample" 0 "$?"
out="$(scan "release_secret_path = \"$(rep x 40)\"")"
check "a name that ends in path is not a secret" 0 "$?"

# A secret that was already in the base is not a reason to fail this change.
printf 'old_token = "%s"\n' "$(rep z 40)" > "$repo/old.txt"; gitc add -A; gitc commit -q -m "old"
base2="$(git -C "$repo" rev-parse HEAD)"
echo more >> "$repo/README"; gitc add -A; gitc commit -q -m "touch"
(cd "$repo" && "$SCRIPT" "$base2" HEAD >/dev/null 2>&1); check "an old line in the base is not rescanned" 0 "$?"

# A repository lists the paths that hold throwaway keys on purpose. The list is read
# from the base commit, so the change that adds an entry does not use it.
git -C "$repo" reset -q --hard "$base"
printf '# test keys\n^fixtures/\n' > "$repo/.secret-scan-allow"
gitc add -A; gitc commit -q -m "list the fixtures"
allow_base="$(git -C "$repo" rev-parse HEAD)"
mkdir -p "$repo/fixtures"
printf -- '-----BEGIN %s-----\n%s\n' 'PRIVATE KEY' "$(rep M 40)" > "$repo/fixtures/test.pem"
gitc add -A; gitc commit -q -m "fixture"
(cd "$repo" && "$SCRIPT" "$allow_base" HEAD >/dev/null 2>&1); check "a path listed in .secret-scan-allow of the base is skipped" 0 "$?"
printf -- '-----BEGIN %s-----\n' 'PRIVATE KEY' > "$repo/elsewhere.pem"; gitc add -A; gitc commit -q -m "elsewhere"
(cd "$repo" && "$SCRIPT" "$allow_base" HEAD >/dev/null 2>&1); check "a key outside the listed paths still fails" 1 "$?"

# The list the change itself carries excuses nothing: it is the change under review.
git -C "$repo" reset -q --hard "$base"
mkdir -p "$repo/fixtures"
printf -- '-----BEGIN %s-----\n%s\n' 'PRIVATE KEY' "$(rep M 40)" > "$repo/fixtures/test.pem"
printf '^fixtures/\n' > "$repo/.secret-scan-allow"
gitc add -A; gitc commit -q -m "fixture and its own list"
out="$(cd "$repo" && "$SCRIPT" "$base" HEAD 2>&1)"; rc=$?
check "a list added by the change itself is not used" 1 "$rc"
check "and the key it listed is named" 1 "$(printf '%s' "$out" | grep -c 'private key block')"

# A change that widens the list of the base is judged by the list of the base too.
git -C "$repo" reset -q --hard "$allow_base"
printf -- '-----BEGIN %s-----\n' 'PRIVATE KEY' > "$repo/elsewhere.pem"
printf '# test keys\n^fixtures/\n^elsewhere\\.pem\n' > "$repo/.secret-scan-allow"
gitc add -A; gitc commit -q -m "widen the list and use it"
out="$(cd "$repo" && "$SCRIPT" "$allow_base" HEAD 2>&1)"; rc=$?
check "a path the change adds to the list of the base is not skipped" 1 "$rc"
check "and the key it listed is named" 1 "$(printf '%s' "$out" | grep -c 'private key block')"

# An expression that does not compile fails the scan with its own message, whether
# the change adds a credential or not, instead of emptying the set it filters. The
# credential is one the scan reports when no list exists.
bad_list() { # <expression> <added line>: a base holding the list, and a change adding the line
	git -C "$repo" reset -q --hard "$base"
	printf '# test keys\n%s\n' "$1" > "$repo/.secret-scan-allow"; gitc add -A; gitc commit -q -m "list"
	bad_base="$(git -C "$repo" rev-parse HEAD)"
	printf '%s\n' "$2" > "$repo/c.txt"; gitc add -A; gitc commit -q -m "change"
	out="$(cd "$repo" && "$SCRIPT" "$bad_base" HEAD 2>&1)"; rc=$?
}
aws="id AKI""A$(rep Q 16)"
bad_list '[unclosed' "$aws"
check "an expression that does not compile fails" 1 "$rc"
check "and says it is not a regular expression" 1 "$(printf '%s' "$out" | grep -c 'not a regular expression')"
check "and does not report a clean scan" 0 "$(printf '%s' "$out" | grep -c 'no credential-shaped lines added')"
bad_list '[unclosed' 'just an ordinary line'
check "an expression that does not compile fails a change that adds nothing" 1 "$rc"
check "and says so for that change too" 1 "$(printf '%s' "$out" | grep -c 'not a regular expression')"
bad_list '^.*$' "$aws"
check "an expression that matches every path fails" 1 "$rc"
check "and says it would switch the scan off" 1 "$(printf '%s' "$out" | grep -c 'matches every path')"
bad_list '^fixtures/' "$aws"
check "a list of paths that compile still reports a key outside them" 1 "$rc"
check "and names the key, not the list" 1 "$(printf '%s' "$out" | grep -c 'AWS access key')"

# A grep that fails while the list is applied must not empty the set. The stub fails
# only for that call, so the credential below can only be seen if the failure is not
# read as "nothing left".
mkdir -p "$WORK/stub"
real_grep="$(command -v grep)"
printf '#!/bin/sh\ncase "$*" in *"^(^fixtures/)"*) exit 2 ;; esac\nexec %s "$@"\n' "$real_grep" > "$WORK/stub/grep"
chmod +x "$WORK/stub/grep"
bad_list '^fixtures/' "$aws"
out="$(cd "$repo" && PATH="$WORK/stub:$PATH" "$SCRIPT" "$bad_base" HEAD 2>&1)"; rc=$?
check "a grep that fails while the list is applied fails the scan" 1 "$rc"
check "and says the list could not be applied" 1 "$(printf '%s' "$out" | grep -c 'could not apply')"
check "and does not report a clean scan" 0 "$(printf '%s' "$out" | grep -c 'no credential-shaped lines added')"
out="$(cd "$repo" && PATH="$WORK/stub:$PATH" "$SCRIPT" "$bad_base" "$bad_base" 2>&1)"; rc=$?
check "the same stub on a change with nothing to filter is accepted" 0 "$rc"

# What names a file, and what the scan reads. The base lists ^fixtures/, so a line the scan
# attributes to a path under fixtures/ is excused and a line it attributes to another is not.
plant() { # <path> <line>...: a change adding one file (and the attributes in $ATTR, if set)
	local file="$1"; shift
	git -C "$repo" reset -q --hard "$allow_base"
	mkdir -p "$repo/$(dirname -- "$file")"
	printf '%s\n' "$@" > "$repo/$file"
	[ -z "${ATTR:-}" ] || printf '%s\n' "$ATTR" > "$repo/.gitattributes"
	gitc add -A; gitc commit -q -m "plant"
	out="$(cd "$repo" && "$SCRIPT" "$allow_base" HEAD 2>&1)"; rc=$?
}
named() { printf '%s' "$out" | grep -cF -- "$1" || true; }

# A line of added text that looks like a diff header does not name the file that follows.
plant evil.txt '++ b/fixtures/ok.txt' "$aws"
check "a credential after an added line shaped like a diff header is refused" 1 "$rc"
check "and it is attributed to the file that holds it, at its own line" 1 "$(named 'evil.txt:2 AWS access key')"
plant evil.txt '++ b/fixtures/ok.txt' 'just a line'
check "the same file without the credential is accepted" 0 "$rc"
plant fixtures/ok.txt "$aws"
check "a credential in a listed path is still skipped" 0 "$rc"

# A file the base already holds under another name adds nothing: a move out of a listed
# path is not a new credential, and a move that adds one is.
git -C "$repo" reset -q --hard "$base"
mkdir -p "$repo/fixtures"
printf '^fixtures/\n' > "$repo/.secret-scan-allow"
printf '%s\n' "$aws" > "$repo/fixtures/k.pem"
gitc add -A; gitc commit -q -m "a listed fixture"
moved_base="$(git -C "$repo" rev-parse HEAD)"
moved() { # <what to do in the tree>: scan the change it makes
	git -C "$repo" reset -q --hard "$moved_base"
	(cd "$repo" && eval "$1"); gitc add -A; gitc commit -q -m "moved"
	out="$(cd "$repo" && "$SCRIPT" "$moved_base" HEAD 2>&1)"; rc=$?
}
moved 'mkdir moved && git mv fixtures/k.pem moved/k.pem'
check "a listed file moved as it is is accepted" 0 "$rc"
moved 'mkdir copied && cp fixtures/k.pem copied/k.pem'
check "a copy of a listed file is accepted" 0 "$rc"
# shellcheck disable=SC2016 # the commands are run by eval in the repository, where $aws is set
moved 'mkdir moved && git mv fixtures/k.pem moved/k.pem && printf "%s\n" "$aws" >> moved/k.pem'
check "the same move with a credential added is refused" 1 "$rc"
check "and the added line is named" 1 "$(named 'moved/k.pem:2 AWS access key')"
# shellcheck disable=SC2016 # as above
moved 'mkdir moved && printf "%s\n" "$aws" > moved/k.pem && printf "%s\n" more >> moved/k.pem'
check "a file with other content under a new name is read" 1 "$rc"

# A name made of pathspec characters names that file alone, not the files it would match.
plant xzy.txt "$aws"
mkdir -p "$repo"; printf '%s\n' 'just a line' > "$repo/x*y.txt"; gitc add -A; gitc commit -q -m "a name with a star"
out="$(cd "$repo" && "$SCRIPT" "$allow_base" HEAD 2>&1)"; rc=$?
check "a credential in one file is refused" 1 "$rc"
check "and a file named with a star is not given the lines of the file it would match" 0 "$(named 'x*y.txt:1')"
check "and the credential is attributed to the file that holds it" 1 "$(named 'xzy.txt:1 AWS access key')"

# A name with a control character cannot be told from two records.
plant $'evil\nfixtures/z.txt' "$aws"
check "a file name with a newline is refused" 1 "$rc"
check "and the refusal is for the name" 1 "$(named 'has a control character in its name')"
plant $'evil\tz.txt' 'just a line'
check "a file name with a tab is refused" 1 "$rc"
plant 'a b/c d.txt' 'just a line'
check "a file name with spaces is accepted" 0 "$rc"
plant 'a b/c d.txt' "$aws"
check "and a credential in it is still refused, by its own name" 1 "$rc"
check "and attributed to that path" 1 "$(named 'a b/c d.txt:1 AWS access key')"

# The marker is read from the text of a line, never from the name of the file.
plant 'secret-scan:allow.txt' "$aws"
check "a file whose name carries the marker is not skipped" 1 "$rc"

# The list is compared with the path alone: an entry cannot reach a line number.
git -C "$repo" reset -q --hard "$base"
printf '^.*:1:\n' > "$repo/.secret-scan-allow"; gitc add -A; gitc commit -q -m "a list of line numbers"
numbers_base="$(git -C "$repo" rev-parse HEAD)"
printf '%s\n' "$aws" > "$repo/c.txt"; gitc add -A; gitc commit -q -m "line one"
out="$(cd "$repo" && "$SCRIPT" "$numbers_base" HEAD 2>&1)"; rc=$?
check "an entry that matches a line number does not excuse the line" 1 "$rc"
check "and the credential is named" 1 "$(named 'c.txt:1 AWS access key')"

# What a line is judged by is its text: a directory called example is not a placeholder.
plant example/config.txt "release_secret = \"$(rep c 40)\""
check "a long secret under a directory called example is refused" 1 "$rc"
check "and named" 1 "$(named 'example/config.txt:1 long value assigned to a secret-like name')"
plant example/config.txt "release_secret = \"your-$(rep c 40)\""
check "the same assignment of a placeholder is accepted" 0 "$rc"

# What the tree under review says about how to show a file does not change what is read.
git -C "$repo" config diff.hide.textconv true
git -C "$repo" config diff.ext.command true
for attr in '* -diff' '* binary' '* diff=hide' '* diff=ext'; do
	ATTR="$attr" plant leak.txt "$aws"
	check "a credential is refused under the attribute '$attr'" 1 "$rc"
	check "and named under '$attr'" 1 "$(named 'leak.txt:1 AWS access key')"
	ATTR="$attr" plant leak.txt 'just a line'
	check "a clean line is accepted under '$attr'" 0 "$rc"
done
git -C "$repo" config --unset diff.hide.textconv
git -C "$repo" config --unset diff.ext.command

# A changed file that git shows as binary, or shows no change for although its content
# changed, fails the scan. The stub stands for a git that does so, which the flags above
# keep real git from doing.
mkdir -p "$WORK/gitshim"
real_git="$(command -v git)"
cat > "$WORK/gitshim/git" <<EOF
#!/bin/sh
case "\$*" in
	*" -U0 "*)
		case "\${GIT_SHIM:-}" in
			binary) echo "Binary files a/x and b/x differ"; exit 0 ;;
			empty | emptynosize) exit 0 ;;
			fail) echo "fatal: stub" >&2; exit 128 ;;
		esac
		;;
	*"ls-tree"*)
		[ "\${GIT_SHIM:-}" != lstree ] || { echo "fatal: stub" >&2; exit 128; }
		;;
	*"cat-file -s"*)
		[ "\${GIT_SHIM:-}" != emptynosize ] || { echo "fatal: stub" >&2; exit 128; }
		;;
esac
exec $real_git "\$@"
EOF
chmod +x "$WORK/gitshim/git"
shimmed() { # <mode>: scan the change of the last plant with the stub git
	out="$(cd "$repo" && GIT_SHIM="$1" PATH="$WORK/gitshim:$PATH" "$SCRIPT" "$allow_base" HEAD 2>&1)"; rc=$?
}
plant leak.txt 'just a line'
shimmed binary
check "a file git shows as binary fails the scan" 1 "$rc"
check "and the refusal is for the file being unread" 1 "$(named 'leak.txt as binary')"
shimmed empty
check "a file git shows no change for fails the scan" 1 "$rc"
check "and the refusal says its content changed" 1 "$(named 'shows no change for leak.txt although its content changed')"
shimmed emptynosize
check "a file git shows no change for, whose size cannot be read, fails the scan" 1 "$rc"
check "and the refusal is for the size" 1 "$(named 'could not read the size of leak.txt')"
shimmed fail
check "a file whose diff cannot be read fails the scan" 1 "$rc"
check "and the refusal names the file" 1 "$(named 'could not diff leak.txt')"
shimmed lstree
check "a base whose files cannot be listed fails the scan" 1 "$rc"
check "and the refusal names the base" 1 "$(named 'could not list the files of')"
shimmed none
check "the same change is accepted when git shows it" 0 "$rc"
# A change with no hunks that is not a change of content is not refused.
git -C "$repo" reset -q --hard "$allow_base"
printf 'content\n' > "$repo/script.sh"; gitc add -A; gitc commit -q -m "script"
mode_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" update-index --chmod=+x script.sh; gitc commit -q -m "mode only"
out="$(cd "$repo" && "$SCRIPT" "$mode_base" HEAD 2>&1)"; rc=$?
check "a change of mode alone is accepted" 0 "$rc"
: > "$repo/empty.txt"; gitc add -A; gitc commit -q -m "an empty file"
out="$(cd "$repo" && "$SCRIPT" "$mode_base" HEAD 2>&1)"; rc=$?
check "an empty file is accepted" 0 "$rc"

# A range git cannot read is a failure, not an empty change. The same call on a range
# that can be read, and has nothing added, is accepted.
out="$(cd "$repo" && "$SCRIPT" 0000000000000000000000000000000000000000 HEAD 2>&1)"; rc=$?
check "a base that does not exist fails" 1 "$rc"
check "and says the diff could not be read" 1 "$(printf '%s' "$out" | grep -c 'could not diff')"
check "and does not report a clean scan" 0 "$(printf '%s' "$out" | grep -c 'no credential-shaped lines added')"
head_now="$(git -C "$repo" rev-parse HEAD)"
out="$(cd "$repo" && "$SCRIPT" "$head_now" HEAD 2>&1)"; rc=$?
check "an empty range is accepted" 0 "$rc"
check "and reports a clean scan" 1 "$(printf '%s' "$out" | grep -c 'no credential-shaped lines added')"

"$SCRIPT" >/dev/null 2>&1; check "no arguments fails" 1 "$?"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
