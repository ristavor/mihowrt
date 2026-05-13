'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const rootDir = path.resolve(__dirname, '..');

function sourcePath(relativePath) {
	return path.join(rootDir, relativePath);
}

function readSource(relativePath) {
	return fs.readFileSync(sourcePath(relativePath), 'utf8');
}

function createContext(globals = {}) {
	const context = Object.assign({
		console,
		Date,
		Math,
		Promise,
		URLSearchParams,
		clearTimeout,
		setTimeout,
		baseclass: { extend: value => value },
		_: value => value
	}, globals);

	vm.createContext(context);
	vm.runInContext(`
if (!String.prototype.format) {
	String.prototype.format = function() {
		let i = 0;
		const args = arguments;
		return this.replace(/%[ds]/g, () => String(args[i++]));
	};
}
`, context);

	return context;
}

function evaluateLuCIModule(relativePath, globals = {}) {
	const source = readSource(relativePath);
	const context = createContext(globals);
	const names = Object.keys(context);
	const wrapper = `(function(${names.join(',')}) {\n${source}\n})`;
	const fn = vm.runInContext(wrapper, context, { filename: sourcePath(relativePath) });
	const module = fn(...names.map(name => context[name]));

	return { context, module, source };
}

function extractBetween(source, start, end, label = start) {
	const startIndex = source.indexOf(start);
	if (startIndex === -1)
		throw new Error(`${label} not found`);

	const endIndex = source.indexOf(end, startIndex);
	if (endIndex === -1)
		throw new Error(`${label} end not found`);

	return source.slice(startIndex, endIndex).trim();
}

function assert(condition, message) {
	if (!condition)
		throw new Error(message);
}

function assertEq(actual, expected, message) {
	if (actual !== expected)
		throw new Error(`${message}: expected '${expected}', got '${actual}'`);
}

module.exports = {
	assert,
	assertEq,
	createContext,
	evaluateLuCIModule,
	extractBetween,
	readSource,
	rootDir,
	sourcePath
};
