/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
const sidebars = {
  docs: [
    'intro',
    'getting-started',
    {
      type: 'category',
      label: 'Guides',
      collapsed: false,
      items: [
        'guides/how-it-works',
        'guides/styling',
        'guides/fonts-and-text',
        'guides/debugging',
        'guides/building-the-engine-from-source',
      ],
    },
    {
      type: 'category',
      label: 'Reference',
      collapsed: false,
      items: [
        'reference/cli',
        'reference/engine-binary-flags',
        'reference/supported-components-and-style-props',
        'reference/platforms-and-requirements',
      ],
    },
    'contributing-and-releasing',
  ],
};

module.exports = sidebars;
