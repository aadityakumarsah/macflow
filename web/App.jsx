import React, { useState } from 'react'
import {
  ArrowUpRight, Check, CircleHelp, Clapperboard, Command, Copy,
  Download, FolderOpen, Fullscreen, LayoutPanelLeft, LockKeyhole, Menu,
  Monitor, MousePointer2, MousePointerClick, Play, Ratio, Scissors,
  ShieldCheck, Sparkles, Star, Video, WandSparkles, X,
} from 'lucide-react'

const RELEASE = 'https://github.com/aadityakumarsah/macflow/releases/latest'
const REPO = 'https://github.com/aadityakumarsah/macflow'
const INSTALL = 'curl -fsSL https://raw.githubusercontent.com/aadityakumarsah/macflow/main/install.sh | bash'
const LATEST_RELEASE_API = 'https://api.github.com/repos/aadityakumarsah/macflow/releases/latest'
const ratios = [
  { label: '16:9', className: 'landscape' },
  { label: '9:16', className: 'portrait' },
  { label: '1:1', className: 'square' },
  { label: 'Custom', className: 'custom' },
]

function GithubMark() {
  return <svg width="17" height="17" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 .75a11.25 11.25 0 0 0-3.558 21.924c.563.104.77-.244.77-.543 0-.267-.01-.974-.016-1.912-3.132.68-3.793-1.51-3.793-1.51-.512-1.3-1.25-1.646-1.25-1.646-1.023-.699.077-.684.077-.684 1.132.08 1.727 1.162 1.727 1.162 1.006 1.724 2.639 1.226 3.283.937.102-.728.394-1.226.716-1.508-2.5-.284-5.128-1.25-5.128-5.56 0-1.229.44-2.233 1.16-3.02-.117-.285-.503-1.428.11-2.977 0 0 .944-.302 3.094 1.154A10.78 10.78 0 0 1 12 5.37c.956.005 1.918.13 2.817.379 2.148-1.456 3.09-1.154 3.09-1.154.615 1.549.229 2.692.113 2.977.722.787 1.158 1.791 1.158 3.02 0 4.32-2.633 5.273-5.14 5.55.405.35.766 1.046.766 2.108 0 1.522-.014 2.75-.014 3.124 0 .301.203.65.775.54A11.252 11.252 0 0 0 12 .75Z"/></svg>
}

function CopyInstallButton({ onCopy, copied, className = '' }) {
  return <button className={`button button-primary ${className}`} type="button" onClick={onCopy}>
    {copied ? <Check size={17} /> : <Copy size={17} />} {copied ? 'Copied to clipboard' : 'Copy install command'}
  </button>
}

function DmgDownload({ className = '' }) {
  const [busy, setBusy] = useState(false)
  async function download(event) {
    event.preventDefault()
    if (busy) return
    setBusy(true)
    try {
      const response = await fetch(LATEST_RELEASE_API, { headers: { Accept: 'application/vnd.github+json' } })
      if (!response.ok) throw new Error('Could not read the latest release')
      const release = await response.json()
      const asset = release.assets?.find(item => item.name?.toLowerCase().endsWith('.dmg'))
      window.location.assign(asset?.browser_download_url || RELEASE)
    } catch {
      window.location.assign(RELEASE)
    }
  }
  return <a className={`button button-outline ${className}`} href={RELEASE} onClick={download} aria-busy={busy}>
    <Download size={17} /> {busy ? 'Finding latest .dmg…' : 'Download .dmg'}
  </a>
}

function Brand() {
  return <a className="brand" href="#top" aria-label="FocusFlow home">
    <img src="./icon.png" alt="" /><span>FocusFlow<span className="brand-dot">.</span></span>
  </a>
}

function Header({ onCopy, copied }) {
  const [open, setOpen] = useState(false)
  return <header className="site-header" id="top">
    <div className="header-inner wrap">
      <Brand />
      <nav className={open ? 'main-nav is-open' : 'main-nav'} aria-label="Main navigation">
        <a href="#how" onClick={() => setOpen(false)}>How it works</a>
        <a href="#editor" onClick={() => setOpen(false)}>The editor</a>
        <a href="#formats" onClick={() => setOpen(false)}>Canvas</a>
        <a href="./studio/" onClick={() => setOpen(false)}>Tab studio <ArrowUpRight size={14} /></a>
        <a className="nav-github" href={REPO} target="_blank" rel="noopener noreferrer" onClick={() => setOpen(false)}><GithubMark /><Star size={13} fill="currentColor" /> Star on GitHub</a>
      </nav>
      <button className="header-cta" type="button" onClick={onCopy} title="Copy the FocusFlow install command" aria-label={copied ? 'Install command copied' : 'Copy install command'}>{copied ? <Check size={15} /> : <Copy size={15} />} {copied ? 'Copied' : 'Download'}</button>
      <button className="menu-button" type="button" aria-label={open ? 'Close menu' : 'Open menu'} aria-expanded={open} onClick={() => setOpen(!open)}>
        {open ? <X size={22} /> : <Menu size={22} />}
      </button>
    </div>
  </header>
}

function DemoScreen() {
  return <div className="demo-screen">
    <div className="demo-top"><span className="demo-pill"><span /> LIVE PREVIEW</span><span>Presentation_01</span><span>•••</span></div>
    <div className="demo-content">
      <div className="demo-kicker">A BETTER WAY TO SHOW YOUR WORK</div>
      <div className="demo-title">Make every<br /><em>detail</em> count.</div>
      <div className="demo-lines"><i /><i /></div>
      <div className="demo-orbit orbit-one" /><div className="demo-orbit orbit-two" />
      <div className="demo-card"><span className="demo-card-icon"><Play size={13} fill="currentColor" /></span><span>From idea to impact<br /><small>See what matters</small></span></div>
    </div>
  </div>
}

function ProductWindow({ size = 2, ratio = '16:9', compact = false }) {
  const width = `${Math.round(size * 15 + 15)}px`
  return <div className={`product-window ${compact ? 'product-compact' : ''}`} aria-label="Illustration of the FocusFlow editor">
    <div className="product-titlebar"><div className="product-title-brand"><span className="product-app-icon"><MousePointer2 size={12} fill="white" /></span><strong>FocusFlow</strong><span className="product-divider" /> <span>Studio preview</span></div><div className="product-title-right"><span>↶</span><span>↷</span><span>⋯</span><span className="product-export"><ArrowUpRight size={12} /> Export video</span></div></div>
    <div className="product-body">
      <div className="product-rail"><div className="product-rail-item"><span>◉</span> Record</div><div className="product-rail-item"><FolderOpen size={12} /> Recordings</div><span className="product-rail-caption">STUDIO</span><div className="product-rail-item"><LayoutPanelLeft size={12} /> Canvas</div><div className="product-rail-item active"><MousePointer2 size={12} /> Cursor</div><div className="product-rail-item"><Sparkles size={12} /> Motion</div><div className="product-rail-item"><Video size={12} /> Camera</div></div>
      <div className="product-main"><div className="product-preview-top"><span>⛶ &nbsp; PREVIEW</span><span>{ratio} &nbsp; · &nbsp; 1920 × 1080</span></div><div className="product-stage"><div className="product-stage-inner"><DemoScreen /><div className="demo-cursor" style={{ width, height: width }}><span className="demo-click-ring"/><MousePointer2 size="100%" fill="white" stroke="#1c1c2e" strokeWidth={1.4}/></div></div></div><div className="product-transport"><span>↺</span><span className="product-play"><Play size={10} fill="currentColor" /></span><span>↻</span><small>00:08 / 00:24</small></div><div className="product-timeline"><div className="timeline-label">TIMELINE <span>2 effects</span></div><div className="timeline-ruler">00:00 <span>00:05</span><span>00:10</span><span>00:15</span></div><div className="timeline-track"><span className="timeline-track-head">Video</span><span className="timeline-track-block">Launch demo.mp4</span></div><div className="timeline-track"><span className="timeline-track-head">Zoom</span><span className="timeline-zoom-block">Click zoom</span></div><div className="timeline-playhead" /></div></div>
      <div className="product-inspector"><strong>Cursor</strong><div className="inspector-separator"/><span className="inspector-cap">CURSOR</span><div className="inspector-row"><span>Show cursor</span><span className="tiny-switch" /></div><div className="inspector-row"><span>Size</span><b>{size}×</b></div><div className="fake-slider"><span style={{ width: `${Math.min(86, size * 15)}%` }} /></div><div className="size-choices"><span>1×</span><span className={size === 2 ? 'selected' : ''}>2×</span><span className={size === 3 ? 'selected' : ''}>3×</span><span className={size === 4 ? 'selected' : ''}>4×</span></div><div className="inspector-separator"/><span className="inspector-cap">CLICK EFFECTS</span><div className="inspector-row"><span>Animate clicks</span><span className="tiny-switch" /></div><div className="inspector-row"><span>Animation</span><span className="fake-select">Ripple⌄</span></div><div className="effect-colors"><i/><i/><i/><i/></div></div>
    </div>
  </div>
}

function SectionIntro({ eyebrow, title, text, center = false }) {
  return <div className={`section-intro ${center ? 'center' : ''}`}><span className="eyebrow">{eyebrow}</span><h2>{title}</h2><p>{text}</p></div>
}

function App() {
  const [cursorSize, setCursorSize] = useState(2)
  const [clickStyle, setClickStyle] = useState('Ripple')
  const [ratio, setRatio] = useState('16:9')
  const [copyStatus, setCopyStatus] = useState('idle')
  async function copyInstall() {
    try {
      let worked = false
      if (navigator.clipboard?.writeText) {
        try { await navigator.clipboard.writeText(INSTALL); worked = true } catch { /* Try the selection fallback. */ }
      }
      if (!worked) {
        const field = document.createElement('textarea')
        field.value = INSTALL
        field.style.position = 'fixed'
        field.style.opacity = '0'
        document.body.appendChild(field)
        field.select()
        worked = document.execCommand('copy')
        field.remove()
        if (!worked) throw new Error('Copy failed')
      }
      setCopyStatus('copied')
      window.setTimeout(() => setCopyStatus('idle'), 3000)
    } catch {
      setCopyStatus('failed')
    }
  }
  return <>
    <Header onCopy={copyInstall} copied={copyStatus === 'copied'} />
    <div className={`copy-toast ${copyStatus === 'idle' ? '' : 'visible'}`} role="status" aria-live="polite">
      {copyStatus === 'copied' ? <><Check size={16} /> Install command copied. Paste it in Terminal.</> : copyStatus === 'failed' ? 'Copy failed. Select the command below to copy it.' : ''}
    </div>
    <main>
      <section className="hero wrap" aria-labelledby="hero-title">
        <div className="hero-copy"><div className="hero-announcement"><span className="announcement-dot" /> THE SCREEN RECORDER WITH AN EDITOR INSIDE <ArrowUpRight size={13}/></div><h1 id="hero-title">Make your screen<br />worth <em>watching.</em></h1><p>Record on your Mac. Give clicks the focus they deserve. Shape a polished video without leaving the editor.</p><div className="hero-actions"><CopyInstallButton onCopy={copyInstall} copied={copyStatus === 'copied'} /><DmgDownload /></div><div className="hero-proof"><span className="proof-icon"><Check size={12}/></span> Free &amp; open source <span className="proof-divider"/> macOS 14+ · Apple silicon</div></div>
        <div className="hero-product"><div className="hero-glow" /><div className="hero-product-inner"><div className="float-note note-one"><span><MousePointerClick size={16}/></span> Clicks become zooms</div><ProductWindow size={cursorSize} ratio={ratio}/><div className="float-note note-two"><span><Ratio size={16}/></span> Every ratio, one recording</div></div><p className="hero-caption">A focused workspace for everything after you press record.</p></div>
      </section>

      <div className="marquee"><div className="wrap marquee-inner"><span>ONE CONTINUOUS WORKFLOW</span><span>Capture</span><i/><span>Focus</span><i/><span>Finish</span><i/><span>Share</span></div></div>

      <section id="how" className="section workflow wrap"><SectionIntro eyebrow="01 / THE WORKFLOW" title={<>From recording to <em>ready.</em></>} text="The small steps between capture and a good video belong in one place." /><div className="workflow-grid"><article><div className="step-head"><span>01</span><Monitor size={21}/></div><h3>Record exactly what you need.</h3><p>Choose a window, a display, or a single Chrome tab. Add camera and microphone only when you want them.</p><div className="step-tags"><span>Window</span><span>Display</span><span>Chrome tab</span></div></article><article><div className="step-head"><span>02</span><MousePointerClick size={21}/></div><h3>Let clicks guide the eye.</h3><p>Click activity becomes smooth zooms. Resize the recorded cursor, style the click, or place focus by hand.</p><div className="step-tags"><span>Auto zoom</span><span>Cursor</span><span>Click effects</span></div></article><article><div className="step-head"><span>03</span><Clapperboard size={21}/></div><h3>Make it feel finished.</h3><p>Frame the content, set your canvas, trim the timeline, then export an MP4 or MOV for wherever it goes next.</p><div className="step-tags"><span>Canvas</span><span>Timeline</span><span>Export</span></div></article></div></section>

      <section id="editor" className="section cursor-feature"><div className="wrap feature-grid"><div className="feature-copy"><span className="eyebrow">02 / THE CURSOR</span><h2>A pointer people<br />can <em>actually follow.</em></h2><p>Make the cursor larger after a native recording. Give every click a subtle ripple, pulse, or press so the action never gets lost.</p><ul className="tick-list"><li><Check size={16}/> Size from 0.5× to 6×</li><li><Check size={16}/> Click animations and soft highlights</li><li><Check size={16}/> Styled in the preview and final export</li></ul><div className="feature-note"><CircleHelp size={16}/> Cursor resizing uses a separate pointer track from native Window or Display recordings.</div></div><div className="cursor-playground"><div className="playground-head"><span>TRY THE CURSOR</span><span className="live-pill"><i/> LIVE PREVIEW</span></div><div className="playground-canvas"><div className="playground-caption">Small details.<br /><em>Big difference.</em></div><div className="playground-pointer" style={{ transform: `translate(-50%, -50%) scale(${0.65 + cursorSize * 0.28})` }}><div className={clickStyle === 'Press' ? 'pointer-ring press' : 'pointer-ring'} /><MousePointer2 size={52} fill="#fff" stroke="#1b1b2e" strokeWidth={1.4} /></div><div className="playground-grid" /></div><div className="playground-controls"><div className="control-top"><label htmlFor="cursor-size">Cursor size</label><strong>{cursorSize.toFixed(1)}×</strong></div><input id="cursor-size" type="range" min="0.5" max="6" step="0.1" value={cursorSize} onChange={e => setCursorSize(Number(e.target.value))}/><div className="control-bottom"><span>0.5×</span><span>6×</span></div><div className="effect-picker"><span>Click effect</span><div>{['Ripple','Pulse','Press'].map(style => <button key={style} className={clickStyle === style ? 'is-selected' : ''} onClick={() => setClickStyle(style)} type="button">{style}</button>)}</div></div></div></div></div></section>

      <section id="formats" className="section formats wrap"><div className="feature-grid format-grid"><div className="format-art"><div className="format-art-top"><span>CANVAS PREVIEW</span><span>{ratio === 'Custom' ? '21:9' : ratio}</span></div><div className={`format-stage ${ratios.find(r => r.label === ratio)?.className || 'landscape'}`}><div className="format-image"><div className="format-image-top"><i/><i/><i/><span>Project overview</span></div><div className="format-image-body"><div className="format-mini-title">Thoughtful work<br /><em>deserves the frame.</em></div><div className="format-mini-card"><span>01</span><span>Clearer stories start here.</span></div></div></div></div><div className="ratio-options" role="group" aria-label="Preview aspect ratio">{ratios.map(r => <button type="button" key={r.label} className={ratio === r.label ? 'active' : ''} aria-pressed={ratio === r.label} onClick={() => setRatio(r.label)}>{r.label}</button>)}</div></div><div className="feature-copy"><span className="eyebrow">03 / THE CANVAS</span><h2>One recording.<br /><em>Every frame.</em></h2><p>Go wide for a presentation, square for a feed, or vertical for a short. Custom proportions give you precise control over the final frame.</p><ul className="tick-list"><li><Check size={16}/> 16:9, 9:16, 1:1, 4:3 and custom</li><li><Check size={16}/> One-tap presets and width/height controls</li><li><Check size={16}/> Backgrounds, padding and a native Mac frame</li></ul><a className="inline-link" href="#download">Get the app <ArrowUpRight size={17}/></a></div></div></section>

      <section className="section detail-section"><div className="wrap"><SectionIntro eyebrow="04 / THE DETAILS" title={<>The finish is in the <em>details.</em></>} text="A quiet editor with the tools you need, available when you need them." center /><div className="detail-grid"><article><div className="detail-icon"><WandSparkles size={21}/></div><h3>Motion with purpose</h3><p>Automatic click zooms, pans, entrances, spotlights and callouts help guide attention.</p></article><article><div className="detail-icon"><Scissors size={21}/></div><h3>A practical timeline</h3><p>Trim, split, duplicate, move and resize effects with undo close at hand.</p></article><article><div className="detail-icon"><LayoutPanelLeft size={21}/></div><h3>Your visual system</h3><p>Pick a solid color, gradient, image, or a softly blurred version of the recording itself.</p></article><article><div className="detail-icon"><Fullscreen size={21}/></div><h3>Preview in full</h3><p>Step away from controls and see the video at full screen before it leaves your Mac.</p></article></div></div></section>

      <section className="section privacy"><div className="wrap privacy-inner"><div><span className="eyebrow">BUILT FOR YOUR MAC</span><h2>Your work stays<br /><em>your work.</em></h2><p>FocusFlow is a native macOS app. Recordings and projects save locally, and the browser tab companion passes your capture back to the editor on your Mac.</p><a className="privacy-link" href={REPO}>See the source on GitHub <ArrowUpRight size={18}/></a></div><div className="privacy-card"><div className="privacy-symbol"><LockKeyhole size={34}/></div><div className="privacy-card-line"><FolderOpen size={18}/><span>Files saved on your Mac</span><Check size={17}/></div><div className="privacy-card-line"><ShieldCheck size={18}/><span>Local recording handoff</span><Check size={17}/></div><div className="privacy-card-line"><Command size={18}/><span>Open source</span><Check size={17}/></div><small>No account required to record or edit.</small></div></div></section>

      <section id="download" className="section download wrap"><span className="eyebrow">READY WHEN YOU ARE</span><h2>Make the next one<br /><em>impossible to miss.</em></h2><p>Free and open source for macOS 14+ on Apple silicon.</p><div className="download-actions"><CopyInstallButton onCopy={copyInstall} copied={copyStatus === 'copied'} /><DmgDownload /></div><div className="install-card"><div><span>Install with Terminal</span><code>{INSTALL}</code></div><button type="button" onClick={copyInstall} aria-label={copyStatus === 'copied' ? 'Command copied' : 'Copy install command'}>{copyStatus === 'copied' ? <><Check size={16}/> Copied</> : <><Copy size={16}/> Copy</>}</button></div><p className="install-note">Download uses the latest GitHub release. If you choose the disk image, open FocusFlow from the mounted .dmg.</p></section>
    </main>
    <footer className="footer"><div className="wrap footer-inner"><Brand/><p>Record clearly. Edit calmly. Share confidently.</p><div><a href={REPO}>GitHub</a><a href={RELEASE}>Releases</a><a href="./studio/">Tab studio</a></div></div></footer>
  </>
}

export default App
