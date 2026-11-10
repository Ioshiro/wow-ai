'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');

function render(source) {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);
  function run(code) {
    if (lauxlib.luaL_dostring(L, to_luastring(code)) !== lua.LUA_OK) {
      throw new Error(to_jsstring(lua.lua_tostring(L, -1)));
    }
  }
  try {
    run(fs.readFileSync(path.join(__dirname, '../addon/WoWAI/Markdown.lua'), 'utf8'));
    lua.lua_pushstring(L, to_luastring(source));
    lua.lua_setglobal(L, to_luastring('SOURCE'));
    run('ROWS = WoWAI_Markdown.Render(SOURCE)');
    lua.lua_getglobal(L, to_luastring('ROWS'));
    const rows = [];
    for (let i = 1; i <= lua.lua_rawlen(L, -1); i++) {
      lua.lua_rawgeti(L, -1, i);
      const row = {};
      for (const field of ['kind', 'text', 'depth']) {
        lua.lua_getfield(L, -1, to_luastring(field));
        if (!lua.lua_isnil(L, -1)) row[field] = field === 'depth' ? lua.lua_tonumber(L, -1) : to_jsstring(lua.lua_tostring(L, -1));
        lua.lua_pop(L, 1);
      }
      rows.push(row);
      lua.lua_pop(L, 1);
    }
    return rows;
  } finally {
    lua.lua_close(L);
  }
}

test('fenced code retains whitespace and literal markdown instead of formatting commands', () => {
  const rows = render('## Result\n\n```lua\n  local value = "**literal**"\n\treturn value\n```\n\nDone.');
  assert.deepEqual(rows.filter(row => row.kind === 'code').map(row => row.text), ['  local value = "**literal**"', '\treturn value']);
  assert.ok(rows.some(row => row.kind === 'h' && row.text.includes('Result')));
  assert.ok(rows.some(row => row.kind === 'p' && row.text.includes('Done.')));
});

test('untrusted WoW hyperlinks and textures cannot become active escape sequences', () => {
  const text = render('Reply |Hitem:123|h[click]|h and |Tbad:64|t, café.').map(row => row.text).join('\n');
  assert.doesNotMatch(text.replace(/\|\|/g, ''), /\|[HT]/);
  assert.ok(text.includes('café'));
});

test('nested lists retain depth and table content survives the header separator', () => {
  const rows = render('- Parent\n  - Child\n\n| Name | State |\n| --- | --- |\n| Alpha | Ready |');
  const list = rows.filter(row => row.kind === 'li');
  assert.equal(list.length, 2);
  assert.ok(list[1].depth > list[0].depth);
  const table = rows.filter(row => row.kind === 'tr').map(row => row.text).join('\n');
  assert.ok(table.includes('Name'));
  assert.ok(table.includes('Alpha'));
  assert.ok(table.includes('Ready'));
  assert.ok(!table.includes('---'));
});
