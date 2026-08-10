'use strict';
const {initImpeller} = require('./init');
const {runImpeller} = require('./run');

const commands = [
  {
    name: 'init-impeller',
    description: 'Scaffold the impeller/ folder into this React Native app',
    options: [{name: '--force', description: 'Overwrite existing scaffolded files'}],
    func: (argv, config, args) => initImpeller(argv, config, {force: Boolean(args && args.force)}),
  },
  {
    name: 'run-impeller',
    description: 'Bundle with Metro (platform=impeller) and launch the Impeller engine',
    options: [{name: '--release', description: 'Build a production bundle'}],
    func: (argv, config) => runImpeller(argv, config, {}),
  },
];

module.exports = {commands, initImpeller, runImpeller};
