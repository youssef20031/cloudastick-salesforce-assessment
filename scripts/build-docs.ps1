<#
.SYNOPSIS
    Builds the ABC Pharmacy Markdown documentation into print-ready PDFs.

.DESCRIPTION
    Markdown -> HTML -> PDF, with no global installs and no pandoc:

      1. `npx marked` (version pinned by -MarkedVersion) renders the Markdown body.
      2. The body is wrapped in one self-contained HTML file with embedded print CSS
         (A4 page box, typography, table rules, page-break rules) written to docs/dist/.
      3. Mermaid is loaded from cdnjs and draws every ```mermaid fenced block in place.
      4. Headless Chrome prints that file to docs/dist/<name>.pdf.

    Conventions honoured in the Markdown source:

      <!-- doc-title: ... -->      cover page title      (falls back to the first H1)
      <!-- doc-subtitle: ... -->   cover page subtitle
      <!-- doc-version: ... -->    cover page version
      <!-- doc-date: ... -->       cover page date       (falls back to today)
      <!-- doc-author: ... -->     cover page author
      <!-- doc-toc: true -->       insert an auto-generated contents page

    The first H1 is lifted out of the body and rendered on the cover page, so a
    document never prints its own title twice.

      <!-- TODO(main-session): ... -->

    is rendered as a visible "pending" callout, so nothing ships as a silent gap.
    Pass -HideTodos for the final hand-in build to drop them from the PDF instead.

.PARAMETER Only
    Build a single document: -Only SOLUTION_DOCUMENTATION (the .md suffix is optional).

.PARAMETER HideTodos
    Drop TODO(main-session) callouts from the output instead of rendering them.

.PARAMETER KeepHtml
    Keep the intermediate .html next to the PDF (it is kept by default; use
    -KeepHtml:$false to delete it after printing).

.EXAMPLE
    pwsh -File scripts/build-docs.ps1
    pwsh -File scripts/build-docs.ps1 -Only API_DOCUMENTATION
    npm run docs

.NOTES
    Chrome's --print-to-pdf honours the CSS @page box but has no support for CSS
    paged-media margin boxes, so page numbers are not available while
    --no-pdf-header-footer is in force. That flag is deliberate: Chrome's built-in
    header/footer prints the file:// URL across the top of every page.
#>
[CmdletBinding()]
param(
    [string]$Only,
    [switch]$HideTodos,
    [bool]$KeepHtml = $true,
    [string]$MarkedVersion = '18.0.13',
    [string]$MermaidVersion = '11.15.0',
    [int]$VirtualTimeBudgetMs = 15000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$DocsDir  = Join-Path $RepoRoot 'docs'
$DistDir  = Join-Path $DocsDir 'dist'

function Write-Step { param([string]$Message) Write-Host "  $Message" -ForegroundColor DarkGray }
function Write-Ok   { param([string]$Message) Write-Host "  $Message" -ForegroundColor Green }

# --------------------------------------------------------------------- chrome

function Find-Chrome {
    <#  Chrome is not on PATH in a default Windows install, so probe the three
        locations the installer actually uses, then fall back to the registry. #>
    # Built as separate strings first: Join-Path throws on a null base, and
    # ProgramFiles(x86) does not exist on every machine. The outer @() keeps the
    # result an array even when Where-Object matches nothing or exactly one path.
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA) | Where-Object { $_ }
    $relatives = @(
        'Google\Chrome\Application\chrome.exe',
        'Google\Chrome Beta\Application\chrome.exe',
        'Chromium\Application\chrome.exe'
    )
    $probes = @()
    foreach ($root in $roots) {
        foreach ($rel in $relatives) { $probes += (Join-Path $root $rel) }
    }
    $candidates = @($probes | Where-Object { Test-Path -LiteralPath $_ })

    if ($candidates.Count -gt 0) { return $candidates[0] }

    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'
    )
    foreach ($rp in $regPaths) {
        try {
            $exe = (Get-ItemProperty -Path $rp -ErrorAction Stop).'(default)'
            if ($exe -and (Test-Path -LiteralPath $exe)) { return $exe }
        } catch { }
    }

    $onPath = Get-Command chrome.exe -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    throw @"
Google Chrome was not found, so the HTML cannot be printed to PDF.
Looked in:
  $env:ProgramFiles\Google\Chrome\Application\chrome.exe
  ${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe
  $env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe
  the chrome.exe App Paths registry keys, and PATH.
Install Chrome (https://www.google.com/chrome/), or edit Find-Chrome in
scripts/build-docs.ps1 to point at any Chromium build you already have.
"@
}

# ------------------------------------------------------------------ templates

$HtmlTemplate = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{{TITLE}}</title>
<style>
  @page { size: A4; margin: 18mm 15mm 16mm 15mm; }

  :root {
    --ink:      #1a1d21;
    --muted:    #5b6570;
    --rule:     #d4dae0;
    --accent:   #0b5f57;
    --accent-2: #0b827c;
    --code-bg:  #f5f7f8;
  }

  * { box-sizing: border-box; }

  html { -webkit-print-color-adjust: exact; print-color-adjust: exact; }

  body {
    margin: 0;
    color: var(--ink);
    background: #fff;
    font-family: "Segoe UI", "Helvetica Neue", Arial, sans-serif;
    font-size: 10.2pt;
    line-height: 1.52;
    text-rendering: optimizeLegibility;
  }

  /* ---------------------------------------------------------- cover page */

  .cover {
    height: 247mm;                 /* A4 height less the @page margins */
    display: flex;
    flex-direction: column;
    justify-content: center;
    page-break-after: always;
    break-after: page;
  }
  .cover .eyebrow {
    font-size: 9pt;
    letter-spacing: .18em;
    text-transform: uppercase;
    color: var(--accent-2);
    font-weight: 600;
  }
  .cover h1.cover-title {
    font-size: 27pt;
    line-height: 1.18;
    margin: 10mm 0 4mm;
    padding: 0;
    border: 0;
    color: var(--ink);
    page-break-before: auto;
    break-before: auto;
  }
  .cover .subtitle {
    font-size: 12.5pt;
    color: var(--muted);
    max-width: 130mm;
    margin-bottom: 14mm;
  }
  .cover .rule { height: 3px; width: 46mm; background: var(--accent-2); margin-bottom: 12mm; }
  .cover dl { display: grid; grid-template-columns: 30mm 1fr; gap: 2mm 6mm; margin: 0; font-size: 9.6pt; }
  .cover dt { color: var(--muted); text-transform: uppercase; letter-spacing: .06em; font-size: 8.4pt; padding-top: .6mm; }
  .cover dd { margin: 0; }

  /* ------------------------------------------------------------ headings */

  h1, h2, h3, h4, h5, h6 { color: var(--ink); font-weight: 600; page-break-after: avoid; break-after: avoid-page; }

  h1 {
    font-size: 19pt;
    line-height: 1.25;
    margin: 0 0 6mm;
    padding-bottom: 2.5mm;
    border-bottom: 2px solid var(--accent-2);
    page-break-before: always;
    break-before: page;
  }
  h1:first-of-type { page-break-before: auto; break-before: auto; }

  h2 { font-size: 13.5pt; margin: 8mm 0 3mm; }
  h3 { font-size: 11.4pt; margin: 6mm 0 2mm; }
  h4 { font-size: 10.4pt; margin: 5mm 0 2mm; color: var(--muted); text-transform: uppercase; letter-spacing: .05em; }

  p { margin: 0 0 3.2mm; orphans: 3; widows: 3; }

  ul, ol { margin: 0 0 3.2mm; padding-left: 6mm; }
  li { margin-bottom: 1.2mm; }
  li > ul, li > ol { margin-top: 1.2mm; }

  a { color: var(--accent); text-decoration: none; word-break: break-word; }

  strong { font-weight: 600; }

  hr { border: 0; border-top: 1px solid var(--rule); margin: 6mm 0; }

  /* -------------------------------------------------------------- tables */

  table {
    width: 100%;
    border-collapse: collapse;
    margin: 0 0 4mm;
    font-size: 8.6pt;
    line-height: 1.4;
    page-break-inside: avoid;      /* keep a short table whole ... */
    break-inside: avoid;
  }
  table.long { page-break-inside: auto; break-inside: auto; }  /* ... but let a long one flow */
  thead { display: table-header-group; }                        /* repeat the header on each page */
  tr { page-break-inside: avoid; break-inside: avoid; }
  th, td {
    border: 1px solid var(--rule);
    padding: 1.6mm 2.2mm;
    text-align: left;
    vertical-align: top;
    overflow-wrap: anywhere;       /* long API names must wrap, never overflow */
    word-break: normal;
  }
  th { background: #eef3f4; font-weight: 600; color: var(--ink); }
  tbody tr:nth-child(even) td { background: #fafbfc; }
  td code, th code { font-size: 8pt; }

  /* ---------------------------------------------------------------- code */

  code, kbd, samp {
    font-family: "Cascadia Mono", Consolas, "Courier New", monospace;
    font-size: 9pt;
    background: var(--code-bg);
    border: 1px solid #e4e9ec;
    border-radius: 2px;
    padding: 0 1.1mm;
    overflow-wrap: anywhere;
  }
  pre {
    background: var(--code-bg);
    border: 1px solid #e4e9ec;
    border-left: 3px solid var(--accent-2);
    border-radius: 3px;
    padding: 2.6mm 3.2mm;
    margin: 0 0 4mm;
    font-size: 8.6pt;
    line-height: 1.45;
    white-space: pre-wrap;         /* wrap rather than clip at the page edge */
    overflow-wrap: anywhere;
    page-break-inside: avoid;
    break-inside: avoid;
  }
  pre code { background: none; border: 0; padding: 0; font-size: inherit; }

  blockquote {
    margin: 0 0 4mm;
    padding: 2mm 4mm;
    border-left: 3px solid var(--rule);
    color: var(--muted);
  }

  /* ------------------------------------------------------------- mermaid */

  .mermaid-wrap {
    margin: 0 0 5mm;
    padding: 3mm 0;
    text-align: center;
    page-break-inside: avoid;
    break-inside: avoid;
  }
  .mermaid { background: none; border: 0; padding: 0; margin: 0; white-space: pre; }
  .mermaid svg { max-width: 100% !important; height: auto !important; }

  /* ---------------------------------------------------------- todo boxes */

  .todo {
    margin: 0 0 4mm;
    padding: 2.4mm 3.2mm;
    background: #fff8e6;
    border: 1px solid #e3c168;
    border-left: 3px solid #c08a12;
    border-radius: 3px;
    font-size: 9pt;
    color: #6b4d05;
    page-break-inside: avoid;
    break-inside: avoid;
  }
  .todo .todo-label {
    display: block;
    font-size: 7.6pt;
    font-weight: 700;
    letter-spacing: .1em;
    text-transform: uppercase;
    margin-bottom: 1mm;
  }

  /* ----------------------------------------------------------------- toc */

  .toc { page-break-after: always; break-after: page; }
  .toc h2 { margin-top: 0; border-bottom: 1px solid var(--rule); padding-bottom: 2mm; }
  .toc ol { list-style: none; padding-left: 0; counter-reset: toc1; }
  .toc > ol > li { counter-increment: toc1; margin-bottom: 1.4mm; font-weight: 600; }
  .toc > ol > li > a::before { content: counter(toc1) ".  "; color: var(--muted); }
  .toc ol ol { padding-left: 7mm; margin: 1mm 0 2mm; font-weight: 400; }
  .toc ol ol li { margin-bottom: .8mm; color: var(--muted); font-size: 9.4pt; }
  .toc a { color: var(--ink); }

  .doc-footnote { margin-top: 8mm; padding-top: 3mm; border-top: 1px solid var(--rule); font-size: 8.4pt; color: var(--muted); }
</style>
</head>
<body>
{{COVER}}
{{TOC}}
<main>
{{BODY}}
</main>
<script src="https://cdnjs.cloudflare.com/ajax/libs/mermaid/{{MERMAID_VERSION}}/mermaid.min.js"></script>
<script>
  // Mermaid draws every <pre class="mermaid"> block. Chrome is given a virtual
  // time budget on the command line, which covers this asynchronous render.
  if (window.mermaid) {
    window.mermaid.initialize({
      startOnLoad: true,
      theme: 'neutral',
      fontFamily: '"Segoe UI", "Helvetica Neue", Arial, sans-serif',
      fontSize: 13,
      flowchart: { useMaxWidth: true, htmlLabels: true, curve: 'basis', nodeSpacing: 34, rankSpacing: 44 },
      er: { useMaxWidth: true, layoutDirection: 'TB', entityPadding: 10, minEntityWidth: 90, fontSize: 11 },
      sequence: { useMaxWidth: true }
    });
  } else {
    document.querySelectorAll('pre.mermaid').forEach(function (el) {
      el.insertAdjacentHTML('beforebegin',
        '<div class="todo"><span class="todo-label">Diagram not rendered</span>' +
        'Mermaid could not be loaded from cdnjs. Re-run the build with network access.</div>');
    });
  }
</script>
</body>
</html>
'@

$CoverTemplate = @'
<header class="cover">
  <div class="eyebrow">{{EYEBROW}}</div>
  <h1 class="cover-title">{{COVER_TITLE}}</h1>
  <div class="subtitle">{{COVER_SUBTITLE}}</div>
  <div class="rule"></div>
  <dl>
{{COVER_META}}
  </dl>
</header>
'@

# ----------------------------------------------------------------- utilities

function ConvertTo-HtmlText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

function Get-DocMeta {
    <# Pulls the <!-- doc-key: value --> markers out of the Markdown source. #>
    param([string]$Markdown)
    $meta = @{}
    $rx = [regex]'(?im)^\s*<!--\s*doc-(title|subtitle|version|date|author|eyebrow|toc)\s*:\s*(.*?)\s*-->\s*$'
    foreach ($m in $rx.Matches($Markdown)) {
        $meta[$m.Groups[1].Value.ToLowerInvariant()] = $m.Groups[2].Value
    }
    return $meta
}

function New-Slug {
    param([string]$Text)
    $s = ([regex]'<[^>]+>').Replace($Text, '')
    $s = [System.Net.WebUtility]::HtmlDecode($s).ToLowerInvariant()
    $s = ([regex]'[^a-z0-9]+').Replace($s, '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($s)) { $s = 'section' }
    return $s
}

# ---------------------------------------------------------------- the build

function Build-Document {
    param(
        [Parameter(Mandatory)] [System.IO.FileInfo]$MarkdownFile,
        [Parameter(Mandatory)] [string]$ChromeExe,
        [Parameter(Mandatory)] [string]$WorkDir
    )

    $name    = [System.IO.Path]::GetFileNameWithoutExtension($MarkdownFile.Name)
    $htmlOut = Join-Path $DistDir "$name.html"
    $pdfOut  = Join-Path $DistDir "$name.pdf"

    Write-Host ""
    Write-Host "$($MarkdownFile.Name)" -ForegroundColor Cyan

    $markdown = Get-Content -LiteralPath $MarkdownFile.FullName -Raw -Encoding UTF8
    $meta     = Get-DocMeta -Markdown $markdown

    # ---- cover title: explicit metadata, else the first H1 (which is then removed)
    $title = if ($meta.ContainsKey('title')) { $meta['title'] } else { $null }
    $h1rx  = [regex]'(?m)^\#\s+(.+?)\s*$'
    $h1    = $h1rx.Match($markdown)
    if ($h1.Success) {
        if (-not $title) { $title = $h1.Groups[1].Value }
        $markdown = $h1rx.Replace($markdown, '', 1)   # the cover carries it instead
    }
    if (-not $title) { $title = $name }

    # ---- strip the doc-* markers, then render TODOs as visible callouts
    $markdown = ([regex]'(?im)^\s*<!--\s*doc-[a-z]+\s*:.*?-->\s*$\r?\n?').Replace($markdown, '')

    $todoRx = [regex]'(?s)<!--\s*TODO\(main-session\)\s*:\s*(.*?)-->'
    $todoCount = $todoRx.Matches($markdown).Count
    if ($HideTodos) {
        $markdown = $todoRx.Replace($markdown, '')
    } else {
        $markdown = $todoRx.Replace($markdown, {
            param($m)
            $body = ConvertTo-HtmlText ($m.Groups[1].Value.Trim() -replace '\s*\r?\n\s*', ' ')
            '<div class="todo"><span class="todo-label">To be completed before hand-in</span>' + $body + '</div>'
        })
    }

    # ---- Markdown -> HTML body (npx marked, pinned)
    $tmpMd   = Join-Path $WorkDir "$name.src.md"
    $tmpHtml = Join-Path $WorkDir "$name.body.html"
    Set-Content -LiteralPath $tmpMd -Value $markdown -Encoding UTF8 -NoNewline

    Write-Step "marked@$MarkedVersion ..."
    & npx --yes "marked@$MarkedVersion" --gfm -i $tmpMd -o $tmpHtml 2>&1 | Where-Object { $_ } | ForEach-Object { Write-Verbose $_ }
    if ($LASTEXITCODE -ne 0) { throw "marked failed for $($MarkdownFile.Name) (exit $LASTEXITCODE)." }
    if (-not (Test-Path -LiteralPath $tmpHtml)) { throw "marked produced no output for $($MarkdownFile.Name)." }

    $body = Get-Content -LiteralPath $tmpHtml -Raw -Encoding UTF8

    # ---- ```mermaid fences -> <pre class="mermaid"> for the client-side renderer
    $mermaidRx = [regex]'(?s)<pre><code class="language-mermaid">(.*?)</code></pre>'
    $diagrams  = $mermaidRx.Matches($body).Count
    $body = $mermaidRx.Replace($body, {
        param($m)
        '<div class="mermaid-wrap"><pre class="mermaid">' + $m.Groups[1].Value.Trim() + '</pre></div>'
    })

    # ---- heading anchors (needed by the contents page, useful in the HTML)
    $used = @{}
    $body = ([regex]'(?s)<h([234])>(.*?)</h\1>').Replace($body, {
        param($m)
        $level = $m.Groups[1].Value
        $inner = $m.Groups[2].Value
        $slug  = New-Slug $inner
        $n = 2
        while ($used.ContainsKey($slug)) { $slug = (New-Slug $inner) + "-$n"; $n++ }
        $used[$slug] = $true
        "<h$level id=`"$slug`">$inner</h$level>"
    })

    # ---- mark wide tables so they may break across pages
    $body = ([regex]'(?s)<table>(.*?)</table>').Replace($body, {
        param($m)
        $rows = ([regex]'<tr>').Matches($m.Groups[1].Value).Count
        if ($rows -gt 12) { "<table class=`"long`">$($m.Groups[1].Value)</table>" } else { $m.Value }
    })

    # ---- contents page
    $toc = ''
    if ($meta.ContainsKey('toc') -and $meta['toc'] -match '^(?i)true|yes|1$') {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine('<nav class="toc"><h2>Contents</h2>')
        $headings = [regex]::Matches($body, '(?s)<h([23]) id="([^"]+)">(.*?)</h\1>')
        $openSub = $false
        [void]$sb.AppendLine('<ol>')
        foreach ($h in $headings) {
            $lvl  = [int]$h.Groups[1].Value
            $id   = $h.Groups[2].Value
            $text = ([regex]'<[^>]+>').Replace($h.Groups[3].Value, '')
            if ($lvl -eq 2) {
                if ($openSub) { [void]$sb.AppendLine('</ol></li>'); $openSub = $false } else { [void]$sb.AppendLine('</li>') }
                [void]$sb.Append("<li><a href=`"#$id`">$text</a>")
            } else {
                if (-not $openSub) { [void]$sb.AppendLine('<ol>'); $openSub = $true }
                [void]$sb.AppendLine("<li><a href=`"#$id`">$text</a></li>")
            }
        }
        if ($openSub) { [void]$sb.AppendLine('</ol></li>') } else { [void]$sb.AppendLine('</li>') }
        [void]$sb.AppendLine('</ol></nav>')
        $toc = $sb.ToString() -replace '^<ol>\s*</li>', '<ol>'
    }

    # ---- cover page
    $metaRows = [System.Text.StringBuilder]::new()
    $rowOrder = @(
        @{ key = 'version'; label = 'Version' },
        @{ key = 'date';    label = 'Date'    },
        @{ key = 'author';  label = 'Author'  }
    )
    foreach ($row in $rowOrder) {
        $value = if ($meta.ContainsKey($row.key)) { $meta[$row.key] }
                 elseif ($row.key -eq 'date') { (Get-Date).ToString('d MMMM yyyy') }
                 else { $null }
        if ($value) {
            [void]$metaRows.AppendLine("    <dt>$(ConvertTo-HtmlText $row.label)</dt><dd>$(ConvertTo-HtmlText $value)</dd>")
        }
    }
    [void]$metaRows.AppendLine("    <dt>Status</dt><dd>$(if ($todoCount -gt 0 -and -not $HideTodos) { "Draft - $todoCount item(s) pending" } else { 'Issued' })</dd>")

    $cover = $CoverTemplate.
        Replace('{{EYEBROW}}',       (ConvertTo-HtmlText $(if ($meta.ContainsKey('eyebrow')) { $meta['eyebrow'] } else { 'ABC Pharmacy - Salesforce Entry Assessment' }))).
        Replace('{{COVER_TITLE}}',   (ConvertTo-HtmlText $title)).
        Replace('{{COVER_SUBTITLE}}',(ConvertTo-HtmlText $(if ($meta.ContainsKey('subtitle')) { $meta['subtitle'] } else { '' }))).
        Replace('{{COVER_META}}',    $metaRows.ToString())

    # ---- one self-contained HTML file
    $html = $HtmlTemplate.
        Replace('{{TITLE}}',            (ConvertTo-HtmlText $title)).
        Replace('{{COVER}}',            $cover).
        Replace('{{TOC}}',              $toc).
        Replace('{{BODY}}',             $body).
        Replace('{{MERMAID_VERSION}}',  $MermaidVersion)

    Set-Content -LiteralPath $htmlOut -Value $html -Encoding UTF8
    Write-Step ("html  {0:N0} KB  ({1} diagram(s), {2} TODO(s))" -f ((Get-Item $htmlOut).Length / 1KB), $diagrams, $todoCount)

    # ---- HTML -> PDF (headless Chrome)
    if (Test-Path -LiteralPath $pdfOut) { Remove-Item -LiteralPath $pdfOut -Force }

    $profileDir = Join-Path $WorkDir "chrome-profile-$name"
    $fileUrl    = ([uri]$htmlOut).AbsoluteUri
    $chromeArgs = @(
        '--headless'
        '--disable-gpu'
        "--print-to-pdf=`"$pdfOut`""
        "--virtual-time-budget=$VirtualTimeBudgetMs"
        '--no-pdf-header-footer'
        '--no-first-run'
        '--no-default-browser-check'
        '--disable-extensions'
        '--hide-scrollbars'
        "--user-data-dir=`"$profileDir`""
        "`"$fileUrl`""
    ) -join ' '

    Write-Step "chrome --print-to-pdf ..."
    $proc = Start-Process -FilePath $ChromeExe -ArgumentList $chromeArgs -NoNewWindow -Wait -PassThru
    if ($proc.ExitCode -ne 0) { throw "Chrome exited with code $($proc.ExitCode) while printing $name." }
    if (-not (Test-Path -LiteralPath $pdfOut)) { throw "Chrome reported success but produced no PDF for $name." }

    $size = (Get-Item -LiteralPath $pdfOut).Length
    if ($size -lt 5KB) { throw "$name.pdf is only $size bytes - the render almost certainly failed." }

    if (-not $KeepHtml) { Remove-Item -LiteralPath $htmlOut -Force }

    Write-Ok ("pdf   {0:N0} KB  ->  docs\dist\$name.pdf" -f ($size / 1KB))

    [pscustomobject]@{
        Document = $name
        Pdf      = $pdfOut
        SizeKB   = [math]::Round($size / 1KB, 1)
        Diagrams = $diagrams
        Todos    = $todoCount
    }
}

# --------------------------------------------------------------------- main

Write-Host ""
Write-Host "ABC Pharmacy documentation build" -ForegroundColor White

if (-not (Test-Path -LiteralPath $DocsDir)) { throw "No docs directory at $DocsDir." }
if (-not (Get-Command npx -ErrorAction SilentlyContinue)) {
    throw "npx was not found on PATH. Install Node.js 20 or later (https://nodejs.org) and re-run."
}

$chrome = Find-Chrome
Write-Step "chrome: $chrome"

$sources = Get-ChildItem -LiteralPath $DocsDir -Filter '*.md' -File | Sort-Object Name
if ($Only) {
    $wanted  = [System.IO.Path]::GetFileNameWithoutExtension($Only)
    $sources = $sources | Where-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) -ieq $wanted }
    if (-not $sources) {
        $available = (Get-ChildItem -LiteralPath $DocsDir -Filter '*.md' -File | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) }) -join ', '
        throw "No document called '$Only' in docs/. Available: $available"
    }
}
if (-not $sources) { throw "No Markdown files found in $DocsDir." }

New-Item -ItemType Directory -Path $DistDir -Force | Out-Null
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("abc-docs-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null

$results = @()
try {
    foreach ($src in $sources) {
        $results += Build-Document -MarkdownFile $src -ChromeExe $chrome -WorkDir $work
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
$results | Format-Table -AutoSize Document, SizeKB, Diagrams, Todos
$pending = ($results | Measure-Object -Property Todos -Sum).Sum
Write-Host ("Built {0} PDF(s) into docs\dist." -f $results.Count) -ForegroundColor Green
if ($pending -gt 0 -and -not $HideTodos) {
    Write-Host ("$pending TODO(main-session) placeholder(s) still open - search the .md sources for 'TODO(main-session)'.") -ForegroundColor Yellow
}
Write-Host ""
