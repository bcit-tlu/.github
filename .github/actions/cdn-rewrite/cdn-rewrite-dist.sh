#!/usr/bin/env bash
# Rewrite asset URLs in dist/ for CDN upload and verify the rewrite succeeded.
set -euo pipefail

CDN_BASE_URL="${CDN_BASE_URL:?CDN_BASE_URL is required}"
CDN_NAMESPACE="${CDN_NAMESPACE:-}"
[ "$CDN_NAMESPACE" = "none" ] && CDN_NAMESPACE=""
REPO_NAME="${REPO_NAME:?REPO_NAME is required}"
SHORT_SHA="${SHORT_SHA:?SHORT_SHA is required}"
ASSET_EXTENSIONS="${ASSET_EXTENSIONS:?ASSET_EXTENSIONS is required}"
DIST_DIR="${DIST_DIR:-dist}"

# Sanitize asset extensions before interpolating them into Perl regex source.
if [[ "$ASSET_EXTENSIONS" =~ [^a-zA-Z0-9,] ]]; then
  echo "ERROR: ASSET_EXTENSIONS contains invalid characters: ${ASSET_EXTENSIONS}" >&2
  exit 1
fi

if [ -n "$CDN_NAMESPACE" ]; then
  CDN_URL="${CDN_BASE_URL%/}/${CDN_NAMESPACE}/${REPO_NAME}/${SHORT_SHA}"
else
  CDN_URL="${CDN_BASE_URL%/}/${REPO_NAME}/${SHORT_SHA}"
fi
EXT_PATTERN="${ASSET_EXTENSIONS//,/|}"
export CDN_URL EXT_PATTERN

echo "Rewriting ${DIST_DIR}/ assets to CDN: ${CDN_URL}"

if [ ! -d "$DIST_DIR" ]; then
  echo "ERROR: dist directory ${DIST_DIR} not found" >&2
  exit 1
fi

# HTML rewrite
find "$DIST_DIR" -type f -name '*.html' | while read -r f; do
  rel="${f#${DIST_DIR}/}"
  rel_dir="$(dirname "$rel")"
  [ "$rel_dir" = "." ] && rel_dir=""
  HTML_DIR="$rel_dir" perl -pi -e '
    my $cdn  = $ENV{CDN_URL}  // q{};
    my $exts = $ENV{EXT_PATTERN} // q{};
    my $dir  = $ENV{HTML_DIR}    // q{};
    exit 0 unless $cdn && $exts;

    my $norm = sub {
      my ($p) = @_;
      my @out;
      for my $seg (split m{/+}, $p) {
        next if $seg eq q{} || $seg eq q{.};
        if ($seg eq q{..}) { pop @out if @out; next; }
        push @out, $seg;
      }
      return join q{/}, @out;
    };

    my $pat = qr{(src|href|data-src)\s*=\s*(["\x27])([^"\x27]+\.(?:$exts)(?:[#?][^"\x27]*)?)\2}i;
    s{$pat}{
      my ($attr, $q, $path) = ($1, $2, $3);
      $path =~ s{^\s+|\s+$}{}g;
      if ($path =~ m{://} || ($cdn ne q{} && index($path, $cdn) == 0) || $path =~ m{^(?:[a-zA-Z][a-zA-Z0-9+.+-]*:|//)}) {
        "$attr=$q$path$q";
      } else {
        my $p = $path;
        $p =~ s{^\./}{};
        if ($p =~ m{^/}) { $p =~ s{^/}{}; }
        else { $p = $dir ? "$dir/$p" : $p; }
        $p = $norm->($p);
        "$attr=$q$cdn/$p$q";
      }
    }eg;
  ' "$f"
done

# CSS rewrite
find "$DIST_DIR" -type f -name '*.css' | while read -r f; do
  rel="${f#${DIST_DIR}/}"
  rel_dir="$(dirname "$rel")"
  [ "$rel_dir" = "." ] && rel_dir=""
  CSS_DIR="$rel_dir" perl -pi -e '
    my $cdn  = $ENV{CDN_URL}  // q{};
    my $exts = $ENV{EXT_PATTERN} // q{};
    my $dir  = $ENV{CSS_DIR}     // q{};
    exit 0 unless $cdn && $exts;

    my $norm = sub {
      my ($p) = @_;
      my @out;
      for my $seg (split m{/+}, $p) {
        next if $seg eq q{} || $seg eq q{.};
        if ($seg eq q{..}) { pop @out if @out; next; }
        push @out, $seg;
      }
      return join q{/}, @out;
    };

    my $is_abs = sub {
      my ($p) = @_;
      $p =~ s{^\s+|\s+$}{}g;
      return 1 if $p =~ m{://};
      return 1 if $cdn ne q{} && index($p, $cdn) == 0;
      return $p =~ m{^(?:[a-zA-Z][a-zA-Z0-9+.+-]*:|//|data:)}i;
    };

    my $rewrite = sub {
      my ($path) = @_;
      $path =~ s{^\s+|\s+$}{}g;
      return $path if $is_abs->($path);
      my $p = $path;
      $p =~ s{^\./}{};
      if ($p =~ m{^/}) { $p =~ s{^/}{}; }
      else { $p = $dir ? "$dir/$p" : $p; }
      $p = $norm->($p);
      return "$cdn/$p";
    };

    # Handle @import first so url() inside @import is preserved as a valid
    # @import url("...") statement rather than being stripped to a bare path.
    my $import_pat = qr{\@import\s+(?:url\()?(["\x27]?)([^"\x27\)]+\.(?:$exts)(?:[#?][^"\x27\)]*)?)\1\)?}i;
    s{$import_pat}{
      my ($q, $path) = ($1, $2);
      my $new = $rewrite->($path);
      "\@import url(\"$new\")";
    }eg;

    my $url_pat = qr{url\(\s*(["\x27]?)([^"\x27\)]+\.(?:$exts)(?:[#?][^"\x27\)]*)?)\1\s*\)}i;
    s{$url_pat}{
      my ($q, $path) = ($1, $2);
      my $new = $rewrite->($path);
      "url(" . ($q // q{}) . $new . ($q // q{}) . ")";
    }eg;
  ' "$f"
done

# JS rewrite
find "$DIST_DIR" -type f -name '*.js' | while read -r f; do
  rel="${f#${DIST_DIR}/}"
  rel_dir="$(dirname "$rel")"
  [ "$rel_dir" = "." ] && rel_dir=""
  JS_DIR="$rel_dir" perl -pi -e '
    my $cdn  = $ENV{CDN_URL}  // q{};
    my $exts = $ENV{EXT_PATTERN} // q{};
    my $dir  = $ENV{JS_DIR}      // q{};
    exit 0 unless $cdn && $exts;

    my $norm = sub {
      my ($p) = @_;
      my @out;
      for my $seg (split m{/+}, $p) {
        next if $seg eq q{} || $seg eq q{.};
        if ($seg eq q{..}) { pop @out if @out; next; }
        push @out, $seg;
      }
      return join q{/}, @out;
    };

    my $is_abs = sub {
      my ($p) = @_;
      $p =~ s{^\s+|\s+$}{}g;
      return 1 if $p =~ m{://};
      return 1 if $cdn ne q{} && index($p, $cdn) == 0;
      return $p =~ m{^(?:[a-zA-Z][a-zA-Z0-9+.+-]*:|//|data:)}i;
    };

    my $rewrite = sub {
      my ($path) = @_;
      $path =~ s{^\s+|\s+$}{}g;
      return $path if $is_abs->($path);
      my $p = $path;
      $p =~ s{^\./}{};
      if ($p =~ m{^/}) { $p =~ s{^/}{}; }
      else { $p = $dir ? "$dir/$p" : $p; }
      $p = $norm->($p);
      return "$cdn/$p";
    };

    my $str_pat = qr{(["\x27])([^"\x27]+?\.(?:$exts)(?:[#?][^"\x27]*)?)\1}i;
    s{$str_pat}{
      my ($q, $path) = ($1, $2);
      my $new = $rewrite->($path);
      $q . $new . $q;
    }eg;
  ' "$f"
done

echo "CDN rewrite complete."

# Verify the rewrite actually injected the immutable CDN URL into files that
# contain asset references. Use the same patterns the rewriter uses so plain
# extension-shaped text (e.g. examples in documentation) does not trigger false
# positives.
missing_files=$(find "$DIST_DIR"/ -type f \( -name '*.html' -o -name '*.css' -o -name '*.js' \) | while read -r f; do
  has_asset_ref=$(perl -e '
    my $cdn  = $ARGV[0] // q{};
    my $exts = $ARGV[1] // q{};
    my $file = $ARGV[2];
    exit 0 unless $cdn && $exts;
    open my $fh, q{<}, $file or exit 0;
    my $content = do { local $/; <$fh> };
    my $html_pat = qr{(src|href|data-src)\s*=\s*(["\x27])([^"\x27]+\.(?:$exts)(?:[#?][^"\x27]*)?)\2}i;
    my $css_url_pat = qr{url\(\s*(["\x27]?)([^"\x27\)]+\.(?:$exts)(?:[#?][^"\x27\)]*)?)\1\s*\)}i;
    my $css_import_pat = qr{\@import\s+(?:url\()?(["\x27]?)([^"\x27\)]+\.(?:$exts)(?:[#?][^"\x27\)]*)?)\1\)?}i;
    my $js_pat = qr{(["\x27])([^"\x27]+?\.(?:$exts)(?:[#?][^"\x27]*)?)\1}i;
    exit 1 if $content =~ $html_pat || $content =~ $css_url_pat || $content =~ $css_import_pat || $content =~ $js_pat;
    exit 0;
  ' "$CDN_URL" "$EXT_PATTERN" "$f")

  if [ "$has_asset_ref" -eq 1 ] && ! grep -qF "${CDN_URL}/" "$f"; then
    printf '%s\n' "$f"
  fi
done)
if [ -n "${missing_files}" ]; then
  echo "ERROR: rewrite did not inject ${CDN_URL}/ into the following files:" >&2
  echo "${missing_files}" >&2
  exit 1
fi
