'use strict';
const fs = require('node:fs');
const path = require('node:path');

// Use the game's load order so extracted modules are exercised by every VM.
module.exports = function addonFiles(directory) {
  return fs.readFileSync(path.join(directory, 'WoWAI.toc'), 'utf8')
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(line => line && !line.startsWith('#') && /\.lua$/i.test(line))
    .map(line => line.replace(/\\/g, '/'));
};
