#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
node - "$ROOT_DIR" <<'NODE'
const fs = require('fs'), path = require('path'), assert = require('assert');
const root = process.argv[2];
const dir = path.join(root, 'rootfs/www/luci-static/resources');
const files = [path.join(dir, 'mihowrt/api.js'), ...fs.readdirSync(path.join(dir, 'view/mihowrt')).map(f => path.join(dir, 'view/mihowrt', f))];
const strings = new Set();
const literal = "'(?:[^'\\\\]|\\\\.)*'";
const decode = s => Function('return ' + s)();
for (const file of files) {
 const source = fs.readFileSync(file, 'utf8');
 for (const m of source.matchAll(new RegExp('(?<![\\w])_\\(\\s*(' + literal + ')', 'g'))) strings.add(decode(m[1]));
 for (const m of source.matchAll(new RegExp('N_\\([^,]+,\\s*(' + literal + '),\\s*(' + literal + ')', 'g'))) { strings.add(decode(m[1])); strings.add(decode(m[2])); }
}
const po = fs.readFileSync(path.join(root, 'po/ru/mihowrt.po'), 'utf8');
const catalog = new Set();
for (const m of po.matchAll(/^msgid(?:_plural)? (".*")(?:\n".*")*/gm)) {
 const value = m[0].replace(/^msgid(?:_plural)? /, '').split('\n').map(s => JSON.parse(s)).join('');
 if (value) {
  assert(!catalog.has(value), 'duplicate msgid: ' + value);
  catalog.add(value);
 }
}
const missing = [...strings].filter(s => !catalog.has(s));
const obsolete = [...catalog].filter(s => !strings.has(s) && !['Overview'].includes(s));
assert.deepStrictEqual(missing, [], 'missing translations');
assert.deepStrictEqual(obsolete, [], 'obsolete translations');
assert(po.includes('Plural-Forms: nplurals=3;'), 'Russian plural header');
for (const [id, translated] of [
 ['Service is running', 'Служба MihoWRT работает'],
 ['Install dashboard', 'Установить панель Mihomo'],
 ['Remove dashboard', 'Удалить панель Mihomo'],
 ['Test', 'Проверить отклик'],
 ['Remote lists', 'Списки по ссылкам'],
 ['Update remote lists', 'Обновить списки по ссылкам'],
 ['Starts at boot', 'Запускается при включении роутера'],
 ['System log is not available.', 'Журнал недоступен.'],
 ['Traffic mode', 'Режим маршрутизации'],
 ['Update now', 'Обновить подписку']
]) assert(po.includes('msgid ' + JSON.stringify(id) + '\nmsgstr ' + JSON.stringify(translated)), 'glossary: ' + id);

const msgstrs = [...po.matchAll(/msgstr(?:\[\d+\])?\s+(".*"(?:\s*\n".*")*)/g)].map(m => m[1]);
msgstrs.push(JSON.stringify(fs.readFileSync(path.join(root, 'README.ru.md'), 'utf8')));
for (const str of msgstrs) {
 const text = JSON.parse('[' + str.replace(/\n/g, ',') + ']').join('');
 assert(!/(?:GiB|MiB|KiB|ГиБ|МиБ|КиБ)/.test(text), 'forbidden GiB/MiB/KiB in Russian translation: ' + text);
 assert(!/удалённ\S*\s+списк/i.test(text), 'forbidden удалённые списки in Russian translation: ' + text);
 assert(!/(?:профил|провайдер|прокси-сервер|Обновить сейчас|веб-панел|системный журнал)/i.test(text), 'forbidden glossary term: ' + text);
 const serviceMatches = [...text.matchAll(/(?<!VPN-)[Сс]ервис\S*/gi)];
 assert.strictEqual(serviceMatches.length, 0, 'forbidden сервис (as MihoWRT) in Russian translation: ' + text);
}

console.log('ok - exact JS translation catalog including plurals');
NODE
