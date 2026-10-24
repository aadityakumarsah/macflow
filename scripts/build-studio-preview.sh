#!/bin/zsh
set -euo pipefail

# Generates docs/studio/ — a hostable preview of the Tab Studio interface.
#
# The in-app studio under Sources/FocusFlow/BrowserRecorder is served by
# BrowserRecorderBridge from the app's own origin, so it links its assets with
# absolute paths and posts captured media back to that origin. Neither works
# from a static host, so this script copies the page, rewrites the asset paths
# to relative, and adds a banner saying recording needs the app. The in-app
# files are never modified.

ROOT_DIR="${0:A:h:h}"
SOURCE="$ROOT_DIR/Sources/FocusFlow/BrowserRecorder"
OUTPUT="$ROOT_DIR/docs/studio"

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"
cp "$SOURCE/style.css" "$SOURCE/recorder.js" "$SOURCE/editor-core.js" "$OUTPUT/"

/usr/bin/python3 - "$SOURCE/index.html" "$OUTPUT/index.html" <<'PY'
import sys

source, output = sys.argv[1], sys.argv[2]
html = open(source, encoding="utf-8").read()

# Served from /studio/, so root-absolute asset paths would miss.
html = html.replace('href="/style.css"', 'href="style.css"')
html = html.replace('src="/recorder.js"', 'src="recorder.js"')
html = html.replace('<a class="brand" href="/"', '<a class="brand" href="../"')

banner = """<link rel="stylesheet" href="preview.css">"""
html = html.replace("</head>", banner + "</head>", 1)

# Two states: a plain visitor sees a preview, while a page opened by the app
# carries a session in its fragment and is the real recorder. The banner is
# written for the first and removed at runtime for the second.
notice = """<div class="preview-notice" id="preview-notice">
<p><strong>Interface preview.</strong> This is the Tab Studio exactly as it looks inside FocusFlow. Recording from here needs the app: open <em>Record \u2192 Chrome tab</em> in FocusFlow and it will bring you back to this page with a session attached.</p>
<a href="../">Get FocusFlow</a>
</div>
<script>
// A fragment of the form "<token>&port=NNNN" means FocusFlow opened this page
// and is listening on that port, so this is a live studio, not a preview.
(function () {
  var fragment = location.hash.slice(1);
  if (/&port=\\d+/.test(fragment)) {
    var notice = document.getElementById("preview-notice");
    if (notice) notice.remove();
  }
})();
</script>"""
html = html.replace("<body>", "<body>" + notice, 1)

open(output, "w", encoding="utf-8").write(html)
PY

cat > "$OUTPUT/preview.css" <<'EOF'
.preview-notice {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 10px 18px;
    padding: 13px 5%;
    background: #10351f;
}

.preview-notice p {
    flex: 1;
    min-width: 260px;
    margin: 0;
    color: #cfe5d6;
    font-size: 12.5px;
    line-height: 1.6;
}

.preview-notice strong { color: #fff; font-weight: 650; }

.preview-notice a {
    padding: 8px 15px;
    border-radius: 7px;
    background: #2ea06a;
    color: #04150c;
    font-weight: 650;
    text-decoration: none;
    white-space: nowrap;
}

.preview-notice a:hover { background: #3dbb7e; }

EOF

echo "$OUTPUT"
