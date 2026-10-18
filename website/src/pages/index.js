import React from 'react';
import Layout from '@theme/Layout';
import Link from '@docusaurus/Link';
import useBaseUrl from '@docusaurus/useBaseUrl';
import styles from './index.module.css';

function ArrowIcon(props) {
  return (
    <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" {...props}>
      <path d="M5 12h14" />
      <path d="M13 6l6 6-6 6" />
    </svg>
  );
}

const BACKENDS = [
  { os: 'macOS (arm64)', backend: 'Native Metal, 4x MSAA' },
  { os: 'Linux (x64)', backend: 'OpenGL ES over EGL (Mesa)' },
  { os: 'Windows (x64)', backend: 'OpenGL ES over ANGLE (Direct3D 11)' },
];

const DOCS = [
  { href: '/docs/intro', title: 'Introduction', dek: 'Why this exists and what it is today.' },
  { href: '/docs/getting-started', title: 'Get started', dek: 'Install the package, add the platform to your app, and run it.' },
  { href: '/docs/guides/how-it-works', title: 'How it works', dek: 'Fabric, the scene graph, the raster thread, engine resolution.' },
  { href: '/docs/reference/supported-components-and-style-props', title: 'Supported components and style props', dek: "What renders today, and what's still gated off." },
  { href: '/docs/reference/platforms-and-requirements', title: 'Platforms and requirements', dek: 'Backend and OS requirements for Linux, macOS, and Windows.' },
  { href: '/docs/contributing-and-releasing', title: 'Contributing and releasing', dek: 'Gates, mutation-verify, commit conventions, and how a release ships.' },
];

export default function Home() {
  return (
    <Layout
      title="react-native-impeller-platform"
      description="An out-of-tree React Native platform rendered through Flutter's Impeller engine, for Linux, macOS, and Windows."
    >
      <header className={styles.hero}>
        <div className={styles.heroInner}>
          <div className={styles.heroId}>
            <h1 className={styles.title}>React Native, rendered through Impeller</h1>
            <p className={styles.lede}>
              An out-of-tree React Native platform. Fabric's view tree drives an embedded
              C++ renderer built on Flutter's Impeller engine, so the same app runs on
              desktop targets React Native doesn't support on its own.
            </p>
            <div className={styles.ctas}>
              <Link className={styles.ctaPrimary} to={useBaseUrl('/docs/getting-started')}>
                Get started <ArrowIcon />
              </Link>
              <Link className={styles.ctaSecondary} to="https://github.com/blbaker/react-native-impeller-platform">
                View source
              </Link>
            </div>
          </div>
          <div className={styles.heroDiagram}>
            <ArchDiagram />
          </div>
        </div>
      </header>

      <main>
        <section className={styles.section}>
          <div className={styles.sectionHead}>
            <h2 className={styles.sectionTitle}>Why this exists</h2>
            <p className={styles.sectionIntro}>
              React Native creates matching native views on iOS and Android. Every
              other platform needs someone to build that layer.
            </p>
          </div>
          <div className={styles.prose}>
            <p>
              React Native's own docs list partner platforms for macOS and Windows.
              For Linux they point to a renderer built on Skia whose README still
              calls it a proof of concept, with no commit since March 2023.
            </p>
            <p>
              This platform renders on Linux, macOS, and Windows through Impeller
              instead of Skia. Flutter built Impeller to fix the problems it had
              with Skia, and it now ships as a standalone SDK with a C API meant
              for projects outside Flutter: a prebuilt binary for every Flutter
              commit, text layout and shaping included, and shaders compiled ahead
              of time so nothing compiles at runtime. It already renders a React
              Native app in daily use.
            </p>
          </div>
        </section>

        <section className={styles.section}>
          <div className={styles.sectionHead}>
            <h2 className={styles.sectionTitle}>Platforms</h2>
            <p className={styles.sectionIntro}>
              Each OS gets the same graphics backend Flutter ships there.
            </p>
          </div>
          <ul className={styles.backendList}>
            {BACKENDS.map((b) => (
              <li key={b.os} className={styles.backendRow}>
                <span className={styles.backendOs}>{b.os}</span>
                <span className={styles.backendDetail}>{b.backend}</span>
              </li>
            ))}
          </ul>
        </section>

        <section className={styles.section}>
          <div className={styles.sectionHead}>
            <h2 className={styles.sectionTitle}>Read the docs</h2>
          </div>
          <ul className={styles.docList}>
            {DOCS.map((d) => (
              <li key={d.href} className={styles.docRow}>
                <Link className={styles.docLink} to={useBaseUrl(d.href)}>
                  <span className={styles.docTitle}>{d.title}</span>
                  <span className={styles.docDek}>{d.dek}</span>
                </Link>
              </li>
            ))}
          </ul>
        </section>
      </main>
    </Layout>
  );
}

// A plain flow diagram of the render path, drawn from the real architecture
// (see docs/how-it-works): JS/Fabric commits, the platform thread mounts,
// a raster thread builds the Impeller display list and presents it.
function ArchDiagram() {
  return (
    <svg viewBox="0 0 360 220" width="100%" height="auto" className={styles.diagramSvg} role="img" aria-label="JS thread commits to the platform thread, which hands a frame to the raster thread, which presents through Impeller.">
      <g className={styles.diagramNode}>
        <rect x="8" y="12" width="150" height="44" rx="8" />
        <text x="83" y="30" textAnchor="middle" className={styles.diagramLabel}>JS thread</text>
        <text x="83" y="46" textAnchor="middle" className={styles.diagramSub}>Hermes, React, Fabric commit</text>
      </g>
      <g className={styles.diagramNode}>
        <rect x="8" y="88" width="150" height="44" rx="8" />
        <text x="83" y="106" textAnchor="middle" className={styles.diagramLabel}>Platform thread</text>
        <text x="83" y="122" textAnchor="middle" className={styles.diagramSub}>mount + scene graph</text>
      </g>
      <g className={styles.diagramNode}>
        <rect x="8" y="164" width="150" height="44" rx="8" />
        <text x="83" y="182" textAnchor="middle" className={styles.diagramLabel}>Raster thread</text>
        <text x="83" y="198" textAnchor="middle" className={styles.diagramSub}>display list -&gt; present</text>
      </g>
      <g className={styles.diagramNode} data-accent="true">
        <rect x="202" y="88" width="150" height="44" rx="8" />
        <text x="277" y="106" textAnchor="middle" className={styles.diagramLabel}>Impeller</text>
        <text x="277" y="122" textAnchor="middle" className={styles.diagramSub}>Metal / GLES per OS</text>
      </g>
      <path d="M83 56 V88" className={styles.diagramArrow} markerEnd="url(#arrow)" />
      <path d="M83 132 V164" className={styles.diagramArrow} markerEnd="url(#arrow)" />
      <path d="M158 186 H202 V132" className={styles.diagramArrow} markerEnd="url(#arrow)" />
      <defs>
        <marker id="arrow" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
          <path d="M0 0L10 5L0 10z" className={styles.diagramArrowHead} />
        </marker>
      </defs>
    </svg>
  );
}
