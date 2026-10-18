import React from 'react';
import Signature from '@site/src/components/Signature';

// Replaces the stock multi-column Infima footer. bbaker.dev's own footer is
// just the traced signature linking home; this docs site does the same,
// the only place that mark appears.
export default function FooterWrapper() {
  return (
    <footer className="footer footer--light">
      <div className="container">
        <div className="bb-foot">
          <a href="https://bbaker.dev" aria-label="Brandon Baker">
            <Signature />
          </a>
        </div>
      </div>
    </footer>
  );
}
