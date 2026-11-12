#!/usr/bin/env bash
# Verify dist/ can be served unchanged from /<repo>/<ref>/ on any channel host.
# Fails on: root-absolute refs, ../ refs escaping the dist root, baked CDN hosts.
set -euo pipefail

# Empty extension list is allowed: ref detection still runs when ASSET_NAMES
# names published extensionless files; the baked-hostname check always runs.
ASSET_EXTENSIONS="${ASSET_EXTENSIONS:-}"
ASSET_NAMES="${ASSET_NAMES:-}"
DIST_DIR="${DIST_DIR:-dist}"
CDN_BASE_URL="${CDN_BASE_URL:-}"

if [[ "$ASSET_EXTENSIONS" =~ [^a-zA-Z0-9,] ]]; then
  echo "ERROR: ASSET_EXTENSIONS contains invalid characters: ${ASSET_EXTENSIONS}" >&2
  exit 1
fi
name_re='[^a-zA-Z0-9,._% -]'  # via var: a space in the class word-splits on the =~ RHS
if [[ "$ASSET_NAMES" =~ ${name_re} ]]; then
  echo "ERROR: ASSET_NAMES contains invalid characters: ${ASSET_NAMES}" >&2
  exit 1
fi

EXT_PATTERN="${ASSET_EXTENSIONS//,/|}"
NAME_PATTERN="${ASSET_NAMES//,/|}"

# Candidate-ref suffix shared by all detectors: a path ending in a published
# extension (.css) or in a published extensionless basename as a full path
# segment (/robots, a/LICENSE). __C__ is a per-syntax placeholder the perl
# substitutes with that syntax's path-char class — quoted attrs stop at the
# quote, unquoted at whitespace or '=', CSS values at ')' — so a candidate
# can never swallow a following reference.
REF_TAIL=''
if [ -n "${EXT_PATTERN}" ]; then
  REF_TAIL="__C__+\\.(?:${EXT_PATTERN})"
fi
if [ -n "${NAME_PATTERN}" ]; then
  REF_TAIL="${REF_TAIL:+${REF_TAIL}|}(?:__C__*?/)?(?:${NAME_PATTERN})"
fi
export REF_TAIL CDN_BASE_URL

if [ ! -d "$DIST_DIR" ]; then
  echo "ERROR: dist directory ${DIST_DIR} not found" >&2
  exit 1
fi

VIOLATIONS=$(mktemp)
trap 'rm -f "$VIOLATIONS"' EXIT

# HTML and CSS refs resolve relative to the file's own directory, so both root-absolute and escaping-../ refs are checkable.
find "$DIST_DIR" -type f \( -name '*.html' -o -name '*.css' \) -print0 | while IFS= read -r -d '' f; do
  rel="${f#"${DIST_DIR}"/}"
  rel_dir="$(dirname "$rel")"
  [ "$rel_dir" = "." ] && rel_dir=""
  FILE="$f" FILE_DIR="$rel_dir" perl -e '
    my $file = $ENV{FILE};
    my $dir  = $ENV{FILE_DIR} // q{};
    my $tail = $ENV{REF_TAIL} // q{};
    exit 0 unless $tail;
    # Per-syntax path-char classes so a candidate stops at its own boundary
    # (never swallows the next attribute or url()).
    my $mk = sub { my $c = shift; (my $r = $tail) =~ s/__C__/$c/g; return qr/$r/; };
    my $reQ = $mk->(q{[^"\x27]});          # inside quotes — html attr or css; ) is legal here
    my $reU = $mk->(q{[^\s"\x27=<>`]});    # unquoted html attr value
    my $reC = $mk->(q{[^"\x27\)]});        # unquoted css value — stops at )

    open my $fh, q{<}, $file or exit 0;
    my $content = do { local $/; <$fh> };

    my $norm = sub {
      my ($p) = @_;
      my @out;
      for my $seg (split m{/+}, $p) {
        next if $seg eq q{} || $seg eq q{.};
        if ($seg eq q{..}) {
          if (@out && $out[-1] ne q{..}) { pop @out; next; }
          push @out, $seg; next; # preserve leading .. — they escape dist
        }
        push @out, $seg;
      }
      return join q{/}, @out;
    };

    my $check = sub {
      my ($path, $kind) = @_;
      $path =~ s{^\s+|\s+$}{}g;
      # External / scheme / protocol-relative / fragment / data URIs are fine.
      return if $path =~ m{^(?:[a-zA-Z][a-zA-Z0-9+.+-]*:|//|#)}i;
      if ($path =~ m{^/}) {
        print "${file}: ${kind} root-absolute ref ${path}\n";
        return;
      }
      my $p = $path;
      $p =~ s{^\./}{};
      my $resolved = $norm->($dir ne q{} ? "${dir}/${p}" : $p);
      if ($resolved =~ m{^\.\.}) {
        print "${file}: ${kind} ref ${path} escapes the dist root\n";
      }
    };

    while ($content =~ m{(src|href|data-src)\s*=\s*(?:(["\x27])((?:${reQ})(?:[#?][^"\x27]*)?)\2|((?:${reU})(?:[#?][^\s"\x27<>`]*)?)(?=$|[\s"\x27=<>`]))}gi) {
      $check->(defined $3 ? $3 : $4, q{html});
    }
    while ($content =~ m{\@import\s+(?:url\()?\s*(?:(["\x27])((?:${reQ})(?:[#?][^"\x27]*)?)\1\)?|((?:${reC})(?:[#?][^"\x27\)]*)?))}gi) {
      $check->(defined $2 ? $2 : $3, q{css-import});
    }
    while ($content =~ m{url\(\s*(?:(["\x27])((?:${reQ})(?:[#?][^"\x27]*)?)\1|((?:${reC})(?:[#?][^"\x27\)]*)?))\s*\)}gi) {
      $check->(defined $2 ? $2 : $3, q{css-url});
    }
  ' >> "$VIOLATIONS"
done

# JS refs resolve against the *document*, which we cannot know here — so only root-absolute string literals are flagged; relative and ../ strings are the caller's responsibility.
find "$DIST_DIR" -type f -name '*.js' -print0 | while IFS= read -r -d '' f; do
  FILE="$f" perl -e '
    my $file = $ENV{FILE};
    my $tail = $ENV{REF_TAIL} // q{};
    exit 0 unless $tail;
    (my $re = $tail) =~ s/__C__/[^"\x27]/g;
    my $reQ = qr/$re/;
    open my $fh, q{<}, $file or exit 0;
    my $content = do { local $/; <$fh> };
    while ($content =~ m{(["\x27])(/(?!/)(?:${reQ})(?:[#?][^"\x27]*)?)\1}gi) {
      print "${file}: js root-absolute string $2\n";
    }
  ' >> "$VIOLATIONS"
done

# A baked CDN hostname anywhere in dist defeats byte-identical promotion.
HOST_PATTERN='azurefd\.net'
if [ -n "${CDN_BASE_URL}" ]; then
  host="$(printf '%s' "${CDN_BASE_URL}" | sed -E 's|^https?://||; s|/.*$||')"
  if [ -n "${host}" ]; then
    HOST_PATTERN="${HOST_PATTERN}|$(printf '%s' "${host}" | sed -E 's/[.^$*+?(){}\[\]|\\]/\\&/g')"
  fi
fi
while IFS= read -r f; do
  printf '%s\n' "${f}: baked CDN hostname" >> "$VIOLATIONS"
done < <(grep -rlE "${HOST_PATTERN}" "$DIST_DIR" --include='*.html' --include='*.css' --include='*.js' || true)

if [ -s "$VIOLATIONS" ]; then
  echo "ERROR: dist/ is not host-agnostic — assets cannot be promoted latest→stable as identical bytes:" >&2
  sort -u "$VIOLATIONS" >&2
  echo "" >&2
  echo "Fix the references above (make them relative, or inject the CDN host at deploy time) or take the build failure as an explicit decision to keep per-channel bytes." >&2
  exit 1
fi

echo "CDN verify: dist/ is host-agnostic."
